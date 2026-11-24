// The SQRL Forest Kitten boards at WG 8, FK33 and FK35 (targets/sqrl-fk3[35].toml; docs/sqrl-fk.md): the
// same PCB and 8 GB HBM2 with a VU33P (one SLR) or a VU35P (two); the accelerator (otpu_board, one
// slice of NCH = 8 channels of CB = 128 bytes, the WG targets') on the card's HBM2. Channel j is an
// otpu_hbm_ch bridge (PC j: its beat m at byte j x 2^CL + m x CB, CL = CAW + log2(CB); its AXI3 side at
// aclk, 256 bits) through a register slice (otpu_axi3_rs, NRS of them; R and B as plain stages: the
// bridges take every beat) onto one AXI3 port of AMD's HBM IP, m_*[j]. The top puts channel j on the
// HBM's port 4j, in mini-switch j: the 1 GiB at j x 1 GiB is that mini-switch's four pseudo-channels,
// so the bridge never crosses the HBM's switch (the host's DMA window j is port 4j + 1, the same
// mini-switch, in the top). As otpu_bcu_wg_sys without its DIMMs' pairs, the governor, the BMC and the
// second card.
//
// CAW, the channels' beat address bits: 23 (1 GiB a channel, the card's 8 GB). otpu_board takes
// DRAM_LOG2 (the card's bytes) and CH_LOG2 (a channel's) from it here; its AW (the address registers'
// bits, at least DRAM_LOG2) comes in OTPU_BOARD.
//
// otpu_board's parameters other than this module's own are OTPU_BOARD's (opentpu.host.boardmacro
// board_defines: every otpu_board parameter of the target's rtl_params; the build's defines file,
// opentpu/host/board.py for the board model). Without it the module stops.
//
// Clocks: clk (the accelerator's, CORE_KHZ), clk_f (2 x clk, rising with it: TMEM_PMP 1), aclk (the
// bridges' AXI side and the HBM's AXI ports: a bridge's 256 bits move 32 bytes an aclk). arst: the
// HBM's ports in reset (any clock: the top's, the HBM uncalibrated or its AXI reset), through a
// synchronizer into the bridges' AXI halves and their register slices. calib: both stacks
// calibrated and no catastrophic temperature trip (any clock; otpu_board synchronizes it: STATUS
// CALIB). RLY[4 j +: 4]: channel j's bridge pipeline between its halves (otpu_hbm_ch N: the HBM in
// SLR0, the slice in SLR1), a far channel's W at half width.
//
// HNP 2 (two HBM ports a channel, otpu_hbm_ch NP 2): channel j's bridge on m_*[2 j] and m_*[2 j + 1]
// (the top's HBM ports 4j and 4j + 2: the mini-switch's two halves, its pseudo-channels 4j, 4j + 1
// and 4j + 2, 4j + 3), each burst on both, a native beat's bytes 32 l .. 32 l + 31 and 64 + 32 l ..
// on port l, at the channel's byte j x 2^CL + l x 2^(CL-1) + 64 m (CAPS2 bit26, CH_ILV: the host
// lays its windows out alike); its posted reads 2 writes a beat (otpu_board NAT_XQB 1). HNP 1: one
// port a channel, m_*[j], as before. At HNP 2 a bridge keeps 128 reads in flight (RCD; 64 at HNP 1): port W's
// posted stream at twice the rate over the same ~300 ns of HBM latency (tb_hbmch: 64 held it to 78% of the pair at
// a 250 MHz core, 128 fills it).
`ifndef OTPU_BOARD
`define OTPU_BOARD
`define OTPU_BOARD_UNSET
`endif
`ifndef OTPU_WPOST                // the board's NAT_WPOST (opentpu.host.boardmacro board_defines)
`define OTPU_WPOST 0
`endif
`ifndef OTPU_XPOST                // the board's NAT_XPOST
`define OTPU_XPOST 0
`endif
`ifndef OTPU_RHB                  // the board's NAT_RHB / NAT_WHB
`define OTPU_RHB 0
`endif
`ifndef OTPU_WHB
`define OTPU_WHB 0
`endif
`ifndef OTPU_XSW                  // log2 of the board's FIFO_DEPTH
`define OTPU_XSW 10
`endif
module otpu_sqrl_fk_sys #(
  parameter int NCH      = 8,
  parameter int CB       = 128,
  parameter int CAW      = 23,
  parameter int OAW      = 33,            // the HBM's AXI address bits (8 GB)
  parameter int CORE_KHZ = 150000,
  parameter int CORE_KHZ1 = CORE_KHZ,     // the fallback clock, or CORE_KHZ: none
  parameter int DDR_MTS  = 1800,
  parameter logic [4*NCH-1:0] RLY = '0,
  parameter int NRS      = 1,             // register slices between a bridge and its HBM port
  parameter int MWAIT    = 8,             // aclk cycles a partial burst waits (otpu_hbm_ch mwait)
  parameter int ARD      = 32,            // the bridges' read credits (with NAT_XPOST)
  parameter int HNP      = 1,             // HBM ports a channel (1, or 2: otpu_hbm_ch NP)
  parameter int RCD      = 0              // a bridge's reads in flight (otpu_hbm_ch RCD; 0: 128 at HNP 2, 64 at 1)
) (
  input  logic                    clk,
  input  logic                    clk_f,
  input  logic                    rst,
  input  logic                    ctl_mrst,     // the control master's reset, in clk (otpu_board)
  input  logic                    aclk,
  input  logic                    arst,
  input  logic                    calib,
  input  logic [11:0]             temp,
  output logic [2:0]              led,
  // control registers: AXI4-Lite slave, clk (BAR0 0x0)
  input  logic [11:0]             s_ctl_awaddr,
  input  logic                    s_ctl_awvalid,
  output logic                    s_ctl_awready,
  input  logic [31:0]             s_ctl_wdata,
  input  logic [3:0]              s_ctl_wstrb,
  input  logic                    s_ctl_wvalid,
  output logic                    s_ctl_wready,
  output logic [1:0]              s_ctl_bresp,
  output logic                    s_ctl_bvalid,
  input  logic                    s_ctl_bready,
  input  logic [11:0]             s_ctl_araddr,
  input  logic                    s_ctl_arvalid,
  output logic                    s_ctl_arready,
  output logic [31:0]             s_ctl_rdata,
  output logic [1:0]              s_ctl_rresp,
  output logic                    s_ctl_rvalid,
  input  logic                    s_ctl_rready,
  // the channels' HBM ports (AXI3 256-bit, aclk; AxSIZE 32 bytes, INCR, ID 0: the top's), HNP a
  // channel: port HNP j + l channel j's l. R and B are taken every cycle (m_rready, m_bready: 1)
  output logic [NCH*HNP-1:0]          m_awvalid,
  input  logic [NCH*HNP-1:0]          m_awready,
  output logic [NCH*HNP-1:0][OAW-1:0] m_awaddr,
  output logic [NCH*HNP-1:0][3:0]     m_awlen,
  output logic [NCH*HNP-1:0]          m_wvalid,
  input  logic [NCH*HNP-1:0]          m_wready,
  output logic [NCH*HNP-1:0][255:0]   m_wdata,
  output logic [NCH*HNP-1:0][31:0]    m_wstrb,
  output logic [NCH*HNP-1:0]          m_wlast,
  input  logic [NCH*HNP-1:0]          m_bvalid,
  output logic [NCH*HNP-1:0]          m_bready,
  input  logic [NCH*HNP-1:0][1:0]     m_bresp,
  output logic [NCH*HNP-1:0]          m_arvalid,
  input  logic [NCH*HNP-1:0]          m_arready,
  output logic [NCH*HNP-1:0][OAW-1:0] m_araddr,
  output logic [NCH*HNP-1:0][3:0]     m_arlen,
  input  logic [NCH*HNP-1:0]          m_rvalid,
  output logic [NCH*HNP-1:0]          m_rready,
  input  logic [NCH*HNP-1:0][255:0]   m_rdata,
  input  logic [NCH*HNP-1:0][1:0]     m_rresp,
  input  logic [NCH*HNP-1:0]          m_rlast
);
  localparam int XSW = `OTPU_XSW;
  localparam int CL  = CAW + $clog2(CB);  // a channel's byte address bits
  localparam int XQB = HNP == 2 ? 1 : 2;  // a posted beat's writes, 2^XQB (otpu_board NAT_XQB)
  initial if (NCH < 2 || NCH > (HNP == 2 ? 16 : 8) || CB != 128 || CAW < 20 || OAW < CL + $clog2(NCH) || OAW > 34)
    $fatal(1, "otpu_sqrl_fk_sys: %0d channels of %0d bytes (2 .. 8 of 128, 16 at HNP 2), %0d-bit beat addresses, %0d-bit HBM addresses (at least the channels' %0d bytes)",
           NCH, CB, CAW, OAW, NCH << CL);
  initial if (HNP != 1 && HNP != 2) $fatal(1, "otpu_sqrl_fk_sys: HNP %0d (1 or 2)", HNP);
`ifdef OTPU_BOARD_UNSET
  initial $fatal(1, "otpu_sqrl_fk_sys: no OTPU_BOARD (otpu_board's parameters)");
`endif

  // ---- the accelerator's native ports and posted beats
  logic [NCH-1:0]            n_cvalid, n_cready, n_cwe, n_wvalid, n_wready, n_rvalid, n_err;
  logic [NCH-1:0][5:0]       n_wfree;
  logic [NCH-1:0][CAW-1:0]   n_caddr;
  logic [NCH-1:0][CB*8-1:0]  n_wdata, n_rdata;
  logic [NCH-1:0][CB-1:0]    n_wmask;
  logic [NCH-1:0][15:0]      n_wdone;
  logic [NCH-1:0][1:0]       n_csrc;
  logic [NCH-1:0][XSW-1:0]   n_cslot;
  logic [NCH-1:0][4:0][XSW-1:0] p_slot;
  logic [NCH-1:0]            p_we;
  logic [NCH-1:0][1:0][(1 << XQB)-1:0] p_q;
  logic [NCH-1:0][256*HNP-1:0] p_d;
  logic [NCH-1:0][XSW+1:0]   p_cntg;

  otpu_board #(.NC(1), .S(1), .NCH(NCH), .CB(CB), .CORE_KHZ(CORE_KHZ), .CORE_KHZ1(CORE_KHZ1),
               .DDR_MTS(DDR_MTS),
               .HAS_I2C(1'b0), .HOSTCAL(1'b0), .HAS_BMC(1'b0), .NAT_XQB(XQB), .BHW(0),
               .CH_ILV(HNP == 2),
               .DRAM_LOG2(CAW + $clog2(NCH * CB)), .CH_LOG2(CL) `OTPU_BOARD) u_board (
    .clk, .clk_f, .rst, .ctl_mrst, .calib({NCH{calib}}), .ded('0), .temp, .led, .i2c_lo(),
    .i2c_pin(5'h1F),
    .x2_s_tdata(), .x2_s_tvalid(), .x2_s_tlast(), .x2_s_tready(2'b00),
    .x2_m_tdata('0), .x2_m_tvalid(2'b00), .x2_m_tlast(2'b00), .x2_m_thdr(2'b00), .x2_m_tready(),
    .x2_up(2'b00), .x2_rx_err(2'b00), .x2_abort_in(2'b00), .x2_abort(), .x2_rst(), .x2_card(),
    .x2_ncards(), .x2_c_we(), .x2_c_addr(), .x2_c_wd(), .x2_c_rd(32'd0),
    .s_ctl_awaddr, .s_ctl_awvalid, .s_ctl_awready, .s_ctl_wdata, .s_ctl_wstrb, .s_ctl_wvalid,
    .s_ctl_wready, .s_ctl_bresp, .s_ctl_bvalid, .s_ctl_bready, .s_ctl_araddr, .s_ctl_arvalid,
    .s_ctl_arready, .s_ctl_rdata, .s_ctl_rresp, .s_ctl_rvalid, .s_ctl_rready,
    .n_cvalid, .n_cready, .n_cwe, .n_caddr, .n_wvalid, .n_wready, .n_wdata, .n_wmask,
    .n_rvalid, .n_rdata, .n_wdone, .n_wfree, .n_err,
    .n_csrc, .n_cslot, .p_clk(aclk), .p_we, .p_q, .p_slot, .p_d, .p_cntg);

  // ---- the HBM's reset in aclk: two registers (their input a false path), then a register for each
  // channel's loads (wrs_b: its bridge's AXI half, wrs_s: its register slices; KEEP: synthesis would
  // merge them), each beside its own
  (* ASYNC_REG = "TRUE" *) logic [1:0] ars = 2'b11;
  always_ff @(posedge aclk) ars <= {ars[0], arst};

  // ---- the bridges and their register slices (q_*: the bridges' ports, HNP a channel)
  localparam int NQ = NCH * HNP;
  logic [NQ-1:0]          q_awvalid, q_awready, q_wvalid, q_wready, q_wlast, q_bvalid, q_bready;
  logic [NQ-1:0]          q_arvalid, q_arready, q_rvalid, q_rready, q_rlast;
  logic [NQ-1:0][33:0]    q_awaddr, q_araddr, r_awaddr, r_araddr;
  logic [NQ-1:0][OAW-1:0] q_awa, q_ara;
  logic [NQ-1:0][3:0]     q_awlen, q_arlen;
  logic [NQ-1:0][255:0]   q_wdata, q_rdata;
  logic [NQ-1:0][31:0]    q_wstrb;
  logic [NQ-1:0][1:0]     q_bresp, q_rresp;
  for (genvar j = 0; j < NCH; j++) begin : g_ch
    localparam int Q = HNP * j;             // the channel's first port
    (* keep = "true", shreg_extract = "no" *) logic wrs_b = 1'b1;
    always_ff @(posedge aclk) wrs_b <= ars[1];
    localparam int N = int'(RLY[4 * j +: 4]);
    (* keep_hierarchy = "yes" *)
    otpu_hbm_ch #(.CB(CB), .CAW(CAW), .PC(5'(j)), .OAW(OAW), .ARD(ARD), .WDD(32), .WPOST(`OTPU_WPOST),
                  .N(N), .WH(N != 0), .AWD(32), .PST(1), .XSW(XSW), .RHB(`OTPU_RHB),
                  .WHB(`OTPU_WHB), .BHW(0), .CPY(1'b0), .NP(HNP), .RCD(RCD > 0 ? RCD : HNP == 2 ? 128 : 64)) u_br (.clk, .rst,
      .n_cvalid(n_cvalid[j]), .n_cready(n_cready[j]), .n_cwe(n_cwe[j]), .n_caddr(n_caddr[j]),
      .n_wvalid(n_wvalid[j]), .n_wready(n_wready[j]), .n_wfree(n_wfree[j]), .n_wdata(n_wdata[j]),
      .n_wmask(n_wmask[j]),
      .n_rvalid(n_rvalid[j]), .n_rdata(n_rdata[j]), .n_wdone(n_wdone[j]), .n_err(n_err[j]),
      .n_csrc(n_csrc[j]), .n_cslot(n_cslot[j]), .p_we(p_we[j]), .p_q(p_q[j]), .p_slot(p_slot[j]),
      .p_d(p_d[j]), .p_cntg(p_cntg[j]),
      .aclk, .arst(wrs_b), .mwait(6'(MWAIT)),
      .m_awvalid(q_awvalid[Q +: HNP]), .m_awready(q_awready[Q +: HNP]), .m_awaddr(q_awa[Q +: HNP]),
      .m_awlen(q_awlen[Q +: HNP]),
      .m_wvalid(q_wvalid[Q +: HNP]), .m_wready(q_wready[Q +: HNP]), .m_wdata(q_wdata[Q +: HNP]),
      .m_wstrb(q_wstrb[Q +: HNP]), .m_wlast(q_wlast[Q +: HNP]), .m_bvalid(q_bvalid[Q +: HNP]),
      .m_bready(q_bready[Q +: HNP]), .m_bresp(q_bresp[Q +: HNP]),
      .m_arvalid(q_arvalid[Q +: HNP]), .m_arready(q_arready[Q +: HNP]), .m_araddr(q_ara[Q +: HNP]),
      .m_arlen(q_arlen[Q +: HNP]),
      .m_rvalid(q_rvalid[Q +: HNP]), .m_rready(q_rready[Q +: HNP]), .m_rdata(q_rdata[Q +: HNP]),
      .m_rresp(q_rresp[Q +: HNP]), .m_rlast(q_rlast[Q +: HNP]), .ev(), .ev_n());
  end
  // each bridge port's register slices onto its HBM port
  for (genvar j = 0; j < NQ; j++) begin : g_pt
    (* keep = "true", shreg_extract = "no" *) logic wrs_s = 1'b1;
    always_ff @(posedge aclk) wrs_s <= ars[1];
    assign q_awaddr[j] = 34'(q_awa[j]);
    assign q_araddr[j] = 34'(q_ara[j]);
    if (NRS > 0) begin : g_rs
      otpu_axi3_rs #(.N(NRS), .RBP(1'b1)) u_rs (.clk(aclk), .rst(wrs_s),
        .s_awvalid(q_awvalid[j]), .s_awready(q_awready[j]), .s_awid(6'd0), .s_awaddr(q_awaddr[j]),
        .s_awlen(q_awlen[j]), .s_wvalid(q_wvalid[j]), .s_wready(q_wready[j]), .s_wdata(q_wdata[j]),
        .s_wstrb(q_wstrb[j]), .s_wlast(q_wlast[j]), .s_bvalid(q_bvalid[j]), .s_bready(q_bready[j]),
        .s_bid(), .s_bresp(q_bresp[j]), .s_arvalid(q_arvalid[j]), .s_arready(q_arready[j]),
        .s_arid(6'd0), .s_araddr(q_araddr[j]), .s_arlen(q_arlen[j]), .s_rvalid(q_rvalid[j]),
        .s_rready(q_rready[j]), .s_rid(), .s_rdata(q_rdata[j]), .s_rresp(q_rresp[j]),
        .s_rlast(q_rlast[j]),
        .m_awvalid(m_awvalid[j]), .m_awready(m_awready[j]), .m_awid(), .m_awaddr(r_awaddr[j]),
        .m_awlen(m_awlen[j]), .m_wvalid(m_wvalid[j]), .m_wready(m_wready[j]), .m_wdata(m_wdata[j]),
        .m_wstrb(m_wstrb[j]), .m_wlast(m_wlast[j]), .m_bvalid(m_bvalid[j]), .m_bready(m_bready[j]),
        .m_bid(6'd0), .m_bresp(m_bresp[j]), .m_arvalid(m_arvalid[j]), .m_arready(m_arready[j]),
        .m_arid(), .m_araddr(r_araddr[j]), .m_arlen(m_arlen[j]), .m_rvalid(m_rvalid[j]),
        .m_rready(m_rready[j]), .m_rid(6'd0), .m_rdata(m_rdata[j]), .m_rresp(m_rresp[j]),
        .m_rlast(m_rlast[j]));
    end else begin : g_dir
      assign m_awvalid[j] = q_awvalid[j]; assign q_awready[j] = m_awready[j];
      assign r_awaddr[j] = q_awaddr[j]; assign m_awlen[j] = q_awlen[j];
      assign m_wvalid[j] = q_wvalid[j]; assign q_wready[j] = m_wready[j];
      assign m_wdata[j] = q_wdata[j]; assign m_wstrb[j] = q_wstrb[j]; assign m_wlast[j] = q_wlast[j];
      assign q_bvalid[j] = m_bvalid[j]; assign m_bready[j] = q_bready[j]; assign q_bresp[j] = m_bresp[j];
      assign m_arvalid[j] = q_arvalid[j]; assign q_arready[j] = m_arready[j];
      assign r_araddr[j] = q_araddr[j]; assign m_arlen[j] = q_arlen[j];
      assign q_rvalid[j] = m_rvalid[j]; assign m_rready[j] = q_rready[j];
      assign q_rdata[j] = m_rdata[j]; assign q_rresp[j] = m_rresp[j]; assign q_rlast[j] = m_rlast[j];
    end
    assign m_awaddr[j] = r_awaddr[j][OAW-1:0];
    assign m_araddr[j] = r_araddr[j][OAW-1:0];
  end
endmodule
