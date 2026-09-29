AIWNIOS ?= $(if $(wildcard coolc/third_party/aiwnios/CMakeLists.txt),coolc/third_party/aiwnios,$(shell git worktree list --porcelain | sed -n '1s/^worktree //p')/coolc/third_party/aiwnios)
export AIWNIOS_DIR := $(abspath $(AIWNIOS))
AIWBIN  := $(AIWNIOS)/aiwnios.app/Contents/MacOS/aiwnios
export AIWNIOS_BIN ?= $(abspath $(AIWBIN))
KSRC    := $(wildcard os/Kernel/*.HC os/Kernel/*.HH)

.PHONY: all run test aiwnios clean fmt fmt-check hooks
all: build/kernel.Image

aiwnios: $(AIWBIN)
$(AIWBIN):
	cmake -S $(AIWNIOS) -B $(AIWNIOS)/build -G Ninja -DCMAKE_BUILD_TYPE=Release
	ninja -C $(AIWNIOS)/build

build/Kernel.BIN: $(KSRC) $(AIWBIN) | build
	tools/aiwcc.sh os/Kernel Kernel.HC $@

LD := aarch64-elf-ld --no-warn-rwx-segments -T os/Kernel/Kernel.ld
ASM_OBJS := build/Boot.o build/Arch.o

build/%.o: os/Kernel/%.S | build
	aarch64-elf-gcc -c $< -o $@

# Pass 1: link the assembly alone (HolyC symbols unresolved) to learn where its
# routines land; the addresses don't depend on the HolyC module.
build/arch.syms: $(ASM_OBJS) os/Kernel/Kernel.ld
	mkdir -p build/pre
	echo 'KBSS_END = 0x800400000;' > build/pre/syms.ld
	$(LD) --unresolved-symbols=ignore-all build/pre/syms.ld $(ASM_OBJS) -o build/pre/arch.elf
	aarch64-elf-nm build/pre/arch.elf | grep ' [Tt] ' > $@

build/kernel.raw build/syms.ld: build/Kernel.BIN build/arch.syms tools/binlink.py
	python3 tools/binlink.py $< build/kernel.raw build/syms.ld build/arch.syms

# Pass 2: the real link; check the assembly didn't move.
build/cool.elf: build/kernel.raw build/syms.ld $(ASM_OBJS) tools/Kernel.S
	aarch64-elf-as tools/Kernel.S -o build/Kernel.o
	$(LD) build/syms.ld $(ASM_OBJS) build/Kernel.o -o $@
	aarch64-elf-nm build/cool.elf | grep -F -f build/arch.syms | cmp -s - build/arch.syms \
	  || { echo "assembly symbols moved between link passes"; rm -f $@; exit 1; }

build/kernel.Image: build/cool.elf
	aarch64-elf-objcopy -O binary $< $@

run: build/kernel.Image coolvm
	gtimeout 60 build/coolvm --cpus 2 --mem 1024 --timeout 55 $<

test: build/kernel.Image coolvm
	tools/kernel-test.sh $<

build:
	mkdir -p build

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
