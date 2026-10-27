#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")" && pwd)"
python=python3
if [[ -x "$root/.venv/bin/python3" ]]; then python="$root/.venv/bin/python3"; fi
if ! command -v "$python" >/dev/null 2>&1; then
  echo '未找到 Python 3。请先安装，再双击本脚本：https://www.python.org/downloads/macos/' >&2
  exit 1
fi
exec "$python" "$root/tools/macos_launcher.py" setup "$@"
