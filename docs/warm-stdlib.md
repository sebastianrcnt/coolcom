# The Warm standard library: design

Status: reviewed; the decisions are at the end. Stage 0 is implemented (see
[warmc/README.md](../warmc/README.md#warms-additions-to-austral)); stages 1-3 are implemented; stages 4-5 are pending. The
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

## Implementation notes

Stage 1: portable `OS.Terminal`, `OS.File`, and `OS.Error` use `OSHost.cool`
and `os/Warm/OSKernel.cool`. `Warm.Kernel` has been removed. The temporary `OS.Raw`
module was removed in stage 5 after migrating its final users. CoolOS extensions are in
`OS.CoolOS.*`. The upstream `Standard.IO` compatibility module uses the same
terminal boundary. Tests include host round trips and kernel shell examples.

Stage 2: `OS.Dir` owns directory handles and directory-entry snapshots. File APIs
now take a borrowed `Dir` and a relative name. `Read` requires an existing file;
`Write` truncates at open and persists at close; `Append` creates if missing and
always writes at the end; `ReadWrite` reads an existing file. Seek beyond EOF
zero-fills the gap on the next write. Stream snapshots survive closing their
parent directory, and closing a stream releases it even when persistence fails.
`OS.File.byteSize` queries `Bytes`; `size` queries `File`. Stream snapshots are
limited to 256 MiB. Directory entries own names; close the iterator on early exit.

Stage 3: `OS.Net` has IPv4 address resolution, owned TCP streams/listeners and
UDP sockets on both backends. Receive and accept take millisecond timeouts
(`-1` waits indefinitely). TCP receive returns zero at EOF; UDP receive returns
a `Datagram` with the sender and source port, including empty datagrams.
`listenPort`/`udpPort` report dynamically assigned ports. Host sockets use
nonblocking descriptors with polling; the kernel keeps its existing network
stack and translates its errors. The kernel UDP payload limit is 1486 bytes.

Stage 4: `OS.Task` moves one typed argument to a named function and returns an
owned `Task[R]`. Intrinsic structural `Sendable` excludes root capabilities,
non-static borrows and raw pointers; audited owning Buffer/Box storage remains
transferable. `join` returns the result or `Aborted`/`Killed`; detach requires
a Free result. Task abort affects that task only. macOS uses pthreads; CoolOS
uses kernel tasks and a completion hook for Kill. `spawnOn` is supported on
CoolOS; macOS returns Other for explicit core affinity. Allocation/startup
failure and abnormal termination cannot destruct arbitrary moved linear values
without a destructor protocol: their nested owned resources may leak.
`OS.Time` exposes UTC calendar conversion and wall/monotonic clocks; `OS.Random`
is an explicitly seeded, non-cryptographic xorshift64 generator.

Stage 5: `OS.Dir.Rights` is a runtime read/write/create/delete set; consuming
`narrow` intersects rights and cannot restore them. Child directories inherit
rights. Each file/listing/mutation/stream-open checks the required rights.
Names must be relative without dot components, drive prefixes or backslashes.
The host walks path components with openat/O_NOFOLLOW and performs IO through
the resulting parent descriptor, including stream persistence, to prevent
symlink traversal and check/open races. CoolOS FAT32 has no symlinks.

`OS.Net.narrowNet(network, allowed: Span[Endpoint])` intersects IPv4 address/port
allow lists. Empty policies deny every endpoint; unrestricted Network comes only
from RootCapability. Restricted policies permit outbound TCP and ephemeral UDP,
and deny listeners/explicit local UDP binds. Each socket retains its own policy
snapshot after the Network is released. UDP send and receive check the peer;
rejected datagrams are consumed without copying their bytes into caller storage.
Resolution is checked against the allowed IP addresses.

Framebuffer operations now require Output and return Result; CoolOS key polling
requires Input and returns typed Key values. No public combined terminal token
remains. Host/kernel capability fixtures cover attenuation, traversal, rights,
network allow-list intersection and denied datagrams; host probes include final
and intermediate symlinks whose outside target remains untouched.

## Lessons from Top/Vim/Tmux

### Top

- `toInt64(Index)` compared the unsigned input against `INT64_MIN` converted to
  unsigned, rejecting small positive values. Its lower-bound check is unnecessary;
  only `INT64_MAX` needs checking. The conversion is now fixed.
- Buffer/String spans and `for` ranges have inclusive end indices. Whole-string
  output needs `length - 1`, with an explicit empty-string branch. This differs
  from the half-open ranges normally used by terminal tools.
- Integer remainder is `rem(a, b)`, not `%`; escape bytes must be literal bytes
  (`\x1b` is not a Warm string escape). ANSI output and padded numbers currently
  require application helpers because the terminal library has no formatter.
- Record fields cannot follow a function call directly. A temporary is required
  for `clock(...).ticks` and `nth(...).info`.
- Updating a Buffer from one of its own elements needs a temporary before the
  mutable borrow; this makes the evaluation and borrow lifetime explicit.

### Vim

- Warm parameters are immutable, so modal command dispatch needs separate mutable
  cursor/count locals. Warm has no `break`, `continue` or `goto`; the dispatch
  epilogue is a separate function and journal/search loops use explicit stop flags.
- Terminal byte output, UTF-8 helpers, incremental syntax state, palette changes
  and source-location lookup were missing from the Warm boundary.
  `OS.CoolOS.Editor` supplies them; syntax and compiler hash structures stay
  behind opaque kernel functions. The low-level module uses addresses of
  caller-owned buffers, so it is deliberately unsafe rather than a safe IO API.
- Stack byte arrays and C-string interop are awkward. Editor-owned reusable scratch
  buffers avoid allocating on every key/paint and are also freed on shell recovery.
  Austral.Memory allocations carry a runtime header and must use `deallocate`,
  whereas buffers allocated by kernel `MAlloc`/`CAlloc` must use kernel `Free`.
- Signed trapping arithmetic currently emits function calls. Byte access in the
  checked gap-buffer accessor uses explicit embeds; large cursor jumps reposition
  the viewport by walking backward from the cursor instead of scanning every
  intervening line. A trial broad arithmetic inliner failed the real editor
  workload despite passing the number suite, and was discarded.
- Static C-string pointers are cached at editor creation. Repeated aggregate span
  temporaries in the large command dispatch produced a null literal pointer in
  the Cool backend; caching also reduces per-command temporary work.
- File buffers use ordinary virtual allocations. They are never passed to DMA;
  the merged large heap may back files above 256 KiB with noncontiguous pages.
- VM comparison (`tools/program-perf.py build/kernel.Image 90b47e3`, the same
  kernel and 640x480 framebuffer): Cool/Warm key navigation averaged 0.10/0.35
  microseconds, insertion 0.02/0.98 microseconds, repaint 3.97/4.40 ms, and a jump
  in a 330 KB file plus repaint 8.33/8.29 ms. Input work remains below a
  microsecond and paint remains below one 60 Hz frame in this run. The initial
  port took about 21 ms for the large jump versus 8 ms in Cool; the gap-byte and
  newline scans and viewport positioning above removed that visible-risk
  regression. These are VM measurements, not a hardware latency guarantee.

### Tmux

- Virtual-terminal creation, resize, focus, lifetime, cursor and dirty-state APIs
  were absent. `OS.CoolOS.VirtualTerminal` now exposes opaque handles and kernel
  functions; Warm owns only its pane tree and window/session records. Closing a
  pane stops its task group and releases the compositor reference in the kernel.
- Free records have no convenient nullable heap-reference/container syntax for
  a mutable tree. The private unsafe boundary uses typed allocation and explicit
  casts for application-owned nodes and an eight-slot window table. Record
  allocations still use `deallocate`; scratch buffers use the kernel allocator.
- `for` binds an `Index`, even when both endpoints are integer literals. The fixed
  eight-window loop needs an explicit conversion before signed layout arithmetic.
  `else if` is a single chain, with just one closing `end if`.
- WarmRun installs libc symbols in the shell's compiler. libc's `exit(status)`
  shadowed the shell command `exit`, so a bare command now resolves explicitly to
  the kernel's `Exit`; explicit `exit(status)` calls retain their C meaning.
- The unchanged Man source-location checks now point at `WarmPrograms.cool`,
  which retains `VimOpen` and the shell-visible `VIM_HIST` limit. Only the fixture's
  relocated source path changed; symbol kinds, line validation, numbered editor
  output and all other oracles are retained.
- Session scratch storage survives detach, and recovery restores the invoking
  terminal's focus/alternate screen. The compositor retains 30 Hz batching and
  delegates changed-cell drawing to the kernel rather than redrawing per key.
- Same-kernel VM comparison of two vertical panes: Cool/Warm key forwarding
  averaged 0.042/0.121 microseconds, and forced compositor repaint 12.69/12.57 ms.
  Both fit the existing 33 ms refresh budget; no noticeable slowdown appeared
  in this measurement. The benchmark checks saved Vim edits and restored focus
  and writes logs plus results under `build/program-perf`.

### GUI window integration (G1)

- The terminal APIs already use the calling task's terminal: size comes from the
  window's cell grid, input from its virtual-terminal queue, and alternate-screen
  restoration targets that same grid. Tmux consumes the window queue and forwards
  events to its active pane; its compositor draws into the parent window.
- Top's initial 200 ms CPU sample used a timed key read and discarded the result.
  A quit key queued while WarmRun compiled the program could be consumed by that
  sample and lost. The first key is now retained and dispatched after the first
  monitor frame, including resize and navigation events.
- Eagerly compiling both editors at every shell startup stalled the GUI compositor
  when Tmux spawned a new pane. Mouse press/move/release transitions could collapse
  before it polled them. Vim and Tmux now load on first use, once per shell, using
  the same WarmRun sources. Forward declarations preserve the shell API and bind
  to Warm's exports when loaded. A new pane no longer compiles unused applications.

## Stage 6: language fixes

Design decisions (2026-10-01), written before implementation:

1. **Loop exits.** Options: stop flags only; unlabelled exits; labelled exits.
   Adopt `break;` / `continue;` and `break outer;` / `continue outer;`, with
   `while outer: condition do` or `for outer: i from ... do`. Labels are local
   to enclosing loops; duplicate active labels and missing targets are errors.
   Each exit must consume loop-local owned values and preserve ownership of
   values outside its target loop. Borrowing and immutable parameters stay as-is;
   there is no arbitrary `goto`.
2. **Remainder.** Options: function only; Euclidean modulo; alias for `rem`.
   Adopt `%` at the `*`/`/` precedence, left associative, lowering to `rem`.
   Division truncates toward zero: a nonzero remainder has the dividend's sign
   (`-7 % 3 = -1`, `7 % -3 = 1`). Zero divisor and signed minimum `% -1`
   abort just like `rem`; floats are rejected.
3. **Escapes.** Options: literal control bytes; C escapes; Unicode scalar escapes.
   Adopt `\xHH` (exactly two hex digits, one byte), `\e` (ESC), `\u{H...}`
   (1-6 hex digits, Unicode scalar encoded as UTF-8), plus `\0`, `\n`, `\r`,
   `\t`, `\\`, `\"`, `\'`. Embedded NUL keeps its byte length. Malformed new
   escapes, surrogates and values above U+10FFFF are errors. Unknown legacy
   escapes remain literal backslash plus character; triple strings/docstrings
   keep their existing rules. Embed snippets keep their source-text semantics.
4. **Postfix fields.** Options: require temporaries; arbitrary temporary borrows;
   read-only paths on computed values. Adopt `f(x).field` and `(expr).field`,
   including chained fields/indexes. The computed base and extracted result must
   be Free: dropping owned fields or borrowing an ephemeral owner is rejected.
   Buffer self-update still requires the explicit borrow-lifetime temporary.
5. **Ranges.** Options: change `to` to half-open (breaking); new punctuation;
   additive named bound. Adopt `for i from start until end do` for `[start,end)`.
   New loops snapshot both bounds once; empty/reversed ranges do no work.
   Existing `to` stays inclusive and retains endpoint re-evaluation. Iteration
   at maximum Index terminates without wrapping. Loop variables remain Index.
   Add `slice`/`sliceMut` to Buffer and String, and `sliceSpan` for borrowed spans,
   with half-open bounds including empty spans; existing getSpan/span APIs stay
   inclusive. Scratch allocation and typed tree containers remain library work;
   no allocator or unsafe editor boundary is changed by this stage.
6. **Formatting.** Options: terminal-only printf; compiler interpolation; portable
   library formatter. Adopt `Standard.Format.format(template, args)` returning
   an owned String, with a borrowed span of typed FormatArg values (text, signed,
   unsigned). Sequential `{}` / `{:s}` / `{:d}` / `{:x}` / `{:X}`, width such as
   `{:6d}` and zero padding `{:06d}`, and escaped `{{` / `}}`. Width is a minimum;
   zero padding follows a minus sign. Bad templates/types/counts abort as bugs.
   No variadic ABI, unsafe printf format strings, or terminal capability needed.
7. **Signed arithmetic.** Options: keep calls; general body inliner; narrowly emit
   Pervasive checked primitives. Adopt only signed trapping +, -, *, / (and rem),
   evaluating operands once into typed temporaries. Preserve all overflow and
   division checks/messages using the emitter's existing checked embed lowering.
   No user-function or broad arithmetic inlining. Require number regressions,
   actual Vim.warm editing/large-file validation and before/after VM measurements.
   Existing editor C-string caching, allocation ownership, lazy loading, terminal
   capabilities and GUI integration remain intact.

Implementation notes:

- The first signed inliner used fresh operand/bound/check temporaries for every
  operation. It passed the number suite but faulted in the real Vim benchmark
  (Sync exception, FAR 0x800201138; `build/stage6-inline-first-failure.log`).
  The adopted emitter reuses typed scratch slots per generated function and
  leaves expression results distinct. Actual Vim editing/saving and large-file
  benchmarks then passed. No broad body inliner was introduced.
  Root cause, fixed later in coolc (FIX(11) in `coolc/Frontend/AIWNIOS_CodeGen.cool`):
  liveness bit sets were sized `8 + b >> 3` bytes, but their union/difference work in
  whole U64 words, so bits of variables numbered 64 and up in a partial last word were
  dropped. Register coloring then split one variable into a register half and a frame
  half; a frame slot that was never written was read (here a stale kernel address).
  With the fix the fresh-temporary inliner passes the same Vim benchmark;
  `make codegen-test` checks generated functions past that boundary on both targets.
- Format's numeric output is split into small helpers; signed magnitude handles
  INT64_MIN without negating it directly. String.fromLiteral and StringBuilder's
  copy loops now use `until`, also handling empty strings without subtraction.
- main was integrated at bfbd7f5 (warmcli). Portable tests run through `tools/warm`
  and `tools/toolchain.mk`; disk application checks stay under `os/Warm` with
  explicit `--coolos`. Standard.Format is discovered by the public host CLI.
  Man APIs are regenerated by `tools/warm-man.py`, including Standard.Format.

Performance (2026-10-01): `python3 tools/warm-inline-perf.py build/kernel.Image
--repeat 3` compares the same unchanged Vim.warm and same kernel image, 640x480,
changing only the signed-inline dispatch in the generated Warm shell package.
Each run checks 2000 navigation keys, 2000 inserted bytes saved to FAT32, 50
repaints, a jump/repaint in a 330 KB file, and restored Tmux focus. Medians:

| Workload | Calls before | Inline after |
| --- | ---: | ---: |
| Vim navigation, microseconds/key | 0.2359 | 0.2281 |
| Vim insertion, microseconds/key | 0.07463 | 0.05950 |
| Vim repaint, milliseconds | 4.0144 | 3.9884 |
| Vim 330 KB jump + repaint, milliseconds | 7.0326 | 7.1165 |
| Tmux forwarding, microseconds/key | 0.07960 | 0.06883 |
| Tmux forced repaint, milliseconds | 15.1548 | 13.3052 |

Insertion improved about 20%; navigation about 3%. Large-file jump increased
about 1.2%, within the spread of these VM trials; repaint costs are effectively
unchanged for Vim. These VM timings do not establish hardware latency or a
Tmux rendering improvement. Full trial data, kernel/package SHA-256 hashes and
logs are in `build/warm-inline-perf/results.json` and `build/warm-inline-perf/`.
The script restores the generated package even when a benchmark fails.

Validation: `make -j test` completed with exit code **0** after integrating main.
This includes 306 unchanged upstream cases, 64 Stage 6 checks with 364 signed
arithmetic results, standard-library/host CLI tests, kernel generated modules,
and 126 real Vim VM input/save/cursor/quit/recovery cases. Tree-sitter's five
corpus fixtures, all 450 tracked Warm files, and the five new source/formatter
files parse; formatter fixtures and corpus are fixed points with identical ASTs.
Man API coverage and regenerated pages passed (`build/stage6-man`).

The first full parallel run timed out in the unchanged Cool GUI drawing test;
that test passed in isolation on both CPU and Venus, and the second full
`make -j test` passed. Logs are `build/stage6-test-first.log`,
`build/stage6-gui-draw-retry.log`, and `build/stage6-test.log`. GUI implementation
files and vendor sources were not edited by this change.


## Stage 7: generated code

Implemented 2026-10-01 in `warmc/Emit.cool`; the Cool compiler, GUI sources and
vendor sources are unchanged.

Simple library access is emitted directly after generic and named-argument
resolution. `Standard.Buffer.length` reads the concrete size field; `nth` and
`storeNth` use the concrete typed array pointer as `ptr[index]`. They retain
`index >= size` followed by `wh_abort` and the original messages unless the
range rule below applies. Pervasive `spanLength`/`spanWriteLength` read
`wh_size`. Span element indexing already emits memory expressions directly.
Builtin `Austral.Memory` load/store, reference loads, positive/negative offsets,
pointer/reference casts and span-to-pointer conversions now emit the equivalent
Cool expressions instead of requesting wrapper functions. Unsafe pointer
operations retain their existing unchecked semantics. Aggregate element loads
still materialize a value copy, and stores still use the existing typed copy
lowering (including narrow integer normalization).

Recognition requires the library module and its source identity: the builtin
Pervasive/Memory paths, or the standard Buffer source paths on the host or
`C:/Warm/Standard` in CoolOS. Application functions called `nth`, `length` or
`store` are ordinary calls. Function values and user-defined wrappers also
remain calls. No general function-body inliner is involved.

The conservative range proof is local to each loop:

- The upper bound must be exactly `length(buffer)`, `spanLength(span)` or
  `spanWriteLength(span)` for `until`, or that query minus the literal `1` for
  inclusive `to`. The subtraction keeps its underflow check, so an empty
  inclusive range still aborts. `to length(buffer)` keeps its access checks.
  Cached lengths, arbitrary smaller bounds, branch inequalities and computed
  indexes such as `i + 1` or `row * width + col` are not inferred.
- The access must use the same declaration for the descriptor and exactly that
  loop's immutable Index binding. Borrow expressions and reference casts may
  identify the same root; different buffers, spans and index aliases do not.
  The proof is pushed while emitting the loop body and popped afterwards.
  Nested span indexing uses it only for the first dimension; later dimensions
  must prove their own bounds.
- A body scan permits the descriptor only as the direct receiver of the known
  length/nth/store accessor, or the base of span element indexing. Descriptor
  replacement, size changes, alias creation, borrowed-descriptor escapes and
  unknown calls receiving it disable the proof, even in unreachable branches.
  Any embed in the body also disables it. Element writes through `storeNth` or
  a mutable span preserve descriptor length. Checked linear ownership and
  borrowing prevent safe aliases from resizing an owned Buffer or mutating an
  immutable Buffer loan. Mutable Buffer reference roots are excluded for now;
  unsafe modules are excluded entirely because they can hide pointer aliases.
- A successful proof removes only the access's bounds comparison. Span
  byte-offset multiplication overflow checks remain, even when its index is
  proven less than the advertised length. Ordinary arithmetic checks remain.
  The tests pass a forged huge span from an unsafe module into a safe proven
  loop and verify that multiplication still aborts before memory is touched.

A safe `until` loop enters with `index < snapshotted_bound <= INDEX_MAX`, and
its Index binding is immutable. Incrementing an entered iteration cannot
therefore overflow. Its per-iteration `index == INDEX_MAX` branch is omitted;
`to` and unsafe-module loops retain it. Both bounds of `until` are still
snapshotted once, and empty/reversed ranges, labelled exits and `continue`
retain their existing behavior. No endpoint evaluation policy changed.

Unsigned primitive operands already held in variables of the required type
avoid a second operand copy when the other operand is a simple variable or
literal. Constants still become typed temporaries where Cool's constant
arithmetic could otherwise use signed semantics. Nested/side-effecting
expressions retain their operand snapshots, and signed arithmetic scratch
storage is unchanged.

### Measurements

`warmc/perf/Access.warm` supplies three new kernels. The runner expands its byte
fixture to 16 KiB, compiles the same source with saved before/after Warm BINs,
and uses the same checked-in Cool seed for both. Each kernel processes
16,777,216 elements, verifies its sum, and reports timed loop execution
(excluding compilation, loading and allocation). Host monotonic timing has
1 ms resolution; these are three-trial medians, not hardware guarantees:

| Workload | Before, ms | After, ms | Speedup |
| --- | ---: | ---: | ---: |
| Buffer sum | 44 | 11 | 4.00× |
| Byte scan | 18 | 15 | 1.20× |
| Flat 128×128 array, row/column indexing | 56 | 26 | 2.15× |

The 2D kernel deliberately retains its computed-index bounds check and checked
row/column arithmetic. Generated source (including the runtime and literal)
shrinks from 118,408 to 116,218 bytes. Reproduce with:

```sh
python3 tools/warm-access-perf.py build/stage7-before-Warm.BIN build/warmcool/Warm.BIN --repeat 3
python3 tools/warm-inline-perf.py build/kernel.Image --repeat 3 --baseline-package build/stage7-before-Kernel.cool --output build/stage7-package-perf
python3 tools/program-perf.py build/kernel.Image 90b47e3
```

Save the baseline Warm BIN and generated Kernel.cool before editing the
emitter. The new optional `--baseline-package` compares that package against the
current one; without it the existing signed-call/inline comparison is preserved.
For this run the baseline package was reconstructed by substituting
`68c3d1a:warmc/Emit.cool` into the generated package. Both packages keep Stage 6
signed arithmetic enabled, use the same current kernel, unchanged Vim/Tmux
sources and 640×480 framebuffer. Compilation finishes before timed operations.
Each VM trial checks saved edits, the 330 KB jump and restored terminal focus.
Three-trial medians:

| Workload | Stage 7 before | Stage 7 after |
| --- | ---: | ---: |
| Vim navigation, µs/key | 0.22781 | 0.22429 |
| Vim insertion, µs/key | 0.05840 | 0.07042 |
| Vim repaint, ms | 3.99726 | 4.09713 |
| Vim 330 KB jump + repaint, ms | 7.04467 | 7.20475 |
| Tmux forwarding, µs/key | 0.08958 | 0.02798 |
| Tmux forced repaint, ms | 12.86903 | 13.43213 |

The same `tools/program-perf.py` command was also run once with each Warm
package installed temporarily (and restored afterwards). Its Warm results:

| Workload | Before | After |
| --- | ---: | ---: |
| Vim navigation, µs/key | 0.21950 | 0.21681 |
| Vim insertion, µs/key | 0.06225 | 0.06508 |
| Vim repaint, ms | 4.19733 | 4.03472 |
| Vim 330 KB jump + repaint, ms | 7.60575 | 7.12913 |
| Tmux forwarding, µs/key | 0.12640 | 0.10731 |
| Tmux forced repaint, ms | 13.30527 | 12.93710 |

Vim insertion's three-trial median increased by about 21% (0.012 µs/key),
and Vim repaint/jump by about 2–3%; this change does not demonstrate an editor
speedup. Tmux forwarding improved in the repeated run, but its separate
single-run result varies substantially, so the measured median is not a
stable 3× claim. Forced repaint is dominated by rendering. The microbenchmarks
isolate the access savings; application timings include VM scheduling/noise.
Full trials, hashes and logs are in `build/stage7-access-perf/`,
`build/stage7-package-perf/` and `build/stage7-final-{before,after}-program.json`.
The fixed kernel SHA-256 is `45644e6f2641c639764339781f6d548745372fe306f729a1b805962f8c4c1010`; the Cool seed SHA-256
is `18677c698bdcd69ee118252db98d6fc77900721f95d62bbdc9d4c70692107488`.

### Validation

`warmc/test_generated.py` adds 28 runtime and emitted-code checks and is part
of `warm-test` / `make -j test`. It covers direct/named accessors, both proven
range forms, mutable span writes, out-of-range reads/stores (including maximum Index literals), inclusive length,
other buffers, changed descriptors, unknown calls, cached bounds, offset
indexes, aliasing, nested dimensions, proof scope, unsafe modules, empty and
reversed ranges, maximum Index with continue, subtraction/addition overflow,
and the independent span multiplication trap.

The complete `make -j test` passed with exit code **0**; the final log is
`build/stage7-test-complete.log`. This includes the unchanged upstream, number,
language, host/standard-library, real Vim/Tmux VM, kernel and GUI tests. An
initial run failed on the new mutable-loan fixture's invalid region cast; the
fixture was corrected without changing the language or borrow checker.

## Stage 8: general-purpose library

Decisions (2026-10-01), implemented in `warmc/standard/src`:

- **Traits.** Options: extend upstream Equality/TotalOrder; add short Eq/Ord/Hash
  traits; use by-value callbacks. **Chosen: Standard.Eq, Standard.Ord and
  Standard.Hash**, keeping the upstream modules compatible. Trait methods take
  independent read-only region-qualified references to `T: Type`, so linear
  String instances never copy or consume their owners. Ord returns Less/Equal/
  Greater; it has no implicit superclass (Austral has no superclass constraints).
  Generic maps explicitly require both Eq and Hash. Instances cover Unit, Bool,
  all signed/unsigned integer widths, Index, ByteSize, String and generic Type
  spans. String and byte spans compare bytes lexicographically. Floats are
  excluded from total Eq/Ord because NaN violates their laws. Import the trait
  module at call sites to make its instances visible, as required by Austral.
  Span traits borrow elements, including linear String elements; the two span
  operands must have the same span-region type. String.equals compares byte
  spans with independent regions. Eq must be reflexive/symmetric/transitive; equal keys must hash identically;
  Ord must agree with Eq when both are implemented. Hashes are deterministic
  Nat64 values, not a persistent serialization format or a cryptographic API.
- **Vector.** Options: duplicate an unsafe allocator; wrap existing Buffer;
  rename Buffer. **Chosen: a distinct owning Vector wrapping audited Buffer**.
  push/insert move any Type in; pop/remove/replace move it out. Empty pop returns
  None. get/set/filter copy only Free elements; borrowGet and half-open slices
  support linear elements. A Cursor visits borrowed elements in index order.
  map consumes the vector and invokes a named Fn once per moved element, in order.
  destroyFree requires Free elements; otherwise drain and destroy each element,
  then destroyEmpty. Index misuse and allocation failure abort as programmer/
  resource errors. Empty slices, including at length, are valid. A live borrow
  must end before mutation/growth/destruction; restart cursors after mutation.
- **Hash storage and ownership.** Options: chaining; open addressing; borrowed
  generic keys with custom destruction. **Chosen: linear probing with a power of
  two capacity, Empty/Tomb/Full tags, 75% used-bucket threshold, doubling and
  tombstone compaction**. Mixed hashes use a deterministic SplitMix64 finalizer.
  Explicit rehash compacts without changing capacity. Free keys + Type values
  keep the insertion API ownership-safe: insert returns Option of the previous
  value, remove/drainOne return ownership, borrowGet does not copy. Repeated
  drainOne calls scan buckets once until the next insert/rehash (O(capacity)
  total), so destroying linear values does not require quadratic searches. Free values
  allow get/destroyFree; linear values require draining and destroyEmpty.
  Owned linear keys would require returning both replaced keys and values and a
  borrowed-key query protocol: deferred instead of silently dropping a String.
  Use immutable Free IDs or borrowed spans as keys; keep their storage alive and
  unchanged for the entire map lifetime. HashSet wraps HashMap[T, Unit], and
  therefore requires Free elements. nextKey/HashSet.next visit occupied buckets
  in unspecified order. Restart cursors after any mutation. Deterministic hashes
  are not resistant to deliberate collision attacks. No hidden destructor or
  equality fallback is introduced. Deque and ordered maps are deferred.
- **Algorithms and callbacks.** Options: insertion/quicksort; stable mergesort;
  language closures. **Chosen: stable bottom-up mergesort**, O(n log n) time and
  O(n) scratch, on mutable spans of Free elements. sortBy uses Fn[T,T,Ordering];
  named functions can compare record fields, with no captured state. binarySearch
  returns the first equal index or None. reverse on spans, min/max, span map and
  filter complement Vector's moving map and Type-capable reverse. A comparator
  must provide a consistent total order; copying sort of linear elements is
  deliberately rejected. Move-aware sorting and closures can be added separately.
- **Text.** Options: separate Text module; extend String; require UTF-8 validity.
  **Chosen: extend Standard.String, with borrowed byte-span inputs**, keeping
  existing byte-string semantics. Owned outputs work with Standard.Format.Text
  through String.slice. equals/find/findFrom/contains/startsWith/endsWith operate
  on bytes, including NUL. Empty needles match a boundary. split preserves empty
  fields; an empty separator splits bytes (empty input gives zero fields). Its
  Vector[String] owns every field. join borrows Strings and copies their bytes.
  replace uses non-overlapping matches; empty needle inserts at every byte
  boundary. trim returns a borrowed view removing ASCII 09-0D/20 whitespace.
  ASCII case conversion copies and preserves other bytes. Strict decodeUtf8
  returns Result[Decoded,Utf8Error], rejecting truncation, overlong encodings,
  surrogates and values above U+10FFFF. utf8Next emits U+FFFD and advances one byte
  on invalid input; utf8Length uses exactly that policy. parseInt/parseNat and
  radix variants (2-36) return Result with empty/digit-position/overflow/radix
  errors. Parsing accepts an optional sign (Nat accepts +), consumes the whole
  input and checks limits before arithmetic, including INT64_MIN and UINT64_MAX.
- **Implementation boundary.** Pure library operations use the same generated
  runtime on host and CoolOS. Buffer.borrowNth is bounds checked; its only unsafe
  operation returns an element pointer tied to the owner's region. HashMap's
  internal owning-buffer swap moves the old field once and stores the replacement
  once. Other collection/text/algorithm code uses checked APIs. The compiler carries caller-selected typeclass evidence through nested
  generic calls and function values, including constraints of generic instances.
  String tokens are distinguished from keyword/operator tokens. Its
  read-reference type assertion now also accepts reference field paths, enabling
  mutable field borrows to be shortened to read-only views without copying data.

The executable suites in `warmc/standard/test/{Eq,Vector,HashMap,HashSet,
Algorithms,Text}.warm` run on the host and CoolOS, both precompiled and through
WarmRun. Tests exercise primitive and generic span instances, caller-provided
collision hashes (including nested span keys), linear String values through
rehash/drain, tombstones/churn, iterator exhaustion, stable ordering of equal
record keys, first-duplicate binary search, UTF-8 errors, numeric limits and a
Format round trip. `test_stdlib.py` additionally verifies seven ownership/API
rejections and four checked runtime aborts. The unchanged Top and file-stream
behavior tests cover their migrated comparison helpers.

### Microbenchmarks

Reproduce with `python3 tools/warm-stdlib-perf.py`; code, five raw samples and
checksums are in `warmc/perf/stdlib/`. Measured 2026-10-01 on Apple M6,
macOS 27.0 arm64, Warm host native (coolc arm64). OS.Time.monotonicMs has whole
millisecond resolution. Values below are medians of five samples, not a host /
CoolOS speed comparison. Push/insert include growth and allocation; sorting
excludes input construction and result validation. Every sort checks its order
and every lookup contributes to a checked, repeatable checksum.

| Operation | Elements | Median ms | Sample range ms |
|---|---:|---:|---:|
| Vector push | 1,000,000 | 7 | 6-8 |
| Vector get | 1,000,000 | 1 | 0-1 |
| HashMap insert | 100,000 | 13 | 12-14 |
| HashMap lookup | 100,000 | 2 | 1-2 |
| Stable sort, reverse | 100,000 | 9 | 9-10 |
| Stable sort, deterministic shuffled integers | 100,000 | 10 | 9-10 |
| Stable sort, reverse | 1,000,000 | 109 | 107-110 |
| Stable sort, deterministic shuffled integers | 1,000,000 | 123 | 122-140 |

The get/lookup runs are close to timer resolution; their per-operation costs
should not be inferred precisely from these millisecond readings. Shuffled
input is `(i * 48271) % 2147483647`, deterministic and validated after sorting.
No fragile performance threshold is added to correctness tests.
