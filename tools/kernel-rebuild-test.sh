#!/bin/sh
# The OS rebuilds its own kernel (docs/kernel-rebuild.md): boot the Image with
# the kernel sources on C: (make disk-kernel-src), the prebuilt assembly
# (build/BootStub.BIN) and the shell prelude, let C:/Init.HC run MakeKernel,
# and require C:/Kernel.Image to equal the host's Image and C:/Kernel/Syms.ld
# the host's syms.ld, byte for byte. Needs mtools. Extra arguments go to coolvm.
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
make -s disk-kernel-src KDISK="$disk"
mcopy -i "$disk" "$b/BootStub.BIN" ::Kernel/
mcopy -i "$disk" "$b/ShellPrelude.HH" ::Kernel.HH
cat >"$dir/Init.HC" <<'EOF'
Print("makekernel %d\n", MakeKernel);
Shutdown;
EOF
mcopy -i "$disk" "$dir/Init.HC" ::
log=$dir/log
status=0
gtimeout -k 2 70 build/coolvm --headless --cpus 2 --mem 1024 --timeout 60 \
    --disk "$disk" "$@" "$image" </dev/null >"$log" 2>&1 || status=$?
tr -d '\r' <"$log" | grep -v '^WARNING' >"$dir/out" || true
fail() {
    tail -n 30 "$dir/out"
    echo "kernel-rebuild-test: $1"
    exit 1
}
[ "$status" = 0 ] || fail "coolvm exited with status $status"
grep -qx 'makekernel 0' "$dir/out" || fail "MakeKernel failed"
mcopy -i "$disk" ::Kernel.Image "$dir/Kernel.Image"
mcopy -i "$disk" ::Kernel/Syms.ld "$dir/Syms.ld"
cmp "$dir/Syms.ld" "$b/syms.ld" || fail "C:/Kernel/Syms.ld differs from $b/syms.ld"
cmp "$dir/Kernel.Image" "$image" || fail "C:/Kernel.Image differs from $image"
grep '^Wrote' "$dir/out"
echo "kernel-rebuild-test: the OS built $image ($(wc -c <"$image" | tr -d ' ') bytes) byte for byte"
