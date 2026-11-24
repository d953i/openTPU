# Clock-domain crossings of the host-port mux (rtl/boards/sqrl-fk/otpu_axi3_hmux.sv, the SQRL FK top at 16 channels:
# the host's window k sharing HBM port 4k + 1), all of them in its otpu_afifo instances: u_haw, u_har, u_hw (the host's
# AW, AR and W: hclk, XDMA's clock -> clk, uclk) and u_hb, u_hr (B and R: clk -> hclk). Scoped to the module, read in
# implementation on the synthesized netlist (create_project.tcl: SCOPED_TO_REF otpu_axi3_hmux, PROCESSING_ORDER LATE),
# as boards/bcu1525/constraints/otpu_hbm_ch.tcl does for the bridges' FIFOs:
#   - the gray-coded pointers: one source period, and set_bus_skew of the smaller period (one count's bits together);
#   - a FIFO's distributed RAM, written in one clock and read asynchronously in the other: one destination period (an
#     entry is read no sooner than two destination cycles after its write pointer crossed).
# Without them the two clocks (250 and 450 MHz, one MMCM) are timed as related: FK35 w1 placed, xdma_aclk -3.3 ns.
# The top must not make them asynchronous with set_clock_groups / set_false_path (those override set_max_delay).
set m_w [get_clocks -quiet -of_objects [get_pins -quiet -filter {REF_PIN_NAME == C} -of_objects [get_cells -quiet {u_haw/wgray_reg[0]}]]]
set m_c [get_clocks -quiet -of_objects [get_pins -quiet -filter {REF_PIN_NAME == C} -of_objects [get_cells -quiet {u_haw/rgray_reg[0]}]]]
if {[llength $m_w] != 1 || [llength $m_c] != 1} {
  puts "CRITICAL WARNING: \[otpu_axi3_hmux.tcl\] [current_instance .]: clocks hclk '$m_w', clk '$m_c' (one each expected): the crossings unconstrained"
  namespace eval ::otpu {}
  lappend ::otpu::fail "otpu_axi3_hmux.tcl: [current_instance .]: clocks not found"
} else {
  set t_h [get_property PERIOD $m_w]
  set t_c [get_property PERIOD $m_c]
  set k [expr {min($t_h, $t_c)}]
  # {FIFO, write clock, read clock, write period, read period}
  foreach {f c_w c_r t_w t_r} [list u_haw $m_w $m_c $t_h $t_c u_har $m_w $m_c $t_h $t_c u_hw $m_w $m_c $t_h $t_c \
                                    u_hb $m_c $m_w $t_c $t_h u_hr $m_c $m_w $t_c $t_h] {
    set_max_delay -datapath_only -from $c_w -to [get_cells "$f/wgray_r1_reg\[*\]"] $t_w
    set_bus_skew -from [get_cells "$f/wgray_reg\[*\] $f/wbin_reg\[*\]"] -to [get_cells "$f/wgray_r1_reg\[*\]"] $k
    set_max_delay -datapath_only -from $c_r -to [get_cells "$f/rgray_w1_reg\[*\]"] $t_r
    set_bus_skew -from [get_cells "$f/rgray_reg\[*\] $f/rbin_reg\[*\]"] -to [get_cells "$f/rgray_w1_reg\[*\]"] $k
    set_max_delay -datapath_only -from $c_w -through [get_pins -quiet -filter {DIRECTION == OUT && IS_LEAF} -of_objects \
      [get_cells -quiet -hierarchical -filter "NAME =~ *$f/*mem_reg*"]] -to $c_r $t_r
  }
  namespace eval ::otpu {}
  incr ::otpu::ok(otpu_axi3_hmux)
}
