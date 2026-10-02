#!/bin/sh
# Copy the Mac's console fonts into C:/Fonts (docs/fonts.md). Font files are not in the
# repository: Sarasa Mono K (Regular and Bold, for FontSet and Settings) from
# ~/Library/Fonts, and the system's NanumGothic.ttc. Missing files are skipped. The console
# font stays the built-in Unifont until FontSet chooses one of these.
# Usage: disk-fonts.sh image [-n]   (-n: leave files that are already there alone)
set -eu
IMG=$1
FLAG=${2:-}
nanum=$(find /System/Library/AssetsV2 -name NanumGothic.ttc 2>/dev/null | head -1 || true)
found=
for f in "$HOME/Library/Fonts/SarasaMonoK-Regular.ttf" "$HOME/Library/Fonts/SarasaMonoK-Bold.ttf" "$nanum"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ -n "$found" ] || { mdir -i "$IMG" ::Fonts >/dev/null 2>&1 || mmd -i "$IMG" ::Fonts </dev/null; found=1; }
    if [ "$FLAG" = -n ] && mdir -i "$IMG" "::Fonts/$(basename "$f")" >/dev/null 2>&1; then
        continue
    fi
    mcopy -o -i "$IMG" "$f" ::Fonts/
done
[ -n "$found" ] || echo "disk-fonts: no Sarasa Mono K or NanumGothic on this Mac"
