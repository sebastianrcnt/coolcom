KSRC    := $(wildcard os/Kernel/*.HC os/Kernel/*.HH coolc/Runtime/*.HC) coolc/Fmt/HCTok.HC
COOLC_SEED := $(abspath coolc/seed/Compiler.BIN)

.PHONY: c2hc-test stbtt-test all run test vim-test key-test tmux-test ansi-test syntax-test disk-install disk-seed reloc-check clean fmt fmt-check hooks native-host native-kernel seed font selfhost-test m1n1-payload
all: build/kernel.Image

# Native macOS BIN loader and checked-in self-hosted compiler image.
native-host: build/coolc
build/coolc: coolc/Host/native.c coolc/Host/except.S | build
	clang -std=c11 -Wall -Wextra -Werror -O2 -fno-omit-frame-pointer -ffixed-x28 $^ -o $@

native-kernel: build/Kernel.BIN

# Rebuild the seed from the current compiler sources: the old seed compiles
# gen1, gen1 compiles gen2, gen2 compiles gen3; gen2 must equal gen3.
SEEDC = COOLC_COMPILER_BIN=$(abspath $(1)) gtimeout 90 build/coolc build/native-src/Native.HC $(2) > $(2).log 2>&1 || { tail -5 $(2).log; exit 1; }
seed: build/coolc
	tools/native/prepare.sh
	$(call SEEDC,$(COOLC_SEED),build/seed1.BIN)
	$(call SEEDC,build/seed1.BIN,build/seed2.BIN)
	$(call SEEDC,build/seed2.BIN,build/seed3.BIN)
	cmp build/seed2.BIN build/seed3.BIN
	cp build/seed2.BIN coolc/seed/Compiler.BIN
	@echo "seed updated (commit coolc/seed/Compiler.BIN)"

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
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc os/Kernel/Kernel.HC $@ > $(B)/coolc-kernel.log 2>&1
	tail -1 $(B)/coolc-kernel.log

build/hcfmt.BIN: coolc/Fmt/Native.HC coolc/Fmt/HCFmt.HC coolc/Fmt/HCTok.HC coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc coolc/Fmt/Native.HC $@ > build/hcfmt-compile.log 2>&1
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
build/ShellPrelude.HH: $(KSRC) tools/mkprelude.py | build
	python3 tools/mkprelude.py os/Kernel/Kernel.HC > $@

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

BLOBS := SHELL_PRELUDE=build/ShellPrelude.HH ARM64_OPS=os/Kernel/Arm64Ops.csv
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

# make run only adds os/Disk files that are missing, so edits made inside the OS
# survive; `make disk-install` overwrites them with the repo versions.
# C:/Kernel.HH (the shell prelude) declares the kernel for programs compiled
# with Cmp; C:/Compiler holds the compiler sources (tools/native/prepare.sh), so
# Cmp("C:/Compiler/Native.HC") in the OS rebuilds coolc/seed/Compiler.BIN.
DISK_FILES := os/Disk/Init.HC os/Disk/Vim.HC os/Disk/Tmux.HC os/Disk/Nyan.HC
disk-install: build/disk.img build/ShellPrelude.HH
	mcopy -o -i build/disk.img $(DISK_FILES) ::
	mcopy -o -i build/disk.img build/ShellPrelude.HH ::Kernel.HH
	tools/native/prepare.sh
	mmd -i build/disk.img ::Compiler 2>/dev/null || true
	mcopy -o -i build/disk.img build/native-src/* ::Compiler/

disk-seed: build/disk.img build/ShellPrelude.HH
	@for f in $(DISK_FILES); do \
	  mdir -i build/disk.img ::$$(basename $$f) >/dev/null 2>&1 || mcopy -i build/disk.img $$f :: || exit 1; \
	done
	@mdir -i build/disk.img ::Kernel.HH >/dev/null 2>&1 || mcopy -i build/disk.img build/ShellPrelude.HH ::Kernel.HH
	@mdir -i build/disk.img ::Compiler >/dev/null 2>&1 || { tools/native/prepare.sh && \
	  mmd -i build/disk.img ::Compiler && mcopy -i build/disk.img build/native-src/* ::Compiler/; }

run: build/kernel.Image coolvm disk-seed
	build/coolvm --cpus 2 --mem 1024 --disk build/disk.img $<

# Boots at the link address and again 4 MiB higher, so Boot.S relocates.
vim-test: build/kernel.Image coolvm
	python3 tools/vim-test.py $<

# Ctrl+B, Up and Esc must give the same key events from the window and the UART.
key-test: build/kernel.Image coolvm
	python3 tools/key-test.py $<

tmux-test: build/kernel.Image coolvm
	python3 tools/tmux-test.py $<

# 256-color/truecolor SGR, cursor save/restore and AnsiTermSize (os/Kernel/Ansi.HC), on the console and in Tmux.
ansi-test: build/kernel.Image coolvm
	python3 tools/ansi-test.py $<

# Vim highlighting by file extension, block-comment state and compiler symbol-table colors (os/Kernel/Syntax.HC).
syntax-test: build/kernel.Image coolvm
	python3 tools/syntax-test.py $<

# The OS compiles its own compiler: Cmp in the shell must reproduce the seed.
selfhost-test: build/kernel.Image coolvm build/ShellPrelude.HH
	tools/selfhost-test.sh $<

test: build/kernel.Image reloc-check coolvm vim-test key-test tmux-test ansi-test syntax-test warm-kernel-test selfhost-test
	tools/kernel-test.sh $<
	tools/kernel-test.sh $< --load-offset 0x600000

$(B):
	mkdir -p $(B)

clean:
	rm -rf build

# HolyC formatting (coolc/Fmt). The pre-commit hook runs fmt-check on staged files.
HC_FILES = $(shell git ls-files -- '*.HC' '*.HH' | grep -v -e '^coolc/third_party/' -e '^coolc/Fmt/tests/')
fmt:
	tools/hcfmt.sh $(HC_FILES)
fmt-check:
	tools/hcfmt.sh --check $(HC_FILES)
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
warm-kernel-test: build/kernel.Image coolvm
	mkdir -p build/tmp
	TMPDIR="$(CURDIR)/build/tmp" ./warmc/build.sh
	python3 tools/warm-kernel-test.py
