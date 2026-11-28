"""openTPU's host on Windows without changing it: what its device lock, run directory and process checks take from
POSIX, supplied here before `opentpu` is imported (otpu_fk_run.py calls apply(); sitecustomize.py in the processes it
spawns).

  - fcntl: a module of flock() and its LOCK_* constants (upstream imports fcntl at module level in board.py,
    runstate.py, i2c.py and rtlsim.py, and uses flock alone), on LockFileEx: one byte far past any data of the lock
    file, so the lock never blocks reading or writing the file (Windows byte-range locks are mandatory), shared or
    exclusive, LOCK_NB failing with EWOULDBLOCK as flock does; dropped with the file's last handle;
  - os.pread / os.pwrite (lock files: the holder's pid), os.O_NOFOLLOW / O_CLOEXEC / O_NONBLOCK (0: no such flags),
    os.getuid (0: the run directory's owner checks compare it with st_uid, which Windows reports as 0), os.nice (the
    background compiles' os.nice(19): the process's priority class lowered);
  - the run directory: OTPU_RUN_DIR defaults to %TEMP%\\otpu (upstream's /tmp/otpu would be the current drive's
    root);
  - os.replace retried for up to ~1 s on PermissionError: a file just written is often opened for a moment by the
    antivirus or the indexer, and replacing it fails meanwhile (runstate.write_shared's status file: "otpu: no status
    file ([WinError 5] Access is denied ...)" on the first Qwen3.5-2B run, 2026-10-24);
after `opentpu` is imported (patch_runstate()):
  - runstate.pid_alive: os.kill(pid, 0) on Windows is not a probe but GenerateConsoleCtrlEvent(CTRL_C_EVENT) to the
    process group, which interrupts this very process; here OpenProcess + GetExitCodeProcess.
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as W
import errno
import msvcrt
import os
import sys
import tempfile
import time
import types

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class _OVERLAPPED(ctypes.Structure):
    _fields_ = [("Internal", ctypes.c_size_t), ("InternalHigh", ctypes.c_size_t), ("Offset", W.DWORD),
                ("OffsetHigh", W.DWORD), ("hEvent", W.HANDLE)]


_k32.LockFileEx.argtypes = [W.HANDLE, W.DWORD, W.DWORD, W.DWORD, W.DWORD, ctypes.POINTER(_OVERLAPPED)]
_k32.LockFileEx.restype = W.BOOL
_k32.UnlockFileEx.argtypes = [W.HANDLE, W.DWORD, W.DWORD, W.DWORD, ctypes.POINTER(_OVERLAPPED)]
_k32.UnlockFileEx.restype = W.BOOL
_k32.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
_k32.OpenProcess.restype = W.HANDLE
_k32.GetExitCodeProcess.argtypes = [W.HANDLE, ctypes.POINTER(W.DWORD)]
_k32.GetExitCodeProcess.restype = W.BOOL
_k32.CloseHandle.argtypes = [W.HANDLE]

LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN = 1, 2, 4, 8
_LOCKFILE_FAIL_IMMEDIATELY, _LOCKFILE_EXCLUSIVE_LOCK = 0x1, 0x2
_ERROR_LOCK_VIOLATION, _ERROR_IO_PENDING, _ERROR_NOT_LOCKED = 33, 997, 158
_LOCK_OFFSET_HIGH = 0x40000000      # the locked byte: at 2**62, past any data of the file


def _overlapped() -> _OVERLAPPED:
    return _OVERLAPPED(0, 0, 0, _LOCK_OFFSET_HIGH, None)


def flock(fd: int, op: int) -> None:
    """fcntl.flock on Windows (see the module's description)."""
    h = msvcrt.get_osfhandle(fd if isinstance(fd, int) else fd.fileno())
    if op & LOCK_UN:
        if not _k32.UnlockFileEx(h, 0, 1, 0, ctypes.byref(_overlapped())):
            err = ctypes.get_last_error()
            if err != _ERROR_NOT_LOCKED:
                raise OSError(errno.EINVAL, ctypes.FormatError(err).strip(), None, err)
        return
    flags = (_LOCKFILE_EXCLUSIVE_LOCK if op & LOCK_EX else 0) | (_LOCKFILE_FAIL_IMMEDIATELY if op & LOCK_NB else 0)
    if not _k32.LockFileEx(h, flags, 0, 1, 0, ctypes.byref(_overlapped())):
        err = ctypes.get_last_error()
        if err in (_ERROR_LOCK_VIOLATION, _ERROR_IO_PENDING):
            raise BlockingIOError(errno.EWOULDBLOCK, "resource temporarily unavailable (locked)")
        raise OSError(errno.EINVAL, ctypes.FormatError(err).strip(), None, err)


def _pread(fd: int, n: int, off: int) -> bytes:
    pos = os.lseek(fd, 0, os.SEEK_CUR)
    try:
        os.lseek(fd, off, os.SEEK_SET)
        return os.read(fd, n)
    finally:
        os.lseek(fd, pos, os.SEEK_SET)


def _pwrite(fd: int, data, off: int) -> int:
    pos = os.lseek(fd, 0, os.SEEK_CUR)
    try:
        os.lseek(fd, off, os.SEEK_SET)
        return os.write(fd, data)
    finally:
        os.lseek(fd, pos, os.SEEK_SET)


_PROCESS_QUERY_LIMITED_INFORMATION, _STILL_ACTIVE, _ERROR_ACCESS_DENIED = 0x1000, 259, 5


def pid_alive(pid: int) -> bool:
    """runstate.pid_alive on Windows: the process exists and has not exited (access denied: it exists)."""
    if pid <= 0:
        return False
    h = _k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return ctypes.get_last_error() == _ERROR_ACCESS_DENIED
    try:
        code = W.DWORD(0)
        return bool(_k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == _STILL_ACTIVE
    finally:
        _k32.CloseHandle(h)


_k32.GetCurrentProcess.restype = W.HANDLE
_k32.SetPriorityClass.argtypes = [W.HANDLE, W.DWORD]
_k32.SetPriorityClass.restype = W.BOOL
_BELOW_NORMAL_PRIORITY_CLASS, _IDLE_PRIORITY_CLASS = 0x4000, 0x40


def nice(inc: int) -> int:
    """os.nice on Windows: the process's priority class lowered (the background compiles of gen_warm.py and
    vision_warm.py, os.nice(19): idle; a smaller increment: below normal); never raised. Returns the niceness asked."""
    if inc > 0:
        _k32.SetPriorityClass(_k32.GetCurrentProcess(),
                              _IDLE_PRIORITY_CLASS if inc >= 10 else _BELOW_NORMAL_PRIORITY_CLASS)
    return max(0, inc)


_os_replace = os.replace


def _replace(src, dst, *args, **kw):
    for i in range(20):
        try:
            return _os_replace(src, dst, *args, **kw)
        except PermissionError:
            if i == 19:
                raise
            time.sleep(0.005 * (i + 1))


def apply() -> None:
    """Before `opentpu` is imported. Idempotent; nothing off Windows."""
    if sys.platform != "win32" or "fcntl" in sys.modules:
        return
    os.replace = _replace
    m = types.ModuleType("fcntl", "flock() on LockFileEx (boards/sqrl-fk/host/winposix.py)")
    m.flock, m.LOCK_SH, m.LOCK_EX, m.LOCK_NB, m.LOCK_UN = flock, LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN
    sys.modules["fcntl"] = m
    for name in ("O_NOFOLLOW", "O_CLOEXEC", "O_NONBLOCK"):
        if not hasattr(os, name):
            setattr(os, name, 0)
    if not hasattr(os, "pread"):
        os.pread, os.pwrite = _pread, _pwrite
    if not hasattr(os, "getuid"):
        os.getuid = lambda: 0
    if not hasattr(os, "nice"):
        os.nice = nice
    os.environ.setdefault("OTPU_RUN_DIR", os.path.join(tempfile.gettempdir(), "otpu"))


def patch_runstate() -> None:
    """After `opentpu.host.runstate` is importable: its pid_alive (used by _running, the device lock's holder check)."""
    if sys.platform != "win32":
        return
    import opentpu.host.runstate as rs
    rs.pid_alive = pid_alive
