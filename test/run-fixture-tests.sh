#!/bin/bash
# run-fixture-tests.sh — exercises lib/conflict-detect.sh and the pattern
# arrays / pure functions in bin/claude-rc-watchdog.sh against static fixture
# data, entirely via stubbed systemctl/ps/tmux commands placed on PATH.
# Needs no root, no real systemd, and never touches a live service.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
FIXTURES="$ROOT_DIR/test/fixtures"

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/conflict-detect.sh
source "$ROOT_DIR/lib/conflict-detect.sh"
# shellcheck source=../bin/claude-rc-watchdog.sh
source "$ROOT_DIR/bin/claude-rc-watchdog.sh"
# shellcheck source=../bin/claude-daemon.sh
source "$ROOT_DIR/bin/claude-daemon.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $1"; }
test_fail() { FAIL=$((FAIL + 1)); echo "  NOT OK - $1"; }

make_systemctl_stub() {
  local list_fixture="$1" dir="$2"
  cat > "$dir/systemctl" <<EOF
#!/bin/bash
if [ "\$1" = "list-unit-files" ]; then
  cat "$FIXTURES/$list_fixture"
elif [ "\$1" = "show" ]; then
  unit="\${*: -1}"
  case "\$unit" in
    claude-tmux.service) echo "/usr/bin/tmux new-session -d -s claude -x 220 -y 50 /usr/local/bin/claude-daemon.sh" ;;
    cron.service) echo "/usr/sbin/cron -f" ;;
    ssh.service) echo "/usr/sbin/sshd -D" ;;
    *) echo "" ;;
  esac
elif [ "\$1" = "is-active" ]; then
  exit 1
fi
EOF
  chmod +x "$dir/systemctl"
}

test_foreign_conflict_detected() {
  local stubdir; stubdir=$(mktemp -d)
  make_systemctl_stub "systemctl-list-units.foreign.txt" "$stubdir"
  local result
  result=$(PATH="$stubdir:$PATH" scan_systemd_units)
  if [[ "$result" == *"claude-tmux.service"* ]]; then
    pass "foreign unit (claude-tmux.service) detected"
  else
    test_fail "expected claude-tmux.service to be detected as foreign; got: $result"
  fi
}

test_own_package_not_flagged_as_foreign() {
  local stubdir; stubdir=$(mktemp -d)
  make_systemctl_stub "systemctl-list-units.own-package.txt" "$stubdir"
  local result
  result=$(PATH="$stubdir:$PATH" scan_systemd_units)
  if [ -z "$result" ]; then
    pass "cc-service@* units never appear in foreign scan results"
  else
    test_fail "cc-service@* units must never be flagged as foreign; got: $result"
  fi
}

test_loop_process_detected() {
  local stubdir; stubdir=$(mktemp -d)
  cat > "$stubdir/ps" <<EOF
#!/bin/bash
if [ "\$1" = "-eo" ]; then
  cat "$FIXTURES/ps-aux.while-true-loop.txt"
elif [ "\$1" = "-o" ]; then
  pid="\${4:-}"
  [ "\$pid" = "5306" ] && echo "/bin/bash $FIXTURES/sample-daemon-loop.sh"
fi
EOF
  chmod +x "$stubdir/ps"
  local result
  result=$(PATH="$stubdir:$PATH" scan_loop_processes)
  if [[ "$result" == *"LOOP_PROC"* ]]; then
    pass "while-true claude loop process detected"
  else
    test_fail "expected a loop process to be detected; got: $result"
  fi
}

test_install_sh_itself_not_flagged_as_loop() {
  # Regression test: install.sh has its own `while true` (the interactive
  # conflict-resolution retry loop) and references the word "claude" (as a
  # required command), but never invokes claude *inside* that loop. Found
  # via the live E2E test on the reference box, where a naive "file
  # contains both substrings" check flagged install.sh as a foreign
  # always-on daemon merely because a --tmux-session flag value contained
  # the substring "claude".
  if script_has_claude_respawn_loop "$ROOT_DIR/install.sh"; then
    test_fail "install.sh must not be detected as a claude respawn loop"
  else
    pass "install.sh's own while-true loop is correctly not flagged"
  fi
}

test_reference_daemon_script_is_flagged() {
  if script_has_claude_respawn_loop "$FIXTURES/sample-daemon-loop.sh"; then
    pass "a genuine claude-in-while-true daemon script is correctly flagged"
  else
    test_fail "sample-daemon-loop.sh should be detected as a claude respawn loop"
  fi
}

test_normal_session_not_flagged() {
  local stubdir; stubdir=$(mktemp -d)
  cat > "$stubdir/ps" <<EOF
#!/bin/bash
if [ "\$1" = "-eo" ]; then
  cat "$FIXTURES/ps-aux.normal-session.txt"
elif [ "\$1" = "-o" ]; then
  pid="\${4:-}"
  [ "\$pid" = "14122" ] && echo "-bash"
fi
EOF
  chmod +x "$stubdir/ps"
  local result
  result=$(PATH="$stubdir:$PATH" scan_loop_processes)
  if [ -z "$result" ]; then
    pass "normal one-off interactive claude session is not flagged"
  else
    test_fail "a normal interactive session must not be flagged as a loop process; got: $result"
  fi
}

test_pane_patterns() {
  local f base expect matched pat
  for f in "$FIXTURES"/pane-capture.*.txt; do
    base=$(basename "$f")
    case "$base" in
      *normal-idle*|*mid-turn-busy*) expect=no ;;
      *) expect=yes ;;
    esac
    matched=no
    for pat in "${RC_FAIL_PATTERNS[@]}" "${AUTH_FAIL_PATTERNS[@]}"; do
      grep -qE "$pat" "$f" && matched=yes
    done
    if [ "$matched" = "$expect" ]; then
      pass "$base: banner-match expectation ($expect) held"
    else
      test_fail "$base: expected banner-match=$expect got=$matched"
    fi
  done
}

test_rc_ok_pattern_matches_normal_idle() {
  local pat matched=no
  for pat in "${RC_OK_PATTERNS[@]}"; do
    grep -qE "$pat" "$FIXTURES/pane-capture.normal-idle.txt" && matched=yes
  done
  if [ "$matched" = yes ]; then
    pass "normal-idle pane correctly matches an RC_OK pattern"
  else
    test_fail "normal-idle pane should match an RC_OK pattern"
  fi
}

test_busy_pattern() {
  if grep -qE "$BUSY_PATTERN" "$FIXTURES/pane-capture.mid-turn-busy.txt"; then
    pass "busy pattern matches a mid-turn/busy pane"
  else
    test_fail "busy pattern should match the mid-turn-busy fixture"
  fi

  if ! grep -qE "$BUSY_PATTERN" "$FIXTURES/pane-capture.normal-idle.txt"; then
    pass "busy pattern does not match an idle pane"
  else
    test_fail "busy pattern must not match the normal-idle fixture"
  fi
}

test_build_claude_args_default_includes_continue() {
  # shellcheck disable=SC2034  # consumed by build_claude_args() in bin/claude-daemon.sh, a separately sourced file
  CC_PERMISSION_MODE=""
  # shellcheck disable=SC2034
  CC_CLAUDE_NAME=""
  # shellcheck disable=SC2034
  CC_CLAUDE_EXTRA_ARGS=""
  local args=()
  build_claude_args args
  if [[ " ${args[*]} " == *" --continue "* ]]; then
    pass "build_claude_args includes --continue by default"
  else
    test_fail "expected --continue in args, got: ${args[*]}"
  fi
}

test_build_claude_args_no_continue_omits_flag() {
  # shellcheck disable=SC2034  # consumed by build_claude_args() in bin/claude-daemon.sh, a separately sourced file
  CC_PERMISSION_MODE=""
  # shellcheck disable=SC2034
  CC_CLAUDE_NAME=""
  # shellcheck disable=SC2034
  CC_CLAUDE_EXTRA_ARGS=""
  local args=()
  build_claude_args args --no-continue
  if [[ " ${args[*]} " != *" --continue "* ]]; then
    pass "build_claude_args --no-continue omits --continue (first-run bootstrap fallback)"
  else
    test_fail "expected no --continue with --no-continue, got: ${args[*]}"
  fi
}

test_build_claude_args_omits_empty_permission_mode() {
  # shellcheck disable=SC2034  # consumed by build_claude_args() in bin/claude-daemon.sh, a separately sourced file
  CC_PERMISSION_MODE=""
  # shellcheck disable=SC2034
  CC_CLAUDE_NAME=""
  # shellcheck disable=SC2034
  CC_CLAUDE_EXTRA_ARGS=""
  local args=()
  build_claude_args args
  if [[ " ${args[*]} " != *" --permission-mode "* ]]; then
    pass "build_claude_args omits --permission-mode when unset (safe default)"
  else
    test_fail "expected no --permission-mode flag, got: ${args[*]}"
  fi
}

echo "== claude-daemon.sh =="
test_build_claude_args_default_includes_continue
test_build_claude_args_no_continue_omits_flag
test_build_claude_args_omits_empty_permission_mode

echo "== conflict-detect.sh =="
test_foreign_conflict_detected
test_own_package_not_flagged_as_foreign
test_loop_process_detected
test_normal_session_not_flagged
test_install_sh_itself_not_flagged_as_loop
test_reference_daemon_script_is_flagged

echo "== claude-rc-watchdog.sh patterns =="
test_pane_patterns
test_rc_ok_pattern_matches_normal_idle
test_busy_pattern

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
