# opt_design's pre-hook in the SQRL FK build (create_project.tcl), as the BCU1525 WG build's bcu1525_wg_check.tcl:
# the late constraint files ran at link_design in this same Vivado, and a failed command or a missed cell there is
# only a CRITICAL WARNING, so the run stops here on what they recorded: each file's misses (::otpu::fail) and what
# each finished, against the design's cells. otpu_hbm_ch.tcl a bridge's core half (otpu_hbm_cs) each,
# otpu_mxu_stage.tcl an MXU lane's staging each (::otpu_mxu_stage_ok), sqrl_fk_top.tcl and sqrl_fk_floorplan.tcl
# once, otpu_clk2x.tcl every pumped MXU column (otpu_mxpc, MXU_PUMP), otpu_axi3_hmux.tcl each host-port mux (16 channels).
namespace eval ::otpu {}
set fk_fail [expr {[info exists ::otpu::fail] ? $::otpu::fail : {}}]
proc fk_count {ref} {
  return [llength [get_cells -quiet -hierarchical -filter "ORIG_REF_NAME == $ref || REF_NAME == $ref"]]
}
foreach {f n} [list otpu_hbm_ch [fk_count otpu_hbm_cs] otpu_axi3_hmux [fk_count otpu_axi3_hmux] sqrl_fk_top 1 sqrl_fk_floorplan 1] {
  set k [expr {[info exists ::otpu::ok($f)] ? $::otpu::ok($f) : 0}]
  if {$k != $n} { lappend fk_fail "$f.tcl finished $k of the build's $n" }
  puts "sqrl_fk_check.tcl: $f.tcl finished $k of $n"
}
set n [fk_count otpu_mxu_stage]
set k [expr {[info exists ::otpu_mxu_stage_ok] ? $::otpu_mxu_stage_ok : 0}]
if {$k != $n} { lappend fk_fail "otpu_mxu_stage.tcl constrained $k of the build's $n" }
puts "sqrl_fk_check.tcl: otpu_mxu_stage.tcl constrained $k of $n"
set n [fk_count otpu_mxpc]
if {$n} {
  set k [expr {[info exists ::otpu::ok(otpu_clk2x_mxu)] ? $::otpu::ok(otpu_clk2x_mxu) : 0}]
  if {$k != $n} { lappend fk_fail "otpu_clk2x.tcl constrained $k of the build's $n pumped MXU columns" }
  puts "sqrl_fk_check.tcl: otpu_clk2x.tcl constrained $k of $n pumped MXU columns"
}
# every port on its pin
set nopin [get_ports -quiet -filter {PACKAGE_PIN == ""}]
if {[llength $nopin]} { lappend fk_fail "[llength $nopin] ports without a pin: [lrange $nopin 0 7]" }
puts "sqrl_fk_check.tcl: [llength [get_ports]] ports, [llength $nopin] without a pin"
if {[llength $fk_fail]} {
  error "sqrl_fk_check.tcl: [llength $fk_fail] constraint checks failed: [join [lrange $fk_fail 0 7] {; }]"
}
report_exceptions -file [file normalize ../../reports/fk_exceptions.rpt]   ;# (the run directory: OUT/otpu.runs/impl_1)
puts "sqrl_fk_check.tcl: every constraint file finished"
