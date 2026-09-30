#!/bin/sh
# The OS compiles its own compiler: boot the kernel Image with the compiler
# sources on C:/Compiler (staged by tools/native/prepare.sh, as `make seed`
# compiles them) and C:/Kernel.coolh (the shell prelude), let the legacy C:/Init.HC (the
# disk has no Init.cool) run Cmp in the shell, and require the BIN it writes to equal coolc/seed/Compiler.BIN
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
mcopy -i "$disk" build/ShellPrelude.coolh ::Kernel.coolh
cat >"$dir/Hello.cool" <<'EOF'
#include "Kernel.coolh"
I64 hello_calls;
I64 Twice(I64 x)
{
    hello_calls++;
    return 2 * x;
}
Print("Hello loaded %d\n", Twice(4));
EOF
cat >"$dir/Ex.cool" <<'EOF'
I64 ex_v = 5;
Print("ex %d\n", ex_v * 3);
ex_v * 7;
EOF
printf 'I64 bad = ;\n' >"$dir/Bad.cool"
# Cmp refuses (no BIN, an error count) a definite bug the compiler found without stopping; Vet reports style findings.
printf '#include "Kernel.coolh"\nU0 Unused()\n{\n    I64 forgotten;\n}\n' >"$dir/Forgot.cool"
printf '#include "Kernel.coolh"\nU0 Vetted(I64 n)\n{\n    if (n = 5)\n        Print("five\\n");\n}\n' >"$dir/VetMe.cool"
printf "StrLen('Tmux');\n" >"$dir/BadPtr.cool"
# A JIT statement with such an error does not run (the AOT compile goes on, to report every error).
printf 'U8 *jit_p;\njit_p = 5;\nPrint("jit-ran\\n");\n' >"$dir/BadJit.cool"
# Legacy .HC files: an extensionless name finds Old.HC when there is no Old.cool, and
# Both.cool before Both.HC. The disk has no Init.cool, so the shell falls back to C:/Init.HC.
printf 'Print("old-hc\\n");\n' >"$dir/Old.HC"
printf 'Print("both-cool\\n");\n' >"$dir/Both.cool"
printf 'Print("both-hc\\n");\n' >"$dir/Both.HC"
printf '#include "Old"\n#include "Both"\n#include "Old.HC"\n' >"$dir/Inc.cool"
# The shell runs C:/Init.HC at startup (typed input can outrun the UART FIFO).
cat >"$dir/Init.HC" <<'EOF'
Cd("C:/");
Print("cmp %d\n", Cmp("Hello"));
Load("Hello");
extern I64 Twice(I64 x);
extern I64 hello_calls;
Print("twice %d calls %d\n", Twice(20), hello_calls);
Print("exe %d\n", ExeFile("Ex"));
ExeFile("Old");
ExeFile("Both");
ExeFile("Inc");
Print("bad %d\n", ExeFile("Bad"));
ExeFile("BadPtr");
ExeFile("BadJit");
Print("forgot %d\n", Cmp("Forgot"));
Print("vet %d\n", Vet("VetMe"));
Print("self %d\n", Cmp("C:/Compiler/Native.cool", "C:/Self.BIN"));
Shutdown;
EOF
mcopy -i "$disk" "$dir/Hello.cool" "$dir/Ex.cool" "$dir/Init.HC" "$dir/Old.HC" "$dir/Both.cool" "$dir/Both.HC" "$dir/Inc.cool" "$dir/Bad.cool" "$dir/BadPtr.cool" "$dir/BadJit.cool" "$dir/Forgot.cool" "$dir/VetMe.cool" ::
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
for line in 'Running C:/Init.HC' 'cmp 0' 'Hello loaded 8' 'twice 40 calls 2' 'ex 15' 'exe 35' 'old-hc' 'both-cool' 'ERROR: Expected an expression' '  C:/Bad.cool,1' 'bad 0' 'ERROR: Integer constant for a pointer parameter' 'ERROR: Integer constant assigned to a pointer (cast it)' "ERROR: Unused local variable 'forgotten' in fun 'Unused'" 'forgot 1' 'vet: [assign-cond] assignment used as a condition (== intended? else add parentheses)' 'Vet: assign-cond=1 empty-stmt=0 unreachable=0 Errs:0' 'vet 1' 'self 0'; do
    grep -qxF "$line" "$dir/out" || fail "missing line: $line"
done
! grep -qx 'jit-ran' "$dir/out" || fail "a JIT statement with a compile error ran"
! grep -qx 'both-hc' "$dir/out" || fail "an extensionless name picked Both.HC over Both.cool"
mcopy -i "$disk" ::Self.BIN "$dir/Self.BIN"
cmp "$dir/Self.BIN" coolc/seed/Compiler.BIN || fail "C:/Self.BIN differs from coolc/seed/Compiler.BIN"
echo "selfhost-test: the OS compiled coolc/seed/Compiler.BIN ($(wc -c <"$dir/Self.BIN" | tr -d ' ') bytes) byte for byte"
