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

From `warmc/`, run `opam exec --switch=austral -- ./run-tests.sh` for the upstream
test suite. The copied upstream standard library test currently fails in the
Buffer capacity-growth case; this is present in the pinned upstream source.
