#!/bin/sh
# Fetch the GNU Unifont .hex source into vendor/unifont (gitignored).
# Prints the .hex path on the last line. Used by `make font`.
set -eu
VER=${UNIFONT_VERSION:-18.0.01}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/vendor/unifont
HEX=$DIR/unifont-$VER.hex
mkdir -p "$DIR"
if [ ! -s "$HEX" ]; then
  curl -sfL "https://unifoundry.com/pub/unifont/unifont-$VER/font-builds/unifont-$VER.hex.gz" -o "$HEX.gz"
  gunzip -f "$HEX.gz"
fi
echo "$HEX"
