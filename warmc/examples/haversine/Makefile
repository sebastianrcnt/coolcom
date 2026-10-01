STDLIB := \
		../../standard/src/Tuples.warmh,../../standard/src/Tuples.warm \
		../../standard/src/Bounded.warmh,../../standard/src/Bounded.warm \
		../../standard/src/Equality.warmh,../../standard/src/Equality.warm \
		../../standard/src/Order.warmh,../../standard/src/Order.warm \
		../../standard/src/Box.warmh,../../standard/src/Box.warm \
		../../standard/src/Buffer.warmh,../../standard/src/Buffer.warm \
		../../standard/src/Vector.warmh,../../standard/src/Vector.warm \
		../../standard/src/String.warmh,../../standard/src/String.warm \
		../../standard/src/StringBuilder.warmh,../../standard/src/StringBuilder.warm \
		../../standard/src/IO/IO.warmh,../../standard/src/IO/IO.warm \
		../../standard/src/IO/Terminal.warmh,../../standard/src/IO/Terminal.warm \
		
PROG := Haversine

ENTRY := Example.$(PROG):main

SRC := \
	$(PROG).warmh,$(PROG).warm

.DEFAULT: all
# Needs build/warmc and build/coolc: `make build/warmc` in the repository root.
ROOT := ../../..
all:
	$(ROOT)/build/warmc compile $(STDLIB) $(SRC) --entrypoint=$(ENTRY) --target-type=hc --output=main.cool
	COOLC_COMPILER_BIN=$(ROOT)/coolc/seed/Compiler.BIN $(ROOT)/build/coolc main.cool main.BIN
	@echo "run it: $(ROOT)/build/coolc --run main.BIN"

.PHONY: clean
clean:
	rm -f main.cool main.BIN
