# Warm syntax additions (stage 0 of docs/warm-stdlib.md)

- `001`: `& | ^ ~ << >>`, precedence and chains of the same operator.
- `002`: region elision in parameter types (two spans, a `Span!`, a `&!`).
- `003`, `004`, `007`: `private` in a module body without an interface: not importable;
  the public functions that use it are; `private` on a declaration the interface declares
  is an error.
- `005`: `Result` with `Ok` and `Err`.
- `006`: a shift by the type's width or more aborts.
