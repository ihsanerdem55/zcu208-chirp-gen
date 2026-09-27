# Host-side command tests; AXI register reads/writes are mocked, not RFDC hardware.
source [file join [file dirname [info script]] .. tcl chirp_ctrl.tcl]
rename creg_rd real_creg_rd
rename creg_wr real_creg_wr
set writes {}
set status 1
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
proc rd32 {address} {
    if {$address == 0x4004400C} { return 15 }
    if {$address == 0x40044228} { return 12 }
    return 0
}
proc wr32 {address value} { lappend ::writes [list $address $value] }
proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error "FAIL: $message" }
}
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
set status 3
# A pending request times out without another APPLY toggling/cancelling it.
rejects_without_writes {chirp_apply}
set status 1
set writes {}
nco_set 1.5e9
set word [expr {wide(round(1.5e9 / $::FS_DAC * pow(2, 48))) & 0xFFFFFFFFFFFF}]
assert {[lindex [lindex $writes 0] 0] == 0x4004609C} "NCO writes tile 228"
assert {[lindex [lindex $writes 0] 1] == ($word & 65535)} "NCO low word"
assert {[lindex [lindex $writes end] 0] == 0x40046020} "NCO update register"
puts "PASS: control defaults, range checks, pending APPLY, reconfiguration and NCO addresses"
