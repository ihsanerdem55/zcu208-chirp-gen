#!/usr/bin/env bash
# Behavioural simulation without a Vivado project (Linux).
#   source <Vivado>/settings64.sh
#   cd <package>/sim && ./run_xsim.sh          # GUI with waveforms
#                        ./run_xsim.sh batch    # console only
set -e
cd "$(dirname "$0")"
cp -f ../rtl/sincos_qw.mem .
xvlog -sv ../rtl/sincos_qw_rom.sv ../rtl/noise_src.sv ../rtl/chirp_core.sv ../rtl/chirp_axil_regs.sv \
          ../rtl/chirp_gen_top.sv ../rtl/chirp_gen_wrapper.v tb_chirp_gen.sv
xelab -debug typical tb_chirp_gen -s tb_chirp_sim
if [ "$1" = "batch" ]; then
    xsim tb_chirp_sim -R
else
    xsim tb_chirp_sim -gui -tclbatch xsim_wave.tcl
fi
