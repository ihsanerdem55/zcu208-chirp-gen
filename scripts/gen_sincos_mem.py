#!/usr/bin/env python3
"""Generate the quarter-wave sine table used by sincos_qw_rom.sv.

Table: Q[i] = round(AMP * sin(2*pi*(i + 0.5) / 2**PHASE_BITS)),  i = 0 .. 2**(PHASE_BITS-2) - 1
The +0.5 offset makes the quarter-wave folding exact (no duplicated end points).

Usage: python3 gen_sincos_mem.py [out_file]   (default: ../rtl/sincos_qw.mem)
"""
import math
import os
import sys

PHASE_BITS = 14            # full-cycle phase resolution -> 16384 points per cycle
QW_BITS = PHASE_BITS - 2   # quarter-wave table address bits -> 4096 entries
AMP = 32767                # 16-bit signed full scale

def table():
    n = 1 << PHASE_BITS
    return [round(AMP * math.sin(2 * math.pi * (i + 0.5) / n)) for i in range(1 << QW_BITS)]

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "rtl", "sincos_qw.mem")
    with open(out, "w") as f:
        for v in table():
            f.write(f"{v & 0xFFFF:04X}\n")
    print(f"wrote {1 << QW_BITS} entries to {out}")
