#!/usr/bin/env bash
# Step 3: check the card: openTPU's self-test (link, memory, compute), its last stage Qwen3.5-0.8B bit for bit against
# openTPU's simulator. Every line should say PASS, the last one "ALL PASS".
#   bash boards/sqrl-fk/linux/3-selftest.sh [--wformat int8] [--dev /dev/xdma1]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
model=()
if [ -f "$REPO/models/Qwen3.5-0.8B/config.json" ]; then model=(--model qwen35); fi
fk -m opentpu.host.selftest "${model[@]}" --wformat fp4 "$@"   # (4-bit as the chat; a later --wformat int8 wins)
