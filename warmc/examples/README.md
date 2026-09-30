# Warm examples

Examples of Warm programs. Build the compiler once with `make build/warmc` in the repository root. Then run `make` in this directory to compile every example to `main.cool` and `main.BIN` in its directory, and run one with `../../../build/coolc --run main.BIN` (`greet` reads a line from standard input, so `echo Bob | ../../../build/coolc --run main.BIN`). To build a single example, `cd` into its directory and run `make`. `warmc/run-examples.sh` compiles, runs and checks all of them; `tools/warm run` does it for one program.

`kernel/` holds programs for the OS's kernel shell (`make warm-kernel-test`).
