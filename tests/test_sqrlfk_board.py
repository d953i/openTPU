"""The SQRL FK33 / FK35 at WG 8 (targets/sqrl-fk35.toml) on its board model: otpu_sqrl_fk_sys (otpu_board
at one slice of 8 channels, the WG targets' otpu_hbm_ch bridges, each on one HBM AXI3 port) in front
of models of those ports (sim/verilator/tb_sqrlfk.sv through SimTransport sqrlfk; otpu_hbm_model
PHYS: channel j's image at HBM byte j x 1 GiB), built at the target's parameters: tiny Qwen3 and
Qwen3.5 images bit for bit against the ISA simulator (logits, instruction counts, the slice's DRAM
read back through the host's channel map), with the HBM ports' latency, jitter and stalls. And the FK35's wide
slice (targets/sqrl-fk35w.toml: WG 16 on 16 channels, all 32 HBM ports) and its host-window mux."""
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from opentpu import target as T
from opentpu.host.board import BoardBackend, SimTransport, device_config

ROOT = Path(__file__).resolve().parents[1]
FK = ROOT / "boards" / "sqrl-fk"
BCU = ROOT / "boards" / "bcu1525"

torch = pytest.importorskip("torch")
transformers = pytest.importorskip("transformers")

TARGET = "sqrl-fk35"


def _transport(dram_bytes: int, plusargs: list | None = None,
               target: str = TARGET) -> SimTransport:
    """The board model with `dram_bytes` of dense channel images (the beats past them sparse:
    the HBM models' ch<c>_hi.txt) of `target`'s build."""
    t = T.load(target)
    rp = T.rtl_params(t)
    p = {k: rp[k] for k in ("MCOLS", "LANES", "TMEM_WORDS", "SEQ_WC", "OUTER", "DSTEP2")}
    p |= {"WG": t.arch["WG"], "ACT_ROWS": t.arch["ACT_ROWS"], "NAT_XPOST": 1}
    p |= {k: rp[k] for k in ("ST16", "KT") if k in rp}
    return SimTransport(ch_bytes=dram_bytes // 8, stall=20, seed=5, target=t, sqrlfk=True,
                        params=p, plusargs=plusargs)


def _tiny(model: str):
    if model == "qwen3":
        from opentpu.llm.qwen3 import Spec
        torch.manual_seed(0)
        hc = transformers.Qwen3Config(hidden_size=256, num_hidden_layers=2, num_attention_heads=4,
                                      num_key_value_heads=2, head_dim=128, intermediate_size=512,
                                      vocab_size=1000, rms_norm_eps=1e-6, rope_theta=1e6,
                                      tie_word_embeddings=True, max_position_embeddings=4096)
        mdl = transformers.Qwen3ForCausalLM(hc).float().eval()
        return {k: v.float().numpy() for k, v in mdl.state_dict().items()}, \
            Spec(256, 2, 4, 2, 128, 512, 1000)
    from test_qwen35 import _tiny_model
    _, W, spec = _tiny_model(8, init=0.2)
    return W, spec


# the HBM ports' freedom: latency jitter, R gaps, AR / AW / W stalls (otpu_hbm_model)
HBM = ["+hbm_jit=60", "+hbm_rgap=20", "+hbm_ast=20", "+hbm_wst=20", "+hbm_rbw=80"]


def test_sqrlfk_target():
    t = T.load(TARGET)
    cfg = T.config(t)
    assert (cfg.S, cfg.MCOLS, cfg.WG, cfg.AW) == (1, 8, 8, 33) and cfg.GALL and not cfg.PAIR
    assert cfg.DRAM_BYTES == 8 << 30
    assert t.platform["board"] == "sqrl-fk" and t.platform["channel_bytes"] == 1 << 30
    assert "boards/sqrl-fk/otpu_sqrl_fk_sys.sv" in T.sources(t)


def test_sqrlfk33_is_the_fk35_design_on_one_slr(tmp_path):
    """The FK33 (targets/sqrl-fk33.toml) is the FK35's design on its one SLR: the same arch, RTL and
    otpu_board parameters but for the half-size part's area cuts (SE_R 1, the MXU's result FIFO in block
    RAM), its own part and platform id, PCIe Gen3 x8 (the FK35 Gen4 x8), and make_defines.py's build
    inputs differ only there and in the bridges' pipelines (N 0: no SLR crossing)."""
    a, b = T.load("sqrl-fk35"), T.load("sqrl-fk33")
    assert a.arch == b.arch and T.sources(a) == T.sources(b)
    cuts = {"SE_R": 1, "MXU_RF_STYLE": "block"}
    assert {k for k in a.uarch.keys() | b.uarch.keys() if a.uarch.get(k) != b.uarch.get(k)} == set(cuts)
    assert {k: b.uarch[k] for k in cuts} == cuts
    assert T.rtl_params(a) | {"PLATFORM": 0} | cuts == T.rtl_params(b) | {"PLATFORM": 0}
    assert (b.tech["part"], b.platform_id, b.platform["pcie_gen"]) == ("xcvu33p-fsvh2104-2-e", 8, 3)
    assert a.platform["pcie_gen"] == 4
    par = {}
    for t in ("sqrl-fk35", "sqrl-fk33"):
        subprocess.run([sys.executable, str(FK / "scripts" / "make_defines.py"), str(tmp_path / t),
                        "--target", t], check=True, capture_output=True)
        par[t] = dict(ln.split(" ", 2)[1:] for ln in (tmp_path / t / "fk_params.tcl").read_text()
                      .splitlines() if ln.startswith("set "))
    assert (par["sqrl-fk35"]["RLY"], par["sqrl-fk33"]["RLY"]) == ("55555555", "00000000")
    assert (par["sqrl-fk35"]["PCIE_GEN"], par["sqrl-fk33"]["PCIE_GEN"]) == ("4", "3")
    assert {k for k in par["sqrl-fk35"] if par["sqrl-fk35"][k] != par["sqrl-fk33"][k]} == \
        {"TARGET", "PART", "RLY", "PCIE_GEN"}


def test_sqrlfk_targets_drive_two_hbm_ports_a_channel(tmp_path):
    """Both FK targets build their bridges on two HBM ports a channel (platform hbm_ports 2:
    make_defines.py's HNP, the top's generic), and --hnp 1 gives the one-port build."""
    for t in ("sqrl-fk35", "sqrl-fk33"):
        assert T.load(t).platform["hbm_ports"] == 2
    for args, hnp in (([], "2"), (["--hnp", "1"], "1")):
        d = tmp_path / hnp
        subprocess.run([sys.executable, str(FK / "scripts" / "make_defines.py"), str(d), *args],
                       check=True, capture_output=True)
        assert f"set HNP {hnp}\n" in (d / "fk_params.tcl").read_text()


@pytest.mark.parametrize("hnp", [1, 2])
def test_sqrlfk_top_lints_against_the_block_designs_ports(have_verilator, tmp_path, hnp):
    """Verilator lint of otpu_fpga_top_sqrl_fk (its RTL, make_defines.py's defines) against the block
    design's wrapper as bd.tcl declares it (boards/sqrl-fk/sim/otpu_bd_wrapper_stub.sv) and the HBM
    IP's ports (hbm_0_stub.sv): no error, and in the board's files no warning but the flip-flops'
    initial values (PROCASSINIT) -- the ports' widths included; a bridge on one HBM port a channel
    and on two (HNP)."""
    subprocess.run([sys.executable, str(FK / "scripts" / "make_defines.py"), str(tmp_path)],
                   check=True, capture_output=True)
    rtl = [str(ROOT / "rtl" / f) for f in T.sources(TARGET)]
    r = subprocess.run(
        ["verilator", "--lint-only", "-Wall", "-Wno-fatal", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM",
         "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-GENUNNAMED", "-Wno-VARHIDDEN",
         "-DSYNTHESIS", "-DOTPU_FPGA_INIT", "--top-module", "otpu_fpga_top_sqrl_fk", f"-GHNP={hnp}",
         str(BCU / "sim" / "unisim_dsp48e2_stub.sv"), str(BCU / "sim" / "unisim_stubs.sv"),
         str(tmp_path / "otpu_sqrl_fk_defines.vh"), *rtl,
         str(FK / "sim" / "otpu_bd_wrapper_stub.sv"), str(FK / "sim" / "hbm_0_stub.sv")],
        capture_output=True, text=True)
    msgs = [m for m in (r.stdout + r.stderr).splitlines() if m.startswith("%")]
    assert not [m for m in msgs if m.startswith("%Error")], msgs[:20]
    fk = ("otpu_fpga_top_sqrl_fk.sv", "otpu_sqrl_fk_sys.sv")
    bad = [m for m in msgs if any(f in m for f in fk) and "PROCASSINIT" not in m]
    assert not bad, bad[:20]


@pytest.mark.parametrize("model,wf,plus,hnp", [
    ("qwen3", "int8", [], 2),
    ("qwen35", "fp4", [], 2),
    ("qwen35", "fp4", HBM, 2),
    ("qwen35", "fp4", HBM, 1),
], ids=["qwen3-int8", "qwen35-fp4", "qwen35-fp4-hbm", "qwen35-fp4-hbm-1port"])
def test_sqrlfk_tiny_models_on_board_model(have_verilator, model, wf, plus, hnp):
    """hnp: the HBM ports a channel (2, the targets': each bridge on two port models, CAPS2 bit26;
    1: the one-port build)."""
    from opentpu.llm.qwen3 import Engine
    W, spec = _tiny(model)
    t = T.load(TARGET)
    need = spec.image(T.config(t), 256, wformat=wf).nbytes
    cfg = T.config(t, DRAM_BYTES=1 << max(22, (need - 1).bit_length() + 1))
    tr = _transport(cfg.DRAM_BYTES, plus)
    tr.params["HNP"] = hnp
    top, srcs, p = tr.sim_build()
    defs = srcs[0].read_text()                   # (OTPU_BOARD: otpu_board's parameters)
    assert all(f".{k}({v})" in defs for k, v in (("NAT_XPOST", 1), ("WG", 8), ("MCOLS", 8)))
    assert p["HNP"] == hnp
    isa = Engine(spec, W, cap=256, cfg=cfg, wformat=wf)
    brd = Engine(spec, W, cap=256, cfg=cfg, wformat=wf,
                 backend=lambda c, m: BoardBackend(c, m, transport=tr))
    info = brd.backend.info
    assert (info["cfg"]["S"], info["cfg"]["channels"], info["cfg"]["WG"]) == (1, 8, 8)
    assert info["caps2"]["chilv"] == (hnp == 2)
    assert info["cfg"]["platform"] == t.platform_id
    assert device_config(info).WG == 8
    for tok in (11, 222, 333):
        a, b = isa.step(tok), brd.step(tok)
        assert np.array_equal(a.view(np.uint32), b.view(np.uint32)), isa.pos
        assert brd.stats[-1]["instructions"] == isa.stats[-1]["instructions"]


# ---- the FK35's wide slice (targets/sqrl-fk35w.toml): MCOLS 16 / WG 16 on 16 channels of 512 MiB, all 32 HBM
# ports (channel c on ports 2c, 2c + 1; the host's window k shares port 4k + 1 through otpu_axi3_hmux)
WIDE = "sqrl-fk35w"


def test_sqrlfk35w_target(tmp_path):
    """The wide target is the FK35's but for the slice's width (MCOLS / WG 16), its channels (16 of 512 MiB),
    SE_R 1 and the MXU's result FIFO in block RAM (area); its own platform id; make_defines.py writes 16
    channels' bridge pipelines (RLY 64 bits) and SNCH 16."""
    a, w = T.load(TARGET), T.load(WIDE)
    cfg = T.config(w)
    assert (cfg.S, cfg.MCOLS, cfg.WG, cfg.AW, cfg.DRAM_BYTES) == (1, 16, 16, 33, 8 << 30)
    assert (w.platform["channels_per_slice"], w.platform["channel_bytes"], w.platform["hbm_ports"]) == \
        (16, 1 << 29, 2)
    assert w.platform_id == 9 and T.by_platform(9).name == WIDE
    diff = {k for k in a.uarch.keys() | w.uarch.keys() if a.uarch.get(k) != w.uarch.get(k)}
    assert diff == {"SE_R", "MXU_RF_STYLE"}, diff
    assert "boards/sqrl-fk/otpu_axi3_hmux.sv" in T.sources(w)
    subprocess.run([sys.executable, str(FK / "scripts" / "make_defines.py"), str(tmp_path), "--target", WIDE],
                   check=True, capture_output=True)
    par = dict(ln.split(" ", 2)[1:] for ln in (tmp_path / "fk_params.tcl").read_text().splitlines()
               if ln.startswith("set "))
    assert (par["SNCH"], par["RLY"], par["HNP"]) == ("16", "5" * 16, "2")


def test_sqrlfk35w_top_lints(have_verilator, tmp_path):
    """Verilator lint of the wide top (NCH 16: 16 bridges on all 32 HBM ports, the host windows' muxes)
    against the block design's and the HBM IP's ports: no error, and in the board's files no warning but
    the flip-flops' initial values."""
    subprocess.run([sys.executable, str(FK / "scripts" / "make_defines.py"), str(tmp_path), "--target", WIDE],
                   check=True, capture_output=True)
    rtl = [str(ROOT / "rtl" / f) for f in T.sources(WIDE)]
    r = subprocess.run(
        ["verilator", "--lint-only", "-Wall", "-Wno-fatal", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM",
         "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-GENUNNAMED", "-Wno-VARHIDDEN",
         "-DSYNTHESIS", "-DOTPU_FPGA_INIT", "--top-module", "otpu_fpga_top_sqrl_fk", "-GHNP=2", "-GNCH=16",
         "-GRLY=64'h5555555555555555",
         str(BCU / "sim" / "unisim_dsp48e2_stub.sv"), str(BCU / "sim" / "unisim_stubs.sv"),
         str(tmp_path / "otpu_sqrl_fk_defines.vh"), *rtl,
         str(FK / "sim" / "otpu_bd_wrapper_stub.sv"), str(FK / "sim" / "hbm_0_stub.sv")],
        capture_output=True, text=True)
    msgs = [m for m in (r.stdout + r.stderr).splitlines() if m.startswith("%")]
    assert not [m for m in msgs if m.startswith("%Error")], msgs[:20]
    fk = ("otpu_fpga_top_sqrl_fk.sv", "otpu_sqrl_fk_sys.sv", "otpu_axi3_hmux.sv")
    bad = [m for m in msgs if any(f in m for f in fk) and "PROCASSINIT" not in m]
    assert not bad, bad[:20]


def test_axi3_hmux_stress(have_verilator, tmp_path):
    """otpu_axi3_hmux (sim/verilator/tb_hmux.sv): a bridge master on the port's clock and a host master on
    its own (450 / 250 MHz) write and read back their regions through one port model that interleaves the
    IDs' R beats and B responses, with random gaps and stalls; every read beat checked, three seeds."""
    rtl = ROOT / "rtl"
    b = subprocess.run(
        ["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal", "-Wno-lint", "-Wno-style",
         "--top-module", "tb_hmux", "--Mdir", str(tmp_path / "obj"), "-o", "tb",
         str(ROOT / "sim" / "verilator" / "tb_hmux.sv"), str(rtl / "boards" / "sqrl-fk" / "otpu_axi3_hmux.sv"),
         str(rtl / "shell" / "otpu_afifo.sv"), str(rtl / "mem" / "otpu_axi_rs.sv")],
        capture_output=True, text=True)
    assert b.returncode == 0, (b.stdout + b.stderr)[-3000:]
    for seed in (1, 2, 3):
        r = subprocess.run([str(tmp_path / "obj" / "tb"), f"+seed={seed}", "+n=400"],
                           capture_output=True, text=True, timeout=600)
        out = r.stdout + r.stderr
        assert "PASS" in out.split() and "FAIL" not in out and "ERROR" not in out, out[-2000:]


def _wide_transport(dram_bytes: int, plusargs: list | None = None) -> SimTransport:
    t = T.load(WIDE)
    rp = T.rtl_params(t)
    p = {k: rp[k] for k in ("MCOLS", "LANES", "TMEM_WORDS", "SEQ_WC", "OUTER", "DSTEP2")}
    p |= {"WG": t.arch["WG"], "ACT_ROWS": t.arch["ACT_ROWS"], "NAT_XPOST": 1}
    p |= {k: rp[k] for k in ("ST16", "KT") if k in rp}
    p["RLY"] = 0x5555555555555555
    return SimTransport(ch_bytes=dram_bytes // 16, stall=20, seed=5, target=t, sqrlfk=True, params=p,
                        plusargs=plusargs)


@pytest.mark.parametrize("model,wf,plus", [
    ("qwen3", "int8", []),
    ("qwen35", "fp4", HBM),
], ids=["qwen3-int8", "qwen35-fp4-hbm"])
def test_sqrlfk35w_tiny_models_on_board_model(have_verilator, model, wf, plus):
    """The wide slice on its board model (otpu_sqrl_fk_sys at NCH 16, 32 HBM port models): tiny Qwen3 int8
    and Qwen3.5 fp4 (with the ports' jitter and stalls) token for token against the ISA simulator."""
    from opentpu.llm.qwen3 import Engine
    W, spec = _tiny(model)
    t = T.load(WIDE)
    need = spec.image(T.config(t), 256, wformat=wf).nbytes
    cfg = T.config(t, DRAM_BYTES=1 << max(23, (need - 1).bit_length() + 1))
    tr = _wide_transport(cfg.DRAM_BYTES, plus)
    top, srcs, p = tr.sim_build()
    defs = srcs[0].read_text()
    assert all(f".{k}({v})" in defs for k, v in (("NAT_XPOST", 1), ("WG", 16), ("MCOLS", 16)))
    assert p["HNP"] == 2 and p["NCH"] == 16
    isa = Engine(spec, W, cap=256, cfg=cfg, wformat=wf)
    brd = Engine(spec, W, cap=256, cfg=cfg, wformat=wf,
                 backend=lambda c, m: BoardBackend(c, m, transport=tr))
    info = brd.backend.info
    assert (info["cfg"]["S"], info["cfg"]["channels"], info["cfg"]["WG"]) == (1, 16, 16)
    assert info["caps2"]["chilv"] and info["cfg"]["platform"] == 9
    assert device_config(info).WG == 16
    for tok in (11, 222, 333):
        a, b = isa.step(tok), brd.step(tok)
        assert np.array_equal(a.view(np.uint32), b.view(np.uint32)), isa.pos
        assert brd.stats[-1]["instructions"] == isa.stats[-1]["instructions"]
