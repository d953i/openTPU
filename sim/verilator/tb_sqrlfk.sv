// Board-level simulation of the SQRL FK33 / FK35 at WG 8 (targets/sqrl-fk3[35].toml): otpu_sqrl_fk_sys (the
// accelerator, otpu_board at one slice of NCH = 8 channels; its bridges, otpu_hbm_ch, on one HBM AXI3
// port each) in front of models of those ports (otpu_hbm_model PHYS: channel j's physical image,
// ch<j>.bin, at HBM byte j x 2^PCL, PCL = CAW + 7), driven by tb_board's host script (+dir=<d>,
// <d>/host.txt; opentpu/host/board.py SimTransport with sqrlfk, which gives otpu_board's parameters
// as OTPU_BOARD, defined in a source before this one: opentpu.host.boardmacro board_defines) on the
// control port (AXI4-Lite in the core clock, as tb_board's). Script lines as tb_bcuwg's:
//   W <addr> <value>          AXI-Lite write
//   P <addr> <mask> <value>   poll until (read(addr) & mask) == value
//   R <addr>                  read, printed as "REG <addr> <value>"
//   C <cycles>                wait (core cycles)
// Numbers are hex. At the end the channel images are dumped (ch<c>_out.bin). WORDS: the slice's
// logical memory words (its 8 channels' dense images); CAW the channels' beat address bits
// (otpu_sqrl_fk_sys's, 23 on the card: 1 GiB a channel).
// HNP 2 (otpu_sqrl_fk_sys HNP: a bridge on two HBM ports): two models a channel, lanes 0 and 1 of its
// image (otpu_hbm_model ILV: PC 2 j + l of 2^(PCL - 1) bytes, the image's 32-byte beats alternating
// between them; each dumps its own copy, ch<j>_l<l>_out.bin, SimTransport merges them).
// Two clocks (+cp= / +ap=: half periods in ps; default 3333 / 1111: the core 150, aclk 450 MHz),
// clk_f at twice the core's, rising with it. The HBM models' timing: +hbm_* (otpu_hbm_model).
module tb_sqrlfk;
  parameter int NCH      = 8;
  parameter int WORDS    = 1 << 20;       // the slice's logical memory words (its NCH channels)
  parameter int CORE_KHZ = 150000;
  parameter logic [4*NCH-1:0] RLY = '0;   // channel j's bridge pipeline N (otpu_sqrl_fk_sys)
  parameter int MWAIT    = 8;             // otpu_sqrl_fk_sys's: a partial burst's wait,
  parameter int ARD      = 32;            // the bridges' read credits
  parameter int CAW      = 23;            // the channels' beat address bits (otpu_sqrl_fk_sys)
  parameter int HNP      = 1;             // HBM ports a channel (otpu_sqrl_fk_sys)
  parameter int RCD      = 0;             // a bridge's reads in flight (otpu_sqrl_fk_sys; 0: its HNP default)

  localparam int CB = 128, PCL = CAW + 7, OAW = PCL + $clog2(NCH) > 33 ? PCL + $clog2(NCH) : 33;
  localparam int BEATS = WORDS / NCH / 8;          // a channel's 32-byte beats
  int cp = 3333, ap = 1111;
  logic cclk = 1'b0, cclk_f = 1'b0, aclk = 1'b0, dump = 1'b0;
  initial begin
    void'($value$plusargs("cp=%d", cp));
    void'($value$plusargs("ap=%d", ap));
  end
  always #(ap) aclk = ~aclk;
  initial forever begin                   // clk_f rises with each edge of the core clock
    #(cp / 2) cclk_f = 1'b0;
    #(cp - cp / 2) begin cclk = ~cclk; cclk_f = 1'b1; end
  end
  logic rst = 1'b1, arst = 1'b1, calib = 1'b0;
  longint cyc = 0, acyc = 0;
  always @(posedge cclk) cyc <= cyc + 1;
  always @(posedge aclk) begin
    acyc <= acyc + 1;
    if (acyc == 40) arst <= 1'b0;
    if (acyc == 200) calib <= 1'b1;
  end

  // ---- the control port (core clock)
  logic [11:0] awaddr = '0, araddr = '0;
  logic [31:0] wdata = '0, rdata;
  logic        awvalid = 1'b0, wvalid = 1'b0, arvalid = 1'b0;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;
  // ---- the channels' HBM ports (HNP a channel: port HNP j + l)
  localparam int NQ = NCH * HNP;
  logic [NQ-1:0]          m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready;
  logic [NQ-1:0]          m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
  logic [NQ-1:0][OAW-1:0] m_awaddr, m_araddr;
  logic [NQ-1:0][3:0]     m_awlen, m_arlen;
  logic [NQ-1:0][255:0]   m_wdata, m_rdata;
  logic [NQ-1:0][31:0]    m_wstrb;
  logic [NQ-1:0][1:0]     m_bresp, m_rresp;
  logic [2:0]              led;

  otpu_sqrl_fk_sys #(.NCH(NCH), .CB(CB), .CAW(CAW), .OAW(OAW), .CORE_KHZ(CORE_KHZ), .RLY(RLY),
                     .MWAIT(MWAIT), .ARD(ARD), .HNP(HNP), .RCD(RCD)) dut (
    .clk(cclk), .clk_f(cclk_f), .rst, .ctl_mrst(1'b0), .aclk, .arst, .calib,
    .temp(12'd0), .led,
    .s_ctl_awaddr(awaddr), .s_ctl_awvalid(awvalid), .s_ctl_awready(awready),
    .s_ctl_wdata(wdata), .s_ctl_wstrb(4'hF), .s_ctl_wvalid(wvalid), .s_ctl_wready(wready),
    .s_ctl_bresp(bresp), .s_ctl_bvalid(bvalid), .s_ctl_bready(1'b1),
    .s_ctl_araddr(araddr), .s_ctl_arvalid(arvalid), .s_ctl_arready(arready),
    .s_ctl_rdata(rdata), .s_ctl_rresp(rresp), .s_ctl_rvalid(rvalid), .s_ctl_rready(1'b1),
    .m_awvalid, .m_awready, .m_awaddr, .m_awlen, .m_wvalid, .m_wready, .m_wdata,
    .m_wstrb, .m_wlast, .m_bvalid, .m_bready, .m_bresp, .m_arvalid, .m_arready,
    .m_araddr, .m_arlen, .m_rvalid, .m_rready, .m_rdata, .m_rresp, .m_rlast);

  // the dump request crosses into aclk as a level the models see for some edges; they write
  // their images at the first
  logic adump = 1'b0, adump_q = 1'b0;
  always @(posedge aclk) begin adump <= dump; adump_q <= adump; end
  int     merr [NQ];
  longint mwap [NQ];
  for (genvar j = 0; j < NQ; j++) begin : g_hbm
    logic [33:0] awa, ara;
    assign awa = 34'(m_awaddr[j]);
    assign ara = 34'(m_araddr[j]);
    otpu_hbm_model #(.BEATS(BEATS), .PC(5'(j)), .PCL(PCL - (HNP - 1)), .PHYS(1'b1), .ILV(HNP == 2),
                     .LANE(j % HNP), .IMG(j / HNP)) u_hbm (
      .clk(aclk), .rst(arst), .dump(adump && !adump_q),
      .awvalid(m_awvalid[j]), .awready(m_awready[j]), .awid(6'd0), .awaddr(awa),
      .awlen(m_awlen[j]), .wvalid(m_wvalid[j]), .wready(m_wready[j]), .wdata(m_wdata[j]),
      .wstrb(m_wstrb[j]), .wlast(m_wlast[j]), .bvalid(m_bvalid[j]), .bready(m_bready[j]),
      .bid(), .bresp(m_bresp[j]), .arvalid(m_arvalid[j]), .arready(m_arready[j]),
      .arid(6'd0), .araddr(ara), .arlen(m_arlen[j]), .rvalid(m_rvalid[j]),
      .rready(m_rready[j]), .rid(), .rdata(m_rdata[j]), .rresp(m_rresp[j]),
      .rlast(m_rlast[j]), .wap(mwap[j]), .nerr(merr[j]));
  end

  // Handshakes driven and sampled on the falling edge, as tb_board's
  task automatic lwrite(input logic [11:0] a, input logic [31:0] v);
    @(negedge cclk);
    awaddr = a; wdata = v; awvalid = 1'b1; wvalid = 1'b1;
    #1;
    while (!(awready && wready)) begin
      @(negedge cclk);
      #1;
    end
    @(negedge cclk);
    awvalid = 1'b0; wvalid = 1'b0;
    while (!bvalid) @(negedge cclk);
  endtask
  task automatic lread(input logic [11:0] a, output logic [31:0] v);
    @(negedge cclk);
    araddr = a; arvalid = 1'b1;
    while (!arready) @(negedge cclk);
    @(negedge cclk);
    arvalid = 1'b0;
    while (!rvalid) @(negedge cclk);
    v = rdata;
  endtask

  task automatic hbm_check(input string when);
    for (int j = 0; j < NQ; j++)
      if (merr[j] != 0) $fatal(1, "tb_sqrlfk: %s: HBM port %0d: %0d errors", when, j, merr[j]);
    if (|dut.n_err) $fatal(1, "tb_sqrlfk: %s: bridge errors %b", when, dut.n_err);
  endtask

  string dir, op;
  integer fd, n;
  longint max_cycles = 64'd1 << 40;
  initial begin
    logic [31:0] a, m, v, r;
    if (!$value$plusargs("dir=%s", dir)) $fatal(1, "+dir= missing");
    void'($value$plusargs("max_cycles=%d", max_cycles));
    repeat (4) @(negedge cclk);
    rst = 1'b0;
    // the script starts once the HBM is calibrated (the card's host waits for STATUS CALIB): the
    // control block ignores LOAD and RUN until then
    while (!calib) @(negedge cclk);
    repeat (16) @(negedge cclk);            // (through otpu_board's synchronizers)
    fd = $fopen($sformatf("%s/host.txt", dir), "r");
    if (fd == 0) $fatal(1, "no host script");
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%s", op);
      if (n != 1) break;
      case (op)
        "W": begin
          n = $fscanf(fd, "%h %h", a, v);
          lwrite(a[11:0], v);
        end
        "P": begin
          n = $fscanf(fd, "%h %h %h", a, m, v);
          do begin
            lread(a[11:0], r);
            if (cyc > max_cycles) begin
              $display("TIMEOUT polling %h (%h)", a, r);
              $finish;
            end
          end while ((r & m) != v);
        end
        "R": begin
          n = $fscanf(fd, "%h", a);
          lread(a[11:0], r);
          $display("REG %h %h", a, r);
        end
        "C": begin
          n = $fscanf(fd, "%h", v);
          repeat (v) @(posedge cclk);
        end
        default: $fatal(1, "bad host op %s", op);
      endcase
    end
    $fclose(fd);
    hbm_check("end");
    @(negedge cclk);
    dump = 1'b1;
    repeat (4) @(negedge aclk);
    dump = 1'b0;
    repeat (4) @(negedge aclk);
    hbm_check("the dump");
    $display("DONE cycles=%0d", cyc);
    $finish;
  end
endmodule
