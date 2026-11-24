# The SQRL FK build's floorplan (create_project.tcl; docs/sqrl-fk.md): unmanaged Tcl, read in implementation only
# and late, before sqrl_fk_top.tcl. The BCU1525 WG build's bcu1525_wg_floorplan.tcl is the model, the layout the
# fork's FK35 builds' (which met 250 / 250 MHz on the part, and Gen4 x8 with pb_xdma).
#
# Both HBM stacks (all 32 AXI ports) sit at the bottom edge of SLR0, the PCIe block (PCIE4C_X1Y0, GTY quads
# 224-227) in SLR0 too. The FK33's xcvu33p is that one SLR; the FK35's xcvu35p has SLR1 above it.
#   - FK35: pblock_slice, SLR1: the accelerator (u_sys/u_board: the slice, its adapter, the control block and the
#     trace) and its bridges' core halves (u_sys/g_ch[j].u_br/u_cs); the bridges' pipelines (otpu_hbm_ln u_ln, N =
#     RLY[4 j +: 4] = 4 + pre: make_defines.py's 5, pre 1, so the crossing pair is register-fed) by SLR as upstream's rule: stages j < pre in SLR1 with the core
#     half, stages pre + 2 .. N - 1 in SLR0, stage N (with the AXI half, otpu_hbm_ac, and the register slice) left
#     to the placer beside its HBM port. Stages pre and pre + 1 each way are the SLR crossing's Laguna TX / RX pair:
#     USER_SLL_REG and in no pblock (an SLR pblock has no Laguna sites). The fork's FK35 put slice 0 and the shell
#     in SLR0 with the memory side once: ~93% of SLR0's CLBs, unroutable.
#   - FK33: no pblock for the accelerator (one SLR).
#   - both, PCIe Gen4 (XDMA's 512-bit AXI: sc_dma's S00 512 data bits): pb_xdma, a hard pblock in the two right
#     columns of SLR0 (the PCIe block at X7Y0) and the top row's right half, for XDMA (54k LUTs at Gen4) and sc_dma's
#     512-bit entry; unconstrained, the fork's f35d000c spread XDMA among the channels and failed (-0.52 ns core,
#     -0.40 uclk).
# OTPU_FK_FP (environment): hard (the default, as the fork's), soft (the pblock IS_SOFT) or none (no pblock_slice;
# pb_xdma still). fk_params.tcl: OTPU_FK_OUT's (run_vivado.sh: OUT), else the run directory's ../../
# (OUT/otpu.runs/impl_1): TARGET and RLY. No return here: in a read_xdc file it does not end the file.
namespace eval ::otpu {}
proc ::otpu::fk_fp_miss {m} {
  puts "CRITICAL WARNING: \[sqrl_fk_floorplan.tcl\] $m"
  lappend ::otpu::fail "sqrl_fk_floorplan.tcl: $m"
}
set fp_mode [expr {[info exists ::env(OTPU_FK_FP)] && $::env(OTPU_FK_FP) ne "" ? $::env(OTPU_FK_FP) : "hard"}]
set fp_par [expr {[info exists ::env(OTPU_FK_OUT)] && $::env(OTPU_FK_OUT) ne ""
                  ? "$::env(OTPU_FK_OUT)/fk_params.tcl" : [file normalize ../../fk_params.tcl]}]
set fp_rly ""
if {![catch {open $fp_par} fh]} {
  set fp_txt [read $fh]
  close $fh
  regexp {set RLY ([0-9a-fA-F]{8}|[0-9a-fA-F]{16})\s} $fp_txt -> fp_rly
}
set fp_nslr [llength [get_slrs -quiet]]
set fp_ok 1

# ---------------------------------------------------------------- the accelerator (FK35: SLR1)
if {$fp_nslr == 1} {
  puts "sqrl_fk_floorplan.tcl: one SLR (FK33): no pblock_slice"
} elseif {$fp_mode eq "none"} {
  puts "sqrl_fk_floorplan.tcl: no pblock_slice (OTPU_FK_FP none)"
} elseif {$fp_nslr != 2} {
  ::otpu::fk_fp_miss "$fp_nslr SLRs (1: FK33, 2: FK35)"
  set fp_ok 0
} else {
  set fp_cells [get_cells -quiet u_sys/u_board]
  set fp_cs [get_cells -quiet {u_sys/g_ch[*].u_br/u_cs}]
  set fp_nch [string length $fp_rly]          ;# the slice's channels (RLY: 4 bits each; 8, or 16 for sqrl-fk35w)
  if {[llength $fp_cells] != 1 || [llength $fp_cs] != $fp_nch || $fp_rly eq ""} {
    ::otpu::fk_fp_miss "u_sys/u_board [llength $fp_cells], bridge core halves [llength $fp_cs] (1, $fp_nch), RLY '$fp_rly' ($fp_par): no floorplan"
    set fp_ok 0
  } else {
    set pb [create_pblock pblock_slice]
    resize_pblock $pb -add SLR1
    add_cells_to_pblock $pb [concat $fp_cells $fp_cs]
    if {$fp_mode eq "soft"} { set_property IS_SOFT TRUE $pb }
    puts "sqrl_fk_floorplan.tcl: pblock_slice in SLR1 ($fp_mode): u_sys/u_board and $fp_nch bridge core halves"
    # the accelerator's reset stages (the top's core_rst_p and their replicas) with their loads
    set fp_rp [get_cells -quiet {core_rst_p_reg*}]
    if {[llength $fp_rp] < 3} {
      ::otpu::fk_fp_miss "the reset pipeline: [llength $fp_rp] core_rst_p registers (3 at least)"
      set fp_ok 0
    } else {
      add_cells_to_pblock $pb $fp_rp
      puts "sqrl_fk_floorplan.tcl: [llength $fp_rp] reset registers (core_rst_p) in pblock_slice"
    }
    # the pipelines: stage j <= pre in SLR1 (pblock_slice), pre < j < N in SLR0 (pblock_slr0), N the placer's
    set pb0 [create_pblock pblock_slr0]
    resize_pblock $pb0 -add SLR0
    if {$fp_mode eq "soft"} { set_property IS_SOFT TRUE $pb0 }
    # Not here: Laguna-only pblocks to pin each crossing pair's sides (USER_SLL_REG alone let the port's FK35 r8 put
    # a back-path pair both in SLR0, -0.052 ns). 2019.2 refused every form tried on r7's netlist: TX and RX in a
    # pblock per side, or the TX only (Place 30-797, "could not find an acceptable tile/site/bel"), one pblock on
    # both sides (Place 30-779: a Laguna-exclusive pblock must stay on one edge of one SLR).
    set nin 0
    set nx 0
    set nsll 0
    for {set c 0} {$c < $fp_nch} {incr c} {
      scan [string index $fp_rly end-$c] %x n
      set pre [expr {$n - 4}]
      if {$pre < 0} {
        ::otpu::fk_fp_miss "channel $c: a pipeline of N $n across one SLR (4 at least)"
        set fp_ok 0
        continue
      }
      set u "u_sys/g_ch?$c?.u_br/u_ln"
      set nst 0
      for {set j 0} {$j < $n} {incr j} {
        set sj [get_cells -quiet [list "$u/fs_reg\[$j\]\[*\]" "$u/bs_reg\[$j\]\[*\]"]]
        if {![llength $sj]} { continue }
        incr nst [llength $sj]
        if {$j == $pre || $j == $pre + 1} {
          # the crossing's Laguna TX / RX pair: USER_SLL_REG only, in no pblock (an SLR pblock
          # leaves out the Laguna sites: the port's FK35 build with stage pre in pblock_slice put it
          # in a slice 35 rows above the boundary, 2.68 ns into its RX register at 450 MHz)
          set_property USER_SLL_REG TRUE $sj
          incr nsll [llength $sj]
        } elseif {$j < $pre} {
          add_cells_to_pblock $pb $sj
          incr nin [llength $sj]
        } else {
          add_cells_to_pblock $pb0 $sj
          incr nx [llength $sj]
        }
      }
      if {!$nst} {
        ::otpu::fk_fp_miss "channel $c: no pipeline stages ($u, N $n)"
        set fp_ok 0
      }
    }
    puts "sqrl_fk_floorplan.tcl: the bridges' pipelines: $nin stage registers in SLR1, $nx in SLR0, $nsll Laguna registers (the crossing pair; stage N with the placer)"
  }
}

# ---------------------------------------------------------------- XDMA at Gen4
if {[llength [get_pins -quiet {u_bd/otpu_bd_i/sc_dma/S00_AXI_wdata[511]}]]} {
  # XDMA and the DMA SmartConnect's 512-bit entry (its S00 entry pipeline and nodes). Its master nodes stay free,
  # toward their exits and the HBM ports along the bottom edge: when they crossed into uclk (450 MHz) and sat here,
  # half the FK35's 60 worst uclk paths were theirs (m00_r_node's upsizer into m00_exit). The whole SmartConnect
  # is on xdma_aclk now (bd.tcl), the host's HBM ports too.
  set pbc [get_cells -quiet u_bd/otpu_bd_i/xdma_0]
  foreach c {s00_entry_pipeline s00_nodes} {
    set x [get_cells -quiet u_bd/otpu_bd_i/sc_dma/inst/$c]
    if {[llength $x]} { lappend pbc $x } else { ::otpu::fk_fp_miss "pb_xdma: no sc_dma $c"; set fp_ok 0 }
  }
  set crs {CLOCKREGION_X6Y0:CLOCKREGION_X7Y3 CLOCKREGION_X3Y3:CLOCKREGION_X5Y3}
  if {![llength [get_clock_regions -quiet {X7Y3 X3Y3}]] || [llength $pbc] != 3} {
    ::otpu::fk_fp_miss "pb_xdma: clock regions X7Y3 / X3Y3 or its cells ($pbc) not found"
    set fp_ok 0
  } else {
    set pbx [create_pblock pb_xdma]
    resize_pblock $pbx -add $crs
    set_property IS_SOFT false $pbx
    # nested in the pipelines' SLR0 pblock when there is one (pblocks overlap only nested)
    if {[llength [get_pblocks -quiet pblock_slr0]]} { set_property PARENT pblock_slr0 $pbx }
    add_cells_to_pblock $pbx $pbc
    puts "sqrl_fk_floorplan.tcl: pb_xdma, [llength $pbc] cells in $crs"
  }
} else {
  puts "sqrl_fk_floorplan.tcl: no pb_xdma (sc_dma's S00 not 512 bits: Gen3)"
}
if {$fp_ok} { incr ::otpu::ok(sqrl_fk_floorplan) }
