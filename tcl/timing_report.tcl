# =============================================================================
# timing_report.tcl  --  write the timing reports needed to diagnose WNS/TNS
#
# Runs automatically after route_design (impl_1 hook set by build_bd.tcl) and
# writes into the impl_1 run directory:
#   vivado/zcu208_chirp/zcu208_chirp.runs/impl_1/timing_*.rpt
# or by hand on an opened implemented design:
#   open_run impl_1
#   source tcl/timing_report.tcl        ;# writes into ./out
#
# timing_failing.txt is a short plain-text list of the worst setup paths
# (slack, logic levels, logic/route delay, clocks, start -> end) that can be
# pasted into a message.
# =============================================================================
proc tr_prop {obj name} {
    if {[catch {get_property $name $obj} v] || $v eq ""} { return "-" }
    return $v
}

# A report problem must never fail the implementation run that sources this.
proc tr_write {} {
    set tr_dir [expr {[info exists ::TIMING_REPORT_DIR] ? $::TIMING_REPORT_DIR : \
                      ([string match *impl_* [file tail [pwd]]] ? [pwd] : [file join [pwd] out])}]
    file mkdir $tr_dir

    report_timing_summary -max_paths 10 -report_unconstrained -file [file join $tr_dir timing_summary.rpt]
    report_timing -setup -max_paths 50 -nworst 1 -unique_pins -sort_by slack \
        -file [file join $tr_dir timing_worst_setup.rpt]
    report_timing -hold -max_paths 20 -nworst 1 -unique_pins -sort_by slack \
        -file [file join $tr_dir timing_worst_hold.rpt]
    report_clock_interaction -delay_type min_max -file [file join $tr_dir timing_clock_interaction.rpt]
    catch {report_design_analysis -timing -max_paths 50 -file [file join $tr_dir timing_design_analysis.rpt]}
    catch {report_design_analysis -logic_level_distribution -file [file join $tr_dir timing_logic_levels.rpt]}
    catch {report_utilization -file [file join $tr_dir utilization.rpt]}

    set tr_paths [get_timing_paths -setup -max_paths 40 -nworst 1 -unique_pins -sort_by slack]
    set tr_fd [open [file join $tr_dir timing_failing.txt] w]
    puts $tr_fd [format "%-8s %-4s %-7s %-7s %-34s %s" slack lvls logic route "clocks (start -> end)" "startpoint -> endpoint"]
    foreach p $tr_paths {
        puts $tr_fd [format "%-8s %-4s %-7s %-7s %-34s %s -> %s" \
            [tr_prop $p SLACK] [tr_prop $p LOGIC_LEVELS] \
            [tr_prop $p DATAPATH_LOGIC_DELAY] [tr_prop $p DATAPATH_NET_DELAY] \
            "[tr_prop $p STARTPOINT_CLOCK] -> [tr_prop $p ENDPOINT_CLOCK]" \
            [tr_prop $p STARTPOINT_PIN] [tr_prop $p ENDPOINT_PIN]]
    }
    close $tr_fd

    set tr_worst [lindex $tr_paths 0]
    puts "INFO: timing reports written to $tr_dir"
    if {$tr_worst ne ""} {
        puts "INFO: worst setup slack [tr_prop $tr_worst SLACK] ns: [tr_prop $tr_worst STARTPOINT_PIN] -> [tr_prop $tr_worst ENDPOINT_PIN]"
    }
}

if {[catch tr_write tr_err]} {
    puts "WARNING: timing_report.tcl did not finish: $tr_err"
}
