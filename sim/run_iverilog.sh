#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
cp ../rtl/sincos_qw.mem .
iverilog -g2012 -DDUMP_FILES -s tb_chirp_gen -o out/tb.vvp \
    tb_chirp_gen.sv ../rtl/*.sv ../rtl/chirp_gen_wrapper.v
vvp -n out/tb.vvp
python3 analyze.py
tclsh test_ctrl.tcl
python3 -m unittest discover -s . -p 'test_*.py'
