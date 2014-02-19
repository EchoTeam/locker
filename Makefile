
.PHONY: all clean dist-clean
.PHONY: get-deps update-deps
.PHONY: compile
.PHONY: test-unit test-ct check
.PHONY: build_plt dialyzer

REBAR_CMD = $(shell which ./rebar || which rebar)
REBAR = $(REBAR_CMD) -C rebar.config
DIALYZER = nice dialyzer

.DEFAULT_GOAL := all

all: get-deps compile

clean:
	$(REBAR) clean
	rm -rf ./ebin
	rm -rf ./logs
	rm -f ./erl_crash.dump
	rm -rf ./.eunit
	rm -f ./test/*.beam

dist-clean: clean
	rm -rf ./deps

get-deps:
	$(REBAR) get-deps

update-deps:
	$(REBAR) update-deps

compile:
	$(REBAR) compile

test-unit:
	$(REBAR) eunit -v skip_deps=true

test-ct:
	$(REBAR) ct skip_deps=true

check: test-unit test-ct

# Dialyzer
DIAAPPS = \
	asn1 \
	compiler \
	crypto \
	erts \
	hipe \
	inets \
	kernel \
	mnesia \
	observer \
	public_key \
	sasl \
	ssl \
	stdlib \
	syntax_tools \
	tools \
	webtool \

STD_PLT = $(HOME)/.dialyzer_plt
USE_PLT = erl_std.plt

build_plt: all $(USE_PLT)
erl_std.plt:
	cp ~/.erl_std.plt . || \
		$(DIALYZER) --build_plt  --apps $(DIAAPPS) --output_plt erl_std.plt

dialyzer: all $(USE_PLT)
	$(DIALYZER) ebin --plts $(USE_PLT)


