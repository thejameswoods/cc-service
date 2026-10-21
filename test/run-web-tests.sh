#!/bin/bash
# run-web-tests.sh — tests bin/cc-service-web.py against stubbed
# tmux/claude/systemctl. Never needs root and never touches real state.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

echo "== cc-service-web tests =="
python3 -m py_compile "$ROOT_DIR/bin/cc-service-web.py" || exit 1
python3 "$ROOT_DIR/test/test_web.py" -v
