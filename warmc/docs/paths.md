# Paths, L-Values, and Reference Transforms

This is a language reference for the current Warm compiler, retained from the
Austral documentation and updated for the Cool implementation. Paths are parsed
in [Parser.cool](../Parser.cool), typed by `WPathType` in
[Check.cool](../Check.cool), checked for ownership in
[Linear.cool](../Linear.cool), and lowered by `WGPath` in
[Emit.cool](../Emit.cool). They are used by Warm programs on both the host and
the kernel; see [the compiler README](../README.md) for build and run commands.

## Paths

A path starts with a named value and has one or more elements:

- `.name` selects a record field.
- `->name` selects a field through a read reference (`&`) or write reference
  (`&!`) to a record.
- `[i]` selects a `Span` or `Span!` element; `i` has type `Index`.

The parser attaches paths to names, rather than arbitrary expressions:
`pos.lat` is supported, while `f().lat` is not. Record fields must be visible
to the current module; opaque payloads cannot be inspected from outside it.
Indexing operates on spans, not the fixed arrays described by the older document.
Generated code checks the span bounds and byte-offset multiplication.

The final value read through a path must have a `Free` type. The head can be
linear: reading `pos.lat` observes `pos` without consuming it, as long as `lat`
is `Free`. Intermediate fields can also be linear; for example, a path can
reach a `Free` element through a mutable span stored in a linear record.
Extracting a linear payload as a value is rejected because it would duplicate
ownership. Use destructuring to move that payload instead.

Examples (with the corresponding record, reference and span types):

```warm
pos.lat
ref->lat
bytes[i]
container.bytes[i]
```

## Reference transforms

`&(path)` produces a reference to a nested value instead of loading the value.
It requires a named head and at least one path element: `&(ref)` is rejected.
Field elements must use `->`, while index elements use `[i]`.

- `&(ref->field)` requires a reference to a record and returns a reference to
  the field, preserving that reference's region and read/write mode.
- `&(bytes[i])` accepts a span and returns an element reference in the span's
  region: `Span` gives `&`, and `Span!` gives `&!`.
- A reference to a span can also be indexed inside a transform. Further
  elements are checked against the reference produced by the preceding step.

Unlike an ordinary path read, a transform can refer to a linear payload without
copying it. The current linearity pass observes the head without consuming it;
the inherited claim that every write-reference transform consumes its head
does not describe this implementation. Borrowing and reborrowing syntax is
separate (`&value`, `&!value`, `&~value` and `borrow ... end borrow`).

Examples:

```warm
let field: &[Int32, R] := &(ref->field);
let element: &[Int32, R] := &(bytes[i]);
let value: Int32 := !element;
```

## L-values and assignment

The left side of `:=` is a variable or a path rooted in a named value. Field
and span-index elements can be combined. The right side must have the target's
type. Assignment cannot change a constant or write through a read reference
or read-only span.

Reassigning a variable or its record fields requires a `var` binding. A `let`
binding or parameter whose head type is `&!` or `Span!` can still write through
that reference or span. Updating a path observes its head; it does not consume
the containing record, reference or span.

Path targets must have a `Free` type, so assignment cannot overwrite a linear
field or span element. Whole-variable assignment can reinitialize a linear
variable after its previous value has been consumed; overwriting a live linear
value or assigning to a borrowed variable is rejected.

Dereference expressions are supported for reading (`!ref`), but are not
assignment targets in the current parser. The older examples `!(ref) := x`
and `!(&(ref->field)) := x` are unsupported; assign through a field or span
path instead.

```warm
count := 10;
pos.lat := 10.0;
ref->field := 10;
bytes[i] := 42;
container.bytes[i] := 42;
```

## Validation

`make warm-test` (also included in `make -j test`) runs `compare.py` against
stored expectations, including [reference-transform cases](../test-programs/suites/013-ref-transforms)
and [span cases](../test-programs/suites/016-spans). The latter cover transforms,
out-of-bounds indexing and writes through spans held in records.
[test_semantics.py](../test_semantics.py) also covers linear-field extraction
and writing through read and mutable references. These tests use the current
Warm compiler and do not require an installed Austral compiler.
