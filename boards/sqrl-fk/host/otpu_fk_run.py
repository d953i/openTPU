"""Run an openTPU tool or script on a SQRL FK33 / FK35 (docs/sqrl-fk.md "Windows host", docs/sqrl-fk-quickstart.md),
on Windows or Linux. On Windows the host runs unchanged over SQRL's driver sqrlfk.sys (sqrlfk.py) instead of Linux's
XDMA devices, with what it takes from POSIX (winposix.py); on Linux over openTPU's XDMA driver (otpu-setup) as is.
Both: the card's target found by itself, the disk caches in the repository, chat / serve with the largest context the
card holds. otpu-fk.cmd (Windows) and boards/sqrl-fk/linux/*.sh run it:

    otpu-fk -m opentpu.host.selftest              # the staged card test (--model qwen35: models/Qwen3.5-0.8B)
    otpu-fk -m opentpu.host.smi --dev sqrlfk0     # the monitor
    otpu-fk tools/qual/perf.py <model dir> fp4    # a script, as __main__ with the remaining arguments
    otpu-fk chat [MODEL] [options]                # opentpu.host.chat --backend board (MODEL: a folder of models/ or
    otpu-fk serve [MODEL] [options]               #   a path, default Qwen3.5-9B; --wformat fp4 unless given; --cap:
                                                  #   the most that fits the card)

OTPU_TARGET: the card's target; unset, the one the card reports (its CFG_PLATFORM: sqrl-fk33 or sqrl-fk35).
--dev: Windows, a board index, sqrlfk<n>, \\\\.\\SqrlFk<n> or /dev/xdma<n> (board n); Linux, /dev/xdma<n>. The disk
caches (compiled programs, 4-bit matrices, model images) under OTPU_CACHE_ROOT, default build/otpu-cache of the
repository.
"""
from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
WIN = sys.platform == "win32"
for p in ((str(HERE), str(ROOT)) if WIN else (str(ROOT),)):
    if p not in sys.path:
        sys.path.insert(0, p)
os.environ.setdefault("TORCHDYNAMO_DISABLE", "1")    # (transformers' compiled helpers need cl.exe on Windows)
CACHE = Path(os.environ.get("OTPU_CACHE_ROOT", ROOT / "build" / "otpu-cache"))
for var, sub in (("OTPU_PROG_CACHE", "prog"), ("OTPU_IMAGE_CACHE", "qcache"), ("OTPU_IMG_CACHE", "img")):
    os.environ.setdefault(var, str(CACHE / sub))
    os.makedirs(os.environ[var], exist_ok=True)
os.environ.setdefault("OTPU_PROG_CACHE_GB", "8")
os.environ.setdefault("OTPU_IMG_CACHE_GB", "64")

if WIN:
    import winposix

    winposix.apply()
    winposix.patch_runstate()
import opentpu.host.board as board  # noqa: E402

if WIN and not getattr(board.XdmaTransport, "_sqrlfk", False):
    from sqrlfk import SqrlFkTransport

    def _transport(dev=None, *args, **kw):
        return SqrlFkTransport(dev, *args, **kw)

    _transport._sqrlfk = True
    board.XdmaTransport = _transport
    _open_transport = board.open_transport

    def _open(dev=None, *args, **kw):
        """open_transport's names, and sqrlfk<n> / \\\\.\\SqrlFk<n> (no "/": upstream's would refuse them)."""
        import re
        if dev and "+" not in dev and re.fullmatch(r"(?i)(sqrlfk|\\\\\.\\sqrlfk)\d+", dev):
            return SqrlFkTransport(dev, dma=kw.get("dma", args[0] if args else True))
        return _open_transport(dev, *args, **kw)

    board.open_transport = _open

MODELS = ROOT / "models"


def _detect_target() -> None:
    """OTPU_TARGET unset: the card's own (its CFG_PLATFORM register, opentpu.target.by_platform: sqrl-fk33 or
    sqrl-fk35), so nobody has to name it; sqrl-fk35 when the card cannot be read. The card: --dev's, else board 0
    (Windows) or the one openTPU card present (Linux). Registers only: no device lock, no DMA."""
    if os.environ.get("OTPU_TARGET"):
        return
    from opentpu import target as T
    from opentpu.host import regs as R
    dev = sys.argv[sys.argv.index("--dev") + 1] if "--dev" in sys.argv[:-1] else None
    name = "sqrl-fk35"
    try:
        if WIN:
            import re

            from sqrlfk import SqrlFk, device_path
            fk = SqrlFk(device_path(dev)[1] if dev and re.search(r"\d+$", dev) else 0)
            try:
                pid = fk.bar_read(0, R.R_CFG_PLATFORM)
            finally:
                fk.close()
        else:
            t = board.open_transport(dev, dma=False)
            try:
                pid = t.reg_read(R.R_CFG_PLATFORM)
            finally:
                t.close()
        found = T.by_platform(pid)
        if found is not None:
            name = found.name
    except Exception:
        pass
    os.environ["OTPU_TARGET"] = name


_detect_target()

DEFAULT_WFORMAT = "fp4"     # chat / serve without --wformat: 4-bit weights (the 9B fits only so; the fastest decode)


def max_cap(model, args) -> int:
    """The largest KV capacity (a multiple of 256, at most the model's max_position_embeddings) whose image, in the
    weight format of `args` (--wformat / --head-format, default auto), fits the card's DRAM (OTPU_TARGET): the
    image's layout alone, no weights read. 0 when not even 256 tokens fit (or the format does not apply)."""
    import json
    from dataclasses import replace

    from opentpu import target as T
    from opentpu.llm import formats as FM
    from opentpu.llm import load_spec
    from opentpu.llm.qwen3 import PREFILL_ROWS

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default

    spec = load_spec(model)
    try:
        wformat, formats = FM.named(spec, FM.auto(spec, opt("--wformat", FM.AUTO)), None)
    except Exception:                       # (e.g. "mix" for a model without a recommended mix)
        return 0
    if formats:
        spec = replace(spec, formats=formats)
    cfg = T.config(os.environ["OTPU_TARGET"])
    big = replace(cfg, DRAM_BYTES=1 << 40)
    c = json.loads(open(os.path.join(model, "config.json")).read())
    top = c.get("text_config", c).get("max_position_embeddings", 32768) // 256 * 256

    def fits(cap):
        try:
            return spec.image(big, cap, 1, PREFILL_ROWS, wformat, opt("--head-format"),
                              lookup=True).nbytes <= cfg.DRAM_BYTES
        except Exception:
            return False

    if fits(top):
        cap = top
    elif not fits(256):
        return 0
    else:
        lo, hi = 256, top
        while hi - lo > 256:
            mid = (lo + hi) // 2 // 256 * 256
            lo, hi = (mid, hi) if fits(mid) else (lo, mid)
        cap = lo
    print(f"weights: {opt('--wformat', 'auto')}; context: {cap} tokens (the most this model and format fit on "
          f"{os.environ['OTPU_TARGET']})", flush=True)
    return cap


def pick_format(model, args) -> tuple[list, int]:
    """Without --wformat: DEFAULT_WFORMAT (4-bit; otpu-chat's own default, auto, is int8 for Qwen3.5-9B, whose image
    needs 11.7 GB of the card's 8) as --wformat arguments; with it, as given. And the most context that fits."""
    extra = [] if "--wformat" in args else ["--wformat", DEFAULT_WFORMAT]
    return extra, max_cap(model, args + extra)


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    if sys.argv[1] in ("chat", "serve"):
        mod = "opentpu.host.chat" if sys.argv[1] == "chat" else "opentpu.serve.api"
        rest = sys.argv[2:]
        model = "Qwen3.5-9B"
        if rest and not rest[0].startswith("-"):
            model = rest.pop(0)
        if (MODELS / model / "config.json").is_file():
            model = str(MODELS / model)
        if "--cap" not in rest:
            extra, cap = pick_format(model, rest)
            if not cap:
                raise SystemExit(f"{model}: does not fit the card's {os.environ['OTPU_TARGET']} memory in any weight "
                                 f"format (try a smaller model)")
            rest += extra + ["--cap", str(cap)]
        if mod == "opentpu.host.chat" and "--max-new" not in rest:
            # a reply of up to 8192 tokens (otpu-chat's 1024 stops long answers for a /continue)
            rest += ["--max-new", str(min(8192, int(rest[rest.index("--cap") + 1])))]
        sys.argv = [mod, "--backend", "board", "--model", model] + rest
        runpy.run_module(mod, run_name="__main__", alter_sys=True)
    elif sys.argv[1] == "-m":
        mod = sys.argv[2]
        sys.argv = [mod] + sys.argv[3:]
        runpy.run_module(mod, run_name="__main__", alter_sys=True)
    else:
        sys.argv = sys.argv[1:]
        if not os.path.exists(sys.argv[0]) and (ROOT / sys.argv[0]).is_file():
            sys.argv[0] = str(ROOT / sys.argv[0])         # (tools\qual\perf.py from any folder)
        runpy.run_path(sys.argv[0], run_name="__main__")


# (a script it runs may import max_cap from here: only the process's own entry dispatches)
if __name__ == "__main__":
    main()
