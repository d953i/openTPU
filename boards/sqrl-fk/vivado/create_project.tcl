# Create the Vivado project for the SQRL Forest Kitten boards (docs/sqrl-fk.md): the FK35 (xcvu35p, two SLRs;
# targets/sqrl-fk35.toml) or the FK33 (xcvu33p, one SLR; targets/sqrl-fk33.toml), the same PCB with 8 GB HBM2 and
# a PCIe edge. The accelerator at WG 8 (one slice of 8 channels, the WG targets') on the HBM through its channel
# bridges (otpu_hbm_ch, one an HBM mini-switch's AXI port), the HBM IP (hbm_0: both stacks, 8 GB;
# rtl/boards/sqrl-fk/otpu_hbm.sv instantiates it), the block design bd.tcl (XDMA, the clocks, the SYSMON, the DMA
# windows) and the top rtl/boards/sqrl-fk/otpu_fpga_top_sqrl_fk.sv.
#   vivado -mode batch -source create_project.tcl -tclargs OUT_DIR
# OUT_DIR holds boards/sqrl-fk/scripts/make_defines.py's output (run_vivado.sh writes it first): fk_params.tcl
# (TARGET, PART, PCIE_GEN, CORE_MHZ, CORE_KHZ, UCLK_MHZ, CAW, RLY, BUILD_ID, ARCH_HASH, RTL: opentpu.target sources) and
# otpu_sqrl_fk_defines.vh (otpu_board's parameters, OTPU_BOARD), a global include. Environment: PCIE_GEN (bd.tcl, over
# fk_params.tcl's: 4 Gen4 x8, 3 Gen3 x8), OTPU_FAST (Vivado's default strategies), OTPU_IP_CACHE, OTPU_FK_FP
# (sqrl_fk_floorplan.tcl: soft, the default, hard or none).
# Built with Vivado 2019.2 (its HBM IP 1.0 and XDMA 4.1; the VU33P / VU35P need a license that covers them):
# untyped string parameters in the RTL, the block design's wrapper under .srcs (2019.2) or .gen (later).
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
if {[llength $argv] < 1} { error "create_project.tcl: OUT_DIR (make_defines.py's output)" }
set out [file normalize [lindex $argv 0]]
source $out/fk_params.tcl
foreach v {TARGET PART CORE_MHZ CORE_KHZ UCLK_MHZ CAW RLY BUILD_ID ARCH_HASH RTL} {
  if {![info exists $v]} { error "create_project.tcl: $out/fk_params.tcl sets no $v" }
}
if {![info exists SNCH]} { set SNCH 8 }     ;# the slice's channels (8, or 16: sqrl-fk35w)
if {[string length $RLY] != $SNCH} { error "create_project.tcl: RLY $RLY: 4 bits a channel, $SNCH channels' N" }
if {![info exists HNP]} { set HNP 1 }       ;# (fk_params.tcl before the two-port bridges)
if {[info exists ::env(PCIE_GEN)] && $::env(PCIE_GEN) ne ""} { set PCIE_GEN $::env(PCIE_GEN) }
if {![info exists PCIE_GEN]} { set PCIE_GEN 4 }
set NCH 8                                   ;# the block design's host DMA windows (one a mini-switch)
puts "SQRL FK ($TARGET, $PART): core $CORE_MHZ MHz, uclk $UCLK_MHZ MHz, $SNCH channels, RLY $RLY, HNP $HNP, CAW $CAW,\
 PCIe Gen$PCIE_GEN x8, BUILD_ID $BUILD_ID, ARCH_HASH $ARCH_HASH"

create_project -force otpu $out -part $PART
if {[info exists ::env(OTPU_IP_CACHE)] && $::env(OTPU_IP_CACHE) ne ""} {
  file mkdir $::env(OTPU_IP_CACHE)
  config_ip_cache -use_cache_location $::env(OTPU_IP_CACHE)
}
set_property target_language Verilog [current_project]

# ---- RTL, otpu_board's parameters first (a global include: every file sees OTPU_BOARD)
foreach f $RTL {
  add_files -norecurse $root/$f
  set_property file_type SystemVerilog [get_files $root/$f]
}
set vh $out/otpu_sqrl_fk_defines.vh
add_files -norecurse $vh
set_property file_type {Verilog Header} [get_files $vh]
set_property is_global_include true [get_files $vh]
# OTPU_FPGA_INIT: no memories' power-on reset (otpu_slice rst_mem; docs/asic.md "Power-up state")
set_property verilog_define {SYNTHESIS OTPU_FPGA_INIT} [get_filesets sources_1]

# ---- the HBM IP: both stacks (8 GB), the global switches on, all 32 AXI ports (the top ties off the ones it does
# not use), the AXI ports on uclk, the reference and APB clocks 100 MHz; temperature-compensated refresh (2019.2's
# default is off)
create_ip -name hbm -vendor xilinx.com -library ip -version 1.0 -module_name hbm_0
set hbm [get_ips hbm_0]
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} CONFIG.USER_MEMORY_DISPLAY {8192}] $hbm
set cfg [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE} \
  CONFIG.USER_HBM_REF_CLK_0 {100} CONFIG.USER_HBM_REF_CLK_1 {100} \
  CONFIG.USER_APB_PCLK_0 {100} CONFIG.USER_APB_PCLK_1 {100} CONFIG.USER_MC_ENABLE_APB_01 {TRUE} \
  CONFIG.USER_AXI_CLK_FREQ $UCLK_MHZ CONFIG.USER_AXI_CLK1_FREQ $UCLK_MHZ]
for {set i 0} {$i < 32} {incr i} { lappend cfg CONFIG.USER_SAXI_[format %02d $i] {true} }
for {set i 0} {$i < 16} {incr i} { lappend cfg CONFIG.USER_MC${i}_REF_TEMP_COMP {true} }
set_property -dict $cfg $hbm
generate_target {instantiation_template synthesis} $hbm

# ---- block design (CORE_MHZ, UCLK_MHZ, PCIE_GEN, NCH in)
source $here/bd.tcl
make_wrapper -files [get_files otpu_bd.bd] -top
add_files -norecurse [lindex [glob $out/otpu.gen/sources_1/bd/otpu_bd/hdl/otpu_bd_wrapper.v \
                                   $out/otpu.srcs/sources_1/bd/otpu_bd/hdl/otpu_bd_wrapper.v] 0]
set_property top otpu_fpga_top_sqrl_fk [current_fileset]
set_property generic "CORE_KHZ=$CORE_KHZ CAW=$CAW RLY=64'h$RLY HNP=$HNP NCH=$SNCH" [current_fileset]

# ---- constraints: the pins and configuration; then, after the IPs' own, as unmanaged Tcl on the synthesized
# netlist (implementation only): the bridges' crossings (upstream's otpu_hbm_ch.tcl, scoped to their core halves),
# the MXU lanes' posted-beat staging (otpu_mxu_stage.tcl, scoped), the TMEM's pumped RAMs (the YPCB's
# otpu_clk2x.tcl), the floorplan (sqrl_fk_floorplan.tcl) and the top's (sqrl_fk_top.tcl, last). opt_design's
# pre-hook (sqrl_fk_check.tcl) stops the run on any of them failing.
set cons $root/boards/sqrl-fk/constraints
set bcu $root/boards/bcu1525/constraints
add_files -fileset constrs_1 -norecurse $cons/sqrl_fk_pins.xdc
set late [list $bcu/otpu_hbm_ch.tcl $cons/otpu_axi3_hmux.tcl $bcu/otpu_mxu_stage.tcl $root/boards/ypcb-00338/constraints/otpu_clk2x.tcl \
               $cons/sqrl_fk_floorplan.tcl $cons/sqrl_fk_top.tcl]
add_files -fileset constrs_1 -norecurse $late
set_property SCOPED_TO_REF otpu_hbm_cs [get_files $bcu/otpu_hbm_ch.tcl]
set_property SCOPED_TO_REF otpu_axi3_hmux [get_files $cons/otpu_axi3_hmux.tcl]
set_property SCOPED_TO_REF otpu_mxu_stage [get_files $bcu/otpu_mxu_stage.tcl]
set_property PROCESSING_ORDER LATE [get_files $late]
set_property USED_IN_SYNTHESIS false [get_files $late]
foreach f $late {
  if {![string match -nocase *tcl* [get_property FILE_TYPE [get_files $f]]]} {
    error "$f: FILE_TYPE [get_property FILE_TYPE [get_files $f]], expected TCL (unmanaged)"
  }
}
set_property STEPS.OPT_DESIGN.TCL.PRE $here/sqrl_fk_check.tcl [get_runs impl_1]

# The fork's FK35 directives (it met 250 / 250 MHz with them): placement spreads the logic, physical optimization
# and routing AggressiveExplore; synthesis as the BCU1525 WG build's (retiming on)
if {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"} {
  set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
  set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
} else {
  set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
  set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
  set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
  set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
  set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
  set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
}
set_property report_strategy {No Reports} [get_runs synth_1]
set_property report_strategy {No Reports} [get_runs impl_1]
puts "project created in $out ($TARGET, HBM 8 x 1 GiB, PCIe Gen$PCIE_GEN x8, core $CORE_MHZ MHz)"
