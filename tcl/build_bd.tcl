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
if {![info exists ADD_ILA]} { set ADD_ILA 1 }

# ------------------------------------------------------------------ project
catch {close_project}
create_project $proj_name $proj_dir -part xczu48dr-fsvg1517-2-e -force
set bp [lindex [lsort [get_board_parts -quiet *zcu208*]] end]
if {$bp eq ""} {
    puts "ERROR: ZCU208 board files not found. Install them from Vivado: Tools > Vivado Store > Boards."
    error "Cannot build without ZCU208 board files"
}
set_property board_part $bp [current_project]
puts "INFO: using board part $bp"

add_files -norecurse [list \
    $repo_dir/rtl/sincos_qw_rom.sv \
    $repo_dir/rtl/noise_src.sv \
    $repo_dir/rtl/chirp_core.sv \
    $repo_dir/rtl/chirp_axil_regs.sv \
    $repo_dir/rtl/chirp_gen_top.sv \
    $repo_dir/rtl/chirp_gen_wrapper.v \
    $repo_dir/rtl/sincos_qw.mem ]
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/zcu208_chirp.xdc
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/chirp_timing.xdc
set_property USED_IN_SYNTHESIS false [get_files chirp_timing.xdc]
set_property PROCESSING_ORDER LATE [get_files chirp_timing.xdc]
if {$ADD_ILA} {
    # Hook scripts belong to the utils_1 fileset so project archives include them.
    add_files -fileset utils_1 -norecurse $repo_dir/tcl/debug_hub.tcl
    set_property STEPS.OPT_DESIGN.TCL.PRE $repo_dir/tcl/debug_hub.tcl [get_runs impl_1]
}
update_compile_order -fileset sources_1

# ------------------------------------------------------------ block design
create_bd_design $bd_name

# --- RF Data Converter -------------------------------------------------------
# Tile 228/channel 0 with its local PLL and a 245.76 MHz CLK104 reference,
# without tile forwarding. Matches a DAC-228 sine design that ran on the
# target board (clock source Tile228, distribution off, 245.76 MHz reference).
# Units follow the IP: sampling rate in GSPS, NCO in GHz, clocks in MHz.
set rfdc [create_bd_cell -type ip -vlnv xilinx.com:ip:usp_rf_data_converter rfdc]
set rfdc_cfg [list \
    CONFIG.Axiclk_Freq             100.000 \
    CONFIG.DAC0_Enable            1 \
    CONFIG.DAC0_Clock_Source      4 \
    CONFIG.DAC0_Clock_Dist        0 \
    CONFIG.DAC0_Sampling_Rate     5.89824 \
    CONFIG.DAC0_PLL_Enable        true \
    CONFIG.DAC0_Refclk_Freq        245.760 \
    CONFIG.DAC0_Outclk_Freq        184.320 \
    CONFIG.DAC0_Fabric_Freq        184.320 \
    CONFIG.DAC0_Multi_Tile_Sync    false \
    CONFIG.DAC_Slice00_Enable      true \
    CONFIG.DAC_Data_Type00         0 \
    CONFIG.DAC_Interpolation_Mode00 8 \
    CONFIG.DAC_Data_Width00        8 \
    CONFIG.DAC_Mixer_Type00        2 \
    CONFIG.DAC_Mixer_Mode00        0 \
    CONFIG.DAC_NCO_Freq00          0.5 \
    CONFIG.DAC_Invsinc_Ctrl00       true]
# Nyquist zone is left at the IP default (zone 1). NCO: 0.5 GHz until nco_set.
# Set related parameters atomically; never silently build a different RF path.
foreach tile {0 1 2 3} {
    lappend rfdc_cfg CONFIG.ADC${tile}_Enable 0
    if {$tile != 0} { lappend rfdc_cfg CONFIG.DAC${tile}_Enable 0 }
    foreach block {0 2} {
        lappend rfdc_cfg CONFIG.ADC_Slice${tile}${block}_Enable false
        if {$tile != 0 || $block != 0} {
            lappend rfdc_cfg CONFIG.DAC_Slice${tile}${block}_Enable false
        }
    }
}
set_property -dict $rfdc_cfg $rfdc

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

# --- DAC fabric clock: rfdc/clk_dac0 -> Clocking Wizard (MMCM) ---------------
# clk_dac0 is absent at configuration and stops on every tile restart; an MMCM
# must be reset after LOCKED falls. chirp_gen_0 drives this reset from the
# independent AXI clock and retries it until the MMCM locks.
set clk_wiz_dac [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_dac]
set_property -dict [list \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {184.320} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {184.320} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} ] $clk_wiz_dac
if {[llength [get_bd_pins -quiet clk_wiz_dac/reset]] != 1} {
    error "clk_wiz_dac has no active-high 'reset' pin; the DAC MMCM could never relock"
}

# --- resets -------------------------------------------------------------------
# CPU_RESET push-button (pin AU1 in the XDC, active high). The reset blocks read
# the polarity from this port, so C_EXT_RESET_HIGH is set automatically.
create_bd_port -dir I -type rst cpu_reset
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports cpu_reset]
set rst_axi [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_axi]
set rst_dac [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_dac]
set_property CONFIG.C_EXT_RESET_HIGH 1 $rst_axi
set_property -dict [list CONFIG.C_EXT_RESET_HIGH 1 CONFIG.C_AUX_RESET_HIGH 1] $rst_dac

# --- JTAG-to-AXI + SmartConnect -------------------------------------------------
set jtag_axi [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
set axi_sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $axi_sc

# --- chirp generator (RTL module reference) -------------------------------------
set chirp [create_bd_cell -type module -reference chirp_gen_wrapper chirp_gen_0]

# ------------------------------------------------------------- connections
set axi_clk [get_bd_pins clk_wiz_axi/clk_out1]
set dac_clk [get_bd_pins clk_wiz_dac/clk_out1]

connect_bd_net -net axi_clk_100m $axi_clk [get_bd_pins rst_axi/slowest_sync_clk] [get_bd_pins jtag_axi_0/aclk] \
    [get_bd_pins axi_sc/aclk] [get_bd_pins rfdc/s_axi_aclk] [get_bd_pins chirp_gen_0/s_axi_aclk]
connect_bd_net [get_bd_pins clk_wiz_axi/locked] [get_bd_pins rst_axi/dcm_locked]
connect_bd_net [get_bd_ports cpu_reset] [get_bd_pins rst_axi/ext_reset_in] [get_bd_pins rst_dac/ext_reset_in]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
    [get_bd_pins axi_sc/aresetn] [get_bd_pins rfdc/s_axi_aresetn] [get_bd_pins chirp_gen_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M00_AXI]   [get_bd_intf_pins chirp_gen_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M01_AXI]   [get_bd_intf_pins rfdc/s_axi]

connect_bd_net [get_bd_pins rfdc/clk_dac0] [get_bd_pins clk_wiz_dac/clk_in1]
connect_bd_net -net dac_clk_184m $dac_clk [get_bd_pins rst_dac/slowest_sync_clk] [get_bd_pins chirp_gen_0/dac_clk] \
    [get_bd_pins rfdc/s0_axis_aclk]
connect_bd_net [get_bd_pins clk_wiz_dac/locked] [get_bd_pins rst_dac/dcm_locked] \
    [get_bd_pins chirp_gen_0/dac_mmcm_locked]
connect_bd_net [get_bd_pins chirp_gen_0/dac_mmcm_reset] [get_bd_pins clk_wiz_dac/reset]
# AXI reset or a DAC-clock loss must also clear the DAC-side handshake and
# waveform; dac_domain_reset stays high until the MMCM lock is stable again.
connect_bd_net [get_bd_pins chirp_gen_0/dac_domain_reset] [get_bd_pins rst_dac/aux_reset_in]
connect_bd_net [get_bd_pins rst_dac/peripheral_aresetn] [get_bd_pins chirp_gen_0/dac_rst_n] \
    [get_bd_pins rfdc/s0_axis_aresetn]
connect_bd_intf_net [get_bd_intf_pins chirp_gen_0/m_axis] [get_bd_intf_pins rfdc/s00_axis]

# dedicated RF pins (placed automatically, no XDC needed)
make_bd_intf_pins_external [get_bd_intf_pins rfdc/dac0_clk]
make_bd_intf_pins_external [get_bd_intf_pins rfdc/vout00]
if {[llength [get_bd_intf_pins -quiet rfdc/sysref_in]]} {
    make_bd_intf_pins_external [get_bd_intf_pins rfdc/sysref_in]
}
# scope trigger (pin set in the XDC)
create_bd_port -dir O trig_out
connect_bd_net [get_bd_pins chirp_gen_0/trig_out] [get_bd_ports trig_out]

# Native ILA avoids System ILA monitor-slot type/version mismatches.
# Full stream + handshake + pulse marker and eight signed 16-bit lane probes.
# ILA samples in the DAC domain; debug_hub.tcl keeps the hub on independent AXI.
# The IP-integrator ILA defaults to AXI-monitor mode, which ignores the native
# probe widths; select native mode explicitly. Probes use chirp_gen_0/mon_*:
# a net on an m_axis pin would detach that pin from the RFDC stream.
set ila_widths [list 128 1 1 1 16 16 16 16 16 16 16 16]
if {$ADD_ILA} {
    set ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila ila_dac]
    set cfg [list CONFIG.C_ENABLE_ILA_AXI_MON false CONFIG.C_MONITOR_TYPE Native \
        CONFIG.C_NUM_OF_PROBES [llength $ila_widths] CONFIG.C_DATA_DEPTH 4096]
    set n 0
    foreach w $ila_widths { lappend cfg CONFIG.C_PROBE${n}_WIDTH $w; incr n }
    set_property -dict $cfg $ila
    connect_bd_net $dac_clk [get_bd_pins ila_dac/clk]
    foreach {probe signal} {0 mon_data 1 mon_gate 2 mon_valid 3 mon_ready} {
        connect_bd_net [get_bd_pins chirp_gen_0/$signal] [get_bd_pins ila_dac/probe$probe]
    }
    for {set n 0} {$n < 8} {incr n} {
        set slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice iq_slice_$n]
        set_property -dict [list CONFIG.DIN_WIDTH 128 CONFIG.DIN_FROM [expr {16*$n+15}] \
            CONFIG.DIN_TO [expr {16*$n}] CONFIG.DOUT_WIDTH 16] $slice
        connect_bd_net [get_bd_pins chirp_gen_0/mon_data] [get_bd_pins iq_slice_$n/Din]
        connect_bd_net [get_bd_pins iq_slice_$n/Dout] [get_bd_pins ila_dac/probe[expr {$n+4}]]
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
        error "Address segment $pat not found; expected $off / $rng"
    }
    set_property range  $rng $seg
    set_property offset $off $seg
}

regenerate_bd_layout
validate_bd_design
set stream [get_bd_intf_pins rfdc/s00_axis]
set nb [get_property CONFIG.TDATA_NUM_BYTES $stream]
if {$nb != 16} { error "RFDC stream must be 128 bits, got $nb bytes" }
set fabric [get_property CONFIG.DAC0_Fabric_Freq $rfdc]
if {abs($fabric - 184.32) > 0.001} { error "RFDC requires $fabric MHz, expected 184.32 MHz" }
# The generator must drive the RFDC through the interface connection.
set snet [get_bd_intf_nets -quiet -of_objects $stream]
if {[llength $snet] != 1 ||
    [lsearch -exact [get_bd_intf_pins -quiet -of_objects $snet] /chirp_gen_0/m_axis] < 0} {
    error "rfdc/s00_axis is not connected to chirp_gen_0/m_axis as an interface"
}
if {$ADD_ILA} {
    set n 0
    foreach w $ila_widths {
        set got [get_property CONFIG.C_PROBE${n}_WIDTH $ila]
        if {$got != $w} { error "ila_dac probe$n is $got bits, expected $w" }
        incr n
    }
}
save_bd_design

# ------------------------------------------------------------ HDL wrapper
set bd_file [get_files $bd_name.bd]
make_wrapper -files $bd_file -top
add_files -norecurse [file join [file dirname $bd_file] hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=================================================================="
puts " Block design ready."
puts " 1. Double-click rfdc: only DAC tile 228 ch0 enabled (see settings above)."
puts " 2. trig_out is on LED0 (AR19); change it in the XDC if you want another pin."
puts " 3. Flow Navigator > Generate Bitstream."
puts "=================================================================="

