#!/bin/sh
# Section dispatcher: host dependencies can add a separate section here.
# Default/--generator/generator: pinned registry and protocol generator inputs.
# --test additionally installs the pinned C oracle dependencies.
set -eu
cd "$(dirname "$0")/.."
case "${1:---generator}" in
    generator|--generator)
        if [ "$#" -gt 0 ]; then shift; fi
        exec python3 tools/venus/vendor.py "$@"
        ;;
    --test|--help|-h)
        exec python3 tools/venus/vendor.py "$@"
        ;;
    *)
        echo "Unknown Venus vendor section: $1 (available: --generator [--test])" >&2
        exit 2
        ;;
esac
