# How shell code finds functions (JIT linking)

Code typed at the shell, `#include`d from it or run with `ExeFile`/`WarmRun` is JIT-compiled
by that shell's compiler into that shell's hash table. This page is about one question:
when such code calls a function, what can it reach, and when is `extern` right?

## What a shell can call

| Kind | Where it comes from | How to call it |
|---|---|---|
| Kernel functions | Every kernel symbol (`KSym.cool`, the table `tools/binlink.py` puts in the Image) is registered as a **system symbol** of the shell (`ShellSyms` in `os/Kernel/Shell.cool`). The shell prelude (`build/ShellPrelude.coolh`, made by `tools/mkprelude.py`) holds an `extern` prototype for each one. | Just call it; the prelude's `extern` binds it. |
| Compiler runtime hooks | `ShellRt(...)` in `Shell.cool` registers a few more system symbols (`Yield`, `FlushMsgs`, ...). | Just call it. |
| Exports of a loaded BIN | `Load("X.BIN")` adds the BIN's exports as system symbols of this shell (`os/Kernel/ShellCmp.cool`). | Declare it with `extern`, then call it. |
| Functions defined in shell code | Compiled into the shell's hash table by an earlier line, `#include` or `ExeFile` in the same shell. | Call it by name: **no `extern`**. |

## The rule for `extern`

In JIT code, `extern` binds a prototype to an **existing system symbol of the same name**.
It never refers to a function defined in JIT code, and it cannot create a symbol. So:

- **Defined in the same shell (or the same package/file)?** Don't write `extern`. Declare
  the prototype plainly if it's used before its definition, or order the definitions.
  An `extern` for it finds no system symbol and fails with `Undefined Extern`.
- **A kernel function that doesn't exist yet?** Add it to `os/Kernel` and rebuild the kernel
  (`make build/kernel.Image`, then `make disk-install` so `C:/Kernel.coolh` matches). Only
  then is it a kernel symbol, and the prelude declares it for you.
- **From a BIN built with `Cmp`?** `Load` it first; then `extern` binds to its exports.
- **`Fs`, `Gs` and other register-based accessors** are not symbols; never `extern` them.

## Debugging `Undefined Extern`

Find the name in `build/syms.ld` (kernel symbols) and `build/ShellPrelude.coolh` (what the
prelude declares):

- In neither, but defined in your own JIT code → remove the `extern` (first case above).
- In neither, and meant to be kernel code → it isn't in the kernel yet; add it and rebuild.
- From a BIN → check that `Load` ran in **this** shell (each shell and Tmux pane has its
  own hash table and its own system symbols).

## Generated code (Warm, Lua, c2hc)

Generators that emit Cool for the OS (`build/warmc --kernel-module`, `package_kernel.py`,
`tools/lua-support`, `tools/c2hc`) must follow the same rule: emit plain prototypes for
functions in the generated package, and `extern` only for kernel functions or `Load`ed BIN
exports. Kernel-side helpers a generated package needs belong in `os/Kernel`.
