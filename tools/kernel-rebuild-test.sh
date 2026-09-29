#!/bin/sh
# The OS rebuilds its own kernel and boots it (docs/kernel-rebuild.md). Boot the
# Image with the kernel sources on C: (tools/disk-files.sh), the prebuilt
# assembly (build/BootStub.BIN) and the shell prelude; C:/Init.HC runs
# MakeKernel, which must write C:/Kernel.Image equal to the host's Image and
# C:/Kernel/Syms.ld equal to the host's syms.ld, byte for byte. Then it adds a
# function to C:/Kernel/Kernel.HC, builds C:/Kernel2.Image and boots it with
# Reboot; on that boot Init.HC types a line at the shell prompt that calls the
# new function and powers off. Needs mtools. Extra arguments go to coolvm.
# Usage: kernel-rebuild-test.sh build/kernel.Image [coolvm options]
set -eu
image=$1
shift
b=$(dirname "$image")
dir=$(mktemp -d build/kernel-rebuild-test.XXXXXX)
[ -n "${KEEP:-}" ] || trap 'rm -rf "$dir"' EXIT
disk=$dir/disk.img
mkfile -n 64m "$disk"
mformat -i "$disk" -F -v REBUILD ::
tools/disk-files.sh "$disk"
mcopy -o -i "$disk" "$b/BootStub.BIN" ::Kernel/
mcopy -i "$disk" "$b/ShellPrelude.HH" ::Kernel.HH
cat >"$dir/Init.HC" <<'EOF'
U8 *s, *t;
I64 n;
if (FileFind("C:/Booted.TXT")) {
    Print("second boot\n");
    s = "extern I64 RebuildMark();\nPrint(\"mark %d\\n\", RebuildMark);\nShutdown;\n";
    while (*s)
        KeyPush(*s++);  // typed at the prompt
} else {
    Print("makekernel %d\n", MakeKernel);
    Copy("C:/Kernel/Syms.ld", "C:/Syms1.ld");
    s = FileRead("C:/Kernel/Kernel.HC", &n);
    t = MStrPrint("%s\nI64 RebuildMark()\n{\n    return 4242;\n}\n", s);
    FileWrite("C:/Kernel/Kernel.HC", t, StrLen(t));
    Print("makekernel2 %d\n", MakeKernel("C:/Kernel2.Image"));
    FileWrite("C:/Booted.TXT", "1", 1);
    Reboot("C:/Kernel2.Image");
    Print("reboot returned\n");
}
EOF
mcopy -o -i "$disk" "$dir/Init.HC" ::
log=$dir/log
status=0
# coolvm keeps the Image passed by Reboot in $TMPDIR while it runs it.
TMPDIR=$PWD/$dir gtimeout -k 2 70 build/coolvm --headless --cpus 2 --mem 1024 --timeout 60 \
    --disk "$disk" "$@" "$image" </dev/null >"$log" 2>&1 || status=$?
tr -d '\r' <"$log" | grep -v '^WARNING' >"$dir/out" || true
fail() {
    tail -n 30 "$dir/out"
    echo "kernel-rebuild-test: $1"
    exit 1
}
[ "$status" = 0 ] || fail "coolvm exited with status $status"
for line in 'makekernel 0' 'makekernel2 0' 'second boot' 'mark 4242'; do
    grep -qx "$line" "$dir/out" || fail "missing line: $line"
done
grep -q 'coolvm: guest reset, booting the [0-9]*-byte Image it passed' "$dir/out" || fail "coolvm did not boot the new Image"
if ls "$dir"/coolvm-boot-* >/dev/null 2>&1; then
    fail "coolvm left its temporary Image behind"
fi
mcopy -i "$disk" ::Kernel.Image "$dir/Kernel.Image"
mcopy -i "$disk" ::Syms1.ld "$dir/Syms.ld"
cmp "$dir/Syms.ld" "$b/syms.ld" || fail "C:/Kernel/Syms.ld differs from $b/syms.ld"
cmp "$dir/Kernel.Image" "$image" || fail "C:/Kernel.Image differs from $image"
grep '^Wrote' "$dir/out"
echo "kernel-rebuild-test: the OS built $image ($(wc -c <"$image" | tr -d ' ') bytes) byte for byte, then changed its kernel, rebuilt it and booted it to a shell prompt"
