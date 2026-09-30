#!/bin/sh
# Connect to a ShellServe in the guest (os/Kernel/NetShell.cool) through coolvm's
# --net-forward, with the tty raw so the Cool shell does the line editing and
# Ctrl+C reaches it. Leave with Exit; (or Ctrl+] ... when using telnet instead).
# Usage: tools/rsh.sh [host port, default 2323] [host, default localhost]
port=${1:-2323}
host=${2:-localhost}
if [ -t 0 ]; then
    old=$(stty -g)
    trap 'stty "$old"; echo' EXIT INT TERM
    stty raw -echo
fi
nc "$host" "$port"
