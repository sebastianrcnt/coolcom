# Austral Standard Library

This is the directory for the Austral Standard Library. It is a work in progress.

## License

Licensed under the [Apache 2.0 license][apache]. See `LICENSE` for details.

[apache]: https://www.apache.org/licenses/LICENSE-2.0

Warm general-purpose modules are Eq, Ord, Hash, Vector, HashMap, HashSet and
Algorithms, with byte-span text, UTF-8 and numeric parsing in String. Their
interfaces document ownership; the complete design is in
[Stage 8](../../docs/warm-stdlib.md#stage-8-general-purpose-library).

Run `python3 warmc/test_stdlib.py` from the repository root for executable
per-module suites, compile-time ownership rejection and checked bounds aborts.
`tools/warm test` includes these suites; `make warm-kernel-test` also runs them
as generated Cool and through guest WarmRun. Reproduce microbenchmarks with
`python3 tools/warm-stdlib-perf.py`.
