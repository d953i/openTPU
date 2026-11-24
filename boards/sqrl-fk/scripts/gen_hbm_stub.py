"""Write boards/sqrl-fk/sim/hbm_0_stub.sv: AMD's HBM IP hbm_0 as an empty module with the ports otpu_hbm
connects (Verilator lint of the FPGA top; the outputs tied to 0)."""
import sys
from pathlib import Path

out = Path(sys.argv[1])
per = [  # (name, dir, width) of AXI_xx_*
    ("ACLK", "input", 1), ("ARESET_N", "input", 1),
    ("ARADDR", "input", 33), ("ARBURST", "input", 2), ("ARID", "input", 6), ("ARLEN", "input", 4),
    ("ARSIZE", "input", 3), ("ARVALID", "input", 1), ("ARREADY", "output", 1),
    ("AWADDR", "input", 33), ("AWBURST", "input", 2), ("AWID", "input", 6), ("AWLEN", "input", 4),
    ("AWSIZE", "input", 3), ("AWVALID", "input", 1), ("AWREADY", "output", 1),
    ("WDATA", "input", 256), ("WLAST", "input", 1), ("WSTRB", "input", 32),
    ("WDATA_PARITY", "input", 32), ("WVALID", "input", 1), ("WREADY", "output", 1),
    ("RREADY", "input", 1), ("RDATA", "output", 256), ("RDATA_PARITY", "output", 32),
    ("RID", "output", 6), ("RLAST", "output", 1), ("RRESP", "output", 2), ("RVALID", "output", 1),
    ("BREADY", "input", 1), ("BID", "output", 6), ("BRESP", "output", 2), ("BVALID", "output", 1),
]
apb = [("PCLK", "input", 1), ("PRESET_N", "input", 1), ("PADDR", "input", 22),
       ("PENABLE", "input", 1), ("PSEL", "input", 1), ("PWDATA", "input", 32),
       ("PWRITE", "input", 1), ("PRDATA", "output", 32), ("PREADY", "output", 1),
       ("PSLVERR", "output", 1)]
ports = [("HBM_REF_CLK_0", "input", 1), ("HBM_REF_CLK_1", "input", 1)]
for i in range(32):
    ports += [(f"AXI_{i:02d}_{n}", d, w) for n, d, w in per]
for s in (0, 1):
    ports += [(f"APB_{s}_{n}", d, w) for n, d, w in apb]
    ports += [(f"apb_complete_{s}", "output", 1), (f"DRAM_{s}_STAT_CATTRIP", "output", 1),
              (f"DRAM_{s}_STAT_TEMP", "output", 7)]
lines = ["// AMD's HBM IP (hbm_0) as an empty module: the ports otpu_hbm connects (written by",
         "// boards/sqrl-fk/scripts, for Verilator's lint of otpu_fpga_top_sqrl_fk only; outputs 0).",
         "module hbm_0 ("]
decl = []
for n, d, w in ports:
    decl.append(f"  {d} wire {'' if w == 1 else f'[{w - 1}:0] '}{n}")
lines.append(",\n".join(decl))
lines.append(");")
for n, d, w in ports:
    if d == "output":
        lines.append(f"  assign {n} = '0;")
lines.append("endmodule")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n")
print(out, len(ports), "ports")
