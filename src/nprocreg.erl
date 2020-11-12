% vim: ts=4 sw=4 et
% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2010 Rusty Klophaus
% Copyright (c) 2013-2020 Jesse Gumm
% See MIT-LICENSE for licensing information.

-module (nprocreg).
-behaviour (gen_server).
-include("nprocreg.hrl").

-export([
    start_link/0,
    get_pid/1,
    get_pid/2,
    get_status/0,
    register_pid/2,
    unregister_key/1,
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(TABLE, nprocreg_data).
-define(INDEX, nprocreg_index).
-define(NODE_CACHE, nprocreg_nodes).
-define(COLLECT_TIMEOUT, timer:seconds(2)).
-define(NODE_CHATTER_INTERVAL, timer:seconds(5)).
-define(NODE_TIMEOUT, timer:seconds(10)).
-define(PRINT(Var), error_logger:info_msg("DEBUG: ~p:~p~n~p~n  ~p~n", [?MODULE, ?LINE, ??Var, Var])).
-define(RPC_TIMEOUT, 1000).

-record(state, {
        nodes=[]    :: [{node(), last_contact()}]
    }).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get_pid(key()) -> undefined | pid().
get_pid(Key) ->
    get_pid(Key, undefined).

-spec get_pid(key(), undefined | fun()) -> undefined | pid().
get_pid(Key, Function) ->
    %% Try to get the pid from the expected Node first. If that doesn't work,
    %% then try to get the pid from one of the other nodes. If we don't find
    %% anything and is_function(Function) == true, then spawn off a new
    %% function on the current node.

    %% This will be a list of nodes, with the first node being the most likely
    %% candidate for Key
    {ExpectedNode, OtherNodes} = get_nodes(Key),

    case get_pid_from_nodes([ExpectedNode | OtherNodes], Key) of
        {ok, Pid} ->
            Pid;
        undefined ->
            maybe_start_function_on_node(ExpectedNode, Key, Function)
    end.

-spec register_pid(key(), pid()) -> ok.
register_pid(Key, Pid) ->
    gen_server:cast({?SERVER, node()}, {register_pid, Key, Pid}).

-spec unregister_key(key()) -> ok.
unregister_key(Key) ->
    gen_server:cast({?SERVER, node()}, {unregister_key, Key}).
     

-spec get_pid_from_nodes([node()], key()) -> undefined | {ok, pid()}.      
get_pid_from_nodes([], _ ) ->
    undefined;
get_pid_from_nodes([Node | Nodes], Key) ->
    case get_pid_from_node(Node, Key) of
        {ok, Pid} ->
            {ok, Pid};
        undefined ->
            get_pid_from_nodes(Nodes, Key)
    end.

-spec get_pid_from_node(node(), key()) -> undefined | {ok, pid()}.
get_pid_from_node(Node,Key) when Node==node() ->
    format_lookup(ets:lookup(?TABLE, Key));
get_pid_from_node(Node, Key) ->
    format_lookup(rpc:call(Node, ets, lookup, [?TABLE, Key], ?RPC_TIMEOUT)).

format_lookup([]) ->
    undefined;
format_lookup({badrpc, _}) ->
    undefined;
format_lookup([{_Key, Pid}]) ->
    {ok, Pid}.

-spec get_nodes() -> [node()].
%% @doc Get the list of nodes that are alive, sorted in ascending order...
get_nodes() ->
    simple_cache:get(?NODE_CACHE, 1000, nodes, fun() ->
        lists:sort([Node || Node <- gen_server:call(?SERVER, get_nodes),
            (net_adm:ping(Node)=:=pong orelse Node=:=node())])
    end).

-spec maybe_start_function_on_node(node(), key(), fun() | undefined) -> undefined | {ok, pid()}.
maybe_start_function_on_node(_Node, _Key, undefined) ->
    undefined;
maybe_start_function_on_node(Node, Key, Fun) when is_function(Fun, 0) ->
    start_function_on_node(Node, Key, Fun).

-spec start_function_on_node(node(), key(), fun() | undefined) -> {ok, pid()}.
start_function_on_node(Node , Key, Function) ->
    gen_server:call({?SERVER, Node}, {start_function, Key, Function}).

-spec get_nodes(key()) -> {node(), [node()]}.
%% @doc Retrieves a list of nodes, with the first node being the most likely
%%      candidate for the pid associated with Key
get_nodes(Key) ->
    Nodes = get_nodes(),

    %% Get an MD5 of the Key...
    <<Int:128/integer>> = crypto:hash(md5, term_to_binary(Key)),

    %% Hash to a node...
    N = (Int rem length(Nodes)) + 1,
    ExpectedNode = lists:nth(N, Nodes),
    OtherNodes = lists:delete(ExpectedNode,Nodes),
    {ExpectedNode, OtherNodes}.

-spec get_status() -> integer().
get_status() ->
    _Status = gen_server:call(?SERVER, get_status).
    
-spec init(term()) -> {ok, #state{}}.
init(_) -> 
    simple_cache:init(?NODE_CACHE),

    %% Broadcast to all nodes at intervals...
    gen_server:cast(?SERVER, broadcast_node),
    timer:apply_interval(?NODE_CHATTER_INTERVAL, gen_server, cast, [?SERVER, broadcast_node]),
    ?TABLE = ets:new(?TABLE, [named_table, set, protected, {keypos, 1}, {read_concurrency, true}]),
    ?INDEX = ets:new(?INDEX, [named_table, set, protected, {keypos, 1}, {read_concurrency, true}]),
    {ok, #state{ nodes=[{node(), never_expire}] }}.

-spec handle_call(Call  :: get_status
                        | get_nodes 
                        | invalid_message, From :: term(), #state{})
                        -> {reply, Reply :: {ok, pid()} | [node()] | integer(), #state{}}.
handle_call(get_status, _From, State = #state{}) ->
    NumLocalPids = ets:info(?TABLE, size),
    {reply, NumLocalPids, State};

handle_call(get_nodes, _From, State) ->
    Nodes = [Node || {Node, _} <- State#state.nodes],
    {reply, Nodes, State};

handle_call({start_function, Key, Function}, _From, State) ->
    {Pid, _Monitor} = erlang:spawn_monitor(Function),
    store_key(Key, Pid),
    {reply, Pid, State};

handle_call(Message, From, State) ->
    error_logger:error_msg("Unhandled Call from ~p: ~p~n",[From,Message]),
     {reply, invalid_message, State}.

-spec handle_cast(Cast  :: {register_node, node()}
                        | {start_function, key(), fun()} 
                        | {get_pid, key()}
                        | broadcast_node, #state{}) -> {noreply, #state{}}.
handle_cast({register_node, Node}, State) ->
    %% Register that we heard from a node. Set the last checkin time to now().
    Nodes = State#state.nodes,
    NewNodes = lists:keystore(Node, 1, Nodes, {Node, os:timestamp()}),
    NewState = State#state { nodes=NewNodes },
    {noreply, NewState};

handle_cast(broadcast_node, State) ->
    %% Remove any nodes that haven't contacted us in a while...
    F = fun({_Node, LastContact}) ->
        (LastContact == never_expire) orelse
        (timer:now_diff(os:timestamp(), LastContact) / 1000) < ?NODE_TIMEOUT
    end,
    NewNodes = lists:filter(F, State#state.nodes),

    %% Alert all nodes that we are here...
    gen_server:abcast(nodes(), ?SERVER, {register_node, node()}),
    {noreply, State#state { nodes=NewNodes }};

handle_cast({register_pid, Key, Pid}, State) ->
    erlang:monitor(process, Pid),
    store_key(Key, Pid),
    {noreply, State};

handle_cast({unregister_key, Key}, State) ->
    delete_key(Key),
    %% TODO: Store the monitor and use demonitor as well. Not essential right now.
    {noreply, State};

handle_cast(Message, State) -> 
    error_logger:error_msg("Unhandled Cast: ~p~n",[Message]),
    {noreply, State}.

store_key(Key, Pid) ->
    ets:insert(?TABLE, {Key, Pid}),
    ets:insert(?INDEX, {Pid, Key}).


-spec handle_info(Info  :: {'DOWN', term(), process, pid(), _Info :: any()}
                        | any(), #state{})
                    -> {noreply, #state{}}.
%% @private
handle_info({'DOWN', _MonitorRef, _Type, Pid, _Info}, State) ->
    %% A process died, so remove it from our list of pids.
    delete_pid(Pid),
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.

delete_pid(Pid) ->
    case ets:lookup(?INDEX, Pid) of
        [{Pid, Key}] ->
            ets:delete(?TABLE, Key),
            ets:delete(?INDEX, Pid);
        [] ->
            ok
    end.

delete_key(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{Key, Pid}] ->
            ets:delete(?TABLE, Key),
            ets:delete(?INDEX, Pid);
        [] ->
            ok
    end.
