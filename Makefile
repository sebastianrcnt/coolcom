# Kernel parts written in Warm: warmc --kernel-module turns each into a Cool file in os/Kernel
# that Kernel.cool includes (generated, not committed; see the rule below).
WARM_KMODS := os/Kernel/NetParse.cool
KSRC    := $(sort $(wildcard os/Kernel/*.cool os/Kernel/*.coolh coolc/Runtime/*.cool) $(WARM_KMODS)) coolc/Fmt/HCTok.cool
COOLC_SEED := $(abspath coolc/seed/Compiler.BIN)

.PHONY: c2hc-test stbtt-test all run test kernel-test kernel-test-reloc vim-test key-test tmux-test ansi-test syntax-test disk-install disk-seed reloc-check clean fmt fmt-check hooks native-host native-kernel seed font selfhost-test m1n1-payload text-test ime-test kernel-rebuild-test top-test cmdline-test checks-test
all: build/kernel.Image

# Native macOS BIN loader and checked-in self-hosted compiler image.
native-host: build/coolc
build/coolc: coolc/Host/native.c coolc/Host/warm_net.h coolc/Host/except.S | build
	clang -std=c11 -Wall -Wextra -Werror -O2 -fno-omit-frame-pointer -ffixed-x28 $(filter %.c %.S,$^) -o $@

native-kernel: build/Kernel.BIN

# Rebuild the seed from the current compiler sources: the old seed compiles
# gen1, gen1 compiles gen2, gen2 compiles gen3; gen2 must equal gen3.
SEEDC = COOLC_COMPILER_BIN=$(abspath $(1)) gtimeout 90 build/coolc build/native-src/Native.cool $(2) > $(2).log 2>&1 || { tail -5 $(2).log; exit 1; }
seed: build/coolc
	tools/native/prepare.sh
	$(call SEEDC,$(COOLC_SEED),build/seed1.BIN)
	$(call SEEDC,build/seed1.BIN,build/seed2.BIN)
	$(call SEEDC,build/seed2.BIN,build/seed3.BIN)
	cmp build/seed2.BIN build/seed3.BIN
	cp build/seed2.BIN coolc/seed/Compiler.BIN
	@echo "seed updated (commit coolc/seed/Compiler.BIN)"

# Style checks (coolc --vet; Vet in the OS): [assign-cond] [empty-stmt] [unreachable]. Reports
# the count per check for each program, the findings go to build/vet/NAME.log. It never fails.
.PHONY: vet
VET_UNITS := kernel=os/Kernel/Kernel.cool compiler=build/native-src/Native.cool warm=warmc/Native.cool hcfmt=coolc/Fmt/Native.cool
vet: build/coolc
	tools/native/prepare.sh
	mkdir -p build/warmcool build/vet
	python3 warmc/embed_builtins.py
	@for u in $(VET_UNITS); do \
	  name=$${u%%=*}; src=$${u#*=}; \
	  COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 90 build/coolc --vet $$src > build/vet/$$name.log 2>&1; \
	  printf '%-9s %s\n' $$name "$$(grep '^Vet:' build/vet/$$name.log || echo 'vet failed, see build/vet/'$$name.log)"; \
	done

# Regenerate the console font blob from GNU Unifont's .hex source (downloaded
# into the gitignored vendor/unifont). The generated os/Kernel/Unifont.BIN is
# committed, so a normal build needs neither the download nor Python here.
font:
	python3 tools/mkfont.py "$$(tools/vendor-unifont.sh | tail -1)" os/Kernel/Unifont.BIN

# B is the build directory, IMAGE_BASE the link address (module = +2 MiB). Only
# `make reloc-check` changes them, to build a second Image at another base.
B ?= build
IMAGE_BASE ?= 0x800200000
MODULE_BASE := $(shell printf '0x%x' $$(($(IMAGE_BASE) + 0x200000)))

$(B)/Kernel.BIN: $(KSRC) coolc/seed/Compiler.BIN build/coolc | $(B)
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc os/Kernel/Kernel.cool $@ > $(B)/coolc-kernel.log 2>&1
	tail -1 $(B)/coolc-kernel.log

# The Warm formatter (tools/warmfmt): warmc/FmtNative.cool, built on the lexer of warmc.
build/warmfmt.BIN: warmc/FmtNative.cool warmc/Format.cool warmc/Core.cool warmc/Lexer.cool coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc warmc/FmtNative.cool $@ > build/warmfmt-compile.log 2>&1
	tail -1 build/warmfmt-compile.log

build/hcfmt.BIN: coolc/Fmt/Native.cool coolc/Fmt/HCFmt.cool coolc/Fmt/HCTok.cool coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc coolc/Fmt/Native.cool $@ > build/hcfmt-compile.log 2>&1
	tail -1 build/hcfmt-compile.log

# -q keeps relocations in the ELF for tools/reloc-check.py.
LD := aarch64-elf-ld --no-warn-rwx-segments -q -T os/Kernel/Kernel.ld --defsym IMAGE_BASE=$(IMAGE_BASE) --defsym MODULE_BASE=$(MODULE_BASE)
ASM_OBJS := $(B)/Boot.o $(B)/Arch.o $(B)/Blob.o $(B)/FontData.o

$(B)/%.o: os/Kernel/%.S os/Kernel/Asm.h | $(B)
	aarch64-elf-gcc -c $< -o $@
# Blob.S embeds the compiler seed (.incbin); binlink puts the shell prelude in the module.
$(B)/Blob.o: coolc/seed/Compiler.BIN
# FontData.S embeds the console font (os/Kernel/Unifont.BIN, made by `make font`).
$(B)/FontData.o: os/Kernel/Unifont.BIN
build/ShellPrelude.coolh: $(KSRC) tools/mkprelude.py | build
	python3 tools/mkprelude.py os/Kernel/Kernel.cool > $@

# Pass 1: link the assembly alone (HolyC symbols unresolved) to learn where its
# routines land; the addresses don't depend on the HolyC module. The unresolved
# symbols get a nearby stand-in so pc-relative references stay in range.
$(B)/arch.syms: $(ASM_OBJS) os/Kernel/Kernel.ld
	mkdir -p $(B)/pre
	aarch64-elf-ld -r $(ASM_OBJS) -o $(B)/pre/all.o
	aarch64-elf-nm -u $(B)/pre/all.o | awk '{print $$2 " = $(MODULE_BASE);"}' > $(B)/pre/syms.ld
	echo 'KBSS_END = $(MODULE_BASE);' >> $(B)/pre/syms.ld
	$(LD) $(B)/pre/syms.ld $(ASM_OBJS) -o $(B)/pre/arch.elf
	aarch64-elf-nm $(B)/pre/arch.elf | grep ' [Tt] ' > $@

# The assembly for MakeKernel, the in-OS linker (tools/mkbootstub.py): linked
# like pass 1 but with stand-ins only for binlink's symbols, so the linker
# script's own (__bss_*, boot_text_end, image_end) keep their real values.
$(B)/BootStub.BIN: $(B)/arch.syms tools/mkbootstub.py
	grep -v -e '^__bss_' -e '^boot_text_end ' -e '^image_end ' $(B)/pre/syms.ld > $(B)/pre/stub-syms.ld
	$(LD) $(B)/pre/stub-syms.ld $(ASM_OBJS) -o $(B)/pre/stub.elf
	python3 tools/mkbootstub.py $(B)/pre/stub.elf $(B)/arch.syms $@

BLOBS := SHELL_PRELUDE=build/ShellPrelude.coolh ARM64_OPS=os/Kernel/Arm64Ops.csv
$(B)/kernel.raw $(B)/syms.ld: $(B)/Kernel.BIN $(B)/arch.syms tools/binlink.py $(foreach b,$(BLOBS),$(word 2,$(subst =, ,$(b))))
	python3 tools/binlink.py --org $(MODULE_BASE) $(addprefix --blob ,$(BLOBS)) $< $(B)/kernel.raw $(B)/syms.ld $(B)/arch.syms

# Pass 2: the real link; check the assembly didn't move.
$(B)/cool.elf: $(B)/kernel.raw $(B)/syms.ld $(ASM_OBJS) tools/Kernel.S
	aarch64-elf-as -I $(B) tools/Kernel.S -o $(B)/Kernel.o
	$(LD) $(B)/syms.ld $(ASM_OBJS) $(B)/Kernel.o -o $@
	aarch64-elf-nm $@ | grep -F -f $(B)/arch.syms | cmp -s - $(B)/arch.syms \
	  || { echo "assembly symbols moved between link passes"; rm -f $@; exit 1; }

$(B)/kernel.Image: $(B)/cool.elf
	aarch64-elf-objcopy -O binary $< $@

# Real-hardware boot payload (docs/m1-platform.md section 2.2): m1n1 + the Mac
# mini (j274) DTB + our gzip'd Image, checked by parsing it back. Install it as
# m1n1's stage 2 or chainload it; M1N1_BOOTARGS sets /chosen/bootargs. m1n1 and
# the DTB are fetched and built in vendor/ by tools/vendor-m1n1.sh (the first
# m1n1 build takes about 10 minutes; needs brew llvm@21 lld@21, rustup rust-src, dtc).
m1n1-payload: build/m1n1-payload.bin
build/m1n1-payload.bin: build/kernel.Image tools/m1n1-payload.py tools/vendor-m1n1.sh
	tools/vendor-m1n1.sh > build/m1n1-vendor.txt
	python3 tools/m1n1-payload.py $$(tail -2 build/m1n1-vendor.txt) $< $@ $(if $(M1N1_BOOTARGS),--bootargs "$(M1N1_BOOTARGS)")

# Relocation completeness: no absolute relocations in the assembly, and a second
# Image linked 4 MiB higher differs from the first exactly at the table's sites.
reloc-check: build/kernel.Image
	python3 tools/reloc-check.py --elf build/cool.elf
	mkdir -p build/alt
	cp build/Kernel.BIN build/alt/Kernel.BIN
	$(MAKE) B=build/alt IMAGE_BASE=0x800600000 build/alt/kernel.Image
	python3 tools/reloc-check.py --elf build/alt/cool.elf
	python3 tools/reloc-check.py --compare build/cool.elf build/kernel.Image build/alt/cool.elf build/alt/kernel.Image

# build/disk.img is the persistent C: drive for make run (FAT32; mount it on
# the Mac with `hdiutil attach build/disk.img` while the VM is not running).
build/disk.img: | build
	mkfile -n 64m $@
	mformat -i $@ -F -v COOLDISK ::

# make run only adds files that are missing, so edits made inside the OS
# survive; `make disk-install` overwrites them with the repo versions.
# tools/disk-files.sh copies os/Disk programs/examples, Warm.cool, and kernel sources (C:/Kernel, for Man).
# C:/Kernel.coolh (the shell prelude) declares the kernel for programs compiled
# with Cmp; C:/Compiler holds the compiler sources (tools/native/prepare.sh), so
# Cmp("C:/Compiler/Native.cool") in the OS rebuilds coolc/seed/Compiler.BIN.
# tools/disk-files.sh puts os/Kernel in C:/Kernel and the runtime files it
# includes as ../../coolc/... in C:/coolc (".." stops at the root), and the
# prebuilt assembly C:/Kernel/BootStub.BIN, so `MakeKernel` in the OS rebuilds
# build/kernel.Image (docs/kernel-rebuild.md).
# Package the Cool implementation of Warm for the kernel shell. disk-files.sh
# also requests this target when populating a test or external disk image.
WARMSRC := coolc/LibC/LibC.cool $(wildcard warmc/*.cool warmc/builtin/*.warmh warmc/builtin/*.warm) warmc/build.sh warmc/embed_builtins.py coolc/seed/Compiler.BIN
build/warmcool/Warm.BIN: $(WARMSRC) build/coolc
	./warmc/build.sh
build/warmcool/Kernel.cool: build/warmcool/Warm.BIN warmc/package_kernel.py warmc/OSKernel.cool warmc/OSCommon.cool warmc/OSDirKernel.cool warmc/OSNetCommon.cool warmc/OSNetKernel.cool
	python3 warmc/package_kernel.py

# The network stack's packet parser (docs/networking.md), compiled to os/Kernel/NetParse.cool.
# That file is in .gitignore, but tools/disk-files.sh copies it to C:/Kernel with the other
# sources, so MakeKernel compiles it too.
os/Kernel/NetParse.cool: os/Kernel/NetParse.warm build/warmc
	build/warmc compile $(filter %.warm,$^) --kernel-module=NetParse --target-type=hc --output=build/NetParse.cool.tmp
	{ printf '// Generated by build/warmc from %s; do not edit (Makefile).\n' "$(notdir $(filter %.warm,$^))"; cat build/NetParse.cool.tmp; } > $@
	rm build/NetParse.cool.tmp

# The Warm compiler on the host: build/warmc compile ... (warmc/README.md), or tools/warm run Foo.warm.
build/warmc: build/warmcool/Warm.BIN
	printf '#!/bin/sh\nexec "%s/build/coolc" --run "%s/build/warmcool/Warm.BIN" "$$@"\n' "$(CURDIR)" "$(CURDIR)" > $@
	chmod +x $@

# The Warm compiler's own tests: every test-programs case against its stored expectation, and the probes.
.PHONY: warm-test
warm-test: build/warmc build/warmcool/Kernel.cool build/warmfmt.BIN
	python3 warmc/compare.py
	python3 warmc/test_frontend.py
	python3 warmc/test_semantics.py
	python3 warmc/test_numbers.py
	python3 warmc/test_cli.py
	python3 warmc/test_standard.py
	python3 warmc/test_os.py
	python3 warmc/test_fmt.py

disk-install: build/disk.img build/ShellPrelude.coolh build/BootStub.BIN
	tools/disk-files.sh build/disk.img
	mcopy -o -i build/disk.img build/ShellPrelude.coolh ::Kernel.coolh
	tools/native/prepare.sh
	mdir -i build/disk.img ::Compiler >/dev/null 2>&1 || mmd -i build/disk.img ::Compiler </dev/null
	mcopy -o -i build/disk.img build/native-src/* ::Compiler/

disk-seed: build/disk.img build/ShellPrelude.coolh build/BootStub.BIN
	tools/disk-files.sh build/disk.img -n
	@mdir -i build/disk.img ::Kernel.coolh >/dev/null 2>&1 || mcopy -i build/disk.img build/ShellPrelude.coolh ::Kernel.coolh
	@mdir -i build/disk.img ::Compiler >/dev/null 2>&1 || { tools/native/prepare.sh && \
	  mmd -i build/disk.img ::Compiler && mcopy -i build/disk.img build/native-src/* ::Compiler/; }

.PHONY: run-qemu qemu-test
# QEMU virt uses the same relocatable arm64 Image and modern virtio-MMIO devices.
# QEMU_ACCEL=auto (default) probes HVF and falls back to TCG; see tools/qemu.py.
run-qemu: build/kernel.Image disk-seed
	python3 tools/qemu.py $< build/disk.img

qemu-test: build/kernel.Image
	python3 tools/qemu-test.py $<

run: build/kernel.Image coolvm disk-seed
	build/coolvm --cpus 2 --mem 1024 --disk build/disk.img $<

# make run with the Mac's ports 2323 and 8080 forwarded to the guest's 23 and 80:
# ShellServe(23); then tools/rsh.sh; HttpServe(80); then curl localhost:8080/ (docs/networking.md).
run-net: build/kernel.Image coolvm disk-seed
	build/coolvm --cpus 2 --mem 1024 --disk build/disk.img --net-forward 2323:23 --net-forward 8080:80 $<

# Boots at the link address and again 4 MiB higher, so Boot.S relocates.
vim-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/vim-test.py $<

# Ctrl+B, Up and Esc must give the same key events from the window and the UART.
key-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/key-test.py $<

tmux-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/tmux-test.py $<

# 256-color/truecolor SGR, cursor save/restore and AnsiTermSize (os/Kernel/Ansi.cool), on the console and in Tmux.
ansi-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/ansi-test.py $<

# Vim highlighting by file extension, block-comment state and compiler symbol-table colors (os/Kernel/Syntax.cool).
syntax-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/syntax-test.py $<

# The compiler's checks: errors for definite bugs, the vet findings (coolc/tests/checks).
checks-test: build/coolc
	tools/native/checks.sh

# The OS compiles its own compiler: Cmp in the shell must reproduce the seed.
selfhost-test: build/kernel.Image coolvm build/ShellPrelude.coolh build/warmcool/Kernel.cool
	tools/selfhost-test.sh $<

# The OS rebuilds its own kernel: MakeKernel in the shell must reproduce build/kernel.Image,
# and a kernel it changed and rebuilt must boot to a shell prompt through Reboot (about 6 s).
kernel-rebuild-test: build/kernel.Image build/BootStub.BIN build/ShellPrelude.coolh coolvm build/warmcool/Kernel.cool
	tools/kernel-rebuild-test.sh $<

# Find, HexDump, Diff, Less and Man on C: (os/Disk); the kernel sources go to C:/Kernel (tools/disk-files.sh).
text-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/text-test.py $<

# Hangul 2-beolsik input from the window's keyboard (os/Kernel/Ime.cool).
ime-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/ime-test.py $<

# coolvm --net-forward into ShellServe (remote shells) and HttpServe, and Wget to C: (os/Kernel/NetShell.cool, NetHttp.cool).
net-forward-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/net-forward-test.py $<

# Top: tasks per core with state and CPU share, heap and FAT32 lines, sort, kill.
top-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/top-test.py $<

# Unix-style command lines (vim a.cool, find foo) and Tab completion in the shell (os/Kernel/ShellCmd.cool).
cmdline-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/cmdline-test.py $<

# Every check boots its own VMs with its own disk images and output directory, so
# `make -j test` runs them side by side. The input scripts sync on the guest's output
# (coolvm `wait`) instead of fixed delays, which keeps them right under that load.
test: gpu-resize-test gpu-pixel-test scroll-test checks-test warm-test reloc-check vim-test key-test tmux-test ansi-test syntax-test warm-kernel-test selfhost-test text-test ime-test top-test kernel-rebuild-test cmdline-test net-forward-test kernel-test kernel-test-reloc qemu-test lua-test lua-kernel-test c2hc-test stbtt-test

# The device and shell self-tests (DevTest.cool), at the link address and 4 MiB higher.
kernel-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	tools/kernel-test.sh $<
kernel-test-reloc: build/kernel.Image coolvm build/warmcool/Kernel.cool
	tools/kernel-test.sh $< --load-offset 0x600000

$(B):
	mkdir -p $(B)

clean:
	rm -rf build

# HolyC formatting (coolc/Fmt) and Warm formatting (warmc/Format.cool). The pre-commit hook runs
# fmt-check on staged files. The suites and the formatter's own fixtures keep their layout
# (the suites' expected diagnostics carry line and column numbers).
HC_FILES = $(shell git ls-files -- '*.cool' '*.coolh' | grep -v -e '^coolc/third_party/' -e '^coolc/Fmt/tests/')
WARM_FILES = $(shell git ls-files -- '*.warm' '*.warmh' | grep -v -e '^warmc/test-programs/suites/' -e '^warmc/fmt-tests/')
fmt:
	tools/hcfmt.sh $(HC_FILES)
	tools/warmfmt $(WARM_FILES)
fmt-check:
	tools/hcfmt.sh --check $(HC_FILES)
	tools/warmfmt --check $(WARM_FILES)
hooks:
	git config core.hooksPath tools/git-hooks

# Apple Virtualization.framework UEFI probe (boot/uefi-probe, tools/vzrun).
# Needs: brew install mtools gptfdisk llvm@21 lld@21
.PHONY: vzprobe vzprobe-gui
vzprobe:
	tools/vzprobe.sh
vzprobe-gui:
	tools/vzprobe.sh --gui --cfg "wait=9 postwait=8"

# coolvm: VM monitor on macOS Hypervisor.framework emulating a subset of the Apple M1 (t8103)
# for developing the M1 drivers (tools/coolvm). Guests run under a timeout.
.PHONY: coolvm coolvm-test
coolvm:
	tools/coolvm/build.sh
coolvm-test: coolvm
	tools/coolvm/test/run.sh

# Small AST-based C to Cool differential tests.
c2hc-test: build/coolc
	python3 tools/c2hc/test.py

stbtt-test: build/coolc build/hcfmt.BIN
	python3 tools/c2hc/stbtt_test.py

.PHONY: warm-kernel-test
warm-kernel-test: build/kernel.Image coolvm build/warmcool/Kernel.cool build/warmc
	mkdir -p build/tmp
	python3 tools/warm-kernel-test.py

# Compare complete scanout pixels with the software fallback, including ring wraps
# and fixed margins; assert FDT capability selection rather than only the picture.
SCROLL_TEST_SIZES := --size 1024x768 --size 3200x2000 --size 1031x775 --size 1024x775
.PHONY: scroll-test
scroll-test: build/kernel.Image coolvm
	python3 tools/scroll-bench.py scroll-test-ref $< --repeat 1 --lines 160 $(SCROLL_TEST_SIZES) --extra=--no-fb-scroll --expect-scanout 0
	python3 tools/scroll-bench.py scroll-test-hw $< --repeat 1 --lines 160 $(SCROLL_TEST_SIZES) --expect-scanout 1 --compare scroll-test-ref
# Lua is translated source, outside the compiler seed and kernel image.
LUASRC := $(wildcard vendor/lua-5.4.9/src/*.[ch] tools/c2hc/*.py coolc/LibC/include/*.h) tools/lua-support/build.py tools/lua-support/Kernel.cool tools/lua-support/Host.cool
build/lua/generated.stamp: $(LUASRC) build/ShellPrelude.coolh
	python3 tools/lua-support/build.py
	touch $@
build/lua/Lua.cool build/lua/LuaRuntime.cool: build/lua/generated.stamp
	@test -f $@ || { rm -f build/lua/generated.stamp; $(MAKE) build/lua/generated.stamp; }
build/lua/Lua.BIN: build/lua/Lua.cool coolc/LibC/LibC.cool build/coolc coolc/seed/Compiler.BIN
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc build/lua/Host.cool $@ > build/lua/compile.log 2>&1
	tail -1 build/lua/compile.log

.PHONY: lua-test lua-kernel-test
lua-test: build/lua/Lua.BIN
	python3 tools/lua-support/test.py
lua-kernel-test: build/lua/LuaRuntime.cool build/kernel.Image coolvm
	python3 tools/lua-support/kernel_test.py
	python3 tools/scroll-bench.py scroll-test-ref $< --repeat 1 --lines 160 $(SCROLL_TEST_SIZES) --extra=--no-gpu --extra=--no-fb-scroll --expect-scanout 0
	python3 tools/scroll-bench.py scroll-test-hw $< --repeat 1 --lines 160 $(SCROLL_TEST_SIZES) --extra=--no-gpu --expect-scanout 1 --compare scroll-test-ref

.PHONY: gpu-pixel-test
gpu-pixel-test: build/kernel.Image coolvm
	python3 tools/scroll-bench.py gpu-pixel-ref $< --repeat 1 --lines 160 --size 640x480 --size 1031x775 --extra=--no-gpu --expect-gpu 0
	python3 tools/scroll-bench.py gpu-pixel $< --repeat 1 --lines 160 --size 640x480 --size 1031x775 --expect-gpu 1 --compare gpu-pixel-ref

.PHONY: gpu-resize-test
gpu-resize-test: build/kernel.Image coolvm build/warmcool/Kernel.cool
	python3 tools/gpu-resize-test.py $<
