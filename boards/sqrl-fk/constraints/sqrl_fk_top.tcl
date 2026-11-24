# Clock-domain crossings of the SQRL FK top (otpu_fpga_top_sqrl_fk) and of otpu_sqrl_fk_sys outside the bridges'
# core halves (boards/bcu1525/constraints/otpu_hbm_ch.tcl, scoped to otpu_hbm_cs) and the MXU lanes' posted-beat
# staging (otpu_mxu_stage.tcl, scoped to otpu_mxu_stage). Unmanaged Tcl, read in implementation only and late
# (create_project.tcl), on the synthesized netlist; not scoped. As the BCU1525 WG top's (bcu1525_wg_top.tcl): no
# clock pair is declared asynchronous (set_clock_groups or a false path between clocks would override the bridges'
# set_max_delay -datapath_only), each crossing here gets its own constraint, and a miss goes to ::otpu::fail:
# sqrl_fk_check.tcl (opt_design's pre-hook) stops the run on it (in a read_xdc file an error or a return is only a
# warning).
#
# The clocks (bd.tcl), all from one MMCM on XDMA's axi_aclk: core_clk (the accelerator) and core_clk2x (its pumped
# TMEM: otpu_clk2x.tcl), uclk (the bridges' HBM AXI ports and AXI halves), clk100 (the HBM's reference and APB
# clock) and xdma_aclk (XDMA's: its DMA SmartConnect, the host's DMA windows and their HBM ports, 4j + 1).
namespace eval ::otpu {}
proc ::otpu::fk_fail {msg} {
  puts "CRITICAL WARNING: \[sqrl_fk_top.tcl\] $msg"
  lappend ::otpu::fail "sqrl_fk_top.tcl: $msg"
}
proc ::otpu::fk_clk {name pin} {
  set c [get_clocks -quiet -of_objects [get_pins -quiet $pin]]
  if {[llength $c] != 1} { ::otpu::fk_fail "$name: clocks '$c' at $pin, expected one" }
  return $c
}
proc ::otpu::fk_cells {what pats} {
  set all {}
  foreach p $pats {
    set c [get_cells -quiet $p]
    if {![llength $c]} { ::otpu::fk_fail "$what: no cell $p" }
    set all [concat $all $c]
  }
  return [get_cells -quiet $all]
}
set c_core [::otpu::fk_clk core_clk {core_rst_reg/C}]
set c_u    [::otpu::fk_clk uclk {u_rst_reg/C}]
set c_x    [::otpu::fk_clk xdma_aclk {xrst_reg/C}]
set t_core [get_property -quiet -min PERIOD $c_core]
set t_u    [get_property -quiet -min PERIOD $c_u]
set t_x    [get_property -quiet -min PERIOD $c_x]
puts "sqrl_fk_top.tcl: core $c_core $t_core ns, uclk $c_u $t_u ns, xdma $c_x $t_x ns"

# ---------------------------------------------------------------- levels into two-flop synchronizers
# both stacks' calibration (apb_complete, clk100) into uclk (hcal_u1: the bridges' AXI reset) and into xdma_aclk
# (hcal_x1: the host's DMA windows' register slices); it and the HBM's catastrophic-temperature trips (no clock)
# into otpu_board's calibration synchronizer (cal_s1, core_clk); XDMA's reset (xdma_aclk) into the control masters'
# reset (lrs1, core_clk): levels, false paths into the first stage
set_false_path -to [::otpu::fk_cells hbm_calib {hcal_u1_reg[*] hcal_x1_reg[*]}]
set_false_path -to [::otpu::fk_cells calib {u_sys/u_board/cal_s1_reg[*]}]
set_false_path -to [::otpu::fk_cells ctl_mrst {lrs1_reg}]
# the block design's reset blocks: their asynchronous inputs (the MMCM's lock, axi_aresetn)
set p [get_pins -quiet -hier -filter {NAME =~ u_bd/*rst_*/ext_reset_in || NAME =~ u_bd/*rst_*/dcm_locked}]
if {[llength $p]} {
  set_false_path -through $p
  puts "sqrl_fk_top.tcl: the reset blocks' inputs, [llength $p] pins"
} else {
  ::otpu::fk_fail "no proc_sys_reset inputs (u_bd/*rst_*/ext_reset_in, dcm_locked)"
}

# ---------------------------------------------------------------- posted-beat counts into core_clk
# Each bridge's p_cntg (otpu_hbm_cs p_g, a gray count from a register, uclk) into the slice's adapter's ASYNC_REG
# synchronizer (otpu_native_dram g_pc.pg1[j], core_clk), or from the last of its otpu_xstg p_clk stages
# (NAT_XSTG_P) when there are some: one uclk period, a bus skew a channel (bcu1525_wg_top.tcl's). Brackets as ? in
# the names: get_cells takes [n] for a bus index.
set n_ch [llength [get_cells -quiet {u_sys/g_ch[*].u_br/u_cs}]]
if {$n_ch != 8 && $n_ch != 16} { ::otpu::fk_fail "$n_ch bridge core halves (8, or 16: sqrl-fk35w)" }
set n_pc 0
if {[llength $c_core] == 1 && [llength $c_u] == 1} {
  for {set j 0} {$j < $n_ch} {incr j} {
    set d [get_cells -quiet "u_sys/u_board/u_mem/g_pc.pg1_reg?$j?\[*\]"]
    set g [get_cells -quiet "u_sys/g_ch?$j?.u_br/u_cs/p_g_reg\[*\]"]
    for {set i 0} {[llength [set gx [get_cells -quiet "u_sys/u_board/u_xs/g_pc?$j?.u_p/g_pipe.g_s?$i?.r_reg\[*\]"]]]} {incr i} {
      set g $gx
    }
    if {![llength $d] || [llength $g] != [llength $d]} {
      ::otpu::fk_fail "channel $j: [llength $g] p_g registers, [llength $d] synchronizer ones: its posted-beat count unconstrained"
      continue
    }
    set_max_delay -datapath_only -from $g -to $d $t_u
    set_bus_skew -from $g -to $d [expr {min($t_u, $t_core)}]
    incr n_pc
  }
}
puts "sqrl_fk_top.tcl: posted-beat counts of $n_pc of $n_ch channels constrained"

# ---------------------------------------------------------------- the clock trees
# core_clk and core_clk2x in one CLOCK_DELAY_GROUP: the placer and the router balance their insertion delays
# (UG949), for the pumped TMEM's 2x -> 1x paths (the port's first FK35 placement: 1.17 ns of skew between the two,
# -1.07 ns from a TMEM UltraRAM on core_clk2x into the SE engine on core_clk). On the FK35, uclk's root at the top
# of SLR0 (USER_CLOCK_ROOT X4Y3), beside the SLR crossing its bridges' pipelines make at 450 MHz (there: 0.65 ns
# of skew on the Laguna hop, -1.31 ns); its loads are the bridges' halves either side and the HBM ports below.
# The group goes on the nets the global buffers drive, inside the block design's clock wizard (as uclk's root
# below): on the top's segments (core_clk, core_clk2x) Vivado took it and ignored it (FK35 r12 placed at 225 MHz:
# the driver nets without it, core_clk's root at X3Y4 and core_clk2x's at X0Y6, 1.19 ns of skew on every TMEM
# UltraRAM -> unit path, -1.43 ns at core_clk)
set cn {}
foreach n {core_clk core_clk2x} {
  set d [get_pins -quiet -leaf -of_objects [get_nets -quiet $n] -filter {DIRECTION == OUT}]
  if {[llength $d] == 1 && [string match BUFG* [get_property -quiet REF_NAME [get_cells -of_objects $d]]]} {
    lappend cn [get_nets -quiet -of_objects $d]
  }
}
if {[llength $cn] != 2} {
  ::otpu::fk_fail "CLOCK_DELAY_GROUP: core_clk's and core_clk2x's global-buffer nets '$cn', expected two"
} else {
  set_property CLOCK_DELAY_GROUP otpu_core $cn
  puts "sqrl_fk_top.tcl: CLOCK_DELAY_GROUP otpu_core on [join $cn]"
}
if {[llength [get_slrs -quiet]] == 2} {
  # (on the segment its global buffer drives, inside the block design's clock wizard: Vivado 12-4418 refuses
  # the top's uclk; a refused set_property is only an error message in a constraint file, so it is caught)
  set ub [get_pins -quiet -leaf -of_objects [get_nets -quiet uclk] -filter {DIRECTION == OUT}]
  set un [get_nets -quiet -of_objects $ub]
  if {[llength $ub] != 1 || ![string match BUFG* [get_property -quiet REF_NAME [get_cells -of_objects $ub]]]
      || [llength $un] != 1} {
    ::otpu::fk_fail "USER_CLOCK_ROOT: uclk's driver '$ub' (a BUFG expected), net '$un'"
  } elseif {[catch {set_property USER_CLOCK_ROOT X4Y3 $un} e]} {
    ::otpu::fk_fail "USER_CLOCK_ROOT X4Y3 on $un: $e"
  } else {
    puts "sqrl_fk_top.tcl: USER_CLOCK_ROOT X4Y3 on uclk ($un, from $ub)"
  }
}

# ---------------------------------------------------------------- the debug hub
# The HBM IP's debug core makes Vivado insert a debug hub, whose clock must be free running (Chipscope 16-213
# otherwise): clk100, the HBM's APB clock (the fork's FK35 builds)
set n [get_nets -quiet clk100]
if {[llength [get_debug_cores -quiet dbg_hub]] && [llength $n] == 1} {
  set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
  set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
  set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
  connect_debug_port dbg_hub/clk $n
  puts "sqrl_fk_top.tcl: debug hub on clk100"
} else {
  puts "sqrl_fk_top.tcl: no debug hub ([llength [get_debug_cores -quiet]] debug cores), or clk100 not found ([llength $n] nets)"
}

if {[llength $c_core] == 1 && [llength $c_u] == 1 && [llength $c_x] == 1 && $n_ch in {8 16} && $n_pc == $n_ch} {
  incr ::otpu::ok(sqrl_fk_top)
}
