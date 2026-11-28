#!/usr/bin/env bash
# Optional: watch the card (otpu-smi): its build, temperature, memory, how busy it is and which program uses it,
# refreshed every second; Ctrl+C ends it. Reads registers only, so it can run beside a chat.
#   bash boards/sqrl-fk/linux/monitor.sh [-q]      (-q: every detail once)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if [ $# -gt 0 ]; then fk -m opentpu.host.smi "$@"; else fk -m opentpu.host.smi -l 1; fi
