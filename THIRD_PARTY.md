# Third-party code

The MIT license in `LICENSE` covers coolcom's own code. These parts come from other
projects and keep their licenses; the files carry their origin in a header comment.

| What | Where | License |
|---|---|---|
| TempleOS (Terry A. Davis): runtime library, FAT32, compiler frontend lineage | `coolc/Runtime`, `coolc/Frontend`, parts of `os/Kernel` | Public domain |
| Aiwnios (nrootconauto): compiler frontend and ARM64/x86-64 backends, `KernelA` headers | `coolc/Frontend`, `coolc/Compiler` | BSD-3-Clause (see file headers) |
| Austral (Fernando Borretti): language, standard library, test suite, from which Warm is forked | `warmc/` | Apache-2.0 WITH LLVM-exception (`warmc/LICENSE`, `warmc/standard/LICENSE`) |
| Lua 5.4.9 (PUC-Rio) | `vendor/lua-5.4.9` | MIT |
| stb_truetype (Sean Barrett) | `coolc/Lib/StbTrueType.cool`, `tools/c2hc` | Public domain / MIT |
| GNU Unifont | `os/Kernel/Unifont.BIN`, `os/Kernel/FontData.S` | GPL-2.0+ with font embedding exception / OFL-1.1 (`os/Kernel/Unifont-LICENSE.txt`) |
| tree-sitter-holyc and zed-holyc (project-solomon) | `tools/zed-coolcom` | MIT (`tools/zed-coolcom/LICENSE`) |
