# sqrlfk.sys 2.1: the SQRL FK33 / FK35 Windows driver (test-signed)

The KMDF driver that openTPU's Windows host (`boards/sqrl-fk/host`, docs/sqrl-fk.md "Windows host") reaches the card
through, in place of Linux's XDMA driver: PCI 1E24:1533, Windows 10 (1709 and later) and 11, x64. Its requests: BAR
register reads and writes, batches of up to 4096 of them, a register poll in the driver, and direct DMA of up to 256 MB
from and to the caller's buffer. The source, its build (Enterprise WDK) and the full description of the requests are
the SQRL_FK33 repository's `driver/windows` (Apache-2.0); this is its `package\` folder, built 2026-10-23.

| File | Bytes | SHA-256 |
|---|--:|---|
| `sqrlfk.sys` | 22,920 | `928685a04bb4bbb1d62b20c18dc5e49db74bd453c99d3ac5b93ab3e77764b181` |
| `sqrlfk.inf` | 1,696 | `929546ccf83850afb5bf39c3cdbff2c5752c75ec09fec92a34b3c83733eff913` |
| `sqrlfk.cat` | 2,378 | `3a20a6ac4e8c9e02216af3af06f8a8655a83e07d77f754f240eb7b78f42f7740` |
| `sqrlfk.cer` | 784 | `af0e0f5b6cb9e06abdedf284586704dee2fd23a61c47fa77e14d830a84cea82d` |
| `sqrlfk.pdb` | 585,728 | `f445925c6e4b14720f07e35e2d572cd5c37cc58dc1e311eb63f4fd725e7d395e` |
| `sqrl_fk_mcap.exe` | 184,832 | `1b6ea4ede4c6bde16ebaeb6bf0a9406142636bd19fdf4bbb1aa7e98d8938b13d` |
| `install.bat` | 265 | `2a7b0668095c8887cf410c173ce6d5bd02f759226a36922bd153fba003d75fd1` |
| `install.ps1` | 2,915 | `40412ed13e0446835eca7dfcf91f4f8517601f799eeef4f7f72d0ee043c6ba82` |

## Install

The package is test-signed (certificate `CN=SQRL FK Test Driver`, `sqrlfk.cer`), which Windows loads only in test
signing mode:

1. Secure Boot off (the PC's firmware setup). As administrator: `bcdedit /set testsigning on`, then restart Windows
   ("Test Mode" shows on the desktop).
2. With the card in the PC (a bitstream loaded or flashed: Device Manager shows a PCI device 1E24:1533), run
   `install.bat`. It asks for administrator rights; Windows then asks whether to install a driver from an unverified
   publisher: install it. The certificate is not added to any trusted store.
3. Device Manager shows "SQRL Forest Kitten FK33/FK35" under System devices (driver 2.1.0.0).

`install.bat /uninstall` removes it. A driver that installs without test signing needs Microsoft's attestation
signing (Partner Center, an EV code-signing certificate).

## Check

As administrator, `sqrl_fk_mcap info` (the PCI location, BARs, XDMA engines), `sqrl_fk_mcap read 0x0` (openTPU's ID
register: `0x4f545055`, "OTPU") and `sqrl_fk_mcap bench` (register and DMA timings). openTPU's own check is
`boards\sqrl-fk\host\otpu-fk.cmd -m opentpu.host.selftest --dev sqrlfk0`.

Notes: one driver owns the device (Xilinx's XDMA driver for Windows cannot be installed beside it); the device opens
for Administrators and SYSTEM only, so run openTPU's tools in an administrator terminal; sleep and hibernate turn the
slot off, which unconfigures the FPGA (it reloads from flash at the next power-on).
