# Independent host toolchain: make -f tools/toolchain.mk warm-host or host-test.
# No OS source, kernel header, VM, cross linker or vendor checkout is required.
.DEFAULT_GOAL := warm-host
COOLC_SEED := $(abspath coolc/seed/Compiler.BIN)
.PHONY: warm-host host-test coolc-test checks-test native-host
warm-host: build/warm build/warmc build/warmfmt.BIN
host-test: coolc-test warm-test
coolc-test: codegen-test checks-test
	coolc/Host/test.sh
checks-test: build/coolc
	tools/native/checks.sh
build:
	mkdir -p build
build/warm: tools/warm | build
	ln -sf ../tools/warm $@
WARMSRC := coolc/LibC/LibC.cool $(wildcard warmc/*.cool warmc/builtin/*.warmh warmc/builtin/*.warm warmc/targets/coolos/*.cool) warmc/build.sh warmc/embed_builtins.py coolc/seed/Compiler.BIN
build/warmcool/Warm.BIN: $(WARMSRC) build/coolc
	./warmc/build.sh

# Native macOS BIN loader and checked-in self-hosted compiler image.
native-host: build/coolc
build/coolc: coolc/Host/native.c coolc/Host/warm_net.h coolc/Host/warm_task.h coolc/Host/warm_file.h coolc/Host/except.S | build
	clang -std=c11 -Wall -Wextra -Werror -O2 -fno-omit-frame-pointer -ffixed-x28 $(filter %.c %.S,$^) -o $@

build/coolc-x86_64: coolc/Host/native.c coolc/Host/x86.S coolc/Host/x86-native.h coolc/Host/warm_net.h coolc/Host/warm_task.h coolc/Host/warm_file.h | build
	clang -arch x86_64 -std=c11 -Wall -Wextra -Werror -O2 -fno-omit-frame-pointer coolc/Host/native.c coolc/Host/x86.S -o $@

.PHONY: codegen-test
codegen-test: build/coolc build/coolc-x86_64
	python3 tools/native/codegen.py


# The Warm formatter (tools/warm fmt): warmc/FmtNative.cool, built on the lexer of warmc.
build/warmfmt.BIN: warmc/FmtNative.cool warmc/Format.cool warmc/Core.cool warmc/Lexer.cool coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc warmc/FmtNative.cool $@ > build/warmfmt-compile.log 2>&1
	tail -1 build/warmfmt-compile.log

build/hcfmt.BIN: coolc/Fmt/Native.cool coolc/Fmt/HCFmt.cool coolc/Fmt/HCTok.cool coolc/seed/Compiler.BIN build/coolc | build
	COOLC_COMPILER_BIN=$(COOLC_SEED) gtimeout 45 build/coolc coolc/Fmt/Native.cool $@ > build/hcfmt-compile.log 2>&1
	tail -1 build/hcfmt-compile.log


# Internal compiler protocol wrapper; tools/warm is the public host command.
build/warmc: build/warmcool/Warm.BIN
	printf '#!/bin/sh\nexec "%s/build/coolc" --run "%s/build/warmcool/Warm.BIN" "$$@"\n' "$(CURDIR)" "$(CURDIR)" > $@
	chmod +x $@

# The Warm compiler's own tests: every test-programs case against its stored expectation, and the probes.
.PHONY: warm-test
warm-test: warm-host
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_host_cli.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/compare.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_frontend.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_semantics.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_numbers.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_language.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_cli.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_standard.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_os.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_tasks.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_gui.py
	WARM_TOOLCHAIN_READY=1 python3 warmc/test_fmt.py
