# =============================================================================
# sim_project.tcl -- behavioural simulation of the chirp generator RTL only
#
# Creates a small Vivado project with the RTL + testbench and launches xsim
# with a prepared waveform. No block design, no board files needed.
#
#   Vivado Tcl console:  cd <package>/tcl
#                        source sim_project.tcl
#
# Result: the Tcl console ends with "*** TEST PASSED ***" and the waveform
# window shows the CW tone, the chirps and the scope trigger.
# =============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize $script_dir/..]
set proj_dir   [file normalize $repo_dir/vivado/chirp_sim]

catch {close_project}
create_project chirp_sim $proj_dir -part xczu48dr-fsvg1517-2-e -force

add_files -norecurse [list \
    $repo_dir/rtl/sincos_qw_rom.sv \
    $repo_dir/rtl/chirp_core.sv \
    $repo_dir/rtl/chirp_axil_regs.sv \
    $repo_dir/rtl/chirp_gen_top.sv \
    $repo_dir/rtl/chirp_gen_wrapper.v \
    $repo_dir/rtl/sincos_qw.mem ]
set_property top chirp_gen_wrapper [get_filesets sources_1]

add_files -fileset sim_1 -norecurse $repo_dir/sim/tb_chirp_gen.sv
set_property top tb_chirp_gen [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# run our waveform script instead of the default 1000 ns
catch {set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]}
if {[catch {set_property -name {xsim.simulate.custom_tcl} \
                        -value $repo_dir/sim/xsim_wave.tcl -objects [get_filesets sim_1]} err]} {
    puts "NOTE: could not attach xsim_wave.tcl ($err); after launch run: source $repo_dir/sim/xsim_wave.tcl"
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
