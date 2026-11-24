// The block design's wrapper (boards/sqrl-fk/vivado/bd.tcl: otpu_bd, its external ports) as an empty module,
// for Verilator's lint of otpu_fpga_top_sqrl_fk only: XDMA's control master M_AXI_CTL (AXI4-Lite, core_clk) and
// its DMA windows M_AXI_DMA0 .. 7 (AXI3 256-bit, uclk, 33-bit HBM addresses, no ID), the clocks and resets.
// Outputs 0. Checked against Vivado 2019.2's generated otpu_bd_wrapper.v, which also has the windows' and M_AXI_CTL's
// cache / lock / prot / qos outputs (the top leaves them open, as here).
`define STUB_DMA(J) \
  output wire [32:0]  M_AXI_DMA``J``_awaddr, \
  output wire [3:0]   M_AXI_DMA``J``_awlen, output wire [2:0] M_AXI_DMA``J``_awsize, \
  output wire [1:0]   M_AXI_DMA``J``_awburst, output wire M_AXI_DMA``J``_awvalid, \
  input  wire         M_AXI_DMA``J``_awready, \
  output wire [255:0] M_AXI_DMA``J``_wdata, output wire [31:0] M_AXI_DMA``J``_wstrb, \
  output wire         M_AXI_DMA``J``_wlast, output wire M_AXI_DMA``J``_wvalid, \
  input  wire         M_AXI_DMA``J``_wready, \
  input  wire [1:0]   M_AXI_DMA``J``_bresp, \
  input  wire         M_AXI_DMA``J``_bvalid, output wire M_AXI_DMA``J``_bready, \
  output wire [32:0]  M_AXI_DMA``J``_araddr, \
  output wire [3:0]   M_AXI_DMA``J``_arlen, output wire [2:0] M_AXI_DMA``J``_arsize, \
  output wire [1:0]   M_AXI_DMA``J``_arburst, output wire M_AXI_DMA``J``_arvalid, \
  input  wire         M_AXI_DMA``J``_arready, \
  input  wire [255:0] M_AXI_DMA``J``_rdata, \
  input  wire [1:0]   M_AXI_DMA``J``_rresp, input wire M_AXI_DMA``J``_rlast, \
  input  wire         M_AXI_DMA``J``_rvalid, output wire M_AXI_DMA``J``_rready
`define STUB_DMA_OFF(J) \
  assign M_AXI_DMA``J``_awaddr = '0; assign M_AXI_DMA``J``_awlen = '0; \
  assign M_AXI_DMA``J``_awsize = '0; assign M_AXI_DMA``J``_awburst = '0; assign M_AXI_DMA``J``_awvalid = 1'b0; \
  assign M_AXI_DMA``J``_wdata = '0; assign M_AXI_DMA``J``_wstrb = '0; assign M_AXI_DMA``J``_wlast = 1'b0; \
  assign M_AXI_DMA``J``_wvalid = 1'b0; assign M_AXI_DMA``J``_bready = 1'b1; \
  assign M_AXI_DMA``J``_araddr = '0; assign M_AXI_DMA``J``_arlen = '0; \
  assign M_AXI_DMA``J``_arsize = '0; assign M_AXI_DMA``J``_arburst = '0; assign M_AXI_DMA``J``_arvalid = 1'b0; \
  assign M_AXI_DMA``J``_rready = 1'b1
module otpu_bd_wrapper (
  input  wire         pcie_refclk_clk_p,
  input  wire         pcie_refclk_clk_n,
  input  wire         pcie_perstn,
  input  wire [7:0]   pcie_mgt_rxp,
  input  wire [7:0]   pcie_mgt_rxn,
  output wire [7:0]   pcie_mgt_txp,
  output wire [7:0]   pcie_mgt_txn,
  output wire         pcie_link_up,
  output wire         core_clk,
  output wire         core_clk2x,
  output wire         core_rstn,
  output wire         uclk,
  output wire         urstn,
  output wire         clk100,
  output wire         clk100_rstn,
  output wire         xdma_aclk,
  output wire         xdma_aresetn,
  output wire [9:0]   device_temp,
  output wire [31:0]  M_AXI_CTL_awaddr,
  output wire         M_AXI_CTL_awvalid,
  input  wire         M_AXI_CTL_awready,
  output wire [31:0]  M_AXI_CTL_wdata,
  output wire [3:0]   M_AXI_CTL_wstrb,
  output wire         M_AXI_CTL_wvalid,
  input  wire         M_AXI_CTL_wready,
  input  wire [1:0]   M_AXI_CTL_bresp,
  input  wire         M_AXI_CTL_bvalid,
  output wire         M_AXI_CTL_bready,
  output wire [31:0]  M_AXI_CTL_araddr,
  output wire         M_AXI_CTL_arvalid,
  input  wire         M_AXI_CTL_arready,
  input  wire [31:0]  M_AXI_CTL_rdata,
  input  wire [1:0]   M_AXI_CTL_rresp,
  input  wire         M_AXI_CTL_rvalid,
  output wire         M_AXI_CTL_rready,
  `STUB_DMA(0), `STUB_DMA(1), `STUB_DMA(2), `STUB_DMA(3),
  `STUB_DMA(4), `STUB_DMA(5), `STUB_DMA(6), `STUB_DMA(7)
);
  assign pcie_mgt_txp = '0; assign pcie_mgt_txn = '0; assign pcie_link_up = 1'b0;
  assign core_clk = 1'b0; assign core_clk2x = 1'b0; assign core_rstn = 1'b0;
  assign uclk = 1'b0; assign urstn = 1'b0; assign clk100 = 1'b0; assign clk100_rstn = 1'b0;
  assign xdma_aclk = 1'b0; assign xdma_aresetn = 1'b0; assign device_temp = '0;
  assign M_AXI_CTL_awaddr = '0; assign M_AXI_CTL_awvalid = 1'b0; assign M_AXI_CTL_wdata = '0;
  assign M_AXI_CTL_wstrb = '0; assign M_AXI_CTL_wvalid = 1'b0; assign M_AXI_CTL_bready = 1'b1;
  assign M_AXI_CTL_araddr = '0; assign M_AXI_CTL_arvalid = 1'b0; assign M_AXI_CTL_rready = 1'b1;
  `STUB_DMA_OFF(0); `STUB_DMA_OFF(1); `STUB_DMA_OFF(2); `STUB_DMA_OFF(3);
  `STUB_DMA_OFF(4); `STUB_DMA_OFF(5); `STUB_DMA_OFF(6); `STUB_DMA_OFF(7);
endmodule
`undef STUB_DMA
`undef STUB_DMA_OFF
