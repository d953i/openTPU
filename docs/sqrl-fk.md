# openTPU on the SQRL Forest Kitten boards (FK33, FK35)

The SQRL Forest Kitten 33 and 35 share one PCB: a Virtex UltraScale+ HBM FPGA with 8 GB of HBM2 in two stacks
(32 pseudo-channels of 256 MiB behind 32 AXI3 256-bit ports), a PCIe x16 edge connector (8 GTY lanes used), two
MT25QU256 configuration flashes (SPI x8) and four green LEDs and an RGB one. No other clock input: everything runs
from XDMA's 250 MHz `axi_aclk`.

| | FK35 | FK33 | FK35 wide (experimental) |
|---|---|---|---|
| target | `targets/sqrl-fk35.toml` (platform 4) | `targets/sqrl-fk33.toml` (platform 8) | `targets/sqrl-fk35w.toml` (platform 9) |
| part | xcvu35p-fsvh2104-2-e, two SLRs | xcvu33p-fsvh2104-2-e, one SLR | xcvu35p |
| slice | MCOLS 8, WG 8, 8 channels of 1 GiB | as the FK35 | MCOLS 16, WG 16, 16 channels of 512 MiB |
| HBM AXI ports | 16 (two a channel) + 8 host | as the FK35 | all 32 (two a channel, the host's shared) |
| bridges' pipelines (`RLY`) | N 5 (the slice in SLR1, the HBM in SLR0) | N 0 | N 5 |
| core / uclk | 225 / 450 MHz | 225 / 450 MHz (not built yet) | 225 / 450 MHz (does not route yet) |
| PCIe | Gen4 x8 | Gen4 x8 | Gen4 x8 |

The FK35 and FK33 build the same design: one WG slice (the `bcu1525-wg` slice: MCOLS 8, WG 8, docs/bcu1525_wg.md)
on eight channels of 128-byte beats, the WG targets' channel bridges (`rtl/mem/otpu_hbm_ch.sv`) in front of the HBM
instead of the BCU1525's DDR4 MIGs. The wide target doubles the slice's MXU and its intake ("The wide slice" below).

| | |
|---|---|
| top | `rtl/boards/sqrl-fk/otpu_fpga_top_sqrl_fk.sv` |
| system | `rtl/boards/sqrl-fk/otpu_sqrl_fk_sys.sv`: otpu_board at one slice of 8 channels, a bridge per channel on two HBM ports (`HNP` 2) and an AXI3 register slice per port |
| HBM | `rtl/boards/sqrl-fk/otpu_hbm.sv`: AMD's HBM IP (`hbm_0`) with its 32 AXI ports as arrays |
| block design | `boards/sqrl-fk/vivado/bd.tcl`: XDMA (PCIE4C_X1Y0, SQRL's identity 1E24:1533), the clocks, the SYSMON, the control interconnect, the DMA SmartConnect onto the eight channels' windows |
| constraints | `boards/sqrl-fk/constraints/`: pins and configuration, the top's crossings, the floorplan; the bridges' and MXU staging's crossings are the BCU1525's scoped files (`otpu_hbm_ch.tcl`, `otpu_mxu_stage.tcl`), the pumped TMEM's the YPCB's (`otpu_clk2x.tcl`) |
| build | `boards/sqrl-fk/run_vivado.sh` (Vivado 2019.2) |
| board model | `sim/verilator/tb_sqrlfk.sv`, `tests/test_sqrlfk_board.py` |

## Memory map

Channel j is HBM bytes j x 1 GiB .. + 1 GiB, the four pseudo-channels of mini-switch j (AXI ports 4j .. 4j + 3).
Its bridge drives ports 4j and 4j + 2 in lockstep (the targets' `hbm_ports = 2`: `otpu_sqrl_fk_sys` HNP 2,
`otpu_hbm_ch` NP 2), the host's DMA window j (the block design's `M_AXI_DMA<j>`, AXI3 256-bit on XDMA's 250 MHz
clock, no ID: the SmartConnect keeps its transactions in order) port 4j + 1; port 4j + 3 is tied off. All stay
inside the mini-switch, so the HBM's global switches carry nothing in normal use (they are on). The host sees
channel j at card address j x 1 GiB (`opentpu.host.board.channel_map`); the target's `channel_bytes` is 1 GiB and
its `AW` 33, so the slice addresses all 8 GB.

Two ports a channel. One HBM AXI port reads one 64-bit pseudo-channel at a time, 14.4 GB/s at 900 MHz DDR, and one
256-bit port at 450 MHz moves the same; the core side of a channel asks for 28.8 GB/s at 225 MHz (a 128-byte beat a
cycle: port W's weights in decode; 19.2 at 150). So each channel is split over two ports, each on its own half of the channel's
1 GiB, two pseudo-channels at once: channel byte o = 128 m + 64 s + 32 l + t (t < 32) is on port 4j + 2l at HBM byte
j GiB + l x 512 MiB + 64 m + 32 s + t (bit 5 of the channel's address moved to bit 29). The bridge's two halves work
in 512-bit beats; `otpu_hbm_np` beside its AXI half sends every burst to both ports at the same offset, the low 256
bits of each beat to port 4j and the high to 4j + 2, and pairs their R beats again through a block-RAM FIFO a port
(512 beats; the AR's credits keep it from filling, so RREADY stays high). Posted reads go into the MXU's lanes as two
512-bit writes a beat (`NAT_XQB` 1, `otpu_mxu` QB 1; its staging RAM 64 entries a lane), and the bridge keeps 128 reads
in flight (`RCD`: twice the rate over the same HBM latency). The bitstream says so in CAPS2 bit26 (`otpu_board`
CH_ILV), and the host's DMA into a channel goes through the same layout (`opentpu.host.board.interleave_ports`,
installed by `Board.info`): every write or read of a channel becomes one DMA call a half. `make_defines.py --hnp 1`
builds the bridges on port 4j alone, as before (CAPS2 bit26 clear).

The bridge's AXI half issues 256-bit beats (512 at two ports, split as above) with ID 0, INCR, 16 beats a burst at
most (AXI3), and takes R and B every cycle (RREADY and BREADY high). WDATA_PARITY is tied low on every port: the HBM
IP's parity checks are all off, so it ignores it (an XOR tree into it was a failing 450 MHz path).

## Clocks

| clock | | from |
|---|---|---|
| core_clk | the accelerator (225 MHz, the target's `core_mhz`) | the block design's MMCM on XDMA's axi_aclk |
| core_clk2x | the pumped TMEM (twice core_clk: 450 MHz) | the same MMCM |
| uclk | the bridges' HBM AXI ports (4j, 4j + 2) and AXI halves (450 MHz: `UCLK_MHZ`) | the same MMCM |
| clk100 | the HBM's reference and APB clocks, the debug hub | the same MMCM |
| xdma_aclk | XDMA's AXI, the DMA SmartConnect, the DMA windows and their HBM ports (4j + 1) (250 MHz) | XDMA |

Each HBM AXI port takes its own clock (`otpu_hbm`'s per-port `aclk`; AMD PG276 "Clocking": the ports' clocks may be
asynchronous), as the equihash and SQRL-Ternary HBM tests clock each port from its own master. So the host's path
has no clock crossing at all: the SmartConnect, the windows' register slices and their HBM ports all run on
`xdma_aclk`. The HBM's global switch runs on the port clock the IP's `CLK_SEL_xx` picks (ports 8 and 24, bridge
ports, so uclk: PG276 asks for the fastest). With the SmartConnect's master side on uclk instead, its nodes' 450 MHz
paths kept the FK35 0.3 ns short.

One MMCM at VCO 900 MHz gives all four: core 225, core_clk2x and uclk 450, clk100 (a 200 MHz core would need two
fractional outputs). core_clk and core_clk2x share a `CLOCK_DELAY_GROUP`, set on their global buffers' nets inside
the clocking wizard (`sqrl_fk_top.tcl`): on the top's net segments Vivado accepted it and ignored it, and the two
clocks' roots landed apart (1.19 ns skew on every pumped-TMEM path at 225 MHz).

225 MHz takes two more things from the slice. `TMEM_RQL` 255 (the targets' uarch) registers every TMEM read port's
data, one more cycle of read latency in each unit (otpu_slice / otpu_tmem; the quantizer holds its reads, the VPU's
front end waits a cycle more, the DMA adds a stage, the MXU's TQ holds `rql_h`). With TMEM_IMPL 3 that register sits
at the UltraRAMs' outputs inside otpu_tmem (`QR`), ahead of the bank mux, so URAM -> unit is a full core period of
routing. And `make_defines.py` builds the collective without GATHER (`COLL_GATHER` 0, a barrier only: one slice has
nothing to gather), which takes its TMEM port away.

One bridge moves 64 bytes a uclk cycle on its two ports, 28.8 GB/s at 450 MHz, so the eight about 230 GB/s (the
HBM's 32 ports' peak is ~460 GB/s; one port a bridge: 14.4 and 115 GB/s). Port W's weight stream has the same
limit, 1 KiB a core cycle (230.4 GB/s at 225 MHz). Its reads in flight a channel (`NAT_XD`, 128 in the targets; the
adapter's default 64 covered ~285 ns of the ~425 ns round trip at 225 MHz) set what it reaches: ~185 GB/s on the
card. A PCIe link reset restarts the MMCM and so the HBM.
The bridges' AXI side stays in reset until both stacks have calibrated (`apb_complete_0/1`); a catastrophic
temperature trip clears the board's CALIB, and otpu_board then refuses RUN and LOAD.

The top's crossings (`sqrl_fk_top.tcl`) follow the BCU1525 WG top's rules: no clock pair is declared asynchronous
(the bridges' `set_max_delay -datapath_only` would be overridden), each synchronizer's first stage is a false path,
and each bridge's posted-beat count into the adapter gets one uclk period and a bus skew. A constraint file's miss
stops the implementation before `opt_design` (`sqrl_fk_check.tcl`).

## Floorplan

Both HBM stacks sit at the bottom edge of SLR0, and so does the PCIe block (clock region X7Y0).

- FK35: `pblock_slice` puts the accelerator (`u_sys/u_board`), its reset stages and the bridges' core halves in
  SLR1. Each bridge's pipeline (`otpu_hbm_ln`, N 5: `RLY` 55555555) has stage 0 with the core half, stages 1 and 2
  (each way) as the SLR crossing's Laguna TX / RX pair (`USER_SLL_REG`, in no pblock: an SLR pblock has no Laguna
  sites), stages 3 and 4 in SLR0 and stage N with the placer beside the AXI half. N 5 puts a register ahead of the
  crossing pair (with N 4 the core half's logic fed the TX register directly, -0.4 ns). `FP=soft` makes the pblocks
  soft, `FP=none` drops them.
- FK33: one SLR, no accelerator pblock.
- Gen4 (both): XDMA and the SmartConnect's 512-bit entry (its S00 entry pipeline and nodes) in a hard pblock
  `pb_xdma` (X6Y0:X7Y3 + X3Y3:X5Y3); the SmartConnect's master nodes stay free to sit toward the HBM ports. The
  fork's FK35 builds needed it: unconstrained, XDMA (54k LUTs at Gen4) spread among the channels and their paths
  failed.

## The wide slice (sqrl-fk35w, experimental)

The FK35 above uses 16 of the HBM's 32 AXI ports for the slice, and its intake (port W: WG x D = 1 KiB a core cycle)
matches them. `sqrl-fk35w` doubles both: one MCOLS 16 / WG 16 slice (2 KiB a step; the SE engine, VPU, sequencer,
DMA, TMEM and quantizer as the FK35's) on 16 channels of 512 MiB. Channel c is a bridge on ports 2c and 2c + 1 (NP 2),
each port on its own pseudo-channel, so nothing crosses the HBM's switches. The top's `NCH` 16 (needs `HNP` 2) sets
it; `make_defines.py` writes `SNCH` 16 and 16 bridges' pipelines (`RLY` 64 bits).

The host keeps its 8 DMA windows of 1 GiB (the block design is the FK35's): window k shares port 4k + 1 with channel
2k's second port through `otpu_axi3_hmux` (`rtl/boards/sqrl-fk`): the bridge's requests carry AXI ID 0, the host's
ID 1, and R and B return by ID; the host's side crosses from XDMA's clock to uclk in `otpu_afifo`s (constrained by
`constraints/otpu_axi3_hmux.tcl`, scoped), and a FIFO keeps W in AW order. Window k then holds channels 2k and 2k + 1
(`opentpu.host.board`'s sqrlfk map at 16 channels).

The MXU at WG 16 (otpu_mxu: a group's scale lines GSL = WG / 4, 4-bit entries over four lines) runs int8, int4 and
fp4 bit for bit with the ISA; NVFP4 at WG 16 is refused (two beats a chunk). The board model at 16 channels streams
fp4 at 396 GB/s (`board_perf.py --sim`, 128 MiB; the FK35's 207).

Status: it does not route. In Vivado 2019.2 the slice and the bridges' core halves fill SLR1 (their 1024-bit channel
boundary would need ~32K SLLs to move, 23K exist): with `SE_R` 1 and the MXU's result FIFO in block RAM (the target's
area cuts) placement reaches 95.8% of SLR1's CLB sites, timing after physical optimization core -0.41 ns, uclk -0.69,
core_clk2x -0.07, xdma +0.08, and the router stops on congestion (Route 35-447). The congestion sits over the MXU's
DSP / UltraRAM / block RAM columns (94-100% used locally), not general logic: the next step is moving the MXU's chunk
FIFOs (240 UltraRAMs) to SLR0, which has all of its DSPs and UltraRAM free.

## Building

```
TARGET=sqrl-fk35 boards/sqrl-fk/run_vivado.sh           # or sqrl-fk33, sqrl-fk35w; STEP=synth for synthesis only
```

`run_vivado.sh` writes `OUT/otpu_sqrl_fk_defines.vh` and `OUT/fk_params.tcl` (`scripts/make_defines.py`), checks
that this Vivado has the part and a license for it (`scripts/preflight.tcl`), creates the project
(`vivado/create_project.tcl`: the HBM IP, the block design, the RTL, the constraints) and builds it
(`vivado/build.tcl`: reports, `otpu.bit`, `otpu.ltx` for the HBM IP's debug core, and the flash image
`otpu_primary.mcs` / `otpu_secondary.mcs`). Knobs: `CORE_MHZ`, `UCLK_MHZ`, `RLY`, `PCIE_GEN=3`, `FP`, `FAST=1`,
`IMPL_STRATEGY`, `SET="K=V ..."` (otpu_board's parameters), `STEP=impl` (re-implement a finished synthesis).

`build.tcl` runs the project's `impl_1` only to `opt_design` (its link reads the late constraint files, its pre-hook
`sqrl_fk_check.tcl` stops the run if one missed) and then places and routes in its own session with
`vivado/impl_np.tcl`, Vivado's non-project flow on that checkpoint: 2019.2's `impl_1` placer and `phys_opt_design`
timed this design wrongly (a constant WNS +1.954 while the clocks failed by up to 1.7 ns) and so skipped its
critical paths. `impl_np.tcl` also forces replication of the uclk fan-outs the routed builds showed long (each bridge
core half's `a_hold` and `a_rs2`, its read FIFOs' write enables, the SmartConnect's master-node resets) and prints
each stage's WNS / WHS per clock. `OTPU_PLACE_DIRECTIVE` (environment) picks the placer directive (default
`AltSpreadLogic_high`). Placement varies by up to ~0.1 ns at the end between directives and runs: of five FK35 runs of
one netlist, `ExtraPostPlacementOpt` closed at 450 MHz (uclk +0.005 ns) and the others ended 0.05-0.07 ns short on
uclk only (`SSI_SpreadLogic_high` and `SSI_BalanceSLLs` placed identically). If a build misses by a few tens of ps,
re-place its `otpu_fpga_top_sqrl_fk_opt.dcp` with another directive before changing the design.

Vivado 2019.2 builds it, the version whose HBM IP and XDMA the fork's FK35 builds closed timing with. The core RTL
takes no typed `string` parameters for it (2019.2 does not elaborate them); the block design's wrapper lands under
`.srcs` there and under `.gen` in later versions, and the project takes either.

## Loading and the host

Load `otpu.bit` over JTAG (Vivado's hardware manager) and rescan the PCIe bus, or write the two `.mcs` files to the
card's flashes. On Linux, `opentpu/host/setup_pcie.sh` binds XDMA to the card (SQRL's 1e24:1533 included). Restart
the host fully (not a warm reboot) after flashing: the FK35's slot trained Gen3 x4 after every hot retrain and Gen4
only after a full restart.

## Verification

- `tests/test_sqrlfk_board.py`: the targets; the FK33 is the FK35's design; both drive two HBM ports a channel; the
  top lints in Verilator against the block design's ports (`boards/sqrl-fk/sim/otpu_bd_wrapper_stub.sv`, checked
  against 2019.2's generated wrapper) and the HBM IP's (`hbm_0_stub.sv`) at one and two ports a channel; tiny Qwen3
  (int8) and Qwen3.5 (fp4) images run bit for bit against the ISA simulator on the board model (otpu_sqrl_fk_sys
  before sixteen HBM port models, two a channel each on its half of the channel's image, with their latency,
  jitter and stalls; and at one port a channel). `tests/test_chilv.py`: the host's two-port layout.
- `tools/exp/hbmch_test.py`: the bridge alone before its port models, at one port and two (builds `np2*`: plain,
  half beats, the FK35's and the FK33's, a small deskew FIFO, 128 reads in flight), every scenario passing. Sequential
  posted reads, a beat a core cycle asked for (tb_hbmch): at 150 MHz one port carries 75% of them (its port 100% busy),
  two 100%; at 200 MHz two carry 100% (128 reads in flight; 87% with 64), at 250 MHz both ports are full (28.8 GB/s).
  Plain reads (sources 0-2, 32 read credits) stay at ~47% of the core's rate at 150 MHz (one port: 50%).
- FK35 timing (Vivado 2019.2, Gen4 x8, uclk 450 MHz), one HBM port a channel (r10c): met on every clock. uclk +0.005
  ns, core_clk +0.059, core_clk2x +0.291, xdma_aclk +0.019, pipe_clk +0.005, the PCIe transceivers' TXOUTCLK +0.029,
  hold +0.002 ns. Two ports a channel (r11, the targets' default; the same placer directive): met on every clock too.
  uclk +0.013 ns, core_clk +0.185, core_clk2x +0.408, xdma_aclk +0.068, pipe_clk +0.026, TXOUTCLK +0.022, hold
  +0.004 ns; synthesis 374k LUTs (43%), 424k FFs, 502 RAMB36 (each bridge 4.8k LUTs and 8 RAMB36, its two deskew
  FIFOs), 6,696 signals across the SLR boundary. On the FK35 (2026-11-19, flashed, Gen4 x4): `otpu-selftest` ALL PASS
  on all 8 channels through the host's two-port layout, and its model stage on Qwen3.5-0.8B ALL PASS in int8 and fp4
  (bit for bit): decode 1.34 / 1.09 Mcycles a token (one port: 1.53 / 1.18), prefill 0.83 / 0.69. The host's DMA,
  split into two calls a transfer and a gather copy, measured 1.63 GB/s host->card and 2.10 card->host (one port: 2.44
  / 5.31).
- FK33: synthesis only. At 79% of the xcvu33p's LUTs its implementation did not route at 450 MHz (congestion).
- On the FK35 (2026-11-19, the one-port build flashed to both QSPI flashes, PCIe Gen4 x4 in this PC's slot): `otpu-selftest`
  ALL PASS (all 8 HBM channels; host->card 2.44 GB/s, card->host 5.31 GB/s), and its model stage on Qwen3.5-0.8B ALL
  PASS in int8 and fp4 ("The capital of France is Paris.", bit for bit with the ISA simulator): decode 1.53 / 1.18
  Mcycles a token, ~98 / ~127 tokens/s at 150 MHz.
- `tools/qual/perf.py` on Qwen3.5-9B, fp4 layers and head (same card): prefill 512 tokens 36.8 tokens/s on the device;
  decode 7.23 Mcycles a token = 20.75 tokens/s on the device (13.1 wall, the host's argmax loop), MXU_STARVE 1%,
  DRAM_WAIT 5%. perf's DRAM_RD (299 MB a token, 6.5 GB/s) does not count port W's posted reads: the weights are ~4 GB a
  token. `tools/board_perf.py wstream` measured port W's stream at 98 GB/s (fp4; 104 int8), ~85% of the eight one-port
  bridges' 115 GB/s, and `tools/q35_trace.py card` (the 9B cut to 4 and 8 layers) put 84% of a decode token in that
  stream: the HBM side was the limit.
- Two ports a channel (r11, same card, same tools): `wstream` 130.6 GB/s fp4 (+33%), 135.9 int8 (+31%), ~85% of port
  W's 153.6 GB/s at 150 MHz, now the limit (the eight bridges' 230 GB/s are not). Qwen3.5-9B fp4: decode 5.62 Mcycles a
  token = 26.69 tokens/s on the device (+29%; 24.4 wall), prefill 37.8 tokens/s. A faster core clock raises port W's
  ceiling next.
- 225 MHz (the targets' clock now; Vivado 2019.2, `AltSpreadLogic_high`), r16: every clock met, WNS +0.007 ns, WHS
  +0.003; core_clk +0.008, core_clk2x +0.015, uclk +0.011, xdma_aclk +0.021, pipe_clk +0.024, TXOUTCLK +0.007. 328k
  LUTs (38%), 398k FFs, 474 RAMB36, 156 URAM, 1,502 DSPs. On the way there core_clk ended -1.09 ns without the
  clock-delay-group fix (and no TMEM_RQL), -0.27 with it, -0.10 with TMEM_RQL's register after the bank mux instead
  of at the RAMs.
- On the FK35 (2026-11-21, r16 flashed, Gen4 x4): `otpu-selftest` ALL PASS at core 225 MHz, its Qwen3.5-0.8B model
  stage ALL PASS in int8 and fp4 (one-token runs 1.42 / 1.19 Mcycles). `wstream` 184.7 GB/s fp4 (1 GiB), 197.3 int8
  (130.6 / 135.9 at 150 MHz; 153.9 / 164.1 at 225 MHz with NAT_XD 64). `tools/qual/perf.py`, tokens/s on the device
  (decode fp4 and int8, prefill of 512 tokens fp4):

  | Qwen3.5 | fp4 | int8 | prefill fp4 |
  |---|---:|---:|---:|
  | 0.8B | 197.7 | 166.3 | 296 |
  | 2B | 141.1 | 93.7 | 207 |
  | 4B | 68.3 | 35.9 | 87 |
  | 9B | 35.2 (wall 33.1) | (11.7 GB image: does not fit) | 52.6 |

  The 9B's decode gained 14% for the stream's 20%: about a quarter of its token is not the weight stream.
- The wide slice: `tests/test_sqrlfk_board.py` lints its top (NCH 16) against the block design's and the HBM IP's
  ports, stresses `otpu_axi3_hmux` (`sim/verilator/tb_hmux.sv`: a bridge and a host master on their own clocks, a
  port that interleaves the IDs' R and B, random stalls, every read checked) and runs tiny Qwen3 int8 and Qwen3.5
  fp4 bit for bit on its board model (32 HBM port models); `tests/test_wg_rtl.py`'s WG 16 grouped MMs. Not yet on the
  card (see "The wide slice").
