#!/usr/bin/env bash
# Alternative host regression runner (Verilator 5+, C++20 compiler, Python, Tcl).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
cp ../rtl/sincos_qw.mem .
# Set VERILATOR=verilator-cli when using the Python wheel distribution.
verilator_cmd=${VERILATOR:-verilator}
for top in tb_chirp_gen tb_chirp_regs tb_noise; do
    "$verilator_cmd" --binary --timing --output-split 0 -Wno-fatal -DDUMP_FILES \
        --top-module "$top" --Mdir "out/$top" "$top.sv" \
        ../rtl/*.sv ../rtl/chirp_gen_wrapper.v > "out/$top-build.log" 2>&1
    "out/$top/V$top"
done
python3 analyze.py
tclsh test_ctrl.tcl
python3 -m unittest discover -s . -p 'test_*.py'
