#!/bin/sh
# Debug aid: build build/portrt with BTrace() calls at every port function
# entry, then compile one test module with the port and show the tail of the
# trace. Usage: tracert.sh <test.HC> [seconds]. Output: build/portrt-trace.log
# Run mkportrt.sh afterwards to get an uninstrumented runtime back.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RT=$ROOT/build/portrt
T=${1:?test file}; SECS=${2:-60}
export PORT_INSTRUMENT=1
"$ROOT/tools/porttest/mkportrt.sh" | tail -1
mkdir -p "$RT/CoolTmpTrace" && cp "$ROOT"/coolc/tests/codegen/* "$RT/CoolTmpTrace/"
printf 'extern I64 b_use_port;\nb_use_port=TRUE;\nCd("CoolTmpTrace");\nCmp("%s",NULL,"Out.BIN");\nExitAiwnios;\n' "$T" > "$RT/CoolTmpTrace/Run.HC"
(cd "$RT" && gtimeout "$SECS" gstdbuf -oL -eL "$ROOT/coolc/third_party/aiwnios/aiwnios.app/Contents/MacOS/aiwnios" \
  -t . -c CoolTmpTrace/Run.HC < /dev/null > "$ROOT/build/portrt-trace.log" 2>&1); echo "exit $?"
rm -rf "$RT/CoolTmpTrace"
LC_ALL=C tr -cd '\11\12\15\40-\176' < "$ROOT/build/portrt-trace.log" | grep -v "Fun [Hh]eader\|Headers.HH" | tail -${TAIL:-30}
