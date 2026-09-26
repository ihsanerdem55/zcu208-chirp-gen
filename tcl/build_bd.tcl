# =============================================================================
# build_bd.tcl  --  create the ZCU208 chirp generator project and block design
#
# Usage (Vivado 2022.2 or newer, ZCU208 board files installed):
#   cd <this repo>/tcl
#   vivado -mode gui -source build_bd.tcl        (or: source build_bd.tcl in the Tcl console)
#
# After it finishes: open the RF Data Converter IP once and check it against the
# settings table in the design guide, then Generate Bitstream.
# =============================================================================
set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize $script_dir/..]
set proj_name  zcu208_chirp
set proj_dir   [file normalize $repo_dir/vivado/$proj_name]
set bd_name    chirp_bd
set ADD_ILA    0        ;# 1 = add a System ILA on the DAC stream.
                        ;# Default 0: with the ILA on the DAC clock, Vivado also clocks the
                        ;# debug hub from the DAC clock, so if the RF-DAC tile does not start,
                        ;# JTAG-to-AXI is unreachable. Enable only after the DAC is known to work.

# ------------------------------------------------------------------ project
catch {close_project}
create_project $proj_name $proj_dir -part xczu48dr-fsvg1517-2-e -force
set bp [lindex [lsort [get_board_parts -quiet *zcu208*]] end]
if {$bp eq ""} {
    puts "ERROR: ZCU208 board files not found. Install them from Vivado: Tools > Vivado Store > Boards."
    return
}
set_property board_part $bp [current_project]
puts "INFO: using board part $bp"

add_files -norecurse [list \
    $repo_dir/rtl/sincos_qw_rom.sv \
    $repo_dir/rtl/chirp_core.sv \
    $repo_dir/rtl/chirp_axil_regs.sv \
    $repo_dir/rtl/chirp_gen_top.sv \
    $repo_dir/rtl/chirp_gen_wrapper.v \
    $repo_dir/rtl/sincos_qw.mem ]
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/zcu208_chirp.xdc
# pins + clock groups refer to IP clocks that only exist after synthesis -> implementation only
set_property USED_IN_SYNTHESIS false [get_files zcu208_chirp.xdc]
update_compile_order -fileset sources_1

# ------------------------------------------------------------ block design
create_bd_design $bd_name

# --- RF Data Converter -------------------------------------------------------
# DAC TILE 230, CHANNEL 0.
# On the ZCU208 the CLK104 LMK04828 reference clock (245.76 MHz) is wired only to
# DAC tile 230 (and ADC tile 226). Using tile 230 means the tile gets its clock
# directly: no clock distribution, no extra tiles. (Tile 228 needs distribution
# through 229 and 230 and otherwise stops at power-up state 6.)
# Naming: DAC tile index 0..3 = tiles 228..231, so tile 230 = index 2:
#   DAC2_* tile settings, DAC_*20 channel settings, ports dac2_clk, clk_dac2,
#   s2_axis_aclk/aresetn, s20_axis, vout20.
set rfdc [create_bd_cell -type ip -vlnv xilinx.com:ip:usp_rf_data_converter rfdc]

# Enable the new channel first, then switch everything else off. Each property is
# set separately so a name that differs in your Vivado version only prints a
# warning; anything that fails must be set by hand in the IP GUI.
set rfdc_cfg [dict create \
    DAC_Slice20_Enable       true  \
    DAC2_Enable              1     \
    DAC2_Sampling_Rate       5.89824 \
    DAC2_PLL_Enable          true  \
    DAC2_Refclk_Freq         245.760 \
    DAC2_Outclk_Freq         184.320 \
    DAC2_Multi_Tile_Sync     false \
    DAC_Interpolation_Mode20 8     \
    DAC_Data_Width20         8     \
    DAC_Mixer_Type20         2     \
    DAC_Mixer_Mode20         0     \
    DAC_NCO_Freq20           1.0   \
    DAC_Invsinc_Ctrl20       true  \
    DAC_Slice00_Enable       false \
    DAC_Slice02_Enable       false \
    DAC_Slice10_Enable       false \
    DAC_Slice12_Enable       false \
    DAC_Slice22_Enable       false \
    DAC_Slice30_Enable       false \
    DAC_Slice32_Enable       false \
    DAC0_Enable              0     \
    DAC1_Enable              0     \
    DAC3_Enable              0     \
    ADC_Slice00_Enable       false \
    ADC_Slice02_Enable       false \
    ADC_Slice10_Enable       false \
    ADC_Slice12_Enable       false \
    ADC_Slice20_Enable       false \
    ADC_Slice22_Enable       false \
    ADC_Slice30_Enable       false \
    ADC_Slice32_Enable       false ]
dict for {k v} $rfdc_cfg {
    if {[catch {set_property CONFIG.$k $v $rfdc} err]} {
        puts "WARNING: could not set rfdc CONFIG.$k = $v -> set it in the IP GUI ($err)"
    }
}

# --- sanity check: I/Q stream must be 128 bits (4 complex samples x 32 bits) ----
set nb [get_property -quiet CONFIG.TDATA_NUM_BYTES [get_bd_intf_pins -quiet rfdc/s20_axis]]
if {$nb ne "16"} {
    puts "=================================================================="
    puts "CRITICAL: rfdc/s20_axis is [expr {$nb eq "" ? "missing" : "[expr {$nb*8}] bits wide"}], expected 128 bits."
    puts "  Open the rfdc IP. Only DAC tile 230 channel 0 enabled: Mixer Type = Fine,"
    puts "  Mixer Mode = I/Q -> Real, Interpolation = 8x, Samples per AXI4-Stream"
    puts "  cycle = 8, Sampling rate 5898.24 MSPS, PLL on, Reference clock 245.76 MHz,"
    puts "  Required AXI4-Stream clock 184.32 MHz, NCO 1000 MHz, Inverse sinc on."
    puts "=================================================================="
}

# --- AXI clock: board USER_SI570_C0 (300 MHz) -> Clocking Wizard -> 100 MHz ---
# Explicit top-level port (pins AP20/AP19 in the XDC, taken from the ZCU208 board
# file). No board automation, so it works the same in every Vivado version.
set clk_wiz_axi [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_axi]
set_property -dict [list \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ {300.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.USE_RESET {false} ] $clk_wiz_axi
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sysclk_300
set_property CONFIG.FREQ_HZ 300000000 [get_bd_intf_ports sysclk_300]
connect_bd_intf_net [get_bd_intf_ports sysclk_300] [get_bd_intf_pins clk_wiz_axi/CLK_IN1_D]

# --- DAC fabric clock: rfdc/clk_dac2 -> Clocking Wizard (MMCM) ---------------
set clk_wiz_dac [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_dac]
set_property -dict [list \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {184.320} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {184.320} \
    CONFIG.USE_RESET {false} ] $clk_wiz_dac

# --- resets -------------------------------------------------------------------
# CPU_RESET push-button (pin AU1 in the XDC, active high). The reset blocks read
# the polarity from this port, so C_EXT_RESET_HIGH is set automatically.
create_bd_port -dir I -type rst cpu_reset
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports cpu_reset]
set rst_axi [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_axi]
set rst_dac [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_dac]

# --- JTAG-to-AXI + SmartConnect -------------------------------------------------
set jtag_axi [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
set axi_sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $axi_sc

# --- chirp generator (RTL module reference) -------------------------------------
set chirp [create_bd_cell -type module -reference chirp_gen_wrapper chirp_gen_0]

# ------------------------------------------------------------- connections
set axi_clk [get_bd_pins clk_wiz_axi/clk_out1]
set dac_clk [get_bd_pins clk_wiz_dac/clk_out1]

connect_bd_net $axi_clk [get_bd_pins rst_axi/slowest_sync_clk] [get_bd_pins jtag_axi_0/aclk] \
    [get_bd_pins axi_sc/aclk] [get_bd_pins rfdc/s_axi_aclk] [get_bd_pins chirp_gen_0/s_axi_aclk]
connect_bd_net [get_bd_pins clk_wiz_axi/locked] [get_bd_pins rst_axi/dcm_locked]
connect_bd_net [get_bd_ports cpu_reset] [get_bd_pins rst_axi/ext_reset_in] [get_bd_pins rst_dac/ext_reset_in]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
    [get_bd_pins axi_sc/aresetn] [get_bd_pins rfdc/s_axi_aresetn] [get_bd_pins chirp_gen_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M00_AXI]   [get_bd_intf_pins chirp_gen_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M01_AXI]   [get_bd_intf_pins rfdc/s_axi]

connect_bd_net [get_bd_pins rfdc/clk_dac2] [get_bd_pins clk_wiz_dac/clk_in1]
connect_bd_net $dac_clk [get_bd_pins rst_dac/slowest_sync_clk] [get_bd_pins chirp_gen_0/dac_clk] \
    [get_bd_pins rfdc/s2_axis_aclk]
connect_bd_net [get_bd_pins clk_wiz_dac/locked] [get_bd_pins rst_dac/dcm_locked]
connect_bd_net [get_bd_pins rst_dac/peripheral_aresetn] [get_bd_pins chirp_gen_0/dac_rst_n] \
    [get_bd_pins rfdc/s2_axis_aresetn]
connect_bd_intf_net [get_bd_intf_pins chirp_gen_0/m_axis] [get_bd_intf_pins rfdc/s20_axis]

# dedicated RF pins (placed automatically, no XDC needed)
make_bd_intf_pins_external [get_bd_intf_pins rfdc/dac2_clk]
make_bd_intf_pins_external [get_bd_intf_pins rfdc/vout20]
if {[llength [get_bd_intf_pins -quiet rfdc/sysref_in]]} {
    make_bd_intf_pins_external [get_bd_intf_pins rfdc/sysref_in]
}
# scope trigger (pin set in the XDC)
create_bd_port -dir O trig_out
connect_bd_net [get_bd_pins chirp_gen_0/trig_out] [get_bd_ports trig_out]

# --- optional System ILA on the DAC stream -------------------------------------
# Slot 0 is switched to AXI4-Stream (default is AXI4-MM, which is why a pin called
# SLOT_0_AXIS did not exist). Wrapped in catch: the ILA is a debug extra and must
# never stop the build.
if {$ADD_ILA} {
    if {[catch {
        set ila [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila ila_dac]
        set_property -dict [list \
            CONFIG.C_MON_TYPE {MIX} \
            CONFIG.C_NUM_MONITOR_SLOTS {1} \
            CONFIG.C_SLOT_0_INTF_TYPE {xilinx.com:interface:axis_rtl:1.0} \
            CONFIG.C_NUM_OF_PROBES {1} \
            CONFIG.C_DATA_DEPTH {4096} ] $ila
        set axis_net [get_bd_intf_nets -of_objects [get_bd_intf_pins chirp_gen_0/m_axis]]
        connect_bd_intf_net -intf_net $axis_net [get_bd_intf_pins chirp_gen_0/m_axis] \
            [get_bd_intf_pins ila_dac/SLOT_0_AXIS]
        connect_bd_net [get_bd_pins chirp_gen_0/trig_out] [get_bd_pins ila_dac/probe0]
        connect_bd_net $dac_clk [get_bd_pins ila_dac/clk]
        connect_bd_net [get_bd_pins rst_dac/peripheral_aresetn] [get_bd_pins ila_dac/resetn]
    } err]} {
        puts "WARNING: System ILA not added ($err). The design works without it."
        catch {delete_bd_objs [get_bd_cells -quiet ila_dac]}
    }
}

# ------------------------------------------------------------ address map
# chirp_gen at 0x4000_0000 (64 KB), RF Data Converter at 0x4004_0000 (256 KB).
# chirp_ctrl.tcl uses these two addresses.
assign_bd_address
foreach {pat off rng} {*chirp_gen_0* 0x40000000 64K *rfdc* 0x40040000 256K} {
    set seg [get_bd_addr_segs -quiet -filter "NAME =~ $pat" \
                 -of_objects [get_bd_addr_spaces jtag_axi_0/Data]]
    if {$seg eq ""} {
        puts "WARNING: address segment $pat not found; set it in the Address Editor ($off, $rng)"
        continue
    }
    set_property range  $rng $seg
    set_property offset $off $seg
}

regenerate_bd_layout
validate_bd_design
save_bd_design

# ------------------------------------------------------------ HDL wrapper
set bd_file [get_files $bd_name.bd]
make_wrapper -files $bd_file -top
add_files -norecurse [file join [file dirname $bd_file] hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=================================================================="
puts " Block design ready."
puts " 1. Double-click rfdc: only DAC tile 230 ch0 enabled (see settings above)."
puts " 2. trig_out is on LED0 (AR19); change it in the XDC if you want another pin."
puts " 3. Flow Navigator > Generate Bitstream."
puts "=================================================================="
