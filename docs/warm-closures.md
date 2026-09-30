# Warm: function values for tasks (design, for review)

Status: a proposal for stage 4 of [warm-stdlib.md](warm-stdlib.md) (`OS.Task`), which needs to
start a task that runs a function. Nothing here is implemented. Choices that are yours are
listed with options and a recommendation (**Rec.**), and collected at the end.

## What exists

- `Fn[A1, ..., An, R]` is a function value: a pointer to a top-level function (or a
  specialization of a generic one, given an asserted type). It captures nothing, its type is
  `Free`, and calling it is an ordinary call (`let f: Fn[Int32, Int32] := inc; f(1)`). In
  the generated Cool it is a `U8 *` code pointer to the function with warmc's private ABI
  (aggregates by pointer, an aggregate result through an out pointer).
- The kernel starts a task with `Spawn(U0 (*fp)(U8 *data), U8 *data, name, cpu)`: one code
  pointer and one untyped data pointer.
- Linear types, borrows with regions, and capabilities (`Tasks`, `Dir`, `Network`: linear
  tokens) are checked per function; nothing today crosses a task boundary.

## 1. Plain function pointers or closures

- **A. A function pointer plus one typed argument.** `spawn(&!tasks, worker, arg)` runs
  `worker(arg)` in the new task. `arg: T` is the whole environment: a record holding what the
  task needs (numbers, owned buffers, capabilities). No new language construct; the state is
  explicit and its type is visible in the signature.
- **B. Closures that capture by move.** `closure [dir, count] (): Unit is ... end` builds a
  value of a new linear type `Closure[R]` holding a code pointer and a heap environment.
  Nicer to write, but a new expression form, a new type, environment layout and freeing in
  the backend, and rules for calling a linear value (once) versus a reusable one.
- **C. Closures with borrowed captures** (Rust's `&` captures). Needs region-annotated
  closure types and escape analysis, and borrowed captures can never cross tasks anyway.

**Rec.: A for stage 4**, with B as a later extension designed so that it is sugar over A (an
environment record plus a function), and C not at all. A covers everything spawning needs;
closures pay off mainly for callbacks (sorting keys, iterators), which no stage needs yet.

## 2. Linear values, borrows and capabilities across a task

The rule: **a task receives only what it owns.** Concretely, with A:

- **Moving.** `arg` is passed by value, so the ordinary linearity check already consumes it
  at the spawn site: a capability or a buffer moved into a task can no longer be used by the
  parent. This is how a task gets authority: `spawn(&!tasks, logger, LogJob(dir => logsDir,
  ...))` hands it a (possibly narrowed) `Dir` and nothing else.
- **No borrows across tasks.** A reference or span points into the parent's memory with a
  region that ends when the parent's borrow ends, which a task outlives. So `T` and the
  result `R` must not contain `&`, `&!`, `Span` or `Span!` with a region other than
  `Static`. Options for enforcing it: (a) a built-in marker typeclass `Sendable` that the
  compiler implements for exactly the types with no such references, and `spawn` requires
  `generic [T: Type(Sendable), R: Type(Sendable)]`; (b) a special check on calls to `spawn`
  only; (c) no check. **Rec.: (a)**: library code stays generic (a `spawnAll` helper can
  forward the constraint) and the error names the offending type. Users cannot write
  `instance Sendable(...)`.
- **Raw pointers.** `Pointer[T]` and `Address[T]` are not `Sendable` either (they would
  smuggle a borrow). Unsafe code that really means to share memory has to pass an integer
  address and rebuild the pointer in the task, which is possible only in an unsafe module and
  stands out in review. That friction is intended.
- **RootCapability** is not `Sendable`: a task gets derived capabilities only, so what a
  task can do is always visible at the spawn site.
- **Getting values back.** The result `R` (also `Sendable`, may be linear) comes back through
  `join`. A task that returns a capability hands the authority back to its parent.
- **No shared mutable state** in stage 4: no reference-counted sharing, no locks. Tasks
  communicate by argument and result only (channels are a later extension, section 5).

## 3. Representation in the Cool backend

With A, the compiler adds almost nothing; `OS.Task` (an unsafe module) does the work in Warm:

```
record Job[T, R]: Linear is         -- one heap block per task, CAlloc'd by spawn
    body: Fn[T, R];
    arg: Option[T];                 -- taken by the task
    result: Option[R];              -- filled by the task
    state: Nat64;                   -- running, done, failed, detached (atomic in the adapter)
    message: Span[Nat8, Static];    -- the abort message when failed
end;

function trampoline[T, R](data: Address[Nat8]): Unit   -- the task's entry, called by Cool
```

- `spawn` allocates the `Job`, moves `arg` into it, and calls the adapter
  `WkSpawn(entry, job, name, cpu)`, which calls the kernel's `Spawn`. `entry` is the code
  pointer of `trampoline` specialized for `T, R`: its private-ABI signature is
  `U8 f(U8 *data)`, which a Cool `U0 (*)(U8 *)` can call because every argument is a scalar.
  The one compiler addition: an unsafe-only way to turn an `Fn` whose parameters and result
  are all scalars into an `Address[Nat8]` (e.g. `Austral.Memory.codeAddress(f)`), checked
  so that a function with aggregate parameters cannot be passed to Cool as a plain pointer.
- The trampoline runs in the new task, takes `arg`, calls `body(arg)`, stores the result and
  marks the job done. The adapter wraps it in `try`, so an abort in the task (a failed check)
  marks the job failed with its message instead of killing anything else.
- **Who frees the job:** `join` waits for done or failed (`Sleep`/`Yield` loop on the state),
  moves the result out and frees the block. `detach` marks it detached, and the trampoline
  frees it when it finishes. The state change is one atomic step (`LBts` in the adapter), so
  the block is freed exactly once whichever side comes last.
- **A killed task** (`Kill`, Ctrl+C on its shell) never finishes the trampoline: `join`
  returns `Err(Killed)`. Linear values the task owned at that moment are leaked (their
  memory is freed only if the kernel frees that task's heap); this is documented, not hidden.

Closures (B, later) reuse the same pieces: `Closure[R]` is a record of a code pointer and an
`Address` of a heap environment record whose fields are the captures; building one
allocates the environment and moves the captures in; calling it (consuming, once) calls the
code with the environment and frees it; dropping an uncalled closure is an explicit
`discard(c)` that frees the environment and must itself consume any linear captures, so a
closure holding linear captures cannot be dropped silently.

## 4. Syntax

Stage 4 adds no syntax: a task body is a named top-level function.

```
record CopyJob: Linear is
    source: Dir;           -- narrowed to read-only by the parent
    target: Dir;
    name: String;
end;

function copyOne(job: CopyJob): Result[Index, IoError] is ... end;

let task: Task[Result[Index, IoError]] := spawn(&!tasks, copyOne, CopyJob(source => ro, target => out, name => n));
...
case join(task) of
    when Ok(value: Result[Index, IoError]) do ...
    when Err(error: TaskError) do ...
end case;
```

For closures later, options: (a) an explicit capture list, `closure [ro, n] (x: Nat64): Unit is
... end`; (b) implicit captures of whatever the body names. **Rec.: (a)**: it matches Austral's
explicitness, makes moves visible (every name in the list is consumed), and keeps the parser
simple.

## 5. Stage 4 minimum, and later

Stage 4 (what Codex implements):

```
module OS.Task:
    acquireTasks(&!root): Tasks; releaseTasks(tasks)
    spawn[T: Type(Sendable), R: Type(Sendable)](tasks: &![Tasks], body: Fn[T, R], arg: T)
        : Result[Task[R], IoError]                      -- Task[R]: Linear
    spawnOn(tasks, body, arg, core: Index)              -- the same on one core
    join[R](task: Task[R]): Result[R, TaskError]        -- TaskError: Aborted(message), Killed
    detach[R: Free](task: Task[R]): Unit                -- only when nothing linear comes back
    sleep(&tasks, ms); yield(&tasks)
```

Compiler work: the `Sendable` marker typeclass and `codeAddress` for scalar-only `Fn`s. The
rest is `OS.Task` in Warm and a few adapter functions (`WkSpawn`, the atomic state, the
`try` around the trampoline).

Later, in this order: channels (`Channel[T: Sendable]` split into linear `Sender`/`Receiver`
ends, the way to talk to a running task); move closures (B), first called-once, then reusable
ones whose captures are all `Free`; shared read-only data (`Shared[T]` for `Free` `T`,
reference-counted); cancellation (a token the parent can set and the task polls).

## Decisions for you

1. Function values for stage 4: **A, a function pointer and one typed argument**; B closures
   now; or C.
2. Keeping borrows out of tasks: **a built-in `Sendable` marker**, a check on `spawn` only, or
   none.
3. `RootCapability` in a task: **not allowed** (derived capabilities only), or allowed.
4. `detach`: **only for `Free` results**, always, or not at all.
5. An abort inside a task: **the task fails and `join` returns `Err(Aborted)`**, or the abort
   also stops the parent.
6. Later closure syntax: **explicit capture list**, or implicit captures.

**Decided (user, 2026-09-30):** all six follow the recommendations: A (function pointer +
one typed argument), a built-in `Sendable` marker, no `RootCapability` in tasks, `detach`
only for `Free` results, an abort fails only its task (`join` returns `Err(Aborted)`), and
an explicit capture list for later closures.
