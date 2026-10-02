# Implementation-only CDC constraints. Do not use set_clock_groups here: that
# would override the max-delay bound on the bundled parameter transfer.
#
# XDC accepts plain constraint commands only: Vivado skips Tcl control flow
# (if/foreach/error) in constraint files, so every exception is written out.
# A query that matches nothing produces a critical warning in the
# implementation log; check for it after changing any RTL register names.

# Bundled parameter transfer, AXI -> DAC. req_sync gives the data at least two
# DAC clocks to settle; bound propagation and skew to one DAC period (5.425 ns).
# Sources r_* and destinations cap_* are DONT_TOUCH flops with no logic between
# them (apart from the load enable), and each cap_* has a single load, so
# implementation cannot replicate them out of these exceptions. (The previous
# destinations fanned out into the generator: implementation replicated
# cw_mode_reg into cw_mode_reg_rep*, which no exception covered, and those
# AXI -> DAC paths failed by about 1 ns.)
set src [get_cells -hier -regexp {.*u_regs/r_(ctrl|fstart|krate|pw|pri|amp|phase0)_reg(\[[0-9]+\])?}]
set dst [get_cells -hier -regexp {.*u_regs/cap_(ctrl|fstart|krate|pw|pri|amp|phase0)_reg(\[[0-9]+\])?}]
set_max_delay -datapath_only 5.425 -from $src -to $dst
set_bus_skew 5.425 -from $src -to $dst

# Single-bit synchronizers: only the first stage's D input is asynchronous.
# The stage-0 to stage-1 paths must still meet destination-clock timing.
#   req_sync  AXI -> DAC   APPLY toggle
#   ack_sync  DAC -> AXI   APPLY acknowledge
#   rdy_sync  DAC -> AXI   DAC domain ready
#   hb_sync   DAC -> AXI   DAC clock heartbeat
#   lock_sync (unclocked)  clk_wiz_dac LOCKED
set_false_path -to [get_pins -of_objects [get_cells -hier -regexp {.*u_regs/(req|ack|rdy|hb|lock)_sync_reg\[0\]}] -filter {REF_PIN_NAME == D}]

# AXI-clocked reset levels into the DAC side: dac_domain_reset feeds the DAC
# reset controller's auxiliary input (synchronized inside proc_sys_reset) and
# dac_mmcm_reset the asynchronous MMCM RST pin. Neither is a timed transfer.
set_false_path -from [get_cells -hier -regexp {.*u_regs/(dom_rst_q|mmcm_rst_q)_reg}]
