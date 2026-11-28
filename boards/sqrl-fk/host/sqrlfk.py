"""openTPU's card transport on Windows: the SQRL FK33/FK35 KMDF driver sqrlfk.sys (the SQRL_FK33 repository's
driver/windows, driver 2.1 or later) instead of Linux's XDMA character devices (docs/sqrl-fk.md "Windows host").

SqrlFkTransport has the interface of upstream opentpu.host.board.XdmaTransport (and vcu128_otpu's EthTransport), so

    from opentpu.host.board import Board
    from sqrlfk import SqrlFkTransport
    b = Board(transport=SqrlFkTransport())

works as with upstream's card: mem_write / mem_read (channel j = 2s + c, offset in the channel; card address
bases[j] + off, bases from the CFG registers through Board.info), reg_write / reg_read / reg_read_many (BAR0, the
block design's AXI-Lite bus: openTPU's control registers at 0x0000), poll, close; the attributes Board reads
(threaded, streams, ecc, run_h2c, host_idle, bases, devname, poll_exact, the _dma lock). It is a subclass of
XdmaTransport: the poll algorithm, the run-time H2C limit and the DMA lock are upstream's.

The driver's requests (sqrlfk_ioctl.h), through ctypes DeviceIoControl on \\\\.\\SqrlFk<index>:
  - BAR_READ / BAR_WRITE: one register (~1.7 us); REG_BATCH: up to 4096 reads and writes (~1.07 us each);
  - DMA_WRITE_DIRECT / DMA_READ_DIRECT: up to 256 MB from or into the caller's buffer, which the driver moves through
    its 4 MB DMA buffer in halves (lengths a multiple of 4: whole 64-byte beats here).
The driver's I/O queue is sequential: one request at a time on the device, whichever handle or thread sends it, so a
DMA call of DMA_CHUNK bytes delays another thread's register access by up to a few ms (correct, only slower).

otpu_fk_run.py (here) installs it in place of XdmaTransport (and makes the host run on Windows: winposix.py) for
openTPU's tools, e.g. `otpu-fk -m opentpu.host.selftest`.
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as W
import re

import numpy as np

from opentpu.host.board import BEAT, XdmaTransport, _dma_lock
from opentpu.host.runstate import DeviceLock

# ------------------------------------------------------------------------------ sqrlfk_ioctl.h (driver 2.1)
DRIVER_MIN = 0x00020001             # REG_BATCH, POLL, the direct DMA requests
NO_BAR = 0xFFFFFFFF
REG_OPS_MAX = 4096
DMA_DIRECT_MAX = 256 << 20
_TYPE = 0x8A35
_R, _W = 1, 2                       # FILE_READ_ACCESS, FILE_WRITE_ACCESS


def _ctl(function: int, method: int, access: int) -> int:
    return (_TYPE << 16) | (access << 14) | (function << 2) | method


GTS = {1: "2.5", 2: "5.0", 3: "8.0", 4: "16.0", 5: "32.0"}     # DEVPKEY_PciDevice_*LinkSpeed codes


def _pnp_link(vendor_device: int, bus: int) -> str | None:
    """'16.0 GT/s x4' of the present PCI device VEN/DEV (VendorDevice: vendor in the low 16 bits) on `bus`, from
    Windows' PnP properties (PowerShell's Get-PnpDeviceProperty); None if there is no such device or no answer."""
    import subprocess
    ven, dev = vendor_device & 0xFFFF, vendor_device >> 16
    ps = (f"Get-PnpDevice -PresentOnly | Where-Object {{ $_.InstanceId -like 'PCI\\VEN_{ven:04X}&DEV_{dev:04X}*' }} | "
          "ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName "
          "DEVPKEY_Device_BusNumber,DEVPKEY_PciDevice_CurrentLinkSpeed,DEVPKEY_PciDevice_CurrentLinkWidth | "
          "ForEach-Object { $_.Data }) -join ',' }")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True,
                             text=True, timeout=20, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.split():
        f = line.split(",")
        if len(f) == 3 and f[0].isdigit() and int(f[0]) == bus and f[1].isdigit() and f[2].isdigit():
            return f"{GTS.get(int(f[1]), f[1])} GT/s x{int(f[2])}"
    return None


IOCTL_GET_INFO = _ctl(0x800, 0, _R)
IOCTL_BAR_READ = _ctl(0x804, 0, _R)
IOCTL_BAR_WRITE = _ctl(0x805, 0, _R | _W)
IOCTL_REG_BATCH = _ctl(0x808, 0, _R | _W)
IOCTL_POLL = _ctl(0x809, 0, _R)
IOCTL_DMA_WRITE_DIRECT = _ctl(0x80A, 1, _R | _W)    # METHOD_IN_DIRECT
IOCTL_DMA_READ_DIRECT = _ctl(0x80B, 2, _R | _W)     # METHOD_OUT_DIRECT


class INFO(ctypes.Structure):
    _fields_ = [("Version", W.ULONG), ("VendorDevice", W.ULONG), ("BusNumber", W.ULONG), ("Address", W.ULONG),
                ("McapOffset", W.ULONG), ("DmaBar", W.ULONG), ("BarAddress", ctypes.c_uint64 * 6),
                ("BarLength", W.ULONG * 6), ("DmaBufferSize", W.ULONG), ("Reserved", W.ULONG)]


class DMA(ctypes.Structure):
    _fields_ = [("CardAddress", ctypes.c_uint64), ("Length", W.ULONG), ("Channel", W.ULONG)]


class ACCESS(ctypes.Structure):
    _fields_ = [("Bar", W.ULONG), ("Offset", W.ULONG), ("Value", W.ULONG)]


class REG_OP(ctypes.Structure):
    _fields_ = [("Op", W.ULONG), ("Bar", W.ULONG), ("Offset", W.ULONG), ("Value", W.ULONG)]


class POLL(ctypes.Structure):
    _fields_ = [("Bar", W.ULONG), ("Offset", W.ULONG), ("Mask", W.ULONG), ("Value", W.ULONG),
                ("TimeoutUs", W.ULONG), ("SpinUs", W.ULONG)]


class POLL_RESULT(ctypes.Structure):
    _fields_ = [("Done", W.ULONG), ("Last", W.ULONG), ("Reads", W.ULONG), ("Reserved", W.ULONG),
                ("Nanoseconds", ctypes.c_uint64)]


REG_READ, REG_WRITE = 0, 1

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateFileW.argtypes = [W.LPCWSTR, W.DWORD, W.DWORD, W.LPVOID, W.DWORD, W.DWORD, W.HANDLE]
_k32.CreateFileW.restype = W.HANDLE
_k32.DeviceIoControl.argtypes = [W.HANDLE, W.DWORD, W.LPVOID, W.DWORD, W.LPVOID, W.DWORD,
                                 ctypes.POINTER(W.DWORD), W.LPVOID]
_k32.DeviceIoControl.restype = W.BOOL
_k32.CloseHandle.argtypes = [W.HANDLE]
_k32.CloseHandle.restype = W.BOOL
_INVALID = W.HANDLE(-1).value
_GENERIC_RW = 0x80000000 | 0x40000000
_SHARE_RW = 0x1 | 0x2
_OPEN_EXISTING = 3


def device_path(dev: str | int | None = 0) -> tuple[str, int]:
    """\\\\.\\SqrlFk<index> and the index for a board index, a path, "sqrlfk<n>", or None / an upstream Linux node
    (/dev/xdma<n>: board n), so upstream's --dev default still names the first board."""
    if dev is None:
        n = 0
    elif isinstance(dev, int):
        n = dev
    else:
        m = re.search(r"(\d+)$", str(dev))
        n = int(m.group(1)) if m else 0
    return rf"\\.\SqrlFk{n}", n


class SqrlFk:
    """One board through sqrlfk.sys: the driver's requests, nothing of openTPU's (sqrl_fk_mcap.c's in Python)."""

    def __init__(self, dev: str | int | None = 0):
        self.path, self.index = device_path(dev)
        self.handle = None
        h = _k32.CreateFileW(self.path, _GENERIC_RW, _SHARE_RW, None, _OPEN_EXISTING, 0, None)
        if h is None or h == _INVALID:
            err = ctypes.get_last_error()
            raise OSError(None, f"{self.path}: cannot open the SQRL FK board (sqrlfk.sys not installed, or no board "
                                f"{self.index}): {ctypes.FormatError(err).strip()}", self.path, err)
        self.handle = h
        self.info = INFO()
        self._ioctl(IOCTL_GET_INFO, None, 0, ctypes.byref(self.info), ctypes.sizeof(self.info))
        if self.info.Version < DRIVER_MIN:
            v = self.info.Version
            self.close()
            raise RuntimeError(f"{self.path}: sqrlfk.sys {v >> 16}.{v & 0xFFFF}: driver 2.1 or later needed "
                               "(register batches, polls, direct DMA)")

    def close(self) -> None:
        if self.handle is not None:
            _k32.CloseHandle(self.handle)
            self.handle = None

    def _ioctl(self, code: int, inp, insize: int, out, outsize: int) -> int:
        got = W.DWORD(0)
        if not _k32.DeviceIoControl(self.handle, code, inp, insize, out, outsize, ctypes.byref(got), None):
            err = ctypes.get_last_error()
            raise OSError(None, f"{self.path}: request {code:#x}: {ctypes.FormatError(err).strip()}", self.path, err)
        return got.value

    def bar_read(self, bar: int, off: int) -> int:
        a, v = ACCESS(bar, off, 0), W.ULONG(0)
        self._ioctl(IOCTL_BAR_READ, ctypes.byref(a), ctypes.sizeof(a), ctypes.byref(v), 4)
        return v.value

    def bar_write(self, bar: int, off: int, val: int) -> None:
        a = ACCESS(bar, off, val & 0xFFFFFFFF)
        self._ioctl(IOCTL_BAR_WRITE, ctypes.byref(a), ctypes.sizeof(a), None, 0)

    def reg_batch(self, ops: list[tuple[int, int, int, int]]) -> list[int]:
        """(op, bar, offset, value) in order, REG_OPS_MAX a request: each read's value (0 for a write)."""
        out: list[int] = []
        for i in range(0, len(ops), REG_OPS_MAX):
            part = ops[i:i + REG_OPS_MAX]
            req = (REG_OP * len(part))(*[REG_OP(o, b, a, v & 0xFFFFFFFF) for o, b, a, v in part])
            res = (W.ULONG * len(part))()
            self._ioctl(IOCTL_REG_BATCH, req, ctypes.sizeof(req), res, ctypes.sizeof(res))
            out += list(res)
        return out

    def poll(self, bar: int, off: int, mask: int, val: int, timeout_us: int, spin_us: int) -> POLL_RESULT:
        """(reg & mask) == val, read by the driver: back to back for spin_us, then once per timer tick; at most 1 s."""
        q, r = POLL(bar, off, mask, val, timeout_us, spin_us), POLL_RESULT()
        self._ioctl(IOCTL_POLL, ctypes.byref(q), ctypes.sizeof(q), ctypes.byref(r), ctypes.sizeof(r))
        return r

    def dma(self, c2h: bool, card: int, addr: int, n: int, channel: int = 0) -> None:
        """n bytes (a multiple of 4, at most DMA_DIRECT_MAX) between host address `addr` and the XDMA AXI address `card`."""
        q = DMA(card, n, channel)
        self._ioctl(IOCTL_DMA_READ_DIRECT if c2h else IOCTL_DMA_WRITE_DIRECT, ctypes.byref(q), ctypes.sizeof(q),
                    ctypes.c_void_p(addr), n)


# ------------------------------------------------------------------------------ the transport
BAR = 0                     # BAR0: the block design's AXI-Lite bus (openTPU 0x0000, DNA 0x1000 / 0x7000, ...)
DMA_CHUNK = 8 << 20         # bytes per DMA request: as upstream's XdmaTransport calls (its DMA lock's granularity)


class SqrlFkTransport(XdmaTransport):
    """The card through sqrlfk.sys. dev: a board index, \\\\.\\SqrlFk<n>, or upstream's /dev/xdma<n> (board n);
    dma=False: register access only (monitors), no device lock and no DMA."""
    ecc = False                 # HBM, no ECC: no Board.scrub after configuration

    def __init__(self, dev: str | int | None = 0, dma: bool = True):
        path, n = device_path(dev)
        self.dev, self.devname = path, f"sqrlfk{n}"
        self.fk = None
        self.dma_enabled = dma
        # As upstream: the device lock comes before the device is opened.
        self._otpu_lock = DeviceLock(self.devname) if dma else None
        self._dma = _dma_lock(self.devname)
        try:
            self.fk = SqrlFk(n)
        except BaseException:
            self.close()
            raise
        self.bar_bytes = self.fk.info.BarLength[BAR]
        self._link = None

    def pcie_link(self) -> str | None:
        """'8.0 GT/s x8' (upstream's sysfs form, otpu-smi), the link the card trained to: Windows' PnP properties of
        the PCI device on the driver's bus (DEVPKEY_PciDevice_CurrentLinkSpeed / Width), read once (PowerShell,
        about a second); None if unknown."""
        if self._link is None:
            self._link = _pnp_link(self.fk.info.VendorDevice, self.fk.info.BusNumber) or ""
        return self._link or None

    def close(self) -> None:
        if getattr(self, "fk", None) is not None:
            self.fk.close()
            self.fk = None
        if getattr(self, "_otpu_lock", None) is not None:
            self._otpu_lock.release()
            self._otpu_lock = None

    # ---------------------------------------------------------------- memory
    def mem_write(self, ch: int, off: int, data: np.ndarray) -> None:
        """Whole 64-byte beats only, as upstream's: a range off the beat grid is widened, its edge beats read and
        merged here (sub-beat writes can wedge the card's write path: upstream docs/host.md)."""
        a = np.ascontiguousarray(data, np.uint8).reshape(-1)
        if len(a) == 0:
            return
        if off % BEAT or len(a) % BEAT:
            o0, o1 = off // BEAT * BEAT, -(-(off + len(a)) // BEAT) * BEAT
            if o1 - o0 == BEAT:
                buf = self.mem_read(ch, o0, BEAT)
            else:
                buf = np.empty(o1 - o0, np.uint8)
                buf[:BEAT] = self.mem_read(ch, o0, BEAT)
                buf[-BEAT:] = self.mem_read(ch, o1 - BEAT, BEAT)
            buf[off - o0:off - o0 + len(a)] = a
            a, off = buf, o0
        base, addr = self.bases[ch] + off, a.ctypes.data
        for pos in range(0, len(a), DMA_CHUNK):
            k = min(DMA_CHUNK, len(a) - pos)
            with self._dma:                             # never during a card->host call (upstream's _DmaLock)
                self.fk.dma(False, base + pos, addr + pos, k)

    def mem_read(self, ch: int, off: int, n: int, out: np.ndarray | None = None) -> np.ndarray:
        """n bytes of channel `ch` at `off`, DMA'd into `out` (or a new buffer). The DMA is of whole beats: a range
        off the beat grid, or an `out` that is not contiguous, goes through a bounce buffer."""
        buf = np.empty(n, np.uint8) if out is None else out
        if n == 0:
            return buf
        if not buf.flags.c_contiguous:                  # (upstream's memoryview cast refuses one too)
            raise ValueError("mem_read: out must be C-contiguous")
        flat = buf.reshape(-1).view(np.uint8)           # a view: the bytes land in `buf`
        if flat.nbytes < n:
            raise ValueError(f"mem_read: out holds {flat.nbytes} bytes, {n} asked")
        o0, o1 = off // BEAT * BEAT, -(-(off + n) // BEAT) * BEAT
        direct = (o0, o1) == (off, off + n)
        tgt = flat if direct else np.empty(o1 - o0, np.uint8)
        base, addr = self.bases[ch] + o0, tgt.ctypes.data
        for pos in range(0, o1 - o0, DMA_CHUNK):
            k = min(DMA_CHUNK, o1 - o0 - pos)
            with self._dma:                             # never during a host->card call
                self.fk.dma(True, base + pos, addr + pos, k)
        if not direct:
            flat[:n] = tgt[off - o0:off - o0 + n]
        return buf

    # ---------------------------------------------------------------- registers
    def _check(self, off: int) -> None:
        if off < 0 or off + 4 > self.bar_bytes or off & 3:
            raise ValueError(f"register {off:#x}: outside the card's BAR0 ({self.bar_bytes // 1024} KB: openTPU at "
                             "0x0000, DNA 0x1000 / 0x7000, SYSMON 0x3000, I2C 0x9000)")

    def reg_write(self, off: int, val: int) -> None:
        self._check(off)
        self.fk.bar_write(BAR, off, val)

    def reg_read(self, off: int) -> int:
        self._check(off)
        return self.fk.bar_read(BAR, off)

    def reg_read_many(self, offs: list[int]) -> list[int]:
        for o in offs:
            self._check(o)
        return self.fk.reg_batch([(REG_READ, BAR, o, 0) for o in offs]) if offs else []

    def reg_write_many(self, pairs: list[tuple[int, int]]) -> None:
        for o, _ in pairs:
            self._check(o)
        if pairs:
            self.fk.reg_batch([(REG_WRITE, BAR, o, v) for o, v in pairs])

    # poll(): upstream XdmaTransport's (back-to-back reads, then sleeps of elapsed / 32), on reg_read above: one
    # request per read (~1.7 us, upstream's ~1 us mmap read). The driver's POLL request is not used for it: past its
    # spin it reads once per timer tick (15.6 ms), too coarse for a token's end.
