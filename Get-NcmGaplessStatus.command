#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")" && pwd)"
python=python3
if [[ -x "$root/.venv/bin/python3" ]]; then python="$root/.venv/bin/python3"; fi
exec "$python" -B "$root/tools/macos_maintenance.py" status "$@"
