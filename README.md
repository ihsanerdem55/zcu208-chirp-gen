# ZCU208 pulsed LFM chirp generator

One RF-DAC channel (tile 230, ch0 -- the tile the CLK104 reference clock is wired to) of the ZCU208, 5.89824 GSPS, fine-mixer NCO,
controlled from Vivado Hardware Manager over JTAG (no Vitis / PetaLinux).

```
rtl/          SystemVerilog + Verilog wrapper + sine ROM contents (sincos_qw.mem)
constraints/  zcu208_chirp.xdc   -> trig_out pin (default user LED0, AR19)
tcl/          build_bd.tcl       -> creates project + block design
              chirp_ctrl.tcl     -> runtime commands in Hardware Manager
sim/          tb_chirp_gen.sv, analyze.py (bit-exact model + plots)
scripts/      gen_sincos_mem.py  -> regenerates rtl/sincos_qw.mem
```

## Build
1. (Optional) `constraints/zcu208_chirp.xdc`: trig_out is on user LED0 (AR19); change it if you want another pin.
2. Vivado Tcl console: `cd tcl; source build_bd.tcl`
3. Check the RF Data Converter settings, Generate Bitstream.

## Run
1. BoardUI -> System_Controller -> Clocks -> CLK-104 -> LMK04828 245.76 MHz file.
2. Program device (.bit + .ltx).
3. `source tcl/chirp_ctrl.tcl; hw_init; rfdc_status; nco_set 1.5e9; chirp -bw 400e6 -pw 2e-6 -pri 10e-6`

## Simulate (behavioural, RTL only)
Vivado, easiest: Tcl console -> `cd <package>/tcl; source sim_project.tcl`
  -> builds a small sim-only project, runs xsim, prints *** TEST PASSED ***, opens waveforms.
Vivado, no project: `sim/run_xsim.bat` (Windows) or `sim/run_xsim.sh` (Linux) from a Vivado shell.
Icarus Verilog + Python plots:
```
cd sim && mkdir -p out && cp ../rtl/sincos_qw.mem .
iverilog -g2012 -DDUMP_FILES -o tb.vvp tb_chirp_gen.sv ../rtl/*.sv ../rtl/chirp_gen_wrapper.v
vvp -n tb.vvp && python3 analyze.py        # -> out/sim_results.png
```
The testbench is self-checking: a bit-exact reference model checks every output sample.
