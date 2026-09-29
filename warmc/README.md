# Warm compiler

Warm is coolcom's fork of the Austral programming language. This directory
starts from Austral commit `0962d2a8a5d77f7daacd7f696819520733f4897d`
and builds an OCaml compiler named `warmc`. The source language and `.aui`/`.aum`
formats are currently compatible with that upstream commit.

The original project was created by Fernando Borretti and Austral contributors.
Their copyright notices and Apache-2.0-with-LLVM-exception license are preserved
in [LICENSE](LICENSE). The original README is preserved as
[UPSTREAM_README.md](UPSTREAM_README.md). Upstream source:
<https://github.com/austral/austral>.

## Build

Use the existing opam switch named `austral`:

```sh
./warmc/build.sh
./warmc/warmc --version
```

`build.sh` uses `opam exec --switch=austral` and produces `warmc/warmc`. It does
not modify coolcom's root Makefile. To compile a program:

```sh
./warmc/warmc compile example.aum --entrypoint=Example:main --output=example
```

From `warmc/`, run `opam exec --switch=austral -- ./run-tests.sh` for the full
compiler, end-to-end, example, and standard library test suite.

## Fixes since the fork

Warm validates required typeclass methods, duplicate methods, and instance
method signatures. It also corrects the built-in `Printable` instances, fixes
Buffer growth after `realloc`, and checks `Index` and `ByteSize` literals against
the host `size_t` width.
