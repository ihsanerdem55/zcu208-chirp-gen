# =============================================================================
# chirp_ctrl.tcl  --  runtime control of the ZCU208 chirp generator from Vivado
#
# In Vivado Hardware Manager, after Program Device:
#     source <repo>/tcl/chirp_ctrl.tcl
#     hw_init                                   ;# find the JTAG-to-AXI master
#     rfdc_status                               ;# state 15, MMCM locked, config read-back
#     clock_check                               ;# DAC fabric heartbeat
#     nco_set 500e6                             ;# RF centre frequency
#     cw 10e6 0.1                               ;# tone at NCO + 10 MHz, 0.1 of full scale
#     chirp -bw 400e6 -pw 2e-6 -pri 10e-6       ;# 400 MHz LFM, 2 us pulse, 100 kHz PRF
#     noise -bw 200e6 -amp 0.1                  ;# band-limited noise, 200 MHz wide, continuous
#     gen_off
#
# 4x interpolation: 1474.56 MSPS complex at the RFDC input, so chirps and noise
# can use about +-0.4 * 1474.56 = +-590 MHz around the NCO (~1.18 GHz).
# =============================================================================

# ---- design constants (must match the RFDC settings) ------------------------
set ::FS_DAC     5898.24e6          ;# RF-DAC sample rate
set ::INTERP     4
set ::LANES      8                  ;# complex samples per fabric clock (256-bit AXIS)
set ::FS_BB      [expr {$::FS_DAC / $::INTERP}]     ;# 1474.56 MSPS complex
set ::FCLK       [expr {$::FS_BB / $::LANES}]       ;# 184.32 MHz fabric clock
set ::NCO_HZ     500e6              ;# DAC_NCO_Freq00 in tcl/build_bd.tcl; nco_set updates it

set ::CHIRP_BASE 0x40000000
set ::RFDC_BASE  0x40040000
set ::DAC_TILE   0                  ;# CLK104 reference -> tile 228 (index 0)
set ::DAC_BLOCK  0                  ;# channel 0
set ::WAIT_MS    1000               ;# DAC handshake timeout
# Refuse to drive the DAC if the RFDC read-back disagrees with FS_BB/NCO math.
# Set to 0 only to diagnose a read-back that you have checked by other means.
set ::RFDC_CONFIG_CHECK 1

# register offsets (chirp_axil_regs.sv)
array set ::R {ID 0x00 CTRL 0x04 FSTART 0x08 KRATE 0x0C PW 0x10 PRI 0x14 AMP 0x18 PHASE0 0x1C APPLY 0x20 STATUS 0x24}
# CTRL bits:   [0] enable, [1] cw_mode, [2] iq_swap, [3] pack_ilv, [4] noise_mode
# In noise_mode KRATE is reused as the noise bandwidth word (ninc, unsigned Q0.32)
# and PHASE0 as the noise seed.
# STATUS bits: [0] handshake ready, [1] APPLY pending, [2] heartbeat, [3] DAC MMCM locked

# ---- low-level AXI access -----------------------------------------------------
proc hw_init {} {
    set axis [get_hw_axis]
    if {[llength $axis] == 0} { error "No JTAG-to-AXI master found. Program the device first (with probes file)." }
    set ::AXI [lindex $axis 0]
    reset_hw_axi $::AXI
    # Keep AXI errors visible but drop the per-transaction "READ DATA is" chatter.
    catch {set_msg_config -id {Labtoolstcl 44-481} -suppress}
    puts "Using $::AXI"
    set id [rd32 [expr {$::CHIRP_BASE + $::R(ID)}]]
    if {$id != 0x43485250} { error "chirp_gen ID = [format 0x%08X $id], expected 0x43485250" } \
    else                   { puts "chirp_gen found (ID CHRP)" }
}

# Never use run_hw_axi -quiet: it returns TCL_OK even when the transaction fails,
# which would hide SLVERR rejections, timeouts and a lost JTAG link.
proc axi_run {txn kind addr} {
    if {[catch {run_hw_axi $txn} err]} {
        error "JTAG-to-AXI $kind at [format 0x%08X $addr] failed: $err"
    }
}

proc wr32 {addr data} {
    set t [create_hw_axi_txn -force wr_txn $::AXI -type write \
              -address [format %08X $addr] -data [format %08X [expr {$data & 0xFFFFFFFF}]] -len 1]
    axi_run $t write $addr
}

proc rd32 {addr} {
    set t [create_hw_axi_txn -force rd_txn $::AXI -type read -address [format %08X $addr] -len 1]
    axi_run $t read $addr
    set data [get_property DATA $t]
    if {![string is xdigit -strict $data]} {
        error "JTAG-to-AXI read at [format 0x%08X $addr] returned '$data'"
    }
    return [expr {"0x$data" + 0}]
}

proc creg_wr {name val} { wr32 [expr {$::CHIRP_BASE + $::R($name)}] $val }
proc creg_rd {name}     { return [rd32 [expr {$::CHIRP_BASE + $::R($name)}]] }

# Check for an existing request BEFORE writing any new parameters or APPLY.
# Retoggling APPLY while the DAC clock is stopped can cancel the pending request.
# A DAC-domain reset (e.g. MMCM relock) is transient: wait for it to finish.
proc chirp_wait_idle {} {
    set deadline [expr {[clock milliseconds] + $::WAIT_MS}]
    while {1} {
        set st [creg_rd STATUS]
        if {($st & 3) == 1} { return }
        if {[clock milliseconds] >= $deadline} {
            if {$st & 1} {
                error "APPLY still pending; restore the DAC clock before retrying (do not toggle APPLY again)"
            }
            error "DAC handshake not ready (DAC domain in reset, MMCM locked [expr {($st >> 3) & 1}]); run rfdc_status / clock_check"
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

proc ctrl_word {enable cw swap ilv {noise 0}} {
    return [expr {($enable ? 1 : 0) | ($cw ? 2 : 0) | ($swap ? 4 : 0) | \
                  ($ilv ? 8 : 0) | ($noise ? 16 : 0)}]
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
# Warn when the RF band NCO + [f_lo, f_hi] leaves the first Nyquist zone: below
# 0 Hz it folds back onto itself, above FS_DAC/2 it lands in the second zone.
proc band_check {f_lo f_hi} {
    set lo [expr {$::NCO_HZ + min($f_lo, $f_hi)}]
    set hi [expr {$::NCO_HZ + max($f_lo, $f_hi)}]
    if {$lo < 0 || $hi > $::FS_DAC / 2.0} {
        puts [format "WARNING: RF band %.1f..%.1f MHz (NCO %.1f MHz) leaves 0..%.1f MHz; raise/lower the NCO" \
            [expr {$lo/1e6}] [expr {$hi/1e6}] [expr {$::NCO_HZ/1e6}] [expr {$::FS_DAC/2e6}]]
    }
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
    band_check $f_off $f_off
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
    band_check $f0 $f1
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

# Band-limited noise, centred at the RFDC NCO. The generator draws a fresh random
# complex sample every D = FS_BB/bw samples and holds it in between (sample-and-hold),
# so the baseband band is roughly +-bw/2 with a sinc^2 envelope (first nulls at
# +-bw). Set the NCO with nco_set for the RF centre; trim bw against the analyzer.
#   noise -bw 200e6 ?-amp 0.5? ?-pw 0? ?-pri 10e-6? ?-seed 0?
# -pw 0 (default) is continuous noise; -pw > 0 makes pulsed noise (PW/PRI seconds).
# Every noise command restarts the same pseudo-random sequence; -seed (0..2^32-1,
# written to PHASE0) selects another realisation, e.g. uncorrelated noise per run.
proc noise {args} {
    array set o {-bw 100e6 -amp 0.5 -pw 0 -pri 10e-6 -seed 0}
    if {[llength $args] % 2} { error "noise needs option/value pairs" }
    foreach {key val} $args {
        if {![info exists o($key)]} { error "Unknown noise option: $key" }
        if {![string is double -strict $val] || ![expr {abs($val) < Inf}]} {
            error "$key must be finite and numeric"
        }
        set o($key) $val
    }
    if {![string is wide -strict $o(-seed)] || $o(-seed) < 0 || $o(-seed) > 0xFFFFFFFF} {
        error "-seed must be an integer 0..4294967295"
    }
    if {$o(-bw) <= 0} { error "bandwidth must be > 0" }
    set a [amplitude_word $o(-amp)]
    # ninc = round(2^32 * bw / FS_BB) (Q0.32 new-draw fraction per sample), >= 1
    set ninc [expr {wide(round(pow(2,32) * double($o(-bw)) / $::FS_BB))}]
    if {$ninc < 1}            { set ninc 1 }
    if {$ninc > 0xFFFFFFFF}   { set ninc 0xFFFFFFFF }
    if {$o(-bw) > 0.8 * $::FS_BB} {
        puts "WARNING: bw beyond +-[expr {0.4*$::FS_BB/1e6}] MHz; the DAC interpolation filter will roll it off"
    }
    band_check [expr {-$o(-bw) / 2.0}] [expr {$o(-bw) / 2.0}]
    set cont [expr {$o(-pw) <= 0}]
    if {$cont} {
        set pw_clk 0
        set pri_clk 1
    } else {
        set pw_clk  [expr {wide(round($o(-pw)  * $::FCLK))}]
        set pri_clk [expr {wide(round($o(-pri) * $::FCLK))}]
        if {$pw_clk < 1 || $pri_clk < $pw_clk || $pri_clk > 0xFFFFFFFF} {
            error "need 1 <= PW <= PRI (in clocks: PW=$pw_clk PRI=$pri_clk)"
        }
    }
    rfdc_require_running
    chirp_prepare
    creg_wr FSTART 0
    creg_wr KRATE  [expr {$ninc & 0xFFFFFFFF}]
    creg_wr PW     $pw_clk
    creg_wr PRI    $pri_clk
    creg_wr AMP    $a
    creg_wr PHASE0 [expr {wide($o(-seed))}]
    creg_wr CTRL   [ctrl_word 1 $cont $::IQ_SWAP $::PACK_ILV 1]
    chirp_apply
    set d [expr {double($::FS_BB) / (double($ninc) / pow(2,32) * $::FS_BB)}]
    if {$cont} {
        puts [format "noise: bw %.3f MHz (hold D=%.1f samples), amplitude %.3f, continuous" \
            [expr {$o(-bw)/1e6}] $d $o(-amp)]
    } else {
        puts [format "noise: bw %.3f MHz (hold D=%.1f samples), amplitude %.3f, pulsed PW %.3f us PRI %.3f us" \
            [expr {$o(-bw)/1e6}] $d $o(-amp) [expr {$pw_clk/$::FCLK*1e6}] [expr {$pri_clk/$::FCLK*1e6}]]
    }
}

proc gen_off {} {
    if {![catch {chirp_prepare} err]} {
        puts "output off"
        return
    }
    # STATUS[0] = 0 only while the DAC reset holds (or just released) the
    # generator: enable is 0 and APPLY is refused until STATUS[0] returns.
    # A live handshake that did not acknowledge is NOT confirmation of silence.
    set st [creg_rd STATUS]
    if {$st & 1} { error $err }
    if {!($st & 2)} { creg_wr CTRL [expr {[creg_rd CTRL] & ~1}] }
    puts "output off: DAC domain is in reset, which holds the generator disabled until a new cw/chirp"
}

proc chirp_dump {} {
    foreach n {ID CTRL FSTART KRATE PW PRI AMP PHASE0 STATUS} {
        puts [format "%-7s = 0x%08X" $n [creg_rd $n]]
    }
}

# ---- RF Data Converter (register level, from xrfdc_hw.h) ------------------------------
proc rfdc_tile_ctrl {} { return [expr {$::RFDC_BASE + 0x4000 + $::DAC_TILE * 0x4000}] }
proc rfdc_block_drp {} { return [expr {$::RFDC_BASE + 0x6000 + $::DAC_TILE * 0x4000 + $::DAC_BLOCK * 0x400}] }

proc rfdc_state {} {
    set b [rfdc_tile_ctrl]
    return [list [expr {[rd32 [expr {$b + 0x0C}]] & 0xF}] [rd32 [expr {$b + 0x228}]]]
}
proc rfdc_running {} {
    lassign [rfdc_state] state st
    return [expr {$state == 15 && ($st & 12) == 12}]
}

# Read back the channel settings that FS_BB and the NCO word depend on
# (xrfdc_dp.c / xrfdc.c, Gen3 register layout). Valid once the tile runs.
proc rfdc_config {} {
    set b [rfdc_block_drp]
    return [dict create \
        interp   [expr {[rd32 [expr {$b + 0x040}]] & 0x3F}] \
        iq       [expr {[rd32 [expr {$b + 0x044}]] & 0x1}] \
        datapath [expr {[rd32 [expr {$b + 0x034}]] & 0x3}] \
        words    [expr {[rd32 [expr {$b + 0x008}]] & 0x1F}]]
}
proc rfdc_config_errors {cfg} {
    set e {}
    if {[dict get $cfg interp] != $::INTERP} {
        lappend e "interpolation [dict get $cfg interp]x, expected ${::INTERP}x"
    }
    if {[dict get $cfg iq] != 1} { lappend e "real input, expected I/Q" }
    if {[dict get $cfg datapath] == 2} {
        lappend e "IMR datapath halves the NCO sample rate, expected full-bandwidth DUC"
    }
    return $e
}

proc rfdc_status {} {
    lassign [rfdc_state] state st
    puts [format "DAC tile %d: state %d (15 = running), power-up %d, PLL locked %d" \
        [expr {228 + $::DAC_TILE}] $state [expr {($st >> 2) & 1}] [expr {($st >> 3) & 1}]]
    set cs [creg_rd STATUS]
    puts [format "chirp_gen: DAC MMCM locked %d, handshake ready %d, apply pending %d" \
        [expr {($cs >> 3) & 1}] [expr {$cs & 1}] [expr {($cs >> 1) & 1}]]
    if {$state == 15} {
        set cfg [rfdc_config]
        puts [format "DAC ch%d: interpolation %dx, I/Q input %d, datapath mode %d, fabric words %d (expected %d)" \
            $::DAC_BLOCK [dict get $cfg interp] [dict get $cfg iq] [dict get $cfg datapath] [dict get $cfg words] \
            [expr {2 * $::LANES}]]
        foreach e [rfdc_config_errors $cfg] { puts "ERROR: RFDC $e" }
    } else {
        puts "Check CLK104 LMK DCLKout6 = 245.76 MHz to tile 228; use rfdc_restart after programming the clock."
    }
    if {!($cs & 8)} {
        puts "clk_wiz_dac unlocked: no DAC fabric clock yet (hardware retries its reset every ~2.6 ms)"
    }
    return $state
}

proc rfdc_require_running {} {
    lassign [rfdc_state] state st
    if {$state != 15 || ($st & 12) != 12} {
        error "DAC tile 228 is not ready (state=$state, status=[format 0x%08X $st]); run rfdc_status"
    }
    if {$::RFDC_CONFIG_CHECK} {
        set errs [rfdc_config_errors [rfdc_config]]
        if {[llength $errs]} {
            error "DAC tile 228 ch0 does not match this script: [join $errs {; }]. Rebuild with tcl/build_bd.tcl"
        }
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
    set locked [expr {([creg_rd STATUS] >> 3) & 1}]
    error "No DAC fabric heartbeat (MMCM locked $locked); check CLK104, RFDC PLL and clk_wiz_dac lock"
}

# re-run the tile power-on sequence (use after the clock was programmed late)
proc rfdc_restart {} {
    # With the DAC MMCM locked, silence the generator before restarting; a live
    # clock that cannot acknowledge makes gen_off fail and aborts the restart.
    # With the MMCM unlocked the clock is already gone, and the hardware holds
    # the DAC domain in reset until it is stable again: the old waveform cannot resume.
    if {[creg_rd STATUS] & 8} {
        gen_off
    } else {
        puts "DAC MMCM unlocked: the generator is reset when the fabric clock returns"
    }
    set b [rfdc_tile_ctrl]
    wr32 [expr {$b + 0x08}] 0x010F      ;# start state 1, end state 15
    wr32 [expr {$b + 0x04}] 0x1         ;# restart
    set deadline [expr {[clock milliseconds] + 3000}]
    while {[clock milliseconds] < $deadline} {
        after 20
        if {[rfdc_running]} {
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
    set ::NCO_HZ $f
    puts [format "NCO = %.6f MHz" [expr {$f_hz / 1e6}]]
}

