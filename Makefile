KSRC    := $(wildcard os/Kernel/*.HC os/Kernel/*.HH)
COOLC_SEED := $(abspath coolc/seed/Compiler.BIN)

.PHONY: all run test reloc-check clean fmt fmt-check hooks native-host native-kernel
all: build/kernel.Image

# Native macOS BIN loader and checked-in self-hosted compiler image.
native-host: build/coolc
build/coolc: coolc/Host/native.c coolc/Host/except.S | build
	clang -std=c11 -Wall -Wextra -Werror -O2 -fno-omit-frame-pointer -ffixed-x28 $^ -o $@

native-kernel: build/Kernel.BIN

# B is the build directory, IMAGE_BASE the link address (module = +2 MiB). Only
# `make reloc-check` changes them, to build a second Image at another base.
B ?= build
IMAGE_BASE ?= 0x800200000
MODULE_BASE := $(shell printf '0x%x' $$(($(IMAGE_BASE) + 0x200000)))

$(B)/Kernel.BIN: $(KSRC) coolc/seed/Compiler.BIN build/coolc | $(B)
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc os/Kernel/Kernel.HC $@ > $(B)/coolc-kernel.log 2>&1
	tail -1 $(B)/coolc-kernel.log

build/hcfmt.BIN: coolc/Fmt/Native.HC coolc/Fmt/HCFmt.HC coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc coolc/Fmt/Native.HC $@ > build/hcfmt-compile.log 2>&1
	tail -1 build/hcfmt-compile.log

# -q keeps relocations in the ELF for tools/reloc-check.py.
LD := aarch64-elf-ld --no-warn-rwx-segments -q -T os/Kernel/Kernel.ld --defsym IMAGE_BASE=$(IMAGE_BASE) --defsym MODULE_BASE=$(MODULE_BASE)
ASM_OBJS := $(B)/Boot.o $(B)/Arch.o

$(B)/%.o: os/Kernel/%.S os/Kernel/Asm.h | $(B)
	aarch64-elf-gcc -c $< -o $@

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

$(B)/kernel.raw $(B)/syms.ld: $(B)/Kernel.BIN $(B)/arch.syms tools/binlink.py
	python3 tools/binlink.py --org $(MODULE_BASE) $< $(B)/kernel.raw $(B)/syms.ld $(B)/arch.syms

# Pass 2: the real link; check the assembly didn't move.
$(B)/cool.elf: $(B)/kernel.raw $(B)/syms.ld $(ASM_OBJS) tools/Kernel.S
	aarch64-elf-as -I $(B) tools/Kernel.S -o $(B)/Kernel.o
	$(LD) $(B)/syms.ld $(ASM_OBJS) $(B)/Kernel.o -o $@
	aarch64-elf-nm $@ | grep -F -f $(B)/arch.syms | cmp -s - $(B)/arch.syms \
	  || { echo "assembly symbols moved between link passes"; rm -f $@; exit 1; }

$(B)/kernel.Image: $(B)/cool.elf
	aarch64-elf-objcopy -O binary $< $@

# Relocation completeness: no absolute relocations in the assembly, and a second
# Image linked 4 MiB higher differs from the first exactly at the table's sites.
reloc-check: build/kernel.Image
	python3 tools/reloc-check.py --elf build/cool.elf
	mkdir -p build/alt
	cp build/Kernel.BIN build/alt/Kernel.BIN
	$(MAKE) B=build/alt IMAGE_BASE=0x800600000 build/alt/kernel.Image
	python3 tools/reloc-check.py --elf build/alt/cool.elf
	python3 tools/reloc-check.py --compare build/cool.elf build/kernel.Image build/alt/cool.elf build/alt/kernel.Image

run: build/kernel.Image coolvm
	gtimeout 60 build/coolvm --cpus 2 --mem 1024 --timeout 55 $<

# Boots at the link address and again 4 MiB higher, so Boot.S relocates.
test: build/kernel.Image reloc-check coolvm
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
