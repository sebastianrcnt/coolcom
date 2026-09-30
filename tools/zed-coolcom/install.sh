#!/bin/sh
# Build the grammars and (re)install the coolcom Zed extension (Cool + Warm) into Zed.
#
#   tools/zed-coolcom/install.sh
#
# Needs the tree-sitter CLI (npm i -g tree-sitter-cli, or cargo install tree-sitter-cli); it
# downloads wasi-sdk on first use. Cool's grammar (project-solomon/tree-sitter-holyc, pinned in
# extension.toml) is cloned from GitHub once and cached in ~/.cache/coolcom-zed/.
# Restart Zed (or reload the window) afterwards.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ts=${TREE_SITTER:-tree-sitter}
zed=${ZED_EXTENSIONS:-$HOME/Library/Application Support/Zed/extensions}
dest="$zed/installed/coolcom"

# --- Warm grammar: generate from grammar.js (ABI 14) and build the wasm ---
mkdir -p "$here/grammars"
(cd "$here/../tree-sitter-warm" && "$ts" generate --abi 14 && "$ts" build --wasm -o "$here/grammars/warm.wasm")

# --- Cool grammar (holyc): the pinned commit of the upstream grammar ---
rev=$(sed -n '/^\[grammars.holyc\]/,/^$/s/^rev = "\(.*\)"/\1/p' "$here/extension.toml")
repo=$(sed -n '/^\[grammars.holyc\]/,/^$/s/^repository = "\(.*\)"/\1/p' "$here/extension.toml")
src="${XDG_CACHE_HOME:-$HOME/.cache}/coolcom-zed/tree-sitter-holyc"
if [ ! -d "$src/.git" ]; then mkdir -p "$(dirname "$src")"; git clone --quiet "$repo" "$src"; fi
git -C "$src" fetch --quiet origin 2>/dev/null || true
git -C "$src" checkout --quiet "$rev"
(cd "$src" && "$ts" build --wasm -o "$here/grammars/holyc.wasm")

# --- install: same layout Zed keeps for the other extensions (extension.toml, languages/, grammars/*.wasm) ---
rm -rf "$zed/installed/holyc" "$dest"
mkdir -p "$dest/grammars"
cp "$here/extension.toml" "$here/LICENSE" "$dest/"
cp -R "$here/languages" "$dest/languages"
cp "$here/grammars/warm.wasm" "$here/grammars/holyc.wasm" "$dest/grammars/"
echo "installed $dest"
echo "restart Zed to pick it up (Cmd-Q, reopen)"
