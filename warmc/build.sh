#!/usr/bin/env bash
# Warm fork of Austral; see LICENSE and README.md for upstream attribution.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
opam exec --switch=austral -- make -C "$DIR"
printf '%s\n' "$DIR/warmc"
