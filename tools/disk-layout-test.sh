#!/bin/sh
# Migration preserves edits during seeding and removes the old install on refresh.
set -eu
cd "$(dirname "$0")/.."
dir=$(mktemp -d build/disk-layout-test.XXXXXX)
trap 'rm -rf "$dir"' EXIT HUP INT TERM
img=$dir/disk.img
mkfile -n 64m "$img"
mformat -i "$img" -F ::
mmd -i "$img" ::coolc ::coolc/Runtime ::Compiler ::Kernel
printf 'old edited file\n' >"$dir/old"
for path in Init.cool Warm.cool Warm.HC coolc/Runtime/KGlbls.cool Compiler/Native.cool Kernel/Kernel.cool; do
    mcopy -i "$img" "$dir/old" "::$path"
done
tools/disk-files.sh "$img" -n
for path in Init.cool Warm.cool coolc/Runtime/KGlbls.cool Compiler/Native.cool Kernel/Kernel.cool; do
    mtype -i "$img" "::$path" >"$dir/read"
    cmp "$dir/old" "$dir/read"
done
# Also preserve edits in the new directories on subsequent seed runs.
mcopy -o -i "$img" "$dir/old" ::Warm/Examples/greet/Greet.warm
mcopy -o -i "$img" "$dir/old" ::Man/Warm.txt
tools/disk-files.sh "$img" -n
mtype -i "$img" ::Warm/Examples/greet/Greet.warm >"$dir/read"
cmp "$dir/old" "$dir/read"
mtype -i "$img" ::Man/Warm.txt >"$dir/read"
cmp "$dir/old" "$dir/read"
tools/disk-files.sh "$img"
python3 tools/warm-man.py --output "$dir/Man"
for page in "$dir"/Man/*.txt; do
    mtype -i "$img" "::Man/$(basename "$page")" >"$dir/read"
    cmp "$page" "$dir/read"
done
for source in warmc/README.md docs/warm-stdlib.md docs/warm-closures.md; do
    mtype -i "$img" "::Warm/Docs/$(basename "$source")" >"$dir/read"
    cmp "$source" "$dir/read"
done
for path in coolc Compiler Warm.cool Warm.HC; do
    if mdir -i "$img" "::$path" >/dev/null 2>&1; then
        echo "disk-layout-test: legacy path remains: $path" >&2
        exit 1
    fi
done
for path in Cool/Runtime/KGlbls.cool Cool/Fmt/HCTok.cool Cool/LibC/LibC.cool Warm/Warm.cool Warm/Standard/builtin/Pervasive.warm Warm/Standard/OS/Terminal.warm Warm/Examples/greet/Greet.warm; do
    mdir -i "$img" "::$path" >/dev/null
done
mtype -i "$img" ::Warm/Examples/greet/Greet.warm >"$dir/read"
cmp warmc/examples/greet/Greet.warm "$dir/read"
mtype -i "$img" ::Init.cool >"$dir/read"
cmp os/Disk/Init.cool "$dir/read"
mtype -i "$img" ::Kernel/Kernel.cool >"$dir/read"
grep -q '#include "C:/Cool/Runtime/KGlbls.cool"' "$dir/read"
if grep -q '#include "../../coolc/' "$dir/read"; then
    echo 'disk-layout-test: repository include path remains' >&2
    exit 1
fi
echo 'disk-layout-test: seed preserves edits; install migrates old paths and refreshes sources PASS'
