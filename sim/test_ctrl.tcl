# Host-side command tests; AXI register reads/writes are mocked, not RFDC hardware.
source [file join [file dirname [info script]] .. tcl chirp_ctrl.tcl]
set ::WAIT_MS 50
proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error "FAIL: $message" }
}

# Real JTAG-to-AXI wrappers must surface failures (never run_hw_axi -quiet).
set ::AXI hw_axi_1
set axi_fail 0
set axi_data 43485250
proc create_hw_axi_txn {args} { return txn }
proc run_hw_axi {args} {
    # Like Vivado: -quiet returns TCL_OK even when the transaction failed.
    if {$::axi_fail && "-quiet" ni $args} { error "AXI TRANSACTION TIMED OUT" }
}
proc get_property {name object} { return $::axi_data }
assert {[rd32 0x40000000] == 0x43485250} "read data"
set axi_fail 1
assert {[catch {wr32 0x40000020 1} err] && [string match *0x40000020* $err]} "write failure hidden"
assert {[catch {rd32 0x40000024}]} "read failure hidden"
set axi_fail 0
set axi_data ""
assert {[catch {rd32 0x40000024}]} "empty read data accepted"
puts "PASS: JTAG-to-AXI failures propagate"

rename creg_rd real_creg_rd
rename creg_wr real_creg_wr
set writes {}
set status 9                                ;# handshake ready, DAC MMCM locked
set control 8
proc creg_rd {name} {
    if {$name eq "STATUS"} { return $::status }
    if {$name eq "CTRL"} { return $::control }
    error "Unexpected read $name"
}
proc creg_wr {name value} {
    lappend ::writes [list $name $value]
    if {$name eq "CTRL"} { set ::control $value }
}
rename rd32 real_rd32
rename wr32 real_wr32
set tile_state 15
# DAC ch0 read-back: 8x interpolation, I/Q input, full-bandwidth DUC, 8 fabric words
array set rfdc_cfg {0x40046040 8 0x40046044 1 0x40046034 0 0x40046008 8}
proc rd32 {address} {
    if {$address == 0x4004400C} { return $::tile_state }
    if {$address == 0x40044228} { return 12 }
    set key [format 0x%08x $address]
    if {[info exists ::rfdc_cfg($key)]} { return $::rfdc_cfg($key) }
    return 0
}
proc wr32 {address value} { lappend ::writes [list $address $value] }
proc rejects_without_writes {script} {
    set ::writes {}
    assert {[catch {uplevel 1 $script}]} "expected error: $script"
    assert {![llength $::writes]} "invalid command wrote hardware: $script"
}
assert {$::DAC_TILE == 0 && $::PACK_ILV == 1} "tile/packing defaults"
assert {[rfdc_tile_ctrl] == 0x40044000} "tile 228 register base"
assert {[rfdc_block_drp] == 0x40046000} "DAC channel 0 register base"
cw 10e6 0.5
assert {$control == 11} "CW must send interleaved IQ"
assert {[lindex $writes 0] eq {CTRL 8}} "old stream must be disabled before reconfiguration"
set writes {}
chirp -bw 400e6 -pw 2e-6 -pri 10e-6 -phase_deg 270
assert {$control == 9} "chirp must send interleaved IQ"
assert {[lsearch -exact $writes {PHASE0 3221225472}] >= 0} "unsigned phase word"
foreach command {{cw 10e6 -0.1} {cw 400e6} {chirp -amp 1.1} {chirp -unknown 3}
                 {chirp -pw 0} {chirp -pw 10e-6 -pri 1e-6} {chirp -pri 100}
                 {chirp -offset 300e6 -bw 200e6} {chirp -pw Inf} {nco_set Inf}} {
    rejects_without_writes $command
}
set status 0
rejects_without_writes {cw 10e6}
set status 11
# A pending request times out without another APPLY toggling/cancelling it.
rejects_without_writes {chirp_apply}
set status 9
set writes {}
nco_set 1.5e9
set word [expr {wide(round(1.5e9 / $::FS_DAC * pow(2, 48))) & 0xFFFFFFFFFFFF}]
assert {[lindex [lindex $writes 0] 0] == 0x4004609C} "NCO writes tile 228"
assert {[lindex [lindex $writes 0] 1] == ($word & 65535)} "NCO low word"
assert {[lindex [lindex $writes end] 0] == 0x40046020} "NCO update register"
puts "PASS: control defaults, range checks, pending APPLY, reconfiguration and NCO addresses"

# The frequency math is only valid for the configuration it was written for.
foreach {key bad} {0x40046040 4 0x40046044 0 0x40046034 2} {
    set good $rfdc_cfg($key)
    set rfdc_cfg($key) $bad
    rejects_without_writes {nco_set 500e6}
    rejects_without_writes {cw 10e6}
    rejects_without_writes {chirp}
    set rfdc_cfg($key) $good
}
set ::RFDC_CONFIG_CHECK 0
set rfdc_cfg(0x40046040) 4
set writes {}
nco_set 500e6
assert {[llength $writes] > 0} "config check override"
set rfdc_cfg(0x40046040) 8
set ::RFDC_CONFIG_CHECK 1
puts "PASS: RFDC interpolation / I/Q / datapath read-back mismatches refuse to drive the DAC"

# Disabling must remain available with an unhealthy tile but live DAC fabric.
set tile_state 6
set control 11
set writes {}
gen_off
assert {$control == 10} "gen_off failed to disable during tile recovery"
assert {[lsearch -exact $writes {APPLY 1}] >= 0} "disable was not applied"
rejects_without_writes {cw 10e6}
rejects_without_writes {chirp}
set tile_state 15
puts "PASS: gen_off with unhealthy RFDC; enabling still requires a running tile"

# DAC domain held in reset: generator is already forced off; clear the staged enable.
set status 0
set control 11
set writes {}
gen_off
assert {$writes eq {{CTRL 10}}} "reset-state gen_off must only clear the staged enable"
set status 2                                ;# odd toggle while reset: CTRL write would SLVERR
set writes {}
gen_off
assert {![llength $writes]} "reset-state gen_off wrote while a request was pending"
set status 11                               ;# live handshake, never acknowledged
assert {[catch gen_off]} "unacknowledged gen_off reported success"
puts "PASS: gen_off in DAC reset succeeds; an unacknowledged live handshake still fails"

rename clock_check real_clock_check
proc clock_check {} { return 1 }
set status 9
set control 11
set writes {}
rfdc_restart
assert {[lindex $writes 0] eq {CTRL 10}} "restart must disable first"
assert {[lindex $writes end] eq {APPLY 1}} "restart must finish with disabled APPLY"
assert {$control == 10} "restart re-enabled waveform"
# MMCM unlocked (clock already lost): hardware resets the DAC domain on relock.
set status 1
set control 11
set writes {}
rfdc_restart
assert {[lindex $writes 0 0] == 0x40044008 && [lindex $writes 0 1] == 0x010F} \
    "unlocked restart must go straight to the tile"
assert {[lindex $writes end] eq {APPLY 1}} "restart must finish with disabled APPLY"
assert {$control == 10} "restart re-enabled waveform"
puts "PASS: RFDC restart silences the generator (locked and unlocked DAC MMCM)"
