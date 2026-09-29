# Implementation-only CDC constraints. Do not use set_clock_groups here: that
# would override the max-delay bound on the bundled parameter transfer.
# req_sync gives data at least two DAC clocks to settle. Bound data propagation
# and skew to one DAC period (5.425 ns), leaving a full cycle of margin.
set src [get_cells -hier -regexp {.*u_regs/r_(ctrl|fstart|krate|pw|pri|amp|phase0)_reg(\[[0-9]+\])?}]
set dst [get_cells -hier -regexp {.*u_regs/(enable|cw_mode|iq_swap|pack_ilv|f_start|k_rate|pw|pri|amp|phase0)_reg(\[[0-9]+\])?}]
if {![llength $src] || ![llength $dst]} {
    error "Cannot resolve chirp parameter CDC registers; inspect synthesized names"
}
set_max_delay -datapath_only 5.425 -from $src -to $dst
set_bus_skew 5.425 -from $src -to $dst

# Only the first stage of each single-bit synchronizer is asynchronous.
# The stage-0 to stage-1 paths must still meet destination-clock timing.
# lock_sync samples the unclocked clk_wiz_dac LOCKED output.
foreach sync {req_sync ack_sync rdy_sync hb_sync lock_sync} {
    set first [get_cells -hier -regexp ".*u_regs/${sync}_reg\\\[0\\\]"]
    if {[llength $first] != 1} { error "Cannot resolve first stage of $sync" }
    set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
}

# AXI-clocked reset levels into the DAC side: dac_domain_reset feeds the DAC
# reset controller's auxiliary input (synchronized inside proc_sys_reset) and
# dac_mmcm_reset the asynchronous MMCM RST pin. Neither is a timed transfer.
set rst_src [get_cells -hier -regexp {.*u_regs/(dom_rst_q|mmcm_rst_q)_reg}]
if {[llength $rst_src] != 2} { error "Cannot resolve DAC reset supervision registers" }
set_false_path -from $rst_src
