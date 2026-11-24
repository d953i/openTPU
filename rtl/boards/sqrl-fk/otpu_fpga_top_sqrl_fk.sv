// FPGA top for the SQRL Forest Kitten boards, FK33 (xcvu33p, one SLR) and FK35 (xcvu35p, two SLRs): the same
// PCB with 8 GB HBM2 and a PCIe x16 edge (8 lanes used; docs/sqrl-fk.md). The block design otpu_bd (XDMA, the
// clocks, the SYSMON, the control interconnect and XDMA's DMA split onto the 8 channels' windows:
// boards/sqrl-fk/vivado/bd.tcl), the HBM IP (otpu_hbm: hbm_0 with its 32 AXI3 ports as arrays) and
// otpu_sqrl_fk_sys (the accelerator at WG 8 and its 8 channel bridges, otpu_hbm_ch).
//
// Channel j (targets/sqrl-fk3[35].toml: 8 channels of 1 GiB) is HBM bytes j x 1 GiB .. + 1 GiB, the four
// pseudo-channels of mini-switch j (ports 4j .. 4j + 3). Its bridge drives port 4j, the host's DMA window j
// (the block design's M_AXI_DMA<j>: AXI3 256-bit on XDMA's clock, the window's full HBM address) port 4j + 1: both
// stay in the mini-switch. HNP 2 (two HBM ports a channel, otpu_sqrl_fk_sys HNP): the bridge drives ports 4j and
// 4j + 2 in lockstep, the channel's low and high 512 MiB (its bytes interleaved at 32 over them: CAPS2 bit26, the
// host lays its window out alike); HNP 1, port 4j alone. The rest (4j + 3; 4j + 2 at HNP 1) are tied off. The
// HBM's global switches are on.
//
// NCH 16 (the FK35's wide slice, targets/sqrl-fk35w.toml: 16 channels of 512 MiB, HNP 2): channel c's bridge drives
// ports 2c and 2c + 1, each port its own pseudo-channel (otpu_hbm_ch NP 2's halves are 256 MiB there: port l at the
// channel's byte l x 256 MiB, PC 2c + l), so no bridge crosses the HBM's switch and all 32 ports carry the slice. The
// host's window k still enters at port 4k + 1 (mini-switch k: its 1 GiB, channels 2k and 2k + 1), now shared with
// channel 2k's second port through otpu_axi3_hmux (by AXI ID; the host's side across from XDMA's clock in its FIFOs):
// every port on uclk.
//
// Clocks (bd.tcl): everything from XDMA's axi_aclk (250 MHz; the card has no other clock input): core_clk
// (CORE_KHZ) and core_clk2x (the pumped TMEM's), uclk (the bridges' HBM AXI ports and their AXI side) and
// clk100 (the HBM's reference and APB clock); the host's DMA windows' HBM ports run on XDMA's axi_aclk itself. A PCIe link reset restarts the HBM too. Resets: core_rst
// from the block design (MMCM lock, axi_aresetn); the bridges' AXI side stays in reset until both stacks
// have calibrated (apb_complete_0/1, from the APB clock): u_rst, a register the tools may replicate (a
// gate on the reset block's output fanned out to every channel failed at Gen4, f35d000c).
//
// otpu_board's parameters come in OTPU_BOARD (opentpu.host.boardmacro board_defines through the build's
// defines file, boards/sqrl-fk/scripts/make_defines.py), as the BCU1525's WG builds take theirs.
module otpu_fpga_top_sqrl_fk #(
  parameter int CORE_KHZ   = 150000,        // core_clk as the block design makes it
  parameter int DDR_MTS    = 1800,          // HBM2 at 900 MHz (DDR_MTS register)
  parameter int PCIE_LANES = 8,
  parameter int CAW        = 23,            // the channels' beat address bits (1 GiB of 128-byte beats)
  parameter logic [63:0] RLY = 64'h0,       // the bridges' pipelines between their halves (otpu_hbm_ch N, 4 bits a
                                            //   channel: the FK35's slice in SLR1, the HBM in SLR0)
  parameter int HNP        = 1,             // HBM ports a channel's bridge drives (1, or 2: 4j and 4j + 2)
  parameter int NCH        = 8              // the slice's channels: 8 (one a mini-switch), or 16 (HNP 2, one a
                                            //   pseudo-channel pair: every HBM port a bridge's)
) (
  output logic [6:0]  led,                  // 0..3 green, 4..6 the RGB LED (high: on)
  output logic        pcie_clkreq,
  input  logic        pcie_refclk_p,
  input  logic        pcie_refclk_n,
  input  logic        pcie_perst_n,
  input  logic [PCIE_LANES-1:0] pcie_mgt_rxp,
  input  logic [PCIE_LANES-1:0] pcie_mgt_rxn,
  output logic [PCIE_LANES-1:0] pcie_mgt_txp,
  output logic [PCIE_LANES-1:0] pcie_mgt_txn
);
  localparam int NW  = 8;                   // the host's DMA windows (one an HBM mini-switch)
  localparam int NP  = 32;                  // the HBM IP's AXI ports
  localparam int OAW = 33;                  // its address bits (8 GB)
  localparam bit WIDE = NCH == 16;          // every port a bridge's, the host's windows shared (otpu_axi3_hmux)
  initial if (!(NCH == 8 || (NCH == 16 && HNP == 2)))
    $fatal(1, "otpu_fpga_top_sqrl_fk: NCH %0d at HNP %0d (8, or 16 at HNP 2)", NCH, HNP);
  logic        core_clk, core_clk2x, core_rstn, uclk, urstn, clk100, clk100_rstn, xdma_aclk, xdma_aresetn;
  logic        pcie_link_up;
  logic [9:0]  device_temp;                 // SYSMONE4 die-temperature code (core_clk)
  logic [31:0] ctl_awaddr, ctl_araddr, ctl_wdata, ctl_rdata;
  logic [3:0]  ctl_wstrb;
  logic [1:0]  ctl_bresp, ctl_rresp;
  logic ctl_awvalid, ctl_awready, ctl_wvalid, ctl_wready, ctl_bvalid, ctl_bready;
  logic ctl_arvalid, ctl_arready, ctl_rvalid, ctl_rready;
  // the host's DMA windows (AXI3 256-bit, xdma_aclk; bd.tcl)
  logic [NW-1:0][OAW-1:0] dm_awaddr, dm_araddr;
  logic [NW-1:0][3:0]     dm_awlen, dm_arlen;
  logic [NW-1:0][2:0]     dm_awsize, dm_arsize;
  logic [NW-1:0][1:0]     dm_awburst, dm_arburst, dm_bresp, dm_rresp;
  logic [NW-1:0][255:0]   dm_wdata, dm_rdata;
  logic [NW-1:0][31:0]    dm_wstrb;
  logic [NW-1:0] dm_awvalid, dm_awready, dm_wvalid, dm_wready, dm_wlast, dm_bvalid, dm_bready;
  logic [NW-1:0] dm_arvalid, dm_arready, dm_rvalid, dm_rready, dm_rlast;
`define BD_DMA(J) \
    .M_AXI_DMA``J``_awaddr(dm_awaddr[J]), \
    .M_AXI_DMA``J``_awlen(dm_awlen[J]), .M_AXI_DMA``J``_awsize(dm_awsize[J]), \
    .M_AXI_DMA``J``_awburst(dm_awburst[J]), \
    .M_AXI_DMA``J``_awvalid(dm_awvalid[J]), .M_AXI_DMA``J``_awready(dm_awready[J]), \
    .M_AXI_DMA``J``_wdata(dm_wdata[J]), .M_AXI_DMA``J``_wstrb(dm_wstrb[J]), \
    .M_AXI_DMA``J``_wlast(dm_wlast[J]), .M_AXI_DMA``J``_wvalid(dm_wvalid[J]), \
    .M_AXI_DMA``J``_wready(dm_wready[J]), \
    .M_AXI_DMA``J``_bresp(dm_bresp[J]), \
    .M_AXI_DMA``J``_bvalid(dm_bvalid[J]), .M_AXI_DMA``J``_bready(dm_bready[J]), \
    .M_AXI_DMA``J``_araddr(dm_araddr[J]), \
    .M_AXI_DMA``J``_arlen(dm_arlen[J]), .M_AXI_DMA``J``_arsize(dm_arsize[J]), \
    .M_AXI_DMA``J``_arburst(dm_arburst[J]), \
    .M_AXI_DMA``J``_arvalid(dm_arvalid[J]), .M_AXI_DMA``J``_arready(dm_arready[J]), \
    .M_AXI_DMA``J``_rdata(dm_rdata[J]), \
    .M_AXI_DMA``J``_rresp(dm_rresp[J]), \
    .M_AXI_DMA``J``_rlast(dm_rlast[J]), .M_AXI_DMA``J``_rvalid(dm_rvalid[J]), \
    .M_AXI_DMA``J``_rready(dm_rready[J])
  otpu_bd_wrapper u_bd (
    .pcie_refclk_clk_p(pcie_refclk_p), .pcie_refclk_clk_n(pcie_refclk_n),
    .pcie_perstn(pcie_perst_n),
    .pcie_mgt_rxp, .pcie_mgt_rxn, .pcie_mgt_txp, .pcie_mgt_txn,
    .pcie_link_up, .core_clk, .core_clk2x, .core_rstn, .uclk, .urstn, .clk100, .clk100_rstn,
    .xdma_aclk, .xdma_aresetn, .device_temp,
    .M_AXI_CTL_awaddr(ctl_awaddr), .M_AXI_CTL_awvalid(ctl_awvalid), .M_AXI_CTL_awready(ctl_awready),
    .M_AXI_CTL_wdata(ctl_wdata), .M_AXI_CTL_wstrb(ctl_wstrb), .M_AXI_CTL_wvalid(ctl_wvalid),
    .M_AXI_CTL_wready(ctl_wready), .M_AXI_CTL_bresp(ctl_bresp), .M_AXI_CTL_bvalid(ctl_bvalid),
    .M_AXI_CTL_bready(ctl_bready), .M_AXI_CTL_araddr(ctl_araddr), .M_AXI_CTL_arvalid(ctl_arvalid),
    .M_AXI_CTL_arready(ctl_arready), .M_AXI_CTL_rdata(ctl_rdata), .M_AXI_CTL_rresp(ctl_rresp),
    .M_AXI_CTL_rvalid(ctl_rvalid), .M_AXI_CTL_rready(ctl_rready),
    `BD_DMA(0), `BD_DMA(1), `BD_DMA(2), `BD_DMA(3), `BD_DMA(4), `BD_DMA(5), `BD_DMA(6), `BD_DMA(7));
`undef BD_DMA
  assign pcie_clkreq = 1'b0;
  logic core_rst, xrst;
  always_ff @(posedge core_clk) core_rst <= !core_rstn;
  // the accelerator's reset through three more stages, the last replicated by its loads (as upstream's BCU1525 WG
  // top, acc_rst_p): one register into the whole slice became a global buffer from SLR0 across into SLR1, 7.6 ns
  // of route (the port's first FK35 placement, -1.72 ns at 150 MHz). The floorplan puts the stages in SLR1.
  (* shreg_extract = "no", max_fanout = 256 *) logic [2:0] core_rst_p = '1;
  always_ff @(posedge core_clk) core_rst_p <= {core_rst_p[1:0], core_rst};
  always_ff @(posedge xdma_aclk) xrst <= !xdma_aresetn;
  (* ASYNC_REG = "TRUE" *) logic lrs1 = 1'b1, lrs2 = 1'b1;
  always_ff @(posedge core_clk) begin lrs1 <= xrst; lrs2 <= lrs1; end

  // ---- HBM: both stacks calibrated (apb_complete, from the APB clock) releases the bridges' AXI side
  logic [1:0] hbm_calib, hbm_cattrip;
  (* ASYNC_REG = "TRUE" *) logic [1:0] hcal_u1 = '0, hcal_u2 = '0;
  always_ff @(posedge uclk) begin hcal_u1 <= hbm_calib; hcal_u2 <= hcal_u1; end
  (* max_fanout = 64 *) logic u_rst = 1'b1;
  always_ff @(posedge uclk) u_rst <= !urstn || !(&hcal_u2);
  // and the host's DMA windows' register slices (xdma_aclk) the same way
  (* ASYNC_REG = "TRUE" *) logic [1:0] hcal_x1 = '0, hcal_x2 = '0;
  always_ff @(posedge xdma_aclk) begin hcal_x1 <= hbm_calib; hcal_x2 <= hcal_x1; end
  (* max_fanout = 64 *) logic x_rst = 1'b1;
  always_ff @(posedge xdma_aclk) x_rst <= !xdma_aresetn || !(&hcal_x2);
  // each HBM port's clock and reset (otpu_hbm): the bridges' (4j) on uclk, the host's DMA windows' (4j + 1) on
  // XDMA's clock, as their SmartConnect (no crossing anywhere on the host's path: sc_dma's crossing into uclk, its
  // master side at 450 MHz, failed timing; as the equihash HBM test, each port on its own master's clock).
  // Unused ports on uclk. NCH 16: every port on uclk (the host's windows cross in otpu_axi3_hmux).
  // The uclk ports' ARESET_N: urstn (the block design's reset, one flip-flop) through a register and then one
  // register a port (dont_touch: not merged back into one), each placed by its port: urstn straight to every HBM
  // port's pin was 2.0 - 2.3 ns of route (FK35 r14 at 450 MHz: rst_uclk -> AXI_00 / AXI_15 ARESET_N, -0.318 ns).
  // Two cycles later than urstn, long before calibration releases the bridges (u_rst).
  logic urstn_q = 1'b0;
  (* dont_touch = "true", shreg_extract = "no" *) logic [NP-1:0] hp_urstn = '0;
  always_ff @(posedge uclk) begin
    urstn_q  <= urstn;
    hp_urstn <= {NP{urstn_q}};
  end
  logic [NP-1:0] hp_aclk, hp_aresetn;
  for (genvar p = 0; p < NP; p++) begin : g_pclk
    assign hp_aclk[p]    = p % 4 == 1 && !WIDE ? xdma_aclk : uclk;
    assign hp_aresetn[p] = p % 4 == 1 && !WIDE ? xdma_aresetn : hp_urstn[p];
  end
  logic [NP-1:0][OAW-1:0] h_awaddr, h_araddr;
  logic [NP-1:0][5:0]     h_awid, h_arid, h_bid, h_rid;
  logic [NP-1:0][3:0]     h_awlen, h_arlen;
  logic [NP-1:0][2:0]     h_awsize, h_arsize;
  logic [NP-1:0][1:0]     h_awburst, h_arburst, h_bresp, h_rresp;
  logic [NP-1:0]          h_awvalid, h_awready, h_wvalid, h_wready, h_wlast;
  logic [NP-1:0]          h_bvalid, h_bready, h_arvalid, h_arready, h_rvalid, h_rready, h_rlast;
  logic [NP-1:0][255:0]   h_wdata, h_rdata;
  logic [NP-1:0][31:0]    h_wstrb, h_wpar;
  otpu_hbm #(.NHP(NP), .AAW(OAW)) u_hbm (
    .hbm_ref(clk100), .aclk(hp_aclk), .aresetn(hp_aresetn), .pclk(clk100), .presetn(clk100_rstn),
    .h_awaddr, .h_awburst, .h_awid, .h_awlen, .h_awsize, .h_awvalid, .h_awready,
    .h_wdata, .h_wlast, .h_wstrb, .h_wpar, .h_wvalid, .h_wready, .h_bready, .h_bid, .h_bresp, .h_bvalid,
    .h_araddr, .h_arburst, .h_arid, .h_arlen, .h_arsize, .h_arvalid, .h_arready,
    .h_rready, .h_rdata, .h_rid, .h_rlast, .h_rresp, .h_rvalid,
    .calib(hbm_calib), .cattrip(hbm_cattrip), .temp0(), .temp1());

  // ---- the accelerator and its channel bridges (calib: both stacks up and no catastrophic temperature
  // trip; otpu_board refuses RUN and LOAD without it and synchronizes it); b_*[HNP j + l]: channel j's port l
  localparam int NB = NCH * HNP;
  initial if (HNP != 1 && HNP != 2) $fatal(1, "otpu_fpga_top_sqrl_fk: HNP %0d (1 or 2)", HNP);
  logic [NB-1:0]          b_awvalid, b_awready, b_wvalid, b_wready, b_wlast, b_bvalid, b_bready;
  logic [NB-1:0]          b_arvalid, b_arready, b_rvalid, b_rready, b_rlast;
  logic [NB-1:0][OAW-1:0] b_awaddr, b_araddr;
  logic [NB-1:0][3:0]     b_awlen, b_arlen;
  logic [NB-1:0][255:0]   b_wdata, b_rdata;
  logic [NB-1:0][31:0]    b_wstrb;
  logic [NB-1:0][1:0]     b_bresp, b_rresp;
  logic [2:0] board_led;
  otpu_sqrl_fk_sys #(.NCH(NCH), .CB(128), .CAW(CAW), .OAW(OAW), .CORE_KHZ(CORE_KHZ), .DDR_MTS(DDR_MTS),
                     .RLY(RLY[4*NCH-1:0]), .HNP(HNP)) u_sys (
    .clk(core_clk), .clk_f(core_clk2x), .rst(core_rst_p[2]), .ctl_mrst(lrs2), .aclk(uclk), .arst(u_rst),
    .calib(&hbm_calib && !(|hbm_cattrip)), .temp({device_temp, 2'b00}), .led(board_led),
    .s_ctl_awaddr(ctl_awaddr[11:0]), .s_ctl_awvalid(ctl_awvalid), .s_ctl_awready(ctl_awready),
    .s_ctl_wdata(ctl_wdata), .s_ctl_wstrb(ctl_wstrb), .s_ctl_wvalid(ctl_wvalid),
    .s_ctl_wready(ctl_wready), .s_ctl_bresp(ctl_bresp), .s_ctl_bvalid(ctl_bvalid),
    .s_ctl_bready(ctl_bready), .s_ctl_araddr(ctl_araddr[11:0]), .s_ctl_arvalid(ctl_arvalid),
    .s_ctl_arready(ctl_arready), .s_ctl_rdata(ctl_rdata), .s_ctl_rresp(ctl_rresp),
    .s_ctl_rvalid(ctl_rvalid), .s_ctl_rready(ctl_rready),
    .m_awvalid(b_awvalid), .m_awready(b_awready), .m_awaddr(b_awaddr), .m_awlen(b_awlen),
    .m_wvalid(b_wvalid), .m_wready(b_wready), .m_wdata(b_wdata), .m_wstrb(b_wstrb), .m_wlast(b_wlast),
    .m_bvalid(b_bvalid), .m_bready(b_bready), .m_bresp(b_bresp),
    .m_arvalid(b_arvalid), .m_arready(b_arready), .m_araddr(b_araddr), .m_arlen(b_arlen),
    .m_rvalid(b_rvalid), .m_rready(b_rready), .m_rdata(b_rdata), .m_rresp(b_rresp), .m_rlast(b_rlast));

  // WDATA_PARITY tied low on every port: the HBM IP's parity is off (create_project.tcl leaves every
  // USER_MC*_USER_PARITY_EN / *_DQ_PARITY_EN false), so the IP does not use it, and an XOR tree on each bridge
  // port's register-slice output into the HBM block was the port's worst 450 MHz path (FK35 r6, -0.079 ns). The
  // block-design HBM designs on this card (the equihash HBM test, SQRL-Ternary's hbmtest) leave it low too.
  // the bridges' ports (b_*[HNP j + l], channel j's port l): ID 0, 32-byte beats, INCR; R and B taken every cycle.
  // HBM port 4j + 2l (NCH 8), or HNP j + l itself (NCH 16: channel c on ports 2c, 2c + 1); NCH 16's ports 4k + 1
  // go through window k's otpu_axi3_hmux below
  for (genvar j = 0; j < NCH; j++) begin : g_ch
    for (genvar l = 0; l < HNP; l++) begin : g_b
      localparam int Q = HNP * j + l, B = WIDE ? Q : 4 * j + 2 * l;
      if (!(WIDE && B % 4 == 1)) begin : g_dir
        assign h_awaddr[B] = b_awaddr[Q];  assign h_awid[B] = '0;      assign h_awlen[B] = b_awlen[Q];
        assign h_awsize[B] = 3'd5;         assign h_awburst[B] = 2'b01; assign h_awvalid[B] = b_awvalid[Q];
        assign b_awready[Q] = h_awready[B];
        assign h_wdata[B] = b_wdata[Q];    assign h_wstrb[B] = b_wstrb[Q]; assign h_wlast[B] = b_wlast[Q];
        assign h_wvalid[B] = b_wvalid[Q];  assign h_wpar[B] = '0; assign b_wready[Q] = h_wready[B];
        assign b_bresp[Q] = h_bresp[B];    assign b_bvalid[Q] = h_bvalid[B]; assign h_bready[B] = b_bready[Q];
        assign h_araddr[B] = b_araddr[Q];  assign h_arid[B] = '0;      assign h_arlen[B] = b_arlen[Q];
        assign h_arsize[B] = 3'd5;         assign h_arburst[B] = 2'b01; assign h_arvalid[B] = b_arvalid[Q];
        assign b_arready[Q] = h_arready[B];
        assign b_rdata[Q] = h_rdata[B];    assign b_rresp[Q] = h_rresp[B]; assign b_rlast[Q] = h_rlast[B];
        assign b_rvalid[Q] = h_rvalid[B];  assign h_rready[B] = b_rready[Q];
      end
    end
  end
  for (genvar k = 0; k < NW; k++) begin : g_win
    localparam int H = 4 * k + 1;               // the host's port
    // the host's DMA window k on XDMA's clock (250 MHz), through a register slice (all five channels, R and B
    // with skid buffers: the SmartConnect may hold them). Two slices: the SmartConnect sits by XDMA (pb_xdma) and
    // the HBM ports along the bottom edge; at uclk (450 MHz) one slice left the port's R at -0.75 ns (FK35), two
    // let the placer keep one by the port and one by the SmartConnect. The window has no AXI ID (in order), so
    // the slice's ID carries the burst's {AxBURST, AxSIZE}; the HBM port sees ID 0 (NCH 8: the port the window's
    // own), or the hmux's 1 (NCH 16).
    logic [5:0]   r_awid, r_arid;
    logic [33:0]  r_awaddr, r_araddr;
    logic [3:0]   r_awlen, r_arlen;
    logic [255:0] r_wdata, r_rdata;
    logic [31:0]  r_wstrb;
    logic [1:0]   r_bresp, r_rresp;
    logic r_awvalid, r_awready, r_wvalid, r_wready, r_wlast, r_bvalid, r_bready;
    logic r_arvalid, r_arready, r_rvalid, r_rready, r_rlast;
    otpu_axi3_rs #(.N(2), .RBP(1'b0)) u_hrs (.clk(xdma_aclk), .rst(x_rst),
      .s_awvalid(dm_awvalid[k]), .s_awready(dm_awready[k]), .s_awid({1'b0, dm_awburst[k], dm_awsize[k]}),
      .s_awaddr({1'b0, dm_awaddr[k]}), .s_awlen(dm_awlen[k]), .s_wvalid(dm_wvalid[k]), .s_wready(dm_wready[k]),
      .s_wdata(dm_wdata[k]), .s_wstrb(dm_wstrb[k]), .s_wlast(dm_wlast[k]), .s_bvalid(dm_bvalid[k]),
      .s_bready(dm_bready[k]), .s_bid(), .s_bresp(dm_bresp[k]), .s_arvalid(dm_arvalid[k]),
      .s_arready(dm_arready[k]), .s_arid({1'b0, dm_arburst[k], dm_arsize[k]}), .s_araddr({1'b0, dm_araddr[k]}),
      .s_arlen(dm_arlen[k]), .s_rvalid(dm_rvalid[k]), .s_rready(dm_rready[k]), .s_rid(), .s_rdata(dm_rdata[k]),
      .s_rresp(dm_rresp[k]), .s_rlast(dm_rlast[k]),
      .m_awvalid(r_awvalid), .m_awready(r_awready), .m_awid(r_awid), .m_awaddr(r_awaddr),
      .m_awlen(r_awlen), .m_wvalid(r_wvalid), .m_wready(r_wready), .m_wdata(r_wdata),
      .m_wstrb(r_wstrb), .m_wlast(r_wlast), .m_bvalid(r_bvalid), .m_bready(r_bready), .m_bid(6'd0),
      .m_bresp(r_bresp), .m_arvalid(r_arvalid), .m_arready(r_arready), .m_arid(r_arid),
      .m_araddr(r_araddr), .m_arlen(r_arlen), .m_rvalid(r_rvalid), .m_rready(r_rready), .m_rid(6'd0),
      .m_rdata(r_rdata), .m_rresp(r_rresp), .m_rlast(r_rlast));
    if (!WIDE) begin : g_own
      // the window's own port, on XDMA's clock
      assign h_awaddr[H] = r_awaddr[OAW-1:0]; assign h_awid[H] = '0;  assign h_awlen[H] = r_awlen;
      assign h_awsize[H] = r_awid[2:0];       assign h_awburst[H] = r_awid[4:3];
      assign h_awvalid[H] = r_awvalid;        assign r_awready = h_awready[H];
      assign h_wdata[H] = r_wdata;            assign h_wstrb[H] = r_wstrb; assign h_wlast[H] = r_wlast;
      assign h_wvalid[H] = r_wvalid;          assign h_wpar[H] = '0;     assign r_wready = h_wready[H];
      assign r_bvalid = h_bvalid[H];          assign r_bresp = h_bresp[H]; assign h_bready[H] = r_bready;
      assign h_araddr[H] = r_araddr[OAW-1:0]; assign h_arid[H] = '0;  assign h_arlen[H] = r_arlen;
      assign h_arsize[H] = r_arid[2:0];       assign h_arburst[H] = r_arid[4:3];
      assign h_arvalid[H] = r_arvalid;        assign r_arready = h_arready[H];
      assign r_rvalid = h_rvalid[H];          assign r_rdata = h_rdata[H]; assign r_rresp = h_rresp[H];
      assign r_rlast = h_rlast[H];            assign h_rready[H] = r_rready;
      // ports 4k + 3 (and 4k + 2 at HNP 1): unused
      for (genvar u = HNP + 1; u < 4; u++) begin : g_off
        localparam int P = 4 * k + u;
        assign h_awaddr[P] = '0;  assign h_awid[P] = '0;    assign h_awlen[P] = '0;
        assign h_awsize[P] = '0;  assign h_awburst[P] = '0; assign h_awvalid[P] = 1'b0;
        assign h_wdata[P] = '0;   assign h_wstrb[P] = '0;   assign h_wlast[P] = 1'b0;
        assign h_wvalid[P] = 1'b0; assign h_wpar[P] = '0;   assign h_bready[P] = 1'b1;
        assign h_araddr[P] = '0;  assign h_arid[P] = '0;    assign h_arlen[P] = '0;
        assign h_arsize[P] = '0;  assign h_arburst[P] = '0; assign h_arvalid[P] = 1'b0;
        assign h_rready[P] = 1'b1;
      end
    end else begin : g_mux
      // shared with bridge port H (channel 2k's second port) on uclk
      otpu_axi3_hmux #(.OAW(OAW)) u_hmux (.clk(uclk), .rst(u_rst), .hclk(xdma_aclk), .hrst(x_rst),
        .b_awvalid(b_awvalid[H]), .b_awready(b_awready[H]), .b_awaddr(b_awaddr[H]), .b_awlen(b_awlen[H]),
        .b_wvalid(b_wvalid[H]), .b_wready(b_wready[H]), .b_wdata(b_wdata[H]), .b_wstrb(b_wstrb[H]),
        .b_wlast(b_wlast[H]), .b_bvalid(b_bvalid[H]), .b_bready(b_bready[H]), .b_bresp(b_bresp[H]),
        .b_arvalid(b_arvalid[H]), .b_arready(b_arready[H]), .b_araddr(b_araddr[H]), .b_arlen(b_arlen[H]),
        .b_rvalid(b_rvalid[H]), .b_rready(b_rready[H]), .b_rdata(b_rdata[H]), .b_rresp(b_rresp[H]),
        .b_rlast(b_rlast[H]),
        .h_awvalid(r_awvalid), .h_awready(r_awready), .h_awaddr(r_awaddr[OAW-1:0]), .h_awlen(r_awlen),
        .h_awsize(r_awid[2:0]), .h_awburst(r_awid[4:3]), .h_wvalid(r_wvalid), .h_wready(r_wready),
        .h_wdata(r_wdata), .h_wstrb(r_wstrb), .h_wlast(r_wlast), .h_bvalid(r_bvalid), .h_bready(r_bready),
        .h_bresp(r_bresp), .h_arvalid(r_arvalid), .h_arready(r_arready), .h_araddr(r_araddr[OAW-1:0]),
        .h_arlen(r_arlen), .h_arsize(r_arid[2:0]), .h_arburst(r_arid[4:3]), .h_rvalid(r_rvalid),
        .h_rready(r_rready), .h_rdata(r_rdata), .h_rresp(r_rresp), .h_rlast(r_rlast),
        .m_awvalid(h_awvalid[H]), .m_awready(h_awready[H]), .m_awid(h_awid[H]), .m_awaddr(h_awaddr[H]),
        .m_awlen(h_awlen[H]), .m_awsize(h_awsize[H]), .m_awburst(h_awburst[H]), .m_wvalid(h_wvalid[H]),
        .m_wready(h_wready[H]), .m_wdata(h_wdata[H]), .m_wstrb(h_wstrb[H]), .m_wlast(h_wlast[H]),
        .m_bvalid(h_bvalid[H]), .m_bready(h_bready[H]), .m_bid(h_bid[H]), .m_bresp(h_bresp[H]),
        .m_arvalid(h_arvalid[H]), .m_arready(h_arready[H]), .m_arid(h_arid[H]), .m_araddr(h_araddr[H]),
        .m_arlen(h_arlen[H]), .m_arsize(h_arsize[H]), .m_arburst(h_arburst[H]), .m_rvalid(h_rvalid[H]),
        .m_rready(h_rready[H]), .m_rid(h_rid[H]), .m_rdata(h_rdata[H]), .m_rresp(h_rresp[H]),
        .m_rlast(h_rlast[H]));
      assign h_wpar[H] = '0;
    end
  end
  // LEDs: green 0 heartbeat, green 1 PCIe link up and both stacks calibrated, green 2 the accelerator runs or
  // halted cleanly; green 3 and the RGB LED off
  assign led = {4'b0000, board_led[2] | board_led[1], pcie_link_up & (&hbm_calib), board_led[0]};
endmodule
