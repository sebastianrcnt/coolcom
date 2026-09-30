#!/bin/sh
# Generator inputs only; renderer/MoltenVK builds belong to the host milestone.
set -eu
cd "$(dirname "$0")/.."
python3 tools/venus/vendor.py "$@"
