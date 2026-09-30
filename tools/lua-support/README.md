# Lua 5.4 on Coolcom

The unchanged Lua 5.4.9 release is in vendor/lua-5.4.9. It was downloaded from
https://www.lua.org/ftp/lua-5.4.9.tar.gz with SHA-256
2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6.
The release includes its MIT license in doc/readme.html and the source headers.

`tools/lua x.lua` builds and runs the translated interpreter with build/coolc;
`tools/lua` opens its REPL. `make disk-install` installs the shared libc, the Lua
loader and translated runtime. In the OS, use `Lua("C:/x.lua");` or `Lua;`.
`os.exit()` returns to the shell; invocation allocations and file streams are
released by LibCRun. Each call starts a new Lua state. The large runtime is loaded
on the first call in each shell, outside the kernel image and compiler seed.

build.py translates all interpreter and standard-library C files except luac.c
through tools/c2hc, with Lua's supported LUA_USE_JUMPTABLE=0 switch interpreter.
No generated Cool source is edited. The OS build reserves names from Kernel.coolh;
the host build uses the same shared LibC.cool and native OS primitive bindings.

The C locale, UTC clock, math, io files, strings, tables, closures, coroutines and
protected calls use Cool/OS services. C stdio buffers whole files and flushes on
fflush/fclose. Processes, environment variables, signals, shell pipes and dynamic
native modules are not supplied by this OS; package Lua-file loading is available.
The standard interpreter's options (-e, -i, -v, etc.) remain available on the host.
C float is widened by c2hc; Lua's default lua_Number is already double.

`make lua-test` runs a short host smoke test (strings, tables, closures, pcall,
string.format, io.write, errors and REPL). `make lua-kernel-test` boots the OS and
checks file execution, REPL and repeated invocation. Both are part of make test,
as are the c2hc and stbtt comparisons.
