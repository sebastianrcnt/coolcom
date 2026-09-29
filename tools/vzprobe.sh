#!/bin/sh
# Build the VZ launcher, the UEFI probe and the ESP image, run the probe in
# Apple Virtualization.framework (headless, with a timeout) and collect logs.
#
#   tools/vzprobe.sh [--gui] [--cfg 'key=value ...'] [--timeout N]
#
# Outputs (all under build/):
#   vzprobe.log        what arrived on the host through the virtio-console
#                      serial port (vzrun's stdout) -- the console capture
#   vzprobe.esp.log    the probe's own log file, read back from the ESP image
#                      (always complete, independent of the serial path)
#   vzprobe.vzrun.log  vzrun's stderr (launcher status)
#   vzprobe-*.png      window screenshots when --gui is given
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$root"
gui=0
cfg='wait=3 postwait=3'
timeout=40
while [ $# -gt 0 ]; do
  case $1 in
    --gui) gui=1; shift ;;
    --cfg) cfg=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    *) echo "usage: $0 [--gui] [--cfg 'wait=N postwait=N off=psci|rt|rtpost|none'] [--timeout N]" >&2; exit 2 ;;
  esac
done

tools/vzrun/build.sh
boot/uefi-probe/build.sh
echo "$cfg" | tr ' ' '\n' > build/probe.cfg
tools/mkesp.sh -c build/probe.cfg
rm -f build/vz-nvram.bin   # fresh NVRAM: deterministic firmware state

rm -f build/vzprobe*.png build/vzprobe.log build/vzprobe.esp.log
if [ "$gui" = 1 ]; then
  # screenshots: one during the pre-ExitBootServices page, one after it
  set -- --gui --screenshot 7 build/vzprobe-before-ebs.png --screenshot 15 build/vzprobe-after-ebs.png
else
  set --
fi
timeout $((timeout + 20)) build/vzrun --disk build/esp.img --nvram build/vz-nvram.bin \
  --timeout "$timeout" "$@" < /dev/null > build/vzprobe.log 2> build/vzprobe.vzrun.log || true
cat build/vzprobe.vzrun.log
mcopy -n -i build/esp.img@@1048576 ::probe.log build/vzprobe.esp.log 2>/dev/null || echo "no probe.log on ESP"
echo "--- host serial capture: $(wc -c < build/vzprobe.log) bytes (build/vzprobe.log)"
echo "--- ESP log: $(wc -l < build/vzprobe.esp.log) lines (build/vzprobe.esp.log)"
