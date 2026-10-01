MODULES := \
		src/Tuples.warmh,src/Tuples.warm \
		src/Bounded.warmh,src/Bounded.warm \
		src/Equality.warmh,src/Equality.warm \
		src/Order.warmh,src/Order.warm \
		src/Box.warmh,src/Box.warm \
		src/Buffer.warmh,src/Buffer.warm \
		src/Vector.warmh,src/Vector.warm \
		src/Eq.warmh,src/Eq.warm \
		src/Ord.warmh,src/Ord.warm \
		src/Hash.warmh,src/Hash.warm \
		src/HashMap.warmh,src/HashMap.warm \
		src/HashSet.warmh,src/HashSet.warm \
		src/Algorithms.warmh,src/Algorithms.warm \
		src/String.warmh,src/String.warm \
		src/StringBuilder.warmh,src/StringBuilder.warm \
		src/Format.warmh,src/Format.warm \
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
		test/Main.warmh,test/Main.warm \
		test/GeneralSupport.warm \
		test/Eq.warm \
		test/Vector.warm \
		test/HashMap.warm \
		test/HashSet.warm \
		test/Algorithms.warm \
		test/Text.warm \
		test/General.warm
TEST_BIN := test_bin

# The Warm compiler in Cool checks the whole library and its tests (`make build/warmc` first).
# Running them needs C stdio bindings that the Cool backend does not have, so there is no test binary yet.
.DEFAULT: all
all:
	../../build/warmc compile $(MODULES) --entrypoint=Standard.Test:Main --check

.PHONY: clean
clean:
	rm -f $(TEST_BIN)
