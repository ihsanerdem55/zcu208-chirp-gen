# Implementation-only: generated clocks exist after synthesis.
# All AXI/DAC crossings use the toggle handshake or two-stage status synchronizers.
set axi_clks [get_clocks -of_objects [get_nets -hier -filter {NAME =~ */axi_clk_100m}]]
set dac_clks [get_clocks -of_objects [get_nets -hier -filter {NAME =~ */dac_clk_184m}]]
if {![llength $axi_clks] || ![llength $dac_clks]} {
    error "Cannot resolve AXI/DAC clocks; inspect clock names before implementation"
}
set_clock_groups -asynchronous -group $axi_clks -group $dac_clks
