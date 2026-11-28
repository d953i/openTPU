#!/usr/bin/env bash
# Step 2 (once): set up this PC for the card: a Python environment in build/venv-linux with openTPU's commands and the
# packages for models (CPU PyTorch; boards/sqrl-fk/host/requirements.txt), the card's driver (Xilinx's XDMA driver and
# udev rules, by otpu-setup, which asks for sudo), and the models into models/ (default Qwen3.5-0.8B, 1.6 GB, which the
# self-test uses, and Qwen3.5-9B, 18 GB).
#   bash boards/sqrl-fk/linux/2-setup.sh                         the defaults
#   bash boards/sqrl-fk/linux/2-setup.sh Qwen3.5-2B Qwen3.5-4B   other models (run again any time to add some)
# First (Debian / Ubuntu): sudo apt install python3-venv git build-essential patch dkms linux-headers-$(uname -r)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

base=${PYTHON:-python3}
if ! "$base" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    echo "Python 3.10 or later needed ($base): install it, or set PYTHON=/path/to/python3.x" >&2
    exit 1
fi
if [ ! -x "$PY" ]; then
    "$base" -m venv "$VENV" || { echo "making the environment failed: sudo apt install python3-venv, then run this again" >&2; exit 1; }
fi
"$PY" -m pip install --disable-pip-version-check --upgrade pip
"$PY" -m pip install --disable-pip-version-check --extra-index-url https://download.pytorch.org/whl/cpu \
    -r "$REPO/boards/sqrl-fk/host/requirements.txt"
"$PY" -m pip install --disable-pip-version-check -e "$REPO"

echo
echo "== the card's driver (otpu-setup; it asks for your password for sudo)"
"$VENV/bin/otpu-setup"

models=("$@")
if [ ${#models[@]} -eq 0 ]; then models=(Qwen3.5-0.8B Qwen3.5-9B); fi
for m in "${models[@]}"; do
    id=$m
    case $id in */*) ;; *) id=Qwen/$m ;; esac
    echo
    echo "== model $id -> models/${id##*/}"
    "$VENV/bin/hf" download "$id" --local-dir "$REPO/models/${id##*/}"
done
echo
echo "Done. Next:  bash boards/sqrl-fk/linux/3-selftest.sh"
