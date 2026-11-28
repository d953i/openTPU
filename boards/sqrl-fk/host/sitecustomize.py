"""Imported by Python at the start of every process that otpu-fk.cmd runs (its PYTHONPATH has boards/sqrl-fk/host):
winposix.apply() before anything imports opentpu. otpu_fk_run.py does it for the tool's own process; this is for the
processes it spawns: the image build's quantization workers (opentpu.qcache.pool, multiprocessing "spawn") import the
tool's module (e.g. opentpu.host.chat) as their __main__, and with it board.py's module-level `import fcntl`.
"""
import winposix

winposix.apply()
