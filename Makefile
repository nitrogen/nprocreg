all: compile

compile:
	./rebar compile

clean:
	./rebar clean

run: compile
	erl -pa ./ebin -eval "application:start(nprocreg)."


## DIALYZER
DEPS_PLT=$(CURDIR)/.deps_plt
DEPS=erts kernel stdlib sasl

$(DEPS_PLT):
	@echo Building local plt at $(DEPS_PLT)
	@echo 
	@(dialyzer --output_plt $(DEPS_PLT) --build_plt --apps $(DEPS))

dialyzer: compile $(DEPS_PLT)
	@(dialyzer --fullpath --plt $(DEPS_PLT) -Wrace_conditions -r ./ebin)

travis: dialyzer
