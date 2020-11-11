REBAR = $(shell pwd)/rebar3

all: compile

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

run:
	$(REBAR) shell --apps nprocreg

publish:
	$(REBAR) as pkg upgrade
	$(REBAR) as pkg hex publish
	$(REBAR) upgrade


dialyzer: compile
	$(REBAR) dialyzer

travis: dialyzer

