# Write a prebuilt SQRL FK33 / FK35 image (prebuilt/sqrl-fk33/<build>, prebuilt/sqrl-fk35/<build>: one plain
# bitstream in the board's two MT25QU256, dual QSPI) to the card's flashes over JTAG and boot from them; on Linux or
# Windows, with any Vivado or Vivado Lab Edition (its hardware manager needs no license; tested with 2019.2):
#   vivado -mode batch -nojournal -nolog -source fk_flash.tcl -tclargs DIR PART [TARGET] [list]
# DIR: the folder of otpu_primary.mcs / .prm and otpu_secondary.mcs / .prm; PART: xcvu33p (FK33) or xcvu35p (FK35).
# Only the JTAG target whose chain is exactly one device of PART is touched (TARGET, a substring of the hw_target's
# name, picks one when several are; the PC's other cables are left alone); "list" lists the targets and stops.
# Then make the host see the new design: on Linux `sudo otpu-setup --rescan`, on Windows the flash script beside the
# image (it restarts the card's root port), or a full power cycle of the PC either way. About 10 minutes.
# The FK33s seen so far are engineering samples (JTAG IDCODE revision 0): the bitstream version check is off, so
# Vivado's production bitstream programs them (it warns "Incorrect bitstream assigned to device").
if {[llength $argv] < 2} { error "fk_flash.tcl: DIR PART \[TARGET\] \[list\]" }
lassign $argv dir part want mode
if {$want eq "list"} { set want {}; set mode list }
set dir [file normalize $dir]
foreach f {otpu_primary.mcs otpu_primary.prm otpu_secondary.mcs otpu_secondary.prm} {
  if {$mode ne "list" && ![file exists $dir/$f]} { error "fk_flash.tcl: $dir has no $f" }
}
set_param xicom.use_bitstream_version_check false
open_hw_manager
connect_hw_server -allow_non_jtag
set found {}
foreach t [get_hw_targets] {
  if {$want ne {} && ![string match "*$want*" $t]} { continue }
  if {[catch {open_hw_target $t}]} { catch {close_hw_target $t}; puts "FKFLASH $t: no device"; continue }
  set devs [get_hw_devices]
  set parts {}
  foreach d $devs { lappend parts [get_property PART $d] }
  puts "FKFLASH $t: $parts"
  if {[llength $devs] == 1 && [get_property PART [lindex $devs 0]] eq $part} { lappend found $t }
  catch {close_hw_target $t}
}
if {$mode eq "list"} { puts "FKFLASH $part targets: $found"; return }
if {[llength $found] != 1} { error "FKFLASH $part targets: '$found' (want exactly one; TARGET picks)" }
open_hw_target [lindex $found 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "FKFLASH programming $dev on [lindex $found 0] from $dir"
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts mt25qu256-spi-x1_x2_x4_x8] 0]
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE use_file $cfgmem
set_property PROGRAM.FILES [list $dir/otpu_primary.mcs $dir/otpu_secondary.mcs] $cfgmem
set_property PROGRAM.PRM_FILES [list $dir/otpu_primary.prm $dir/otpu_secondary.prm] $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION pull-none $cfgmem
set_property PROGRAM.BLANK_CHECK 0 $cfgmem
set_property PROGRAM.ERASE 1 $cfgmem
set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
set_property PROGRAM.VERIFY 1 $cfgmem
set_property PROGRAM.CHECKSUM 0 $cfgmem
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
program_hw_cfgmem -hw_cfgmem $cfgmem
boot_hw_device $dev
after 8000
refresh_hw_device -quiet -update_hw_probes false $dev
if {[catch {get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev} done]} { set done 1 }
puts "FKFLASH booted from flash: DONE=$done"
if {$done != 1} { error "FKFLASH the FPGA did not configure from flash (DONE=0)" }
