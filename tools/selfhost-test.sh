#!/bin/sh
# The OS compiles its own compiler: boot the kernel Image with the compiler
# sources on C:/Compiler (staged by tools/native/prepare.sh, as `make seed`
# compiles them) and C:/Kernel.HH (the shell prelude), let C:/Init.HC run Cmp
# in the shell, and require the BIN it writes to equal coolc/seed/Compiler.BIN
# byte for byte. Before that the shell AOT-compiles and Loads a small program
# and ExeFiles another, and checks their output. Needs mtools. Extra arguments
# go to coolvm.
# Usage: selfhost-test.sh kernel.Image [coolvm options]
set -eu
image=$1
shift
tools/native/prepare.sh
dir=$(mktemp -d build/selfhost-test.XXXXXX)
[ -n "${KEEP:-}" ] || trap 'rm -rf "$dir"' EXIT
disk=$dir/disk.img
mkfile -n 64m "$disk"
mformat -i "$disk" -F -v SELFHOST ::
mmd -i "$disk" ::Compiler
mcopy -i "$disk" build/native-src/* ::Compiler/
mcopy -i "$disk" build/ShellPrelude.HH ::Kernel.HH
cat >"$dir/Hello.HC" <<'EOF'
#include "Kernel.HH"
I64 hello_calls;
I64 Twice(I64 x)
{
    hello_calls++;
    return 2 * x;
}
Print("Hello loaded %d\n", Twice(4));
EOF
cat >"$dir/Ex.HC" <<'EOF'
I64 ex_v = 5;
Print("ex %d\n", ex_v * 3);
ex_v * 7;
EOF
printf 'I64 bad = ;\n' >"$dir/Bad.HC"
# The shell runs C:/Init.HC at startup (typed input can outrun the UART FIFO).
cat >"$dir/Init.HC" <<'EOF'
Cd("C:/");
Print("cmp %d\n", Cmp("Hello"));
Load("Hello");
extern I64 Twice(I64 x);
extern I64 hello_calls;
Print("twice %d calls %d\n", Twice(20), hello_calls);
Print("exe %d\n", ExeFile("Ex"));
Print("bad %d\n", ExeFile("Bad"));
Print("self %d\n", Cmp("C:/Compiler/Native.HC", "C:/Self.BIN"));
Shutdown;
EOF
mcopy -i "$disk" "$dir/Hello.HC" "$dir/Ex.HC" "$dir/Init.HC" "$dir/Bad.HC" ::
log=$dir/log
status=0
gtimeout -k 2 130 build/coolvm --headless --cpus 2 --mem 1024 --timeout 120 \
    --disk "$disk" "$@" "$image" </dev/null >"$log" 2>&1 || status=$?
tr -d '\r' <"$log" | grep -v '^WARNING' >"$dir/out" || true
fail() {
    tail -n 30 "$dir/out"
    echo "selfhost-test: $1"
    exit 1
}
[ "$status" = 0 ] || fail "coolvm exited with status $status"
for line in 'cmp 0' 'Hello loaded 8' 'twice 40 calls 2' 'ex 15' 'exe 35' 'ERROR: Expected an expression' '  C:/Bad.HC,1' 'bad 0' 'self 0'; do
    grep -qx "$line" "$dir/out" || fail "missing line: $line"
done
mcopy -i "$disk" ::Self.BIN "$dir/Self.BIN"
cmp "$dir/Self.BIN" coolc/seed/Compiler.BIN || fail "C:/Self.BIN differs from coolc/seed/Compiler.BIN"
echo "selfhost-test: the OS compiled coolc/seed/Compiler.BIN ($(wc -c <"$dir/Self.BIN" | tr -d ' ') bytes) byte for byte"
