REBAR = $(shell pwd)/rebar3

all: compile

compile:
	$(REBAR) get-deps compile

clean:
	$(REBAR) clean

run:
	$(REBAR) shell --apps nprocreg

publish:
	$(REBAR) upgrade
	$(REBAR) hex publish
	$(REBAR) upgrade


dialyzer: compile
	$(REBAR) dialyzer

travis: dialyzer

