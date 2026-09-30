STDLIB := \
		../../standard/src/Tuples.warmh,../../standard/src/Tuples.warm \
		../../standard/src/Bounded.warmh,../../standard/src/Bounded.warm \
		../../standard/src/Equality.warmh,../../standard/src/Equality.warm \
		../../standard/src/Order.warmh,../../standard/src/Order.warm \
		../../standard/src/Box.warmh,../../standard/src/Box.warm \
		../../standard/src/Buffer.warmh,../../standard/src/Buffer.warm \
		../../standard/src/String.warmh,../../standard/src/String.warm \
		../../standard/src/StringBuilder.warmh,../../standard/src/StringBuilder.warm \
		../../standard/src/IO/IO.warmh,../../standard/src/IO/IO.warm \
		../../standard/src/IO/Terminal.warmh,../../standard/src/IO/Terminal.warm \
		
PROG := HelloWorld

ENTRY := Example.$(PROG):main

SRC := \
	$(PROG).warmh,$(PROG).warm

.DEFAULT: all
all: 
	../../warmc compile $(STDLIB) $(SRC) --entrypoint=$(ENTRY) --output=main

.PHONY: clean
clean:
	rm main
