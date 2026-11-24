# Build the SQRL FK bitstream from create_project.tcl's project: synthesis, implementation, reports, the bitstream
# and the flash image (the card's two MT25QU256, SPI x8: otpu_primary.mcs and otpu_secondary.mcs; docs/sqrl-fk.md).
#   vivado -mode batch -source build.tcl -tclargs [OUT_DIR] [JOBS] [synth|impl|full] [IMPL_STRATEGY]
# synth: synthesis and its reports only; impl: the implementation of a finished synthesis. The fork's FK35
# build.tcl, after the BCU1525's; the block-RAM collision check is the same.
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$root/build/vivado_sqrl-fk"}]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
set impl_only [expr {[lindex $argv 2] eq "impl"}]
set synth_only [expr {[lindex $argv 2] eq "synth"}]
set strategy [lindex $argv 3]

open_project $out/otpu.xpr
file mkdir $out/reports
set fast [expr {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"}]

if {!$impl_only} {
  generate_target all [get_files otpu_bd.bd]
  export_ip_user_files -of_objects [get_files otpu_bd.bd] -no_script -sync -force -quiet
  create_ip_run [get_files otpu_bd.bd]
  # a block-design IP run that failed (2019.2's out-of-context runs sometimes hang on exit after
  # __synthesis_is_complete__; one killed then counts as failed) blocks synth_1's launch until reset
  foreach r [get_runs -filter {IS_SYNTHESIS && NAME != synth_1}] {
    if {[string match -nocase "*error*" [get_property STATUS $r]]} {
      puts "reset of the failed run $r ([get_property STATUS $r])"
      reset_run $r
    }
  }
  reset_run synth_1
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synthesis failed" }
  set fh [open $out/otpu.runs/synth_1/runme.log]; set slog [read $fh]; close $fh
  set coll [regexp -all -inline {Synth 8-6430\] The Block RAM "[^"]*"} $slog]
  if {[llength $coll]} {
    error "synthesis made asynchronous-read memories block RAMs with a read-address register: [join $coll {; }]"
  }
  open_run synth_1
  report_utilization -hierarchical -hierarchical_depth 4 -file $out/reports/synth_util_hier.rpt
  report_utilization -slr -file $out/reports/synth_util_slr.rpt
  report_timing_summary -max_paths 20 -file $out/reports/synth_timing.rpt
  close_design
  if {$synth_only} { puts "synthesis done: $out/reports/synth_*.rpt"; return }
} else {
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "impl: no finished synthesis to reuse" }
  set_property NEEDS_REFRESH false [get_runs synth_1]
}

if {$strategy ne ""} { set_property strategy $strategy [get_runs impl_1] }
if {!$fast} { set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1] }
# OTPU_RQS: a QoR suggestions file (write_qor_suggestions of an earlier routed run) read before opt_design, its
# automatic implementation suggestions then applied by opt / place / phys_opt (synthesis ones need a new
# synthesis). OTPU_PRE_OPT: a Tcl file sourced there too (the suggestions that are not automatic, done by hand)
set pre [list "source {$here/sqrl_fk_check.tcl}"]   ;# the constraint files' checks first (create_project.tcl)
if {[info exists ::env(OTPU_RQS)] && $::env(OTPU_RQS) ne ""} {
  lappend pre "read_qor_suggestions {[file normalize $::env(OTPU_RQS)]}"
  puts "QoR suggestions: $::env(OTPU_RQS)"
}
if {[info exists ::env(OTPU_PRE_OPT)] && $::env(OTPU_PRE_OPT) ne ""} {
  lappend pre "source {[file normalize $::env(OTPU_PRE_OPT)]}"
  puts "before opt_design: $::env(OTPU_PRE_OPT)"
}
if {[llength $pre] > 1} {
  set hook $out/rqs_pre_opt.tcl
  set fh [open $hook w]; puts $fh [join $pre "\n"]; close $fh
  set_property STEPS.OPT_DESIGN.TCL.PRE $hook [get_runs impl_1]
} else {
  set_property STEPS.OPT_DESIGN.TCL.PRE $here/sqrl_fk_check.tcl [get_runs impl_1]
}
# impl_1 to opt_design only (its link reads the late constraint files and its opt_design pre-hook checks them);
# placement and routing are impl_np.tcl's, in this session (impl_1's own placer and phys_opt timed the design wrongly)
reset_run impl_1
launch_runs impl_1 -to_step opt_design -jobs $jobs
wait_on_run impl_1
if {![file exists $out/otpu.runs/impl_1/otpu_fpga_top_sqrl_fk_opt.dcp]} { error "implementation failed (opt_design)" }
close_project
source $here/impl_np.tcl

report_timing_summary -max_paths 50 -report_unconstrained -warn_on_violation \
  -file $out/reports/timing_summary.rpt
report_timing -max_paths 30 -sort_by group -nworst 1 -file $out/reports/timing_worst.rpt
report_design_analysis -congestion -file $out/reports/congestion.rpt
report_clock_interaction -file $out/reports/clock_interaction.rpt
report_cdc -details -file $out/reports/cdc.rpt
report_utilization -file $out/reports/util.rpt
report_utilization -slr -file $out/reports/util_slr.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $out/reports/util_hier.rpt
report_drc -file $out/reports/drc.rpt
report_methodology -file $out/reports/methodology.rpt
report_power -hierarchical_depth 12 -file $out/reports/power.rpt
report_io -file $out/reports/io.rpt

set fh [open $out/reports/SUMMARY.txt w]
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold] 0]]
puts $fh "WNS $wns ns   WHS $whs ns"
foreach clk [get_clocks] {
  set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup -to $clk] 0]
  if {$p ne ""} {
    set period [get_property PERIOD $clk]
    set slack [get_property SLACK $p]
    set fmax [expr {$slack eq "" ? "n/a" : [format %.1f [expr {1000.0 / ($period - $slack)}]]}]
    puts $fh [format "%-40s period %7.3f ns  slack %8s ns  fmax %s MHz" $clk $period $slack $fmax]
  }
}
close $fh
puts [exec cat $out/reports/SUMMARY.txt]

write_bitstream -force $out/otpu.bit
if {[llength [get_debug_cores -quiet]]} { write_debug_probes -force $out/otpu.ltx }
# the configuration flash: two Micron MT25QU256, 256 Mb (32 MB) each, SPI x8 (64 MB in all): write_cfgmem splits
# the image into otpu_primary.mcs and otpu_secondary.mcs (part mt25qu256-spi-x1_x2_x4_x8)
write_cfgmem -force -format mcs -size 64 -interface SPIx8 -loadbit "up 0x0 $out/otpu.bit" $out/otpu.mcs
puts "bitstream: $out/otpu.bit"
if {$wns < 0} { puts "WARNING: timing not met (WNS $wns ns) -- see reports/timing_summary.rpt" }
