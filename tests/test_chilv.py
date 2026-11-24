"""CAPS2 bit26 (a memory channel on two ports, its bytes interleaved at 32: the SQRL FK's two HBM ports
a channel, otpu_hbm_ch NP 2): opentpu.host.board.interleave_ports puts the channel's bytes where the
bridge reads them (chilv_card), on a transport whose memory is the card's address space."""
import numpy as np
import pytest

from opentpu.host import regs as R
from opentpu.host.board import chilv_card, interleave_ports

CH = 1 << 16                   # a channel's bytes (the windows' layout at any size)


class _Card:
    """A transport over two channels' card bytes, calls logged."""

    def __init__(self):
        self.mem = [np.zeros(CH, np.uint8) for _ in range(2)]
        self.calls = []

    def mem_write(self, ch, off, data):
        a = np.ascontiguousarray(data, np.uint8).reshape(-1)
        self.calls.append(("w", ch, off, len(a)))
        self.mem[ch][off:off + len(a)] = a

    def mem_read(self, ch, off, n, out=None):
        self.calls.append(("r", ch, off, n))
        r = self.mem[ch][off:off + n].copy()
        if out is None:
            return r
        out[:] = r
        return out


def test_caps2_bit26():
    assert R.CAP2_CHILV == 1 << 26
    assert R.caps2(1 << 26)["chilv"] and not R.caps2(0)["chilv"] and not R.caps2(None)["chilv"]


def test_chilv_card_layout():
    """Byte o = 128 m + 64 s + 32 l + t of a channel: port l's half, its beat 2 m + s."""
    for o in (0, 31, 32, 63, 64, 96, 127, 128, 4096 + 40, CH - 1):
        m, s, l, t = o // 128, o // 64 % 2, o // 32 % 2, o % 32
        assert chilv_card(o, CH) == l * CH // 2 + 64 * m + 32 * s + t


@pytest.mark.parametrize("off,n", [(0, 128), (0, 4096), (128, 256), (40, 9), (100, 300),
                                   (CH - 128, 128), (3, CH - 7)])
def test_interleave_ports_round_trip(off, n):
    """Writes land at chilv_card's places (one call a half on the grid; the edges merged off it),
    reads return them, and bytes outside the range keep their values."""
    t = _Card()
    rng = np.random.default_rng(off * 7 + n)
    for c in range(2):
        t.mem[c][:] = rng.integers(0, 256, CH, np.uint8)
    before = [m.copy() for m in t.mem]
    interleave_ports(t, CH)
    interleave_ports(t, CH)                    # (idempotent)
    data = rng.integers(0, 256, n, np.uint8)
    t.calls.clear()
    t.mem_write(1, off, data)
    if off % 128 == 0 and n % 128 == 0:
        assert t.calls == [("w", 1, off // 2, n // 2), ("w", 1, CH // 2 + off // 2, n // 2)]
    want = before[1].copy()
    for i in range(n):
        want[chilv_card(off + i, CH)] = data[i]
    assert np.array_equal(t.mem[1], want) and np.array_equal(t.mem[0], before[0])
    assert np.array_equal(t.mem_read(1, off, n), data)
    out = np.zeros(n, np.uint8)
    assert t.mem_read(1, off, n, out) is out and np.array_equal(out, data)


def test_interleave_ports_refuses_another_size():
    t = _Card()
    interleave_ports(t, CH)
    with pytest.raises(ValueError):
        interleave_ports(t, CH // 2)
