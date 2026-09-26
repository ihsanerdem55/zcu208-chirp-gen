# xsim_wave.tcl -- waveform setup + run for tb_chirp_gen (Vivado simulator)
# Used automatically by tcl/sim_project.tcl and sim/run_xsim.*
# Tip: right-click i_ser / q_ser / f_inst_mhz > Waveform Style > Analog to see the chirp.

add_wave_divider "Control"
add_wave /tb_chirp_gen/aclk
add_wave /tb_chirp_gen/dclk
add_wave -radix hex /tb_chirp_gen/dut/u_top/u_regs/r_ctrl
add_wave /tb_chirp_gen/dut/u_top/u_core/params_load
add_wave -radix unsigned /tb_chirp_gen/dut/u_top/u_core/cnt

add_wave_divider "Output"
add_wave /tb_chirp_gen/trig
add_wave -radix hex /tb_chirp_gen/tdata
add_wave -radix dec /tb_chirp_gen/i_ser
add_wave -radix dec /tb_chirp_gen/q_ser
add_wave /tb_chirp_gen/f_inst_mhz

add_wave_divider "Scoreboard"
add_wave -radix unsigned /tb_chirp_gen/checked
add_wave -radix unsigned /tb_chirp_gen/mism

run all
