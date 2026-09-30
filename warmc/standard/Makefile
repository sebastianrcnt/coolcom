MODULES := \
		src/Tuples.warmh,src/Tuples.warm \
		src/Bounded.warmh,src/Bounded.warm \
		src/Equality.warmh,src/Equality.warm \
		src/Order.warmh,src/Order.warm \
		src/Box.warmh,src/Box.warm \
		src/Buffer.warmh,src/Buffer.warm \
		src/String.warmh,src/String.warm \
		src/StringBuilder.warmh,src/StringBuilder.warm \
		src/IO/IO.warmh,src/IO/IO.warm \
		src/IO/Terminal.warmh,src/IO/Terminal.warm \
		test/Unit.warmh,test/Unit.warm \
		test/Tuples.warmh,test/Tuples.warm \
		test/Bounded.warmh,test/Bounded.warm \
		test/Equality.warmh,test/Equality.warm \
		test/Order.warmh,test/Order.warm \
		test/Box.warmh,test/Box.warm \
		test/Buffer.warmh,test/Buffer.warm \
		test/String.warmh,test/String.warm \
		test/StringBuilder.warmh,test/StringBuilder.warm \
		test/IO/Terminal.warmh,test/IO/Terminal.warm \
		test/Main.warmh,test/Main.warm
TEST_BIN := test_bin

.DEFAULT: all
all: $(TEST_BIN)

$(TEST_BIN): src/*.warmh src/*.warm src/*/*.warmh src/*/*.warm test/*.warmh test/*.warm test/*/*.warmh test/*/*.warm
	../warmc compile $(MODULES) --entrypoint=Standard.Test:Main --output=$(TEST_BIN)

.PHONY: clean
clean:
	-test -f $(TEST_BIN) && rm $(TEST_BIN)
