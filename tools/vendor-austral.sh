#!/usr/bin/env bash
# Idempotently fetch and build the Austral compiler into vendor/austral.
# Verified: OCaml 4.13.0 on macOS/arm64 (opam 2.6, dune 3.22).
# Prints the compiler path on the last line of stdout. Skips completed steps.
set -euo pipefail

AUSTRAL_COMMIT="${AUSTRAL_COMMIT:-0962d2a8a5d77f7daacd7f696819520733f4897d}"
OCAML_VERSION="${OCAML_VERSION:-4.13.0}"
SWITCH=austral

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/vendor/austral"
JOBS="$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export OPAMJOBS="$JOBS" MAKEFLAGS="-j$JOBS" OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes

log() { echo "[vendor-austral] $*" >&2; }
T() { command -v gtimeout >/dev/null 2>&1 && gtimeout "$1" "${@:2}" || "${@:2}"; }

# 1. opam
if ! command -v opam >/dev/null 2>&1; then
  log "installing opam via brew"
  HOMEBREW_NO_AUTO_UPDATE=1 T 900 brew install opam >&2
fi
if [ ! -d "$HOME/.opam" ]; then
  log "initialising opam (no shell rc changes, no sandbox)"
  T 600 opam init -y --disable-sandboxing --bare --no-setup >&2
fi

# 2. source at pinned commit
if [ ! -d "$DIR/.git" ]; then
  log "cloning austral"
  mkdir -p "$ROOT/vendor"
  T 600 git clone https://github.com/austral/austral "$DIR" >&2
fi
if [ "$(git -C "$DIR" rev-parse HEAD)" != "$AUSTRAL_COMMIT" ]; then
  log "checking out $AUSTRAL_COMMIT"
  git -C "$DIR" cat-file -e "$AUSTRAL_COMMIT^{commit}" 2>/dev/null || git -C "$DIR" fetch origin >&2
  git -C "$DIR" checkout -q "$AUSTRAL_COMMIT"
fi

# 3. opam switch
if ! opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
  log "creating opam switch $SWITCH (OCaml $OCAML_VERSION); takes ~1 min"
  T 1800 opam switch create "$SWITCH" "$OCAML_VERSION" >&2
fi
eval "$(opam env --switch="$SWITCH")"

# 4. dependencies (skipped when every pinned dep is already installed)
need=0
for p in dune ppxlib ppx_deriving ppx_sexp_conv sexplib ounit2 menhir zarith yojson; do
  opam list --installed --short "$p" 2>/dev/null | grep -qx "$p" || need=1
done
if [ "$need" = 1 ]; then
  log "installing opam dependencies; takes ~2 min"
  (cd "$DIR" && T 1800 opam install --deps-only -y .) >&2
fi

# 5. build
if [ ! -x "$DIR/austral" ] || [ -n "$(find "$DIR/lib" "$DIR/bin" -newer "$DIR/austral" -type f 2>/dev/null | head -1)" ]; then
  log "building (dune -j $JOBS)"
  (cd "$DIR" && python3 concat_builtins.py && T 1200 dune build -j "$JOBS" && cp _build/default/bin/austral.exe austral) >&2
fi

echo "$DIR/austral"
