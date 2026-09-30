# The Warm standard library: design

Status: reviewed; the decisions are at the end. Stage 0 is implemented (see
[warmc/README.md](../warmc/README.md#warms-additions-to-austral)); stages 1-5 are not. The
options and recommendations (**Rec.**) below are kept as the reasoning behind the decisions.

Warm today has two unrelated libraries: `Standard.*` from Austral (String, Buffer, Box,
`Standard.IO` with a terminal capability whose native bindings are C stdio that we cannot
run) and `Warm.Kernel` (45 kernel operations returning `Int64` codes, whole-file reads into a
linear `Buffer`, `Filesystem`/`Terminal`/`Tasks` tokens). The first real Warm component, the
packet parser (`os/Kernel/NetParse.warm`, [networking.md](networking.md#the-packet-parser-in-warm)),
used neither: it is a pure function over a span. What it taught, briefly:

- The safety model works: every index and length is checked, and a failed check became a
  dropped packet, not a fault. The unsafe part was 60 lines.
- The language was the friction, not the library: no shifts, `Option` from every widening
  conversion (fixed: `widenToNat64`), mandatory parentheses in `(a * 256) + b`, region
  parameters on every helper, and a 22-field record that had to be written out by hand
  across the Cool boundary (`CNetPkt` and an unsafe export module had to be kept in sync; fixed in stage 0).
- Generated code speed matters for kernel use; it was 30x slower than Cool before the
  emitter open-coded operators and indexing, 7x after.

## 1. Syntax direction

Warm's semantics (linear types, borrowing, regions, capabilities, typeclasses) are the point
and stay. The question is surface syntax. Austral chose verbosity on purpose (no precedence,
explicit regions, `end if;`), which costs the most in exactly the code Warm is for: parsers
and drivers full of arithmetic on bytes.

Options:

- **A. Stay Austral-compatible.** Upstream programs and docs keep working verbatim. The
  parser stays as is.
- **B. Austral plus a few additive extensions** (every Austral program still parses):
  1. Shifts `<<` `>>` and bitwise `&` `|` `^` `~` operators on integer types (today
     `bitwiseAnd(a, b)`; shifts do not exist).
  2. Conventional precedence among `* / %`, `+ -`, shifts, `&`, `^`, `|`, comparisons, `and`,
     `or`. Sub-option: whether mixing `and` with `or` still needs parentheses.
  3. Region elision in signatures: `f: Span[Nat8]` and `p: &![Packet]` in a parameter mean a
     fresh region parameter each, so `generic [R: Region]` is needed only when two regions
     must be the same or a region appears in the result.
  4. `.warmh` optional (see below).
- **C. A new syntax** (braces, `fn`, `let mut`). Most readable for C/Rust users, largest
  break: a second grammar, all tests and docs rewritten. Not worth it now.

**Rec.: B**, items 1-4, all additive, so upstream Austral code and our 298 test programs
keep working. Item 2: allow chains and precedence within arithmetic, keep the requirement to
parenthesize `and`/`or` mixtures (the classic bug source).

The `.warmh`/`.warm` split. A lone `.warm` already works (its declarations are all
public). Options: (a) keep the split required for libraries, (b) make it optional
everywhere and add `private` (or `pragma Private`) for body-only modules, (c) drop `.warmh`.
**Rec.: (b)**: interfaces stay for published library modules, where they are the
documentation, and application/kernel modules are one file.

Before (today, from NetParse.warm):

```
generic [R: Region]
function get16(f: Span[Nat8, R], at: Index): Nat64 is
    return (widenToNat64(f[at]) * 256) + widenToNat64(f[at + 1]);
end;

generic [R: Region, P: Region]
function parseIcmp(f: Span[Nat8, R], p: &![Packet, P]): Unit is
    let hl: Index := bitwiseAnd(widenToIndex(f[off]), 15) * 4;
```

After (B):

```
function get16(f: Span[Nat8], at: Index): Nat64 is
    return widenToNat64(f[at]) << 8 | widenToNat64(f[at + 1]);
end;

function parseIcmp(f: Span[Nat8], p: &![Packet]): Unit is
    let hl: Index := (widenToIndex(f[off]) & 15) * 4;
```

## 2. Error model

Today: `Warm.Kernel` returns `Int64` (-1 caught throw, -2 invalid, -3 missing/failed), and
`readFile` returns a `Buffer` even on failure that you must ask `bufferError` about.
Austral's `Option` and `Either[L, R]` exist but nothing uses them for I/O.

Proposal:

- **Aborts are for bugs only**: failed index/overflow checks, broken contracts. They never
  report something the environment did (a missing file, a reset connection).
- **Environment errors are values**: `Result[T, E]`, a new Pervasive union with cases
  `Ok(value)` and `Err(error)` (Either's `Left`/`Right` do not say which side failed). A
  failed acquisition of a linear resource returns `Err` and no resource, so there is no
  dummy object to close.
- **One error type for the library**, `OS.Error.IoError`, a union: `NotFound`, `Exists`,
  `InvalidName`, `Denied` (capability does not allow it), `NoSpace`, `NotEmpty`, `Closed`,
  `Timeout`, `Refused`, `Reset`, `Unreachable`, `Interrupted` (Ctrl+C/Kill), and
  `Other(code: Int64)` for a kernel code with no case yet. `ioErrorCode(e): Int64` and
  `ioErrorText(e): Span[Nat8, Static]` convert for printing and for Cool.
- `Option` is for absence that is not an error (`next(iterator)`, `keyPending`).

Options for the error type: (a) one `IoError` for everything, (b) one per module
(`FileError`, `NetError`), (c) `Int64` codes as today. **Rec.: (a)**. The kernel's own
failure modes overlap heavily, one type composes without conversions, and a module can
still document which cases it returns. Revisit if a module needs payloads (e.g. a parse
position).

## 3. Bytes, strings and ownership at API edges

- **Inputs borrow**: every function that only reads text or bytes takes `Span[Nat8]`, so
  literals (`Span[Nat8, Static]`), `String`s (via `getSpan`) and sub-slices all work
  without copies. Nothing the library receives is retained after the call.
- **Outputs own**: anything the library allocates comes back as a linear owned value,
  `Bytes` for binary data and `String` for text, freed exactly once by the caller. (Today's
  `Warm.Kernel.Buffer` becomes `Bytes`; `Standard.Buffer[T]` remains the generic growable
  array.)
- **UTF-8.** Options: (a) `String` is bytes, UTF-8 by convention, and decoding functions
  yield U+FFFD for bad sequences (Go); (b) `String` guarantees valid UTF-8, checked when
  built from bytes (Rust). **Rec.: (a)**: FAT names and network data are bytes, validation
  at every edge is cost without a safety payoff (memory safety does not depend on it).
- **Across the Cool boundary** (kernel modules such as NetParse, and the kernel adapter):
  - Cool to Warm: `Foreign_Export` functions take scalars and pointers; spans are rebuilt
    by the unsafe export module from pointer and length. **Proposed**: let an exported
    function take `Span[Nat8]` directly, lowered to a `(U8 *, I64)` pair, so the unsafe
    shim disappears for the common case.
  - Warm to Cool results: today a hand-written array of 22 `I64`s. **Proposed**:
    `pragma Export_Layout` on a record of scalar fields makes warmc also emit a Cool class
    with the same fields in the same order (`class CNetPkt {I64 kind, op, ...};`) into the
    generated file, and lets an export return that record through an out pointer. One
    definition, no drift.
  - Ownership never crosses implicitly: Warm does not keep Cool pointers beyond the call,
    and memory Warm allocates is freed by Warm (Cool gets copies or borrowed views valid for
    the call).

## 4. Capabilities and narrowing

Today `RootCapability` yields `Filesystem`, `Terminal` and `Tasks` tokens, each all-or-
nothing, and root can mint any number. Proposal, in the style of WASI/Capsicum (authority is
a handle to something, not a global permission):

- **`Dir`**, a linear handle to one directory with a rights set (`read`, `write`, `create`,
  `delete`). `openRoot(&!fs)` gives `C:/` with all rights. `openDir(&dir, "Sub")` gives a
  sub-directory with the same or fewer rights; `narrow(dir, rights)` consumes and returns a
  weaker `Dir`. All paths are relative to a `Dir`; absolute paths, drive letters, `..` and
  `\` are `InvalidName`, so a `Dir` confines its holder to its subtree. Read-only access to
  one directory is `narrow(openDir(&root, "Logs"), readOnly)`, passed to the helper by
  value.
- **`Network`** with an allow list: `narrowNet(net, host, port)` (one peer), or listen-only
  on given ports.
- **`Terminal`** splits into `Output` and `Input` so a helper can print without reading
  keys.
- Pure queries need no capability (clock, `utf8Width`, conversions); anything that changes
  or blocks on the outside world does (files, network, sleep, spawn).

Choice: rights as (a) a runtime set on one `Dir` type, or (b) types (`ReadDir`, `WriteDir`).
**Rec.: (a)**, with a type-level read-only variant later only if misuse shows up; (b) doubles
every signature. Enforcement is in the kernel adapter, which normalizes the path and checks
rights before calling FAT32 code. As today, this binds safe Warm code only: unsafe Warm and
Cool are outside the model, and kernel modules like NetParse take no capabilities at all
(they are pure functions over what Cool hands them).

## 5. One API, and names

(Decided differently from the recommendation below: OS-facing modules are `OS.*`, see the
decisions.)

`Standard.IO`/`Standard.IO.Terminal` (Austral, C stdio, cannot run natively here) and
`Warm.Kernel` (kernel only) merge into one set of modules with two backends: the kernel
adapter (`Adapter.cool`) and the host (`build/coolc --run` natives: files, stdout, stdin),
so the same program runs under `tools/warm run` and `WarmRun`. Operations a backend lacks
return `Err(Other)` (e.g. framebuffer on the host).

Names. Options: (a) everything under `Warm.*` (`Warm.File`, `Warm.Terminal`, ...), keeping
Austral's pure modules as `Standard.*`; (b) everything under `Std.*`; (c) keep `Standard.*`
and add `Warm.*` only for OS APIs (today's split). **Rec.: (a)**: the prefix says "ours,
with capabilities", and pure `Standard.String`/`Buffer`/`Box` stay recognizable to Austral
readers. Conventions: `camelCase` verbs, `open`/`close` for linear handles, `acquire`/
`release` for capabilities, `Result` for fallible calls, sizes as `Index`, times as
`Int64` milliseconds or a `Duration` record (stage 4).

## Stages

Each stage lists its API sketch and what it depends on. Stage 0 is language work that the
others lean on.

**Stage 0 - language and boundary** (done). Shifts and bitwise operators, precedence,
region elision, optional `.warmh` with `private`; `Result` in Pervasive; span parameters and
`Export_Layout` records on `Foreign_Export`. NetParse was rewritten with them: it is now one
safe file, and the hand-kept `CNetPkt` class and the unsafe export module are gone.

**Stage 1 - unified IO, typed terminal and files** (depends on: 0's `Result`, decision 5,
a host backend in the native runtime).

```
module OS.Error:    union IoError ...; ioErrorCode, ioErrorText
module OS.Terminal: acquireOutput(&!root): Output; acquireInput(&!root): Input
                      write(&!out, text: Span[Nat8]): Result[Unit, IoError]; writeLine
                      readLine(&!in): Result[String, IoError]
                      readKey(&!in): Key            -- union Key: Char(cp), Up, Down, ..., Ctrl(c)
                      setColor(&!out, fg: Color, bg: Color)   -- Color: a union, not Int64
module OS.File:     readAll(&dir, name): Result[Bytes, IoError]
                      writeAll(&dir, name, data: Span[Nat8]): Result[Unit, IoError]
                      exists, delete, makeDir
```
Replaces `Warm.Kernel`'s output, key and whole-file calls; `Standard.IO` is retired.

**Stage 2 - directories and file streams** (depends on: 1; kernel work: FAT32 has only
whole-file `FileRead`/`FileWrite`, so streams need an open-file handle in the kernel
(cluster chain + position), or a first version that buffers the whole file and writes on
close; **Rec.**: the buffered version first, since it fixes the API and the kernel handle can
replace it underneath).

```
module OS.Dir:  openRoot(&!fs): Dir; openDir(&dir, name): Result[Dir, IoError]; closeDir
                  entries(&dir): Result[Entries, IoError]
                  next(&!entries): Option[Entry]   -- Entry: name: String, size, isDir, modified
module OS.File: open(&dir, name, mode): Result[File, IoError]   -- File: Linear
                  read(&!file, into: Span![Nat8]): Result[Index, IoError]   -- 0 at end
                  write(&!file, data: Span[Nat8]): Result[Index, IoError]
                  seek, size, close(file): Result[Unit, IoError]
```

**Stage 3 - sockets** (depends on: 1; the kernel's `NetTcp.cool`/`Net.cool` calls map
directly; host backend optional).

```
module OS.Net: acquireNetwork(&!root): Network
                 resolve(&net, host: Span[Nat8]): Result[Address, IoError]
                 connect(&net, addr, port, timeoutMs): Result[TcpStream, IoError]
                 listen(&net, port): Result[TcpListener, IoError]; accept(&!l, timeoutMs)
                 send(&!s, data): Result[Index, IoError]; receive(&!s, into): Result[Index, IoError]
                 close(s); udpOpen, udpSend, udpReceive
```

**Stage 4 - tasks, time, random** (design of `spawn`: [warm-closures.md](warm-closures.md)) (depends on: 1; `spawn` also needs function values that
can be called from a new kernel task and a decision on how Warm code shares state between
tasks, likely none: pass linear values in, get a result back through `join`).

```
module OS.Time:   now(): DateTime; unixNow(): Int64; monotonicMs(): Int64; Duration
module OS.Task:   acquireTasks(&!root): Tasks; sleep(&tasks, ms); yield(&tasks)
                    spawn(&tasks, f: Fn[T, R], arg: T): Result[Handle[R], IoError]; join
module OS.Random: seeded(seed): Rng; next(&!rng): Nat64  -- not cryptographic
```

**Stage 5 - fine-grained capabilities** (depends on: 2 and 3).
Rights on `Dir` (`narrow`, read-only and subtree confinement enforced in the adapter),
`narrowNet` allow lists, `Output`/`Input` split everywhere, and tests that a narrowed
capability's holder gets `Denied`/`InvalidName` for everything outside it (paths with `..`,
absolute paths, other drives, other hosts).

## Decisions (2026-09-30)

1. Syntax: **B**, the additive extensions. Mixing `and` with `or` still needs parentheses.
2. `.warmh`: **optional**, with `private` for declarations of a module body that other
   modules must not import.
3. Errors: **one `IoError`** (module `OS.Error`) and **`Result` with `Ok`/`Err`**; aborts only
   for bugs.
4. Strings: **bytes by convention** (UTF-8 not validated).
5. Rights: **a runtime set** on one `Dir` type.
6. Names: OS-facing modules are **`OS.*`** (`OS.File`, `OS.Dir`, `OS.Net`, `OS.Terminal`,
   `OS.Time`, `OS.Task`, `OS.Random`, `OS.Error`), and the same code runs on CoolOS and
   macOS. A feature that exists on only one side goes under that side's name, e.g.
   `OS.CoolOS.Framebuffer` (or `OS.MacOS.*`). Pure modules stay **`Standard.*`**.
   (`Warm.Kernel` becomes `OS.*` plus `OS.CoolOS.*` in stage 1.)
7. File streams: **buffer the whole file and write on close first**, then a kernel open-file
   API underneath.
