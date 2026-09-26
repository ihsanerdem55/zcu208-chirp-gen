# =============================================================================
# zcu208_chirp.xdc
# RF pins (DAC clock input, vout20, sysref) are dedicated and placed by the IP.
# Pin numbers below come from the official ZCU208 board file
# (XilinxBoardStore boards/Xilinx/zcu208/production/2.0/part0_pins.xml).
# =============================================================================

# ---- 300 MHz board clock (USER_SI570_C0, 300 MHz at power-up) --------------------
set_property PACKAGE_PIN AP20        [get_ports sysclk_300_clk_p]
set_property PACKAGE_PIN AP19        [get_ports sysclk_300_clk_n]
set_property IOSTANDARD  DIFF_SSTL12 [get_ports sysclk_300_clk_p]
set_property IOSTANDARD  DIFF_SSTL12 [get_ports sysclk_300_clk_n]

# ---- CPU_RESET push-button (active high) --------------------------------------------
set_property PACKAGE_PIN AU1      [get_ports cpu_reset]
set_property IOSTANDARD  LVCMOS18 [get_ports cpu_reset]
set_false_path -from [get_ports cpu_reset]

# ---- Scope trigger --------------------------------------------------------------
# Default: user LED 0 (GPIO_LED_0_LS, pin AR19, 1.2 V bank), taken from the official
# ZCU208 board file (XilinxBoardStore zcu208/2.0/part0_pins.xml).
# The FPGA pin drives a level shifter that drives the LED; probe the LED side of the
# level shifter / the LED resistor with the scope. The LED also glows while pulsing.
# To use another pin instead (e.g. a PMOD header pin), replace PACKAGE_PIN and set
# IOSTANDARD to match that pin's bank voltage (LVCMOS12 / LVCMOS18 / LVCMOS33).
set_property PACKAGE_PIN AR19     [get_ports trig_out]
set_property IOSTANDARD  LVCMOS12 [get_ports trig_out]
set_property DRIVE       8        [get_ports trig_out]
set_property SLEW        FAST     [get_ports trig_out]

# ---- Clock domains ---------------------------------------------------------------
# The 100 MHz AXI clock and the 184.32 MHz DAC clock are unrelated. All crossings go
# through the 2-flop handshake in chirp_axil_regs.sv, so time them as asynchronous.
set_clock_groups -asynchronous \
    -group [get_clocks -quiet clk_out1*clk_wiz_axi*] \
    -group [get_clocks -quiet clk_out1*clk_wiz_dac*]

# trig_out is a scope marker, not a timed interface
set_false_path -to [get_ports trig_out]
