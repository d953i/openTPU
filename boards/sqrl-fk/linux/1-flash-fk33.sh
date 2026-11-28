#!/usr/bin/env bash
# Step 1 (once): write the openTPU image (prebuilt/sqrl-fk33/a3) to an FK33's flash over JTAG, about 10 minutes.
# Needs Vivado Lab Edition (free) or Vivado, any version, with its cable drivers, and a micro-USB cable from the card's USB port (its built-in JTAG) to the PC.
#   bash boards/sqrl-fk/linux/1-flash-fk33.sh            flash the FK33 on USB
#   bash boards/sqrl-fk/linux/1-flash-fk33.sh list       list the USB/JTAG ports Vivado sees and what they hold
#   bash boards/sqrl-fk/linux/1-flash-fk33.sh <cable>    pick one (part of its name, as list prints it)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
flash xcvu33p "$REPO/prebuilt/sqrl-fk33/a3" "$@"
