#!/usr/bin/env bash
# Optional: serve a model to other programs as an OpenAI-style API at http://127.0.0.1:8000/v1 (any OpenAI client or
# chat app that takes a custom server address): the largest model in models/, or name one. Ctrl+C stops it.
#   bash boards/sqrl-fk/linux/serve.sh
#   bash boards/sqrl-fk/linux/serve.sh Qwen3.5-4B --port 8001
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if [ $# -gt 0 ]; then
    fk serve "$@"
else
    m=$(largest_model)
    if [ -z "$m" ]; then echo "No model in models/: run  bash boards/sqrl-fk/linux/2-setup.sh  first." >&2; exit 1; fi
    fk serve "$m"
fi
