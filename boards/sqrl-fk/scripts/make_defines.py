#!/usr/bin/env python3
"""The SQRL Forest Kitten build's generated inputs (targets/sqrl-fk35.toml, sqrl-fk33.toml;
boards/sqrl-fk/vivado/create_project.tcl reads them from OUT):
    python3 boards/sqrl-fk/scripts/make_defines.py OUT [--target sqrl-fk35 | sqrl-fk33]
        [--core-mhz F] [--uclk-mhz F] [--set K=V ...] [--rly N]
OUT/otpu_sqrl_fk_defines.vh: otpu_board's parameters (OTPU_BOARD, OTPU_WPOST .. OTPU_XSW: the
target's rtl_params with --set overrides, the arch knobs' with their ARCH_HASH, and BUILD_ID the
tree's commit: opentpu.host.boardmacro's board_params and board_defines; COLL_GATHER 0 unless
--set: the one slice's collective unit BAR alone), a global include in the
project. OUT/fk_params.tcl: TARGET, PART, PCIE_GEN (the target's pcie_gen), CORE_MHZ, CORE_KHZ (the block design's core clock; core_clk2x at
twice it), UCLK_MHZ (the HBM's AXI ports and the bridges' AXI side), CAW (the channels' beat address
bits from the target's channel_bytes), HNP (the HBM ports a channel's bridge drives: --hnp, default the
target's platform hbm_ports, else 1; otpu_hbm_ch NP), RLY (each bridge's pipeline between its halves, otpu_hbm_ch N:
--rly, default the board's: 5 on the FK35 (4 k + 1: the Laguna pair fed and read by registers only), the slice in SLR1 and the HBM in SLR0; 0 on the FK33's one
SLR), BUILD_ID, ARCH_HASH and RTL, the target's sources in compile order (opentpu.target sources).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from opentpu import target as T                    # noqa: E402
from opentpu.host import boardmacro as BM          # noqa: E402

TARGETS = ("sqrl-fk35", "sqrl-fk33", "sqrl-fk35w")
RLY_DEFAULT = {"sqrl-fk35": 5, "sqrl-fk33": 0, "sqrl-fk35w": 5}   # the bridges' stages across the SLR boundary


def caw(channel_bytes: int, beat_bytes: int) -> int:
    """The channels' beat address bits: 23 (1 GiB of 128-byte beats, an HBM mini-switch)."""
    n = (channel_bytes // beat_bytes - 1).bit_length()
    if channel_bytes != beat_bytes << n or not 20 <= n <= 23:
        raise SystemExit(f"make_defines.py: channel_bytes {channel_bytes}: 2^20 .. 2^23 beats of "
                         f"{beat_bytes} bytes (an HBM mini-switch's 1 GiB at most)")
    return n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", type=Path)
    ap.add_argument("--target", default="sqrl-fk35")
    ap.add_argument("--core-mhz", type=float)
    ap.add_argument("--uclk-mhz", type=float, default=450.0)
    ap.add_argument("--set", action="append", default=[], metavar="K=V")
    ap.add_argument("--rly", type=int, help="each bridge's pipeline N, 0 .. 15")
    ap.add_argument("--hnp", type=int, choices=(1, 2),
                    help="HBM ports a channel (default: the target's platform hbm_ports, else 1)")
    a = ap.parse_args()
    if a.target.partition(":")[0] not in TARGETS:
        raise SystemExit(f"make_defines.py: --target {a.target}: {' or '.join(TARGETS)}, or a "
                         f"variant of it")
    t = T.load(a.target)
    sets = dict(kv.split("=", 1) for kv in a.set)
    # one slice: the collective unit runs BAR alone (otpu_coll_bar, CAPS2 bit0 clear), as the
    # board's simulation builds it (opentpu.rtlsim BOARD_UARCH) and the YPCB's build does: no
    # compiled program has a GATHER at S = 1, and the host refuses one. It has no TMEM port, so
    # the TMEM -> collective paths go (--set COLL_GATHER=1 keeps GATHER)
    sets.setdefault("COLL_GATHER", "0")
    nch = t.platform["channels_per_slice"]
    bp = BM.board_params(t, nch, t.platform["beat_bytes"], sets)
    if bp["S"] != 1 or nch not in (8, 16) or t.platform["beat_bytes"] != 128:
        raise SystemExit(f"make_defines.py: {a.target}: one slice of 8 or 16 channels of 128 bytes")
    mhz = a.core_mhz or float(t.platform["core_mhz"])
    cw = caw(t.platform["channel_bytes"], t.platform["beat_bytes"])
    n = RLY_DEFAULT[a.target.partition(":")[0]] if a.rly is None else a.rly
    if not 0 <= n <= 15:
        raise SystemExit(f"make_defines.py: --rly {n}: 0 .. 15")
    rly = sum(n << (4 * j) for j in range(nch))
    hnp = a.hnp or int(t.platform.get("hbm_ports", 1))
    if hnp not in (1, 2):
        raise SystemExit(f"make_defines.py: hbm_ports {hnp}: 1 or 2")
    if nch == 16 and hnp != 2:
        raise SystemExit(f"make_defines.py: 16 channels need hbm_ports 2 (every HBM port a bridge's)")
    nd = nch                                        # RLY's hex digits: 4 bits a channel
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "otpu_sqrl_fk_defines.vh").write_text(
        "// written by boards/sqrl-fk/scripts/make_defines.py\n"
        "`ifndef OTPU_SQRL_FK_DEFINES\n`define OTPU_SQRL_FK_DEFINES\n"
        f"{BM.board_defines(bp)}`endif\n")
    rtl = " ".join(f"rtl/{f}" for f in T.sources(t))
    (a.out / "fk_params.tcl").write_text(
        "# written by boards/sqrl-fk/scripts/make_defines.py\n"
        f"set TARGET {a.target}\nset PART {t.tech['part']}\nset PCIE_GEN {int(t.platform.get('pcie_gen', 4))}\n"
        f"set CORE_MHZ {mhz:g}\nset CORE_KHZ {round(mhz * 1000)}\nset UCLK_MHZ {a.uclk_mhz:g}\n"
        f"set CAW {cw}\nset RLY {rly:0{nd}x}\nset HNP {hnp}\nset SNCH {nch}\n"
        f"set BUILD_ID {bp['BUILD_ID']:08x}\nset ARCH_HASH {bp['ARCH_HASH']:08x}\n"
        f"set RTL [list {rtl}]\n")
    print(f"make_defines: {a.out}: {a.target} ({t.tech['part']}), core {mhz:g} MHz, uclk "
          f"{a.uclk_mhz:g} MHz, CAW {cw}, {nch} channels, RLY {4 * nd}'h{rly:0{nd}x}, HNP {hnp}, BUILD_ID {bp['BUILD_ID']:08x}, "
          f"ARCH_HASH {bp['ARCH_HASH']:08x}, MCOLS {bp['MCOLS']} WG {bp['WG']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
