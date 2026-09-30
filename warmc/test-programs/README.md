# Test Programs

End-to-end tests of the compiler.

The file hierarchy is:

```
test-programs/
    suites/
        XXX-suite/      # Represents a test suite
            YYY-test/      # Represents a test
                Test.warmh   # Module interface
                Test.warm   # Module body
                austral-stderr.txt   # Expected compiler error (its "kind"), if the program must not compile.
                program-stdout.txt   # Expected program stdout, if the program compiles and runs.
                program-stderr.txt   # Expected program stderr, if the program exits with an error.
                cli.txt              # Custom compiler arguments, if any.
```

The `suites` directory has numbered subdirectories, each representing a test suite: a collection of tests covering specific compiler features.

Each test directory contains some Austral source files (in the simplest cases, `Test.warmh` and `Test.warm`) and some control files:

1. `austral-stderr.txt` is the compiler's error message if the test is expected to fail. The Warm compiler must fail with the same error `kind`.

2. `program-stdout.txt` is the compiled program's stdout if the compiler is expected to succeed. It is compared with the program's output (an empty file means no output).

3. `program-stderr.txt` is present when the program is expected to exit with a nonzero status; it holds its stderr.

Suite and test directories are numbered so that tests run in a predictable order.

`../compare.py` runs the tests with the Warm compiler written in Cool (`make warm-test` from the repository root; `--filter=substring` selects tests). `make.py` generates the `012-numbers` suite.
