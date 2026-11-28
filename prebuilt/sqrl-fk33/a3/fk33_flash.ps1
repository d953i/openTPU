# Flash an FK33 build of board sqrl-fk (prebuilt/sqrl-fk33/a3; prebuilt/sqrl-fk35/r16/fk35_flash.ps1 for the xcvu33p)
# (docs/sqrl-fk.md: one plain bitstream, two MT25QU256 in dual QSPI) and bring the card back on Windows; step by step
# for anyone: docs/sqrl-fk-quickstart.md. Run in an ADMINISTRATOR PowerShell:
#   powershell -ExecutionPolicy Bypass -File fk33_flash.ps1 [-Dir <folder with the .mcs/.prm>] [-Target <hw target>]
#                                                           [-Dna <eFUSE DNA>] [-Vivado <vivado.bat>] [-SkipFlash]
# Vivado: -Vivado, else any Vivado or Vivado Lab Edition (free: its hardware manager programs the flash) in C:\Xilinx or
# C:\AMDDesignTools, 2019.2 first.
# Steps: disable the card's PCI device (1E24:1533) -> program both flashes over JTAG and boot from them -> remove the
# device, restart its root port (the new design's BARs) and rescan, booting from flash again over JTAG if Windows
# misses the card. Only a hardware target that holds exactly one xcvu33p is touched (-Target picks one when several
# do; -Dna also checks the device's eFUSE DNA). Logs go to %TEMP%\fk35_flash.
param(
    [string] $Dir = $PSScriptRoot,
    [string] $Vivado = '',
    [string] $Target = '',
    [string] $Dna = '',
    [string] $RootPort = '',
    [switch] $SkipFlash
)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run this in an Administrator PowerShell' }
if (-not $Vivado) {
    # any edition and version loads the image (the free Lab Edition too): 2019.2 first (the build's), else the newest
    # installed in C:\Xilinx or C:\AMDDesignTools
    $Vivado = @(@('C:\Xilinx\Vivado\2019.2\bin\vivado.bat', 'C:\Xilinx\Vivado_Lab\2019.2\bin\vivado_lab.bat') |
                Where-Object { Test-Path $_ }) +
              @(Get-ChildItem -Path 'C:\Xilinx\Vivado*\*\bin\vivado*.bat', 'C:\AMDDesignTools\*\Vivado*\bin\vivado*.bat' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in 'vivado.bat', 'vivado_lab.bat' } | Sort-Object FullName -Descending | ForEach-Object FullName) |
              Select-Object -First 1
    if (-not $Vivado) { throw 'Vivado not found: install Vivado Lab Edition (free, from AMD; any version) or Vivado, or pass -Vivado <path to vivado.bat>' }
}
"Vivado: $Vivado"
$rel = (Resolve-Path $Dir).Path
foreach ($f in 'otpu_primary.mcs', 'otpu_primary.prm', 'otpu_secondary.mcs', 'otpu_secondary.prm') {
    if (-not (Test-Path (Join-Path $rel $f))) { throw "$rel has no $f" }
}
$relTcl = $rel -replace '\\', '/'
$work = Join-Path $env:TEMP 'fk33_flash'
New-Item -ItemType Directory -Force $work | Out-Null

function Find-Card { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1E24&DEV_1533*' } | Select-Object -First 1 }
function Run-Vivado([string] $tclFile, [string] $log) {
    Push-Location $work
    try { & cmd /c "`"$Vivado`" -mode batch -nojournal -log `"$log`" -notrace -source `"$tclFile`" 2>&1" | Out-File -Encoding ascii "$log.out" } finally { Pop-Location }
    $rc = $LASTEXITCODE
    Select-String -Path "$log.out" -Pattern 'FK35FLASH|Program/Verify|ERROR' | ForEach-Object { Write-Host $_.Line }   # (to the console: the function returns the exit code alone)
    return $rc
}

# the JTAG target: the given one, or the only one whose chain is exactly one xcvu33p (a PC's other cables untouched)
$open = @"
set_param xicom.use_bitstream_version_check false
open_hw_manager
connect_hw_server -allow_non_jtag
set want {$Target}
set dna {$Dna}
set found {}
foreach t [get_hw_targets] {
  if {`$want ne {} && ![string match "*`$want*" `$t]} { continue }
  if {[catch {open_hw_target `$t}]} { catch {close_hw_target `$t}; continue }   ;# (a failed open leaves it open)
  set devs [get_hw_devices]
  if {[llength `$devs] == 1 && [get_property PART [lindex `$devs 0]] eq "xcvu33p"} { lappend found `$t }
  close_hw_target `$t
}
if {[llength `$found] != 1} { error "FK35FLASH xcvu33p targets: '`$found' (want exactly one; -Target picks)" }
open_hw_target [lindex `$found 0]
set dev [lindex [get_hw_devices] 0]
current_hw_device `$dev
refresh_hw_device -update_hw_probes false `$dev
if {`$dna ne {} && [get_property REGISTER.EFUSE.FUSE_DNA `$dev] ne `$dna} { error "FK35FLASH DNA [get_property REGISTER.EFUSE.FUSE_DNA `$dev] is not `$dna" }
puts "FK35FLASH device `$dev on [lindex `$found 0]"
"@
$done = @"
after 8000
refresh_hw_device -quiet -update_hw_probes false `$dev
if {[catch {get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN `$dev} done]} { set done 1; puts "FK35FLASH DONE not readable after the cfgmem core (2019.2); boot_hw_device logged the DONE pin" }
puts "FK35FLASH booted from flash: DONE=`$done"
if {`$done != 1} { error "FK35FLASH the FPGA did not configure from flash (DONE=0)" }
"@
$flashTcl = Join-Path $work 'flash.tcl'
@"
$open
create_hw_cfgmem -hw_device `$dev [lindex [get_cfgmem_parts mt25qu256-spi-x1_x2_x4_x8] 0]
set cfgmem [get_property PROGRAM.HW_CFGMEM `$dev]
set_property PROGRAM.ADDRESS_RANGE use_file `$cfgmem
set_property PROGRAM.FILES [list {$relTcl/otpu_primary.mcs} {$relTcl/otpu_secondary.mcs}] `$cfgmem
set_property PROGRAM.PRM_FILES [list {$relTcl/otpu_primary.prm} {$relTcl/otpu_secondary.prm}] `$cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION pull-none `$cfgmem
set_property PROGRAM.BLANK_CHECK 0 `$cfgmem
set_property PROGRAM.ERASE 1 `$cfgmem
set_property PROGRAM.CFG_PROGRAM 1 `$cfgmem
set_property PROGRAM.VERIFY 1 `$cfgmem
set_property PROGRAM.CHECKSUM 0 `$cfgmem
create_hw_bitstream -hw_device `$dev [get_property PROGRAM.HW_CFGMEM_BITFILE `$dev]
program_hw_devices `$dev
refresh_hw_device `$dev
program_hw_cfgmem -hw_cfgmem `$cfgmem
boot_hw_device `$dev
$done
"@ | Set-Content -Encoding ascii $flashTcl
$bootTcl = Join-Path $work 'boot.tcl'
@"
$open
boot_hw_device `$dev
$done
"@ | Set-Content -Encoding ascii $bootTcl

$card = Find-Card
if (-not $RootPort -and $card) { $RootPort = (Get-PnpDeviceProperty -InstanceId $card.InstanceId -KeyName DEVPKEY_Device_Parent).Data }
if (-not $SkipFlash) {
    if ($card -and $card.Problem -ne 22) { "Disabling $($card.InstanceId)"; & pnputil /disable-device $card.InstanceId | Out-Null }
    "[$(Get-Date -Format HH:mm:ss)] programming both flashes from $rel and booting (~17 min, no progress output) ..."
    if (Run-Vivado $flashTcl (Join-Path $work 'flash.log')) { throw "flash programming or boot failed: $work\flash.log.out" }
    if ($card) { & pnputil /remove-device $card.InstanceId | Out-Null }
}
if ($RootPort) { "Restarting the root port $RootPort (the new BARs)"; & pnputil /restart-device $RootPort | Out-Null }
$new = $null
for ($try = 1; $try -le 3 -and -not $new; $try++) {
    if ($try -gt 1) {
        "Windows did not enumerate the card: booting from flash again (try $try)"
        if (Run-Vivado $bootTcl (Join-Path $work 'boot.log')) { throw "JTAG boot failed: $work\boot.log.out" }
        if ($RootPort) { & pnputil /restart-device $RootPort | Out-Null }
    }
    for ($n = 0; $n -lt 6 -and -not $new; $n++) { & pnputil /scan-devices | Out-Null; Start-Sleep -Seconds 3; $new = Find-Card }
}
if (-not $new) { throw 'the card did not come back: restart Windows fully (Start > Restart), then run the self-test' }
& pnputil /enable-device $new.InstanceId | Out-Null
$sp = (Get-PnpDeviceProperty -InstanceId $new.InstanceId -KeyName DEVPKEY_PciDevice_CurrentLinkSpeed).Data
$wd = (Get-PnpDeviceProperty -InstanceId $new.InstanceId -KeyName DEVPKEY_PciDevice_CurrentLinkWidth).Data
"[$(Get-Date -Format HH:mm:ss)] card back: $($new.InstanceId), PCIe Gen$sp x$wd. (Gen3 is this design's fastest; a full restart, not a warm one, trains the most lanes the slot has.)"

