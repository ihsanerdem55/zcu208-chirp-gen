# opt_design pre-hook: runs after synthesis, before implementation.
# Never clock dbg_hub from the RFDC: it must remain reachable before tile startup.
set hub [get_debug_cores -quiet dbg_hub]
if {[llength $hub] != 1} { error "Expected one debug hub for the enabled DAC ILA" }
set clk [get_nets -hier -filter {NAME =~ */axi_clk_100m}]
if {[llength $clk] != 1} { error "Expected one independent 100 MHz AXI clock net, got $clk" }
disconnect_debug_port dbg_hub/clk
connect_debug_port dbg_hub/clk $clk
set_property C_CLK_INPUT_FREQ_HZ 100000000 $hub
set_property C_ENABLE_CLK_DIVIDER false $hub
puts "INFO: dbg_hub uses independent 100 MHz AXI clock: $clk"
