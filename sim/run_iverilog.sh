#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
cp ../rtl/sincos_qw.mem .
iverilog -g2012 -DDUMP_FILES -s tb_chirp_gen -o out/tb.vvp \
    tb_chirp_gen.sv ../rtl/*.sv ../rtl/chirp_gen_wrapper.v
vvp -n out/tb.vvp
iverilog -g2012 -s tb_chirp_regs -o out/regs.vvp tb_chirp_regs.sv ../rtl/chirp_axil_regs.sv
vvp -n out/regs.vvp
iverilog -g2012 -DDUMP_FILES -s tb_noise -o out/noise.vvp tb_noise.sv ../rtl/*.sv ../rtl/chirp_gen_wrapper.v
vvp -n out/noise.vvp
python3 analyze.py
tclsh test_ctrl.tcl
python3 -m unittest discover -s . -p 'test_*.py'

