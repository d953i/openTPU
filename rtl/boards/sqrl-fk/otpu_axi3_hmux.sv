// One HBM AXI3 port shared by a channel bridge and a host DMA window (the SQRL FK top at 16 channels, where
// every one of the HBM's 32 ports is a bridge's: the host's window k shares port 4k + 1 with channel 2k's
// second port). The bridge's side (b_*) and the port (m_*) are on clk (uclk); the host's side (h_*) on hclk
// (XDMA's clock) through asynchronous FIFOs, so the port's crossing is these FIFOs alone (the earlier
// SmartConnect crossing into uclk failed timing at 450 MHz).
//
// The two share the port by AXI ID: the bridge's bursts go out as ID 0, the host's as ID 1, and the port's R
// and B come back by ID (the HBM IP keeps each ID's order, so the bridge sees its own in order). AW and AR
// alternate between the two when both wait (round robin); W follows AW's order (a FIFO of the granted
// sources): a source's W waits for its AW's grant, as AXI lets a slave (a master never waits on WREADY
// before AWVALID). R and B to the host go into its FIFOs: a host beat with its FIFO full holds the port's
// RREADY / BREADY (the bridge's beats wait behind it: the host owns the port only for model loads and
// results, between the accelerator's runs). The bridge's RREADY / BREADY pass through (its own: 1).
//
// AW, AR and W leave from registers (an otpu_rs each, its skid entry), R and B reach the bridge and the
// host's FIFOs straight from the port. The host's AxSIZE / AxBURST pass through (the window's bursts); the
// bridge's are 32 bytes, INCR.
module otpu_axi3_hmux #(
  parameter int OAW = 33,                   // the HBM's address bits
  parameter int HD  = 32                    // the host's FIFOs' depth (each direction)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                hclk,
  input  logic                hrst,
  // the bridge (clk; ID 0, 32-byte INCR bursts)
  input  logic                b_awvalid,
  output logic                b_awready,
  input  logic [OAW-1:0]      b_awaddr,
  input  logic [3:0]          b_awlen,
  input  logic                b_wvalid,
  output logic                b_wready,
  input  logic [255:0]        b_wdata,
  input  logic [31:0]         b_wstrb,
  input  logic                b_wlast,
  output logic                b_bvalid,
  input  logic                b_bready,
  output logic [1:0]          b_bresp,
  input  logic                b_arvalid,
  output logic                b_arready,
  input  logic [OAW-1:0]      b_araddr,
  input  logic [3:0]          b_arlen,
  output logic                b_rvalid,
  input  logic                b_rready,
  output logic [255:0]        b_rdata,
  output logic [1:0]          b_rresp,
  output logic                b_rlast,
  // the host's window (hclk)
  input  logic                h_awvalid,
  output logic                h_awready,
  input  logic [OAW-1:0]      h_awaddr,
  input  logic [3:0]          h_awlen,
  input  logic [2:0]          h_awsize,
  input  logic [1:0]          h_awburst,
  input  logic                h_wvalid,
  output logic                h_wready,
  input  logic [255:0]        h_wdata,
  input  logic [31:0]         h_wstrb,
  input  logic                h_wlast,
  output logic                h_bvalid,
  input  logic                h_bready,
  output logic [1:0]          h_bresp,
  input  logic                h_arvalid,
  output logic                h_arready,
  input  logic [OAW-1:0]      h_araddr,
  input  logic [3:0]          h_arlen,
  input  logic [2:0]          h_arsize,
  input  logic [1:0]          h_arburst,
  output logic                h_rvalid,
  input  logic                h_rready,
  output logic [255:0]        h_rdata,
  output logic [1:0]          h_rresp,
  output logic                h_rlast,
  // the HBM port (clk)
  output logic                m_awvalid,
  input  logic                m_awready,
  output logic [5:0]          m_awid,
  output logic [OAW-1:0]      m_awaddr,
  output logic [3:0]          m_awlen,
  output logic [2:0]          m_awsize,
  output logic [1:0]          m_awburst,
  output logic                m_wvalid,
  input  logic                m_wready,
  output logic [255:0]        m_wdata,
  output logic [31:0]         m_wstrb,
  output logic                m_wlast,
  input  logic                m_bvalid,
  output logic                m_bready,
  input  logic [5:0]          m_bid,
  input  logic [1:0]          m_bresp,
  output logic                m_arvalid,
  input  logic                m_arready,
  output logic [5:0]          m_arid,
  output logic [OAW-1:0]      m_araddr,
  output logic [3:0]          m_arlen,
  output logic [2:0]          m_arsize,
  output logic [1:0]          m_arburst,
  input  logic                m_rvalid,
  output logic                m_rready,
  input  logic [5:0]          m_rid,
  input  logic [255:0]        m_rdata,
  input  logic [1:0]          m_rresp,
  input  logic                m_rlast
);
  localparam int AXW = OAW + 4 + 3 + 2;     // an address entry: {addr, len, size, burst}
  localparam int HW  = $clog2(HD);

  // ---- the host's side across: AW, AR and W into clk, B and R out of it
  logic           q_awvalid, q_awready, q_arvalid, q_arready, q_wvalid, q_wready;
  logic [AXW-1:0] q_aw, q_ar;
  logic [288:0]   q_w;
  logic           hb_wready, hr_wready;
  otpu_afifo #(.W(AXW), .DEPTH(8)) u_haw (.wclk(hclk), .wrst(hrst), .wvalid(h_awvalid), .wready(h_awready),
    .wdata({h_awaddr, h_awlen, h_awsize, h_awburst}), .wslot('0), .wcommit(), .wused(),
    .rclk(clk), .rrst(rst), .rvalid(q_awvalid), .rready(q_awready), .rdata(q_aw), .rused());
  otpu_afifo #(.W(AXW), .DEPTH(8)) u_har (.wclk(hclk), .wrst(hrst), .wvalid(h_arvalid), .wready(h_arready),
    .wdata({h_araddr, h_arlen, h_arsize, h_arburst}), .wslot('0), .wcommit(), .wused(),
    .rclk(clk), .rrst(rst), .rvalid(q_arvalid), .rready(q_arready), .rdata(q_ar), .rused());
  otpu_afifo #(.W(289), .DEPTH(HD)) u_hw (.wclk(hclk), .wrst(hrst), .wvalid(h_wvalid), .wready(h_wready),
    .wdata({h_wdata, h_wstrb, h_wlast}), .wslot('0), .wcommit(), .wused(),
    .rclk(clk), .rrst(rst), .rvalid(q_wvalid), .rready(q_wready), .rdata(q_w), .rused());
  otpu_afifo #(.W(2), .DEPTH(HD)) u_hb (.wclk(clk), .wrst(rst), .wvalid(m_bvalid && m_bid[0]),
    .wready(hb_wready), .wdata(m_bresp), .wslot('0), .wcommit(), .wused(),
    .rclk(hclk), .rrst(hrst), .rvalid(h_bvalid), .rready(h_bready), .rdata(h_bresp), .rused());
  otpu_afifo #(.W(259), .DEPTH(HD)) u_hr (.wclk(clk), .wrst(rst), .wvalid(m_rvalid && m_rid[0]),
    .wready(hr_wready), .wdata({m_rdata, m_rresp, m_rlast}), .wslot('0), .wcommit(), .wused(),
    .rclk(hclk), .rrst(hrst), .rvalid(h_rvalid), .rready(h_rready), .rdata({h_rdata, h_rresp, h_rlast}),
    .rused());

  // ---- R and B by ID
  assign b_rvalid  = m_rvalid && !m_rid[0];
  assign b_rdata   = m_rdata;
  assign b_rresp   = m_rresp;
  assign b_rlast   = m_rlast;
  assign m_rready  = m_rid[0] ? hr_wready : b_rready;
  assign b_bvalid  = m_bvalid && !m_bid[0];
  assign b_bresp   = m_bresp;
  assign m_bready  = m_bid[0] ? hb_wready : b_bready;

  // ---- AR: round robin into a register slice (its entry {id bit, addr, len, size, burst})
  logic           ar_v, ar_r, ar_h, ar_last = 1'b0;   // ar_last: the host had the last grant
  logic [AXW:0]   ar_d, ar_q;
  assign ar_h      = q_arvalid && (!b_arvalid || !ar_last);
  assign ar_v      = b_arvalid || q_arvalid;
  assign ar_d      = ar_h ? {1'b1, q_ar} : {1'b0, b_araddr, b_arlen, 3'd5, 2'b01};
  assign b_arready = ar_r && !ar_h;
  assign q_arready = ar_r && ar_h;
  always_ff @(posedge clk)
    if (rst) ar_last <= 1'b0;
    else if (ar_v && ar_r) ar_last <= ar_h;
  otpu_rs #(.W(AXW + 1)) u_ar (.clk, .rst, .s_valid(ar_v), .s_ready(ar_r), .s_data(ar_d),
    .m_valid(m_arvalid), .m_ready(m_arready), .m_data(ar_q));
  assign m_arid = {5'd0, ar_q[AXW]};
  assign {m_araddr, m_arlen, m_arsize, m_arburst} = ar_q[AXW-1:0];

  // ---- AW: as AR, each grant's source into the W order (wo: room for it, else no grant)
  logic           aw_v, aw_r, aw_h, aw_g, aw_last = 1'b0;
  logic [AXW:0]   aw_d, aw_q;
  logic           wo_wready, wo_v, wo_h, wo_pop;
  assign aw_h      = q_awvalid && (!b_awvalid || !aw_last);
  assign aw_v      = (b_awvalid || q_awvalid) && wo_wready;
  assign aw_d      = aw_h ? {1'b1, q_aw} : {1'b0, b_awaddr, b_awlen, 3'd5, 2'b01};
  assign aw_g      = aw_v && aw_r;
  assign b_awready = aw_r && wo_wready && !aw_h;
  assign q_awready = aw_r && wo_wready && aw_h;
  always_ff @(posedge clk)
    if (rst) aw_last <= 1'b0;
    else if (aw_g) aw_last <= aw_h;
  otpu_rs #(.W(AXW + 1)) u_aw (.clk, .rst, .s_valid(aw_v), .s_ready(aw_r), .s_data(aw_d),
    .m_valid(m_awvalid), .m_ready(m_awready), .m_data(aw_q));
  assign m_awid = {5'd0, aw_q[AXW]};
  assign {m_awaddr, m_awlen, m_awsize, m_awburst} = aw_q[AXW-1:0];

  // the W order: a small synchronous FIFO of the granted sources (1: the host)
  logic [3:0] wo_q = '0;
  logic [2:0] wo_n = '0;
  assign wo_wready = wo_n < 3'd4;
  assign wo_v      = wo_n != '0;
  assign wo_h      = wo_q[0];
  always_ff @(posedge clk)
    if (rst) begin wo_n <= '0; wo_q <= '0; end
    else begin
      // pop shifts down; a push lands at the first free place after the pop
      logic [3:0] q;
      logic [2:0] n;
      q = wo_pop ? {1'b0, wo_q[3:1]} : wo_q;
      n = wo_n - 3'(wo_pop);
      if (aw_g) q[n[1:0]] = aw_h;
      wo_q <= q;
      wo_n <= n + 3'(aw_g);
    end

  // ---- W: the order's head source's beats into a register slice; its last beat pops the order
  logic         w_v, w_r;
  logic [288:0] w_d;
  assign w_v      = wo_v && (wo_h ? q_wvalid : b_wvalid);
  assign w_d      = wo_h ? q_w : {b_wdata, b_wstrb, b_wlast};
  assign b_wready = wo_v && !wo_h && w_r;
  assign q_wready = wo_v && wo_h && w_r;
  assign wo_pop   = w_v && w_r && w_d[0];
  otpu_rs #(.W(289)) u_w (.clk, .rst, .s_valid(w_v), .s_ready(w_r), .s_data(w_d),
    .m_valid(m_wvalid), .m_ready(m_wready), .m_data({m_wdata, m_wstrb, m_wlast}));
endmodule
