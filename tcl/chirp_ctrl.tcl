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
set ::DAC_TILE   0                  ;# CLK104 reference -> tile 228 (index 0)
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
    if {$id != 0x43485250} { error "chirp_gen ID = [format 0x%08X $id], expected 0x43485250" } \
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

# Check for an existing request BEFORE writing any new parameters or APPLY.
# Retoggling APPLY while the DAC clock is stopped can cancel the pending request.
proc chirp_wait_idle {{timeout_ms 1000}} {
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    while {1} {
        set st [creg_rd STATUS]
        if {($st & 1) == 0} { error "DAC handshake is in reset/recovery; run rfdc_status / clock_check" }
        if {($st & 2) == 0} { return }
        if {[clock milliseconds] >= $deadline} {
            error "APPLY still pending; restore the DAC clock before retrying (do not toggle APPLY again)"
        }
        after 10
    }
}
proc chirp_apply {} {
    chirp_wait_idle
    creg_wr APPLY 1
    chirp_wait_idle
}

# Disable using the CURRENT packing/swap flags, then drain the sample pipeline.
proc chirp_prepare {} {
    chirp_wait_idle
    creg_wr CTRL [expr {[creg_rd CTRL] & ~1}]
    chirp_apply
    after 1
}

# ---- helpers -----------------------------------------------------------------------
proc fword {f_hz} {    ;# signed 32-bit frequency word at the baseband rate
    if {![string is double -strict $f_hz] || ![expr {abs($f_hz) < Inf}]} { error "frequency must be finite and numeric" }
    set w [expr {round(double($f_hz) / $::FS_BB * 4294967296.0)}]
    if {$w >= 2147483648 || $w < -2147483648} { error "frequency $f_hz outside +-FS_BB/2" }
    return [expr {$w & 0xFFFFFFFF}]
}

proc ctrl_word {enable cw swap ilv} {
    return [expr {($enable ? 1 : 0) | ($cw ? 2 : 0) | ($swap ? 4 : 0) | ($ilv ? 8 : 0)}]
}

# packing / swap options, kept between calls (set once during bring-up)
set ::IQ_SWAP 0
set ::PACK_ILV 1   ;# PG269: even 16-bit words = I, odd words = Q
proc iq_options {swap ilv} {
    if {$swap ni {0 1} || $ilv ni {0 1}} { error "swap and ilv must be 0 or 1" }
    if {!$ilv} { puts "WARNING: split packing is for RTL experiments; RFDC I/Q input requires ilv=1" }
    set ::IQ_SWAP $swap; set ::PACK_ILV $ilv
    puts "IQ_SWAP=$swap PACK_ILV=$ilv"
}
proc amplitude_word {amp} {
    if {![string is double -strict $amp] || !($amp >= 0 && $amp <= 1)} {
        error "amplitude must be between 0 and 1"
    }
    return [expr {round($amp * 32767)}]
}

# ---- user commands -----------------------------------------------------------------
# CW tone at (NCO + f_off). amp: 0..1 of full scale
proc cw {f_off {amp 0.5}} {
    set f0 [fword $f_off]
    set a [amplitude_word $amp]
    rfdc_require_running
    chirp_prepare
    creg_wr FSTART $f0
    creg_wr KRATE  0
    creg_wr AMP    $a
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
    if {[llength $args] % 2} { error "chirp needs option/value pairs" }
    foreach {key val} $args {
        if {![info exists o($key)]} { error "Unknown chirp option: $key" }
        if {![string is double -strict $val] || ![expr {abs($val) < Inf}]} {
            error "$key must be finite and numeric"
        }
        set o($key) $val
    }
    set a [amplitude_word $o(-amp)]
    set pw_clk  [expr {wide(round($o(-pw)  * $::FCLK))}]
    set pri_clk [expr {wide(round($o(-pri) * $::FCLK))}]
    if {$pw_clk < 1 || $pri_clk < $pw_clk || $pri_clk > 0xFFFFFFFF} { error "need 1 <= PW <= PRI (in clocks: PW=$pw_clk PRI=$pri_clk)" }
    set ns     [expr {$pw_clk * $::LANES}]
    set f0     [expr {$o(-offset) - $o(-bw) / 2.0}]
    set f1     [expr {$o(-offset) + $o(-bw) / 2.0}]
    if {abs($f0) > 0.4*$::FS_BB || abs($f1) > 0.4*$::FS_BB} {
        puts "WARNING: sweep reaches beyond +-[expr {0.4*$::FS_BB/1e6}] MHz; the DAC interpolation filter will roll it off"
    }
    # frequency-word increase per sample, Q24.8
    set k [expr {round(double($o(-bw)) / $::FS_BB * 4294967296.0 / $ns * 256.0)}]
    if {$k >= 2147483648 || $k < -2147483648} { error "slope too steep for KRATE (Q24.8)" }
    set fw [fword $f0]
    fword $f1
    set phase [expr {wide(round(fmod($o(-phase_deg), 360.0) / 360.0 * 4294967296.0)) & 0xFFFFFFFF}]
    rfdc_require_running
    chirp_prepare
    creg_wr FSTART $fw
    creg_wr KRATE  [expr {$k & 0xFFFFFFFF}]
    creg_wr PW     $pw_clk
    creg_wr PRI    $pri_clk
    creg_wr AMP    $a
    creg_wr PHASE0 $phase
    creg_wr CTRL   [ctrl_word 1 0 $::IQ_SWAP $::PACK_ILV]
    chirp_apply
    set slope [expr {($k / 256.0) * $::FS_BB * $::FS_BB / 4294967296.0}]
    puts [format "LFM %.3f MHz in %.3f us (slope %.4f MHz/us), PRI %.3f us, NCO %+.1f..%+.1f MHz" \
        [expr {$slope * $ns / $::FS_BB / 1e6}] [expr {$pw_clk / $::FCLK * 1e6}] \
        [expr {$slope / 1e12}] [expr {$pri_clk / $::FCLK * 1e6}] [expr {$f0/1e6}] [expr {$f1/1e6}]]
}

proc gen_off {} {
    chirp_prepare
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
    puts [format "chirp_gen: DAC handshake ready %d, apply pending %d" [expr {$cs & 1}] [expr {($cs >> 1) & 1}]]
    if {$state != 15} {
        puts "Check CLK104 LMK DCLKout6 = 245.76 MHz to tile 228; use rfdc_restart after programming the clock."
    }
    return $state
}

proc rfdc_require_running {} {
    set b [rfdc_tile_ctrl]
    set state [expr {[rd32 [expr {$b + 0x0C}]] & 15}]
    set st [rd32 [expr {$b + 0x228}]]
    if {$state != 15 || ($st & 12) != 12} {
        error "DAC tile 228 is not ready (state=$state, status=[format 0x%08X $st]); run rfdc_status"
    }
}

# STATUS[0] alone is not evidence of a running clock: observe heartbeat edges.
proc clock_check {{timeout_ms 1000}} {
    set initial [expr {[creg_rd STATUS] & 4}]
    set deadline [expr {[clock milliseconds] + $timeout_ms}]
    while {[clock milliseconds] < $deadline} {
        after 10
        if {([creg_rd STATUS] & 4) != $initial} {
            puts "DAC fabric heartbeat is changing"
            return 1
        }
    }
    error "No DAC fabric heartbeat; check CLK104, RFDC PLL and clk_wiz_dac lock"
}

# re-run the tile power-on sequence (use after the clock was programmed late)
proc rfdc_restart {} {
    # If the fabric is alive, silence it before restarting. If it is in reset,
    # the RTL remains disabled on recovery. A stopped clock without reset cannot
    # acknowledge silence: fail instead of restarting with an armed waveform.
    if {[creg_rd STATUS] & 1} { gen_off }
    set b [rfdc_tile_ctrl]
    wr32 [expr {$b + 0x08}] 0x010F      ;# start state 1, end state 15
    wr32 [expr {$b + 0x04}] 0x1         ;# restart
    set deadline [expr {[clock milliseconds] + 3000}]
    while {[clock milliseconds] < $deadline} {
        after 20
        if {![catch {rfdc_require_running}]} {
            rfdc_status
            clock_check
            gen_off
            return
        }
    }
    rfdc_status
    error "DAC tile 228 restart timed out"
}

# Set the fine-mixer NCO frequency (Hz) and apply it immediately.
proc nco_set {f_hz} {
    if {![string is double -strict $f_hz] || ![expr {abs($f_hz) < Inf}]} { error "NCO frequency must be finite" }
    rfdc_require_running
    set f [expr {fmod(double($f_hz), $::FS_DAC)}]
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

