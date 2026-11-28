#!/usr/bin/env bash
# Step 4: chat with a model on the card: the largest model in models/ (or name one), with the most context the card
# holds, 4-bit weights (fp4; --wformat int8 for 8-bit). Type a message and press Enter; /help lists the commands, /quit or Ctrl+C ends it. The first chat with a model
# prepares it for some minutes and answers slowly at first; later ones start in seconds.
#   bash boards/sqrl-fk/linux/4-chat.sh
#   bash boards/sqrl-fk/linux/4-chat.sh Qwen3.5-4B [--plain] [--prompt "a question"]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if [ $# -gt 0 ]; then
    fk chat "$@"
else
    m=$(largest_model)
    if [ -z "$m" ]; then echo "No model in models/: run  bash boards/sqrl-fk/linux/2-setup.sh  first." >&2; exit 1; fi
    fk chat "$m"
fi
