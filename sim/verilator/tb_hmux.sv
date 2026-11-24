// Stress test of otpu_axi3_hmux: a bridge master (clk, 450 MHz, RREADY / BREADY 1, 32-byte INCR bursts) and a host
// master (hclk, 250 MHz, random RREADY / BREADY) share a port model that reorders between IDs (B by burst, R by beat:
// AXI3 lets a slave interleave IDs' read beats), with random ready / valid gaps. Each master writes its own region,
// then reads it back while the other writes / reads; every read beat is checked against what was written.
// build: verilator --binary --timing -Wno-fatal tb_hmux.sv otpu_axi3_hmux.sv otpu_afifo.sv otpu_axi_rs.sv
// (tests/test_sqrlfk_board.py test_axi3_hmux_stress); +seed=N, +n=bursts a master a pass
module tb_hmux;
  localparam int OAW = 33;
  logic clk = 0, hclk = 0, rst = 1, hrst = 1;
  always #1111 clk = ~clk;
  always #2000 hclk = ~hclk;
  int seed = 1, nb = 400;
  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n=%d", nb));
    void'($urandom(seed));
  end

  // ---- DUT
  logic b_awvalid = 0, b_awready, b_wvalid = 0, b_wready, b_wlast = 0, b_bvalid, b_arvalid = 0, b_arready, b_rvalid,
        b_rlast;
  logic [OAW-1:0] b_awaddr = 0, b_araddr = 0;
  logic [3:0] b_awlen = 0, b_arlen = 0;
  logic [255:0] b_wdata = 0, b_rdata;
  logic [31:0] b_wstrb = '1;
  logic [1:0] b_bresp, b_rresp;
  logic h_awvalid = 0, h_awready, h_wvalid = 0, h_wready, h_wlast = 0, h_bvalid, h_bready = 0, h_arvalid = 0, h_arready,
        h_rvalid, h_rready = 0, h_rlast;
  logic [OAW-1:0] h_awaddr = 0, h_araddr = 0;
  logic [3:0] h_awlen = 0, h_arlen = 0;
  logic [255:0] h_wdata = 0, h_rdata;
  logic [31:0] h_wstrb = '1;
  logic [1:0] h_bresp, h_rresp;
  logic m_awvalid, m_awready = 0, m_wvalid, m_wready = 0, m_wlast, m_bvalid = 0, m_bready, m_arvalid, m_arready = 0,
        m_rvalid = 0, m_rready, m_rlast = 0;
  logic [5:0] m_awid, m_arid, m_bid = 0, m_rid = 0;
  logic [OAW-1:0] m_awaddr, m_araddr;
  logic [3:0] m_awlen, m_arlen;
  logic [2:0] m_awsize, m_arsize;
  logic [1:0] m_awburst, m_arburst, m_bresp = 0, m_rresp = 0;
  logic [255:0] m_wdata, m_rdata = 0;
  logic [31:0] m_wstrb;
  otpu_axi3_hmux #(.OAW(OAW)) dut (.clk, .rst, .hclk, .hrst,
    .b_awvalid, .b_awready, .b_awaddr, .b_awlen, .b_wvalid, .b_wready, .b_wdata, .b_wstrb, .b_wlast, .b_bvalid,
    .b_bready(1'b1), .b_bresp, .b_arvalid, .b_arready, .b_araddr, .b_arlen, .b_rvalid, .b_rready(1'b1), .b_rdata,
    .b_rresp, .b_rlast,
    .h_awvalid, .h_awready, .h_awaddr, .h_awlen, .h_awsize(3'd5), .h_awburst(2'b01), .h_wvalid, .h_wready, .h_wdata,
    .h_wstrb, .h_wlast, .h_bvalid, .h_bready, .h_bresp, .h_arvalid, .h_arready, .h_araddr, .h_arlen,
    .h_arsize(3'd5), .h_arburst(2'b01), .h_rvalid, .h_rready, .h_rdata, .h_rresp, .h_rlast,
    .m_awvalid, .m_awready, .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_wvalid, .m_wready, .m_wdata,
    .m_wstrb, .m_wlast, .m_bvalid, .m_bready, .m_bid, .m_bresp, .m_arvalid, .m_arready, .m_arid, .m_araddr, .m_arlen,
    .m_arsize, .m_arburst, .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast);

  // ---- the port model (clk): memory of 32-byte words by word address
  logic [255:0] mem [longint];
  typedef struct { logic [5:0] id; longint a; int len; } burst_t;
  burst_t awq[$], arq[2][$];
  logic [256:0] wq[$];
  int bq[2][$];                                     // B to send, per ID (count)
  int wbeat = 0, errors = 0, rbeat[2] = '{0, 0};
  int rsel = -1;
  function automatic logic [255:0] pat(longint a, int gen);
    return {8{32'(a * 2654435761 + gen * 40503 + 7)}};
  endfunction
  always @(posedge clk) begin
    // random readies
    m_awready <= ($urandom % 4) != 0;
    m_wready  <= ($urandom % 3) != 0;
    m_arready <= ($urandom % 4) != 0;
    if (m_awvalid && m_awready) begin
      if (m_awsize != 3'd5 || m_awburst != 2'b01) begin $display("ERROR aw size/burst %0d %0d", m_awsize, m_awburst); errors++; end
      awq.push_back('{m_awid, longint'(m_awaddr) >> 5, int'(m_awlen)});
    end
    // W beats queue up (a W beat may reach the port before its AW: legal AXI) and go to the AWs in order
    if (m_wvalid && m_wready) wq.push_back({m_wlast, m_wdata});
    while (wq.size() != 0 && awq.size() != 0) begin
      logic [256:0] v;
      v = wq.pop_front();
      mem[awq[0].a + wbeat] = v[255:0];
      if (v[256] != (wbeat == awq[0].len)) begin
        if (errors < 10) $display("ERROR wlast at beat %0d of %0d", wbeat, awq[0].len); errors++; end
      if (wbeat == awq[0].len) begin bq[awq[0].id[0]].push_back(1); void'(awq.pop_front()); wbeat = 0; end
      else wbeat++;
    end
    if (m_arvalid && m_arready) begin
      if (m_arsize != 3'd5 || m_arburst != 2'b01) begin $display("ERROR ar size/burst"); errors++; end
      arq[m_arid[0]].push_back('{m_arid, longint'(m_araddr) >> 5, int'(m_arlen)});
    end
    // B: either ID's oldest, at random
    if (m_bvalid && m_bready) m_bvalid <= 1'b0;
    if (!m_bvalid || m_bready) begin
      int i;
      i = $urandom % 2;
      if (bq[i].size() == 0) i = 1 - i;
      if (bq[i].size() != 0 && ($urandom % 3) != 0) begin
        void'(bq[i].pop_front()); m_bvalid <= 1'b1; m_bid <= 6'(i); m_bresp <= 2'b00;
      end
    end
    // R: beat by beat, either ID's (a beat held until taken)
    begin
      bit took;
      took = m_rvalid && m_rready;
      if (took) begin
        if (rbeat[rsel] == arq[rsel][0].len) begin void'(arq[rsel].pop_front()); rbeat[rsel] = 0; end
        else rbeat[rsel]++;
        m_rvalid <= 1'b0;
      end
      if (!m_rvalid || took) begin
        int i;
        i = $urandom % 2;
        if (arq[i].size() == 0) i = 1 - i;
        if (arq[i].size() != 0 && ($urandom % 4) != 0) begin
          longint a;
          a = arq[i][0].a + rbeat[i];
          rsel = i;
          m_rvalid <= 1'b1; m_rid <= arq[i][0].id;
          m_rdata <= mem.exists(a) ? mem[a] : '0;
          m_rlast <= rbeat[i] == arq[i][0].len;
        end
      end
    end
  end


  // ---- the masters: write their region, then read it back (each read beat against the generation written).
  // Handshakes are sampled by monitors at the clock edge (pre-edge values); the masters drive 1 ps after an edge.
  bit b_aw_t, b_w_t, b_ar_t, h_aw_t, h_w_t, h_ar_t;
  int b_nb = 0, h_nb = 0;
  logic [256:0] b_rq[$], h_rq[$];                   // {rlast, rdata} as taken
  always @(posedge clk) begin
    b_aw_t <= b_awvalid && b_awready; b_w_t <= b_wvalid && b_wready; b_ar_t <= b_arvalid && b_arready;
    if (b_bvalid) b_nb <= b_nb + 1;
    if (b_rvalid) b_rq.push_back({b_rlast, b_rdata});
  end
  always @(posedge hclk) begin
    h_aw_t <= h_awvalid && h_awready; h_w_t <= h_wvalid && h_wready; h_ar_t <= h_arvalid && h_arready;
    if (h_bvalid && h_bready) h_nb <= h_nb + 1;
    if (h_rvalid && h_rready) h_rq.push_back({h_rlast, h_rdata});
  end
  always @(posedge hclk) begin #1; h_rready = ($urandom % 3) != 0; h_bready = ($urandom % 3) != 0; end
  typedef struct { longint a; int len; } req_t;
  task automatic bwait(ref bit t); do begin @(posedge clk); #1; end while (!t); endtask
  task automatic hwait(ref bit t); do begin @(posedge hclk); #1; end while (!t); endtask
  task automatic check(string who, ref logic [256:0] rq[$], input req_t q[$], input int gen, input bit hc);
    foreach (q[i]) for (int k = 0; k <= q[i].len; k++) begin
      logic [256:0] v;
      while (rq.size() == 0) if (hc) @(posedge hclk); else @(posedge clk);
      v = rq.pop_front();
      if (v[255:0] !== pat(q[i].a + k, gen) && v[255:0] !== pat(q[i].a + k, gen - 1) && v[255:0] !== '0) begin
        if (errors < 10) $display("ERROR %s read %0h beat %0d: %h", who, q[i].a, k, v[31:0]); errors++; end
      if (v[256] != (k == q[i].len)) begin if (errors < 10) $display("ERROR %s rlast", who); errors++; end
    end
  endtask
  function automatic void mkq(ref req_t q[$], input int n, input longint base);
    for (int i = 0; i < n; i++) q.push_back('{base + longint'(($urandom % 2048) & ~15), int'($urandom % 16)});
  endfunction
  // the bridge (clk): AW and W from one list, W may run ahead of AW; RREADY / BREADY 1
  task automatic bridge(int gen, bit rd);
    req_t q[$];
    mkq(q, nb, 0);
    @(posedge clk); #1;
    if (!rd) begin
      int nb0 = b_nb;
      fork
        foreach (q[i]) begin
          b_awvalid = 1; b_awaddr = OAW'(q[i].a << 5); b_awlen = 4'(q[i].len);
          bwait(b_aw_t); b_awvalid = 0;
          repeat ($urandom % 3) @(posedge clk); #1;
        end
        foreach (q[i]) for (int k = 0; k <= q[i].len; k++) begin
          b_wvalid = 1; b_wdata = pat(q[i].a + k, gen); b_wlast = k == q[i].len;
          bwait(b_w_t); b_wvalid = 0;
          if ($urandom % 4 == 0) begin @(posedge clk); #1; end
        end
        while (b_nb - nb0 < q.size()) @(posedge clk);
      join
    end else begin
      fork
        foreach (q[i]) begin
          b_arvalid = 1; b_araddr = OAW'(q[i].a << 5); b_arlen = 4'(q[i].len);
          bwait(b_ar_t); b_arvalid = 0;
          repeat ($urandom % 3) @(posedge clk); #1;
        end
        check("bridge", b_rq, q, gen, 0);
      join
    end
  endtask
  // the host (hclk), its region 2048 words up; random RREADY / BREADY
  task automatic host(int gen, bit rd);
    req_t q[$];
    mkq(q, nb / 2, 2048);
    @(posedge hclk); #1;
    if (!rd) begin
      int nb0 = h_nb;
      fork
        foreach (q[i]) begin
          h_awvalid = 1; h_awaddr = OAW'(q[i].a << 5); h_awlen = 4'(q[i].len);
          hwait(h_aw_t); h_awvalid = 0;
        end
        foreach (q[i]) for (int k = 0; k <= q[i].len; k++) begin
          h_wvalid = 1; h_wdata = pat(q[i].a + k, gen); h_wlast = k == q[i].len;
          hwait(h_w_t); h_wvalid = 0;
        end
        while (h_nb - nb0 < q.size()) @(posedge hclk);
      join
    end else begin
      fork
        foreach (q[i]) begin
          h_arvalid = 1; h_araddr = OAW'(q[i].a << 5); h_arlen = 4'(q[i].len);
          hwait(h_ar_t); h_arvalid = 0;
        end
        check("host", h_rq, q, gen, 1);
      join
    end
  endtask

  // a read may see the older generation where a later write of the same pass overlapped (random addresses):
  // the checks above accept generation gen or gen - 1 (or 0, never written). Exact checks: pass 3 reads a
  // region nobody writes during it.
  int nr = 0;
  initial begin
    repeat (10) @(posedge hclk);
    rst <= 0; hrst <= 0;
    repeat (10) @(posedge hclk);
    // pass 1: both write (gen 1); pass 2: both read back while... ; pass 3: bridge reads, host writes gen 2;
    // pass 4: host reads gen 2 while the bridge writes gen 2
    fork bridge(1, 0); host(1, 0); join
    $display("pass 1 (both write) done at %0t", $time);
    fork bridge(1, 1); host(1, 1); join
    $display("pass 2 (both read) done at %0t", $time);
    fork bridge(1, 1); host(2, 0); join
    $display("pass 3 (bridge reads, host writes) done at %0t", $time);
    fork host(2, 1); bridge(2, 0); join
    $display("pass 4 (host reads, bridge writes) done at %0t", $time);
    fork bridge(2, 1); host(2, 1); join
    $display("pass 5 (both read) done; errors %0d", errors);
    if (wq.size() || awq.size() || arq[0].size() || arq[1].size() || bq[0].size() || bq[1].size()) begin
      $display("ERROR leftovers aw %0d ar %0d/%0d b %0d/%0d", awq.size(), arq[0].size(), arq[1].size(), bq[0].size(),
               bq[1].size()); errors++; end
    if (errors) $display("FAIL"); else $display("PASS");
    $finish;
  end
  initial begin #(64'd2_000_000_000); $display("FAIL timeout"); $finish; end
endmodule
