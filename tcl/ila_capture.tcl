# Source after chirp_ctrl.tcl, hw_init, and starting a CW/chirp.
# ila_capture out/chirp.csv        ;# next pulse rising edge
# ila_capture out/cw.csv immediate
proc ila_capture {filename {mode pulse}} {
    if {$mode ni {pulse immediate}} { error "mode must be pulse or immediate" }
    set ilas [get_hw_ilas -of_objects [current_hw_device] -filter {CELL_NAME =~ *ila_dac*}]
    if {[llength $ilas] != 1} { error "Expected one ila_dac. Program matching .bit and .ltx files, then refresh device." }
    set ila [lindex $ilas 0]
    # Port numbers survive synthesis/net renaming, unlike probe signal names.
    reset_hw_ila -reset_compare_values true $ila
    set_property CONTROL.TRIGGER_POSITION 256 $ila
    if {$mode eq "pulse"} {
        set trig [get_hw_probes -of_objects $ila -filter {PORT_INDEX == 1}]
        if {[llength $trig] != 1} { error "Cannot find pulse probe (port 1)" }
        set_property TRIGGER_COMPARE_VALUE eq1'bR $trig
        run_hw_ila $ila
    } else {
        run_hw_ila -trigger_now $ila
    }
    # Timeout is in MINUTES (UG835): 0.2 = 12 seconds.
    wait_on_hw_ila -timeout 0.2 $ila
    set data [upload_hw_ila_data $ila]
    display_hw_ila_data $data
    file mkdir [file dirname $filename]
    write_hw_ila_data -force -csv_file $filename $data
    puts "Saved $filename. Plot with: python scripts/plot_ila.py $filename"
}
