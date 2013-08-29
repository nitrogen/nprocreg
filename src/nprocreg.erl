% vim: ts=4 sw=4 et
% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2010 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (nprocreg).
-behaviour (gen_server).

-export([
    start_link/0,
    get_pid/1,
    get_pid/2,
    get_status/0,
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).
-define(COLLECT_TIMEOUT, timer:seconds(2)).
-define(NODE_CHATTER_INTERVAL, timer:seconds(5)).
-define(NODE_TIMEOUT, timer:seconds(10)).
-define(PRINT(Var), error_logger:info_msg("DEBUG: ~p:~p~n~p~n  ~p~n", [?MODULE, ?LINE, ??Var, Var])).
-record(state, { nodes=[], pids=[] }).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

get_pid(Key) ->
    get_pid(Key, undefined).

get_pid(Key, Function) ->
    %% Try to get the pid from the expected Node first. If that doesn't work, then
    %% try to get the pid from one of the other nodes. If we don't
    %% find anything and is_function(Function) == true, then spawn off
    %% a new function on the current node.

    %% This will be a list of nodes, with the first node being the most likely candidate for Key
    {ExpectedNode, OtherNodes} = get_nodes(Key),

    case get_pid_from_nodes([ExpectedNode | OtherNodes], Key) of
        {ok, Pid} ->
            Pid;
        undefined ->
            if
                Function == undefined ->
                    undefined;
                is_function(Function) ->
                    start_function_on_node(ExpectedNode, Key, Function)
            end
    end.

get_pid_from_nodes([], _) ->
    undefined;
get_pid_from_nodes([Node | Nodes], Key) ->
    case get_pid_from_node(Node, Key) of
        {ok, Pid} ->
            {ok, Pid};
        undefined ->
            get_pid_from_nodes(Nodes, Key)
    end.

get_pid_from_node(Node,Key) ->
    gen_server:call({?SERVER, Node}, {get_pid, Key}).

%% Get the list of nodes that are alive, sorted in ascending order...
get_nodes() ->
    lists:sort([Node || Node <- gen_server:call(?SERVER, get_nodes),
        (net_adm:ping(Node)=:=pong orelse Node=:=node())]).

start_function_on_node(Node, Key, Function) ->
    gen_server:call({?SERVER, Node}, {start_function, Key, Function}).

%% Retrieves a list of nodes, with the first node being the most likely candidate for the pid associated with Key
get_nodes(Key) ->
    Nodes = get_nodes(),

    %% Get an MD5 of the Key...
    <<Int:128/integer>> = erlang:md5(term_to_binary(Key)),

    %% Hash to a node...
    N = (Int rem length(Nodes)) + 1,
    ExpectedNode = lists:nth(N, Nodes),
    OtherNodes = lists:delete(ExpectedNode,Nodes),
    {ExpectedNode, OtherNodes}.


get_status() ->
    _Status = gen_server:call(?SERVER, get_status).
    

init(_) -> 
    % Detect when a process goes down so that we can remove it from
    % the registry.
    process_flag(trap_exit, true),

    %% Broadcast to all nodes at intervals...
    gen_server:cast(?SERVER, broadcast_node),
    timer:apply_interval(?NODE_CHATTER_INTERVAL, gen_server, cast, [?SERVER, broadcast_node]),
    {ok, #state{ nodes=[{node(), never_expire}] }}.

handle_call(get_status, _From, State) ->
    %Nodes = lists:sort([Node || {Node, _} <- State#state.nodes, net_admin:ping(Node) == pong]),
    NumLocalPids = length(State#state.pids),
    {reply, NumLocalPids, State};

handle_call(get_nodes, _From, State) ->
    Nodes = [Node || {Node, _} <- State#state.nodes],
    {reply, Nodes, State};

handle_call({start_function, Key, Function}, _From, State) ->
    {Pid, NewState} = start_function(Key, Function, State),
    {reply, Pid, NewState};

handle_call({get_pid, Key}, _From, State) ->
    %% This is called by get_pid_remote. Send back a message with the
    %% Pid if we have it.
    Reply = get_pid_local(Key, State),
    {reply, Reply, State};
    

handle_call(Message, _From, _State) ->
    throw({unhandled_call, Message}).


handle_cast({register_node, Node}, State) ->
    %% Register that we heard from a node. Set the last checkin time to now().
    Nodes = State#state.nodes,
    NewNodes = lists:keystore(Node, 1, Nodes, {Node, now()}),
    NewState = State#state { nodes=NewNodes },
    {noreply, NewState};

handle_cast(broadcast_node, State) ->
    %% Remove any nodes that haven't contacted us in a while...
    F = fun({_Node, LastContact}) ->
        (LastContact == never_expire) orelse
        (timer:now_diff(now(), LastContact) / 1000) < ?NODE_TIMEOUT
    end,
    NewNodes = lists:filter(F, State#state.nodes),

    %% Alert all nodes that we are here...
    gen_server:abcast(nodes(), ?SERVER, {register_node, node()}),
    {noreply, State#state { nodes=NewNodes }};

%% @private
handle_cast(Message, _State) -> 
    throw({unhandled_cast, Message}).

%% @private
handle_info({'EXIT', Pid, _Reason}, State) ->
    %% A process died, so remove it from our list of pids.
    NewPids = lists:keydelete(Pid, 2, State#state.pids),
    {noreply, State#state { pids=NewPids }};

handle_info(_Message, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_pid_local(Key, State) ->
    %% Return the pid if it exists.
    {_Time, KF} = timer:tc(lists,keyfind,[Key, 1, State#state.pids]),
    %error_logger:info_msg("get_pid_local_time for ~p in list ~p: ~p microsec~n",[Key, length(State#state.pids), Time]),
    case KF of
        {Key, Pid} ->
            {ok, Pid};
        false ->
            undefined
    end.


start_function(Key, Function, State) ->
    %% Create the function, register locally.
    Pid = erlang:spawn_link(Function),
    NewPids = [{Key, Pid}|State#state.pids],
    NewState = State#state { pids=NewPids },
    {Pid, NewState}.
    
