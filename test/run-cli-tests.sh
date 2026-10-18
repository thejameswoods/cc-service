#!/bin/bash
# run-cli-tests.sh — smoke-tests install.sh/uninstall.sh argument parsing and
# --dry-run behavior against stubbed tmux/claude/systemctl commands. Never
# needs root and never touches /etc, /opt, or real systemd/tmux state.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
test_fail() { FAIL=$((FAIL + 1)); echo "  NOT OK - $1"; }

make_stub_path() {
  local dir; dir=$(mktemp -d)
  cat > "$dir/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$dir/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  cat > "$dir/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  list-unit-files) exit 0 ;;
  show) echo "" ;;
  is-active) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir"/claude "$dir"/tmux "$dir"/systemctl
  echo "$dir"
}

test_install_help() {
  local out
  out=$(bash "$ROOT_DIR/install.sh" --help 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"Usage:"* ]]; then
    pass "install.sh --help exits 0 and prints usage"
  else
    test_fail "install.sh --help: rc=$rc out=$out"
  fi
}

test_uninstall_help() {
  local out
  out=$(bash "$ROOT_DIR/uninstall.sh" --help 2>&1)
  local rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"Usage:"* ]]; then
    pass "uninstall.sh --help exits 0 and prints usage"
  else
    test_fail "uninstall.sh --help: rc=$rc out=$out"
  fi
}

test_install_missing_project_dir() {
  local out
  out=$(PATH="$(make_stub_path):$PATH" bash "$ROOT_DIR/install.sh" --dry-run 2>&1)
  local rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"--project-dir is required"* ]]; then
    pass "install.sh without --project-dir fails fast with exit 2"
  else
    test_fail "expected exit 2 + 'required' message; got rc=$rc out=$out"
  fi
}

test_install_dry_run_no_conflicts() {
  local stubdir out rc
  stubdir=$(make_stub_path)
  out=$(PATH="$stubdir:$PATH" bash "$ROOT_DIR/install.sh" \
          --project-dir /tmp --service-name citest --tmux-session claude-citest \
          --dry-run --yes 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"[dry-run]"* ]]; then
    pass "install.sh --dry-run with no conflicts completes cleanly"
  else
    test_fail "expected exit 0 with dry-run markers; got rc=$rc out=$out"
  fi
  if [ ! -e /etc/cc-service/citest.env ] && [ ! -e /opt/cc-service/current ]; then
    pass "install.sh --dry-run made no real filesystem changes"
  else
    test_fail "dry-run must never write /etc/cc-service or /opt/cc-service"
  fi
}

test_uninstall_dry_run() {
  local out rc
  out=$(PATH="$(make_stub_path):$PATH" bash "$ROOT_DIR/uninstall.sh" \
          --service-name citest --dry-run --yes 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "uninstall.sh --dry-run completes cleanly"
  else
    test_fail "expected exit 0; got rc=$rc out=$out"
  fi
}

test_install_web_requires_password_file() {
  local out rc
  out=$(PATH="$(make_stub_path):$PATH" bash "$ROOT_DIR/install.sh" \
          --project-dir /tmp --service-name citest --web --dry-run --yes 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == *"--web requires --web-password-file"* ]]; then
    pass "install.sh --web without --web-password-file fails fast with exit 2"
  else
    test_fail "expected exit 2 + message; got rc=$rc out=$out"
  fi
}

test_install_web_dry_run() {
  local out rc
  out=$(PATH="$(make_stub_path):$PATH" bash "$ROOT_DIR/install.sh" \
          --project-dir /tmp --service-name citest --tmux-session claude-citest \
          --web --web-password-file /tmp/pw --web-bind 0.0.0.0 --web-port 9000 \
          --dry-run --yes 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"cc-service-web@citest.service"* ]]; then
    pass "install.sh --web --dry-run plans the cc-service-web unit"
  else
    test_fail "expected exit 0 + web unit in plan; got rc=$rc out=$out"
  fi
}

echo "== install.sh / uninstall.sh CLI smoke tests =="
test_install_help
test_uninstall_help
test_install_missing_project_dir
test_install_dry_run_no_conflicts
test_install_web_requires_password_file
test_install_web_dry_run
test_uninstall_dry_run

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
