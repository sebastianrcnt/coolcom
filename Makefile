AIWNIOS ?= coolc/third_party/aiwnios
export AIWNIOS_DIR := $(abspath $(AIWNIOS))
AIWBIN  := $(AIWNIOS)/aiwnios.app/Contents/MacOS/aiwnios
KSRC    := $(wildcard os/Kernel/*.HC os/Kernel/*.HH)
QEMU    := qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 1G -smp 2 -nographic

.PHONY: all run debug aiwnios clean
all: build/cool.elf

aiwnios: $(AIWBIN)
$(AIWBIN):
	cmake -S $(AIWNIOS) -B $(AIWNIOS)/build -G Ninja -DCMAKE_BUILD_TYPE=Release
	ninja -C $(AIWNIOS)/build

build/Kernel.BIN: $(KSRC) $(AIWBIN) | build
	tools/aiwcc.sh os/Kernel Kernel.HC $@

build/kernel.raw build/syms.ld: build/Kernel.BIN tools/binlink.py
	python3 tools/binlink.py $< build/kernel.raw build/syms.ld

build/cool.elf: build/kernel.raw os/Kernel/Boot.S os/Kernel/Kernel.ld tools/Kernel.S
	aarch64-elf-as os/Kernel/Boot.S -o build/Boot.o
	aarch64-elf-as tools/Kernel.S -o build/Kernel.o
	aarch64-elf-ld --no-warn-rwx-segments -T os/Kernel/Kernel.ld build/Boot.o build/Kernel.o -o $@

run: build/cool.elf
	$(QEMU) -kernel $<

debug: build/cool.elf
	$(QEMU) -kernel $< -s -S

build:
	mkdir -p build

clean:
	rm -rf build
