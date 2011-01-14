all: compile

compile:
	@rebar compile

clean:
	@rebar clean

run: compile
	erl -pa ./ebin -eval "application:start(nprocreg)."
