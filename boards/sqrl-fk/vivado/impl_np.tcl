# The SQRL FK build's placement and routing (build.tcl sources it with OUT set, after impl_1 ran to opt_design):
# Vivado's non-project flow on impl_1's optimized checkpoint, in this session. 2019.2's impl_1 run timed this
# design wrongly from its placer on (place_design's and phys_opt_design's summaries a constant WNS +1.954 on both
# boards, "skipping all physical synthesis optimizations", while report_timing_summary on the same checkpoints
# showed the clocks failing by up to 1.7 ns), so it never optimized the critical paths; opened here, the design's
# timing is the real one and placement and physical optimization work on it (the port's FK35: routed uclk -0.44 ns
# against impl_1's -0.75). Also forced replication of the uclk fan-outs the routed designs showed long: each bridge
# core half's hold (a_hold, into its read FIFOs' resets) and reset (a_rs2, into its FIFOs' enables: FK35 r6
# -0.075 ns), its read FIFOs' write enables (u_rd wrdy, ~300 LUTRAMs each: FK35 r5 -0.344 ns, r6 -0.070 ns) and the
# DMA SmartConnect's master-node resets (m_sc_areset_r). Directives as create_project.tcl's for impl_1 (OTPU_FAST: Vivado's defaults). Writes
# OUT/otpu.runs/impl_1/otpu_fpga_top_sqrl_fk_{placed,physopt,routed,postroute}.dcp and prints each stage's WNS / WHS.
set np_fast [expr {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"}]
set np_dir $out/otpu.runs/impl_1
set np_opt $np_dir/otpu_fpga_top_sqrl_fk_opt.dcp
if {![file exists $np_opt]} { error "impl_np.tcl: no $np_opt (impl_1 to opt_design first)" }
proc np_ts {tag} {
  set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
  set h [get_timing_paths -max_paths 1 -nworst 1 -hold]
  set m "impl_np.tcl: $tag: WNS [get_property SLACK $p] ns, WHS [get_property SLACK $h] ns;"
  foreach c [get_clocks -quiet {uclk_* core_clk_* core_clk2x_* xdma_aclk}] {
    set q [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -to $c]
    if {[llength $q]} { append m " [regsub {_otpu_bd_clk_wiz_0_0$} $c {}] [get_property SLACK $q]" }
  }
  puts $m
}
open_checkpoint $np_opt
np_ts opt
# OTPU_PLACE_DIRECTIVE: another placer directive (placement varies run to run: the port's FK35 r6 and r7, one
# netlist apart, placed uclk at -0.265 and -0.635 ns with AltSpreadLogic_high)
set np_pd [expr {[info exists ::env(OTPU_PLACE_DIRECTIVE)] && $::env(OTPU_PLACE_DIRECTIVE) ne ""
                 ? $::env(OTPU_PLACE_DIRECTIVE) : "AltSpreadLogic_high"}]
if {$np_fast} { place_design } else { puts "impl_np.tcl: place_design -directive $np_pd"; place_design -directive $np_pd }
np_ts placed
write_checkpoint -force $np_dir/otpu_fpga_top_sqrl_fk_placed.dcp
if {!$np_fast} { phys_opt_design -directive AggressiveExplore }
set np_fo {}
foreach pat {*u_cs/a_hold_reg* *u_cs/a_rs2_reg* *u_rd/g_rwr.wrdy_reg* *m_sc_areset_r_reg*} {
  foreach c [get_cells -quiet -hier -filter "NAME =~ $pat && IS_SEQUENTIAL"] {
    set n [get_nets -quiet -of_objects [get_pins -quiet -of_objects $c -filter {DIRECTION == OUT && REF_PIN_NAME == Q}]]
    if {[llength $n] && [get_property FLAT_PIN_COUNT $n] > 16} { lappend np_fo $n }
  }
}
puts "impl_np.tcl: forced replication on [llength $np_fo] nets"
if {[llength $np_fo]} { phys_opt_design -force_replication_on_nets $np_fo }
if {!$np_fast} { phys_opt_design -directive AggressiveExplore }
np_ts physopt
write_checkpoint -force $np_dir/otpu_fpga_top_sqrl_fk_physopt.dcp
if {$np_fast} { route_design } else { route_design -directive AggressiveExplore }
np_ts routed
write_checkpoint -force $np_dir/otpu_fpga_top_sqrl_fk_routed.dcp
if {!$np_fast} {
  phys_opt_design -directive AggressiveExplore
  np_ts postroute
  write_checkpoint -force $np_dir/otpu_fpga_top_sqrl_fk_postroute.dcp
}
