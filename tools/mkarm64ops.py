#!/usr/bin/env python3
"""Make os/Kernel/Arm64Ops.csv, the opcode table of the ARM64 disassembler
(os/Kernel/UAsmARM64.HC), from Aiwnios's Src/AArch64_ops.csv (commit e155e87,
clone it into vendor/aiwnios). Only the columns the disassembler reads are
kept: number, name, prependage, appendage, register kind, then one cell per
instruction bit 31..0 ("0", "1", a field name at its top bit, empty below).
Usage: tools/mkarm64ops.py > os/Kernel/Arm64Ops.csv
"""
import csv
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "vendor/aiwnios/Src/AArch64_ops.csv"

rows = list(csv.reader(open(SRC, encoding="latin-1")))
out = ["num,name,prependage,appendage,specific,bits 31..0 (from Aiwnios Src/AArch64_ops.csv, e155e87)"]
for r in rows[1:]:
    if len(r) > 42 and r[4].strip():
        cells = [r[0], r[4], r[5], r[6], r[8]] + r[11:43]
        assert not any("," in c for c in cells), r
        out.append(",".join(cells))
sys.stdout.write("\n".join(out) + "\n")
