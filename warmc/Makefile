BIN := warmc
SRC := lib/*.ml lib/*.mli lib/*.mll lib/*.mly lib/dune bin/dune bin/warmc.ml lib/BuiltInModules.ml
PREFIX ?= /usr/local

.PHONY: all
all: $(BIN)

lib/BuiltInModules.ml: lib/builtin/*.warmh lib/builtin/*.warm lib/prelude.h lib/prelude.c
	python3 concat_builtins.py

$(BIN): $(SRC)
	dune build
	cp _build/default/bin/warmc.exe $(BIN)

.PHONY: test
test: $(BIN)
	dune runtest

.PHONY: install
install: $(BIN)
	install -D -m 755 warmc $(PREFIX)/bin/warmc

.PHONY: uninstall
uninstall:
	sudo rm $(PREFIX)/bin/warmc

.PHONY: clean
clean:
	rm -f $(BIN); rm -rf _build; rm -f lib/BuiltInModules.ml
