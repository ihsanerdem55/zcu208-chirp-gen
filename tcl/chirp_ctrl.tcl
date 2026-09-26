# =============================================================================
# chirp_ctrl.tcl  --  runtime control of the ZCU208 chirp generator from Vivado
#
# In Vivado Hardware Manager, after Program Device:
#     source <repo>/tcl/chirp_ctrl.tcl
#     hw_init                                   ;# find the JTAG-to-AXI master
#     rfdc_status                               ;# DAC tile must report state 15
#     nco_set 1.5e9                             ;# RF centre frequency
#     cw 10e6 0.5                               ;# tone at NCO + 10 MHz, half scale
#     chirp -bw 400e6 -pw 2e-6 -pri 10e-6       ;# 400 MHz LFM, 2 us pulse, 100 kHz PRF
#     gen_off
# =============================================================================

# ---- design constants (must match the RFDC settings) ------------------------
set ::FS_DAC     5898.24e6          ;# RF-DAC sample rate
set ::INTERP     8
set ::LANES      4
set ::FS_BB      [expr {$::FS_DAC / $::INTERP}]     ;# 737.28 MSPS complex
set ::FCLK       [expr {$::FS_BB / $::LANES}]       ;# 184.32 MHz fabric clock

set ::CHIRP_BASE 0x40000000
set ::RFDC_BASE  0x40040000
set ::DAC_TILE   2                  ;# tile 230 = DAC tile index 2 (228=0 ... 231=3)
set ::DAC_BLOCK  0                  ;# channel 0

# register offsets (chirp_axil_regs.sv)
array set ::R {ID 0x00 CTRL 0x04 FSTART 0x08 KRATE 0x0C PW 0x10 PRI 0x14 AMP 0x18 PHASE0 0x1C APPLY 0x20 STATUS 0x24}

# ---- low-level AXI access -----------------------------------------------------
proc hw_init {} {
    set axis [get_hw_axis]
    if {[llength $axis] == 0} { error "No JTAG-to-AXI master found. Program the device first (with probes file)." }
    set ::AXI [lindex $axis 0]
    reset_hw_axi $::AXI
    puts "Using $::AXI"
    set id [rd32 [expr {$::CHIRP_BASE + $::R(ID)}]]
    if {$id != 0x43485250} { puts "WARNING: chirp_gen ID = [format 0x%08X $id], expected 0x43485250" } \
    else                   { puts "chirp_gen found (ID CHRP)" }
}

proc wr32 {addr data} {
    set t [create_hw_axi_txn -force wr_txn $::AXI -type write \
              -address [format %08X $addr] -data [format %08X [expr {$data & 0xFFFFFFFF}]] -len 1]
    run_hw_axi -quiet $t
}

proc rd32 {addr} {
    set t [create_hw_axi_txn -force rd_txn $::AXI -type read -address [format %08X $addr] -len 1]
    run_hw_axi -quiet $t
    return [expr {"0x[get_property DATA $t]" + 0}]
}

proc creg_wr {name val} { wr32 [expr {$::CHIRP_BASE + $::R($name)}] $val }
proc creg_rd {name}     { return [rd32 [expr {$::CHIRP_BASE + $::R($name)}]] }

# copy all registers into the DAC clock domain and wait for the handshake
proc chirp_apply {} {
    creg_wr APPLY 1
    for {set i 0} {$i < 100} {incr i} {
        if {([creg_rd STATUS] & 0x2) == 0} { return }
    }
    error "APPLY did not complete: is the DAC clock running? (see rfdc_status, STATUS bit0)"
}

# ---- helpers -----------------------------------------------------------------------
proc fword {f_hz} {    ;# signed 32-bit frequency word at the baseband rate
    set w [expr {round(double($f_hz) / $::FS_BB * 4294967296.0)}]
    if {$w >= 2147483648 || $w < -2147483648} { error "frequency $f_hz outside +-FS_BB/2" }
    return [expr {$w & 0xFFFFFFFF}]
}

proc ctrl_word {enable cw swap ilv} {
    return [expr {($enable ? 1 : 0) | ($cw ? 2 : 0) | ($swap ? 4 : 0) | ($ilv ? 8 : 0)}]
}

# packing / swap options, kept between calls (set once during bring-up)
set ::IQ_SWAP 0
set ::PACK_ILV 0
proc iq_options {swap ilv} { set ::IQ_SWAP $swap; set ::PACK_ILV $ilv; puts "IQ_SWAP=$swap PACK_ILV=$ilv" }

# ---- user commands -----------------------------------------------------------------
# CW tone at (NCO + f_off). amp: 0..1 of full scale
proc cw {f_off {amp 0.5}} {
    creg_wr FSTART [fword $f_off]
    creg_wr KRATE  0
    creg_wr AMP    [expr {min(0x7FFF, int(round($amp * 32767)))}]
    creg_wr PHASE0 0
    creg_wr CTRL   [ctrl_word 1 1 $::IQ_SWAP $::PACK_ILV]
    chirp_apply
    puts [format "CW at NCO %+.6f MHz, amplitude %.3f" [expr {$f_off/1e6}] $amp]
}

# Pulsed LFM. Sweeps from (offset - bw/2) to (offset + bw/2) relative to the NCO.
# Negative bw gives a down-chirp.
#   chirp -bw 400e6 -pw 2e-6 -pri 10e-6 ?-offset 0? ?-amp 0.5? ?-phase_deg 0?
proc chirp {args} {
    array set o {-bw 100e6 -pw 1e-6 -pri 10e-6 -offset 0 -amp 0.5 -phase_deg 0}
    array set o $args
    set pw_clk  [expr {int(round($o(-pw)  * $::FCLK))}]
    set pri_clk [expr {int(round($o(-pri) * $::FCLK))}]
    if {$pw_clk < 1 || $pri_clk < $pw_clk} { error "need 1 <= PW <= PRI (in clocks: PW=$pw_clk PRI=$pri_clk)" }
    set ns     [expr {$pw_clk * $::LANES}]
    set f0     [expr {$o(-offset) - $o(-bw) / 2.0}]
    set f1     [expr {$o(-offset) + $o(-bw) / 2.0}]
    if {abs($f0) > 0.4*$::FS_BB || abs($f1) > 0.4*$::FS_BB} {
        puts "WARNING: sweep reaches beyond +-[expr {0.4*$::FS_BB/1e6}] MHz; the DAC interpolation filter will roll it off"
    }
    # frequency-word increase per sample, Q24.8
    set k [expr {round(double($o(-bw)) / $::FS_BB * 4294967296.0 / $ns * 256.0)}]
    if {$k >= 2147483648 || $k < -2147483648} { error "slope too steep for KRATE (Q24.8)" }
    creg_wr FSTART [fword $f0]
    creg_wr KRATE  [expr {$k & 0xFFFFFFFF}]
    creg_wr PW     $pw_clk
    creg_wr PRI    $pri_clk
    creg_wr AMP    [expr {min(0x7FFF, int(round($o(-amp) * 32767)))}]
    creg_wr PHASE0 [expr {int(round($o(-phase_deg) / 360.0 * 4294967296.0)) & 0xFFFFFFFF}]
    creg_wr CTRL   [ctrl_word 1 0 $::IQ_SWAP $::PACK_ILV]
    chirp_apply
    set slope [expr {($k / 256.0) * $::FS_BB * $::FS_BB / 4294967296.0}]
    puts [format "LFM %.3f MHz in %.3f us (slope %.4f MHz/us), PRI %.3f us, NCO %+.1f..%+.1f MHz" \
        [expr {$slope * $ns / $::FS_BB / 1e6}] [expr {$pw_clk / $::FCLK * 1e6}] \
        [expr {$slope / 1e12}] [expr {$pri_clk / $::FCLK * 1e6}] [expr {$f0/1e6}] [expr {$f1/1e6}]]
}

proc gen_off {} {
    creg_wr CTRL [ctrl_word 0 0 $::IQ_SWAP $::PACK_ILV]
    chirp_apply
    puts "output off"
}

proc chirp_dump {} {
    foreach n {ID CTRL FSTART KRATE PW PRI AMP PHASE0 STATUS} {
        puts [format "%-7s = 0x%08X" $n [creg_rd $n]]
    }
}

# ---- RF Data Converter (register level, from xrfdc_hw.h) ------------------------------
proc rfdc_tile_ctrl {} { return [expr {$::RFDC_BASE + 0x4000 + $::DAC_TILE * 0x4000}] }
proc rfdc_block_drp {} { return [expr {$::RFDC_BASE + 0x6000 + $::DAC_TILE * 0x4000 + $::DAC_BLOCK * 0x400}] }

proc rfdc_status {} {
    set b [rfdc_tile_ctrl]
    set state [expr {[rd32 [expr {$b + 0x0C}]] & 0xF}]
    set st    [rd32 [expr {$b + 0x228}]]
    puts [format "DAC tile %d: state %d (15 = running), power-up %d, PLL locked %d" \
        [expr {228 + $::DAC_TILE}] $state [expr {($st >> 2) & 1}] [expr {($st >> 3) & 1}]]
    set cs [creg_rd STATUS]
    puts [format "chirp_gen: DAC clock domain out of reset %d, apply pending %d" [expr {$cs & 1}] [expr {($cs >> 1) & 1}]]
    return $state
}

# re-run the tile power-on sequence (use after the clock was programmed late)
proc rfdc_restart {} {
    set b [rfdc_tile_ctrl]
    wr32 [expr {$b + 0x08}] 0x010F      ;# start state 1, end state 15
    wr32 [expr {$b + 0x04}] 0x1         ;# restart
    after 200
    rfdc_status
}

# Set the fine-mixer NCO frequency (Hz) and apply it immediately.
proc nco_set {f_hz} {
    set f [expr {double($f_hz)}]
    while {$f >  $::FS_DAC / 2.0} { set f [expr {$f - $::FS_DAC}] }
    while {$f < -$::FS_DAC / 2.0} { set f [expr {$f + $::FS_DAC}] }
    set w [expr {wide(round($f / $::FS_DAC * pow(2, 48))) & 0xFFFFFFFFFFFF}]
    set b [rfdc_block_drp]
    wr32 [expr {$b + 0x9C}] [expr {$w & 0xFFFF}]           ;# NCO freq [15:0]
    wr32 [expr {$b + 0x98}] [expr {($w >> 16) & 0xFFFF}]   ;# NCO freq [31:16]
    wr32 [expr {$b + 0x94}] [expr {($w >> 32) & 0xFFFF}]   ;# NCO freq [47:32]
    set u [rd32 [expr {$b + 0x8C}]]                          ;# NCO update source = immediate
    wr32 [expr {$b + 0x8C}] [expr {$u & ~0x7}]
    set d [rd32 [expr {$b + 0x20}]]                          ;# trigger NCO update event
    wr32 [expr {$b + 0x20}] [expr {($d & ~0xF) | 0x2}]
    puts [format "NCO = %.6f MHz" [expr {$f_hz / 1e6}]]
}
