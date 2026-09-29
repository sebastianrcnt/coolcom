#!/bin/sh
# Build tools/vzrun/main.swift -> build/vzrun (ad-hoc signed with the
# com.apple.security.virtualization entitlement).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mkdir -p "$root/build"
swiftc -O -parse-as-library "$here/main.swift" -o "$root/build/vzrun" \
  -framework Virtualization -framework AppKit
codesign --force --sign - --entitlements "$here/entitlements.plist" "$root/build/vzrun"
echo "built $root/build/vzrun"
