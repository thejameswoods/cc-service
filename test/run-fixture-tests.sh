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
# shellcheck source=../bin/cc-service-terminal.sh
source "$ROOT_DIR/bin/cc-service-terminal.sh"

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
      *normal-idle*|*mid-turn-busy*|*no-conversation*) expect=no ;;
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

test_no_conversation_detected() {
  local ok=true
  no_conversation_to_continue "$(cat "$FIXTURES/pane-capture.no-conversation.txt")" || ok=false
  # Everything else the pane can hold must not trigger a fresh session.
  local f
  for f in normal-idle login-required mid-turn-busy reconnect-failed rc-not-started-here; do
    if no_conversation_to_continue "$(cat "$FIXTURES/pane-capture.$f.txt")"; then ok=false; fi
  done
  if no_conversation_to_continue ""; then ok=false; fi
  if $ok; then
    pass "no_conversation_to_continue matches only the 'No conversation found' output"
  else
    test_fail "no_conversation_to_continue matched wrongly (fixture: no-conversation)"
  fi
}

test_build_ttyd_args() {
  local args=() out
  # shellcheck disable=SC2034  # consumed by build_ttyd_args() in bin/cc-service-terminal.sh, a separately sourced file
  CC_TERMINAL_PORT=7681 CC_TERMINAL_IFACE=eth0 CC_TLS_CERT=/c.crt CC_TLS_KEY=/c.key CC_TMUX_SOCKET=sock CC_TMUX_SESSION=claude
  build_ttyd_args args 'hunter2-hunter2'
  out=" ${args[*]} "
  local ok=true want
  for want in " -W " " -O " " -p 7681 " " -i eth0 " " --ssl " " --ssl-cert /c.crt " " --ssl-key /c.key " \
              " -c cc:hunter2-hunter2 " " tmux -L sock attach-session -t claude "; do
    [[ "$out" == *"$want"* ]] || { ok=false; echo "    missing:$want"; }
  done
  # The window must end the argument list (ttyd runs everything after the options).
  [ "${args[-1]}" = "claude" ] || ok=false
  if $ok; then
    pass "build_ttyd_args: writable, origin-checked, TLS, one interface, credential, attaches the session"
  else
    test_fail "build_ttyd_args: $out"
  fi
}

test_build_ttyd_args_defaults() {
  local args=()
  unset CC_TERMINAL_PORT CC_TERMINAL_IFACE CC_TMUX_SOCKET CC_TMUX_SESSION
  # shellcheck disable=SC2034
  CC_TLS_CERT=/c.crt CC_TLS_KEY=/c.key
  build_ttyd_args args 'hunter2-hunter2'
  local out=" ${args[*]} "
  if [[ "$out" == *" -i lo "* && "$out" == *" -p 7681 "* && "$out" == *" tmux attach-session -t claude "* ]]; then
    pass "build_ttyd_args defaults to the loopback interface, port 7681 and session 'claude'"
  else
    test_fail "build_ttyd_args defaults: $out"
  fi
}

# --- project dir on a network mount ----------------------------------------
# `stat` is stubbed on PATH, so no real mount is needed. Each stub reads a
# flag file: while it exists the "server" is down (stat hangs or fails).

make_stat_stub() {
  # make_stat_stub <dir> hang|fail <flag-file> <call-log>
  local dir="$1" mode="$2" flag="$3" calls="$4"
  cat > "$dir/stat" <<EOF
#!/bin/bash
echo x >> "$calls"
if [ -e "$flag" ]; then
  if [ "$mode" = hang ]; then sleep 2; fi
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/stat"
}

test_dir_responsive_existing_dir() {
  _CC_PROBE_PID=""
  if dir_responsive "$ROOT_DIR" 20; then
    pass "dir_responsive: an existing directory answers"
  else
    test_fail "dir_responsive: existing directory reported unresponsive"
  fi
}

test_dir_responsive_missing_dir_fails_fast() {
  _CC_PROBE_PID=""
  local start=$SECONDS
  if ! dir_responsive "$ROOT_DIR/does-not-exist" 50 && [ $((SECONDS - start)) -lt 3 ]; then
    pass "dir_responsive: a missing directory fails at once, not after the timeout"
  else
    test_fail "dir_responsive: missing directory should fail fast"
  fi
}

test_dir_responsive_hung_probe_not_stacked() {
  local d; d=$(mktemp -d)
  local flag="$d/down" calls="$d/calls"
  touch "$flag"
  make_stat_stub "$d" hang "$flag" "$calls"
  _CC_PROBE_PID=""
  local old_path="$PATH" rc1 rc2 rc3 n
  PATH="$d:$PATH"
  dir_responsive /fake 5; rc1=$?          # hangs 2s, gives up after 0.5s
  dir_responsive /fake 5; rc2=$?          # old probe still stuck: must not start another
  n=$(wc -l < "$calls")
  sleep 2.5                               # the stuck probe finishes
  rm -f "$flag"                           # server is back
  dir_responsive /fake 20; rc3=$?
  PATH="$old_path"
  rm -rf "$d"
  if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ "$n" -eq 1 ] && [ "$rc3" -eq 0 ]; then
    pass "dir_responsive: a hung stat times out, is not stacked, and recovers when the server returns"
  else
    test_fail "dir_responsive hung probe: rc1=$rc1 rc2=$rc2 stat-calls=$n rc3=$rc3"
  fi
}

test_wait_for_project_dir_waits_then_continues() {
  local d; d=$(mktemp -d)
  local flag="$d/down" calls="$d/calls" logf="$d/log"
  touch "$flag"
  make_stat_stub "$d" fail "$flag" "$calls"
  _CC_PROBE_PID=""
  local old_path="$PATH" pid i done_in_time=false rc=1
  PATH="$d:$PATH"
  ( CC_PROJECT_DIR_POLL_SEC=1 wait_for_project_dir /fake 2>"$logf" ) &
  pid=$!
  sleep 2.5
  local still_waiting=false
  _cc_pid_running "$pid" && still_waiting=true
  rm -f "$flag"                           # the server comes back
  for ((i = 0; i < 80; i++)); do
    if ! _cc_pid_running "$pid"; then done_in_time=true; break; fi
    sleep 0.1
  done
  if $done_in_time; then wait "$pid"; rc=$?; else kill "$pid" 2>/dev/null; fi
  PATH="$old_path"
  if $still_waiting && $done_in_time && [ "$rc" -eq 0 ] \
     && grep -q "project dir not available" "$logf" \
     && grep -q "project dir available again" "$logf"; then
    pass "wait_for_project_dir: waits while the mount is down, logs it, and returns once it is back"
  else
    test_fail "wait_for_project_dir: still_waiting=$still_waiting done=$done_in_time rc=$rc log=$(tr '\n' '|' < "$logf")"
  fi
  rm -rf "$d"
}

test_unit_template_has_no_mount_dependency() {
  local t="$ROOT_DIR/systemd/cc-service@.service.tmpl"
  if grep -q '^WorkingDirectory={{RUN_AS_HOME}}$' "$t" \
     && ! grep -q 'WorkingDirectory={{CC_PROJECT_DIR}}' "$t" \
     && grep -q '^TimeoutStopSec=' "$t"; then
    pass "service unit: WorkingDirectory is the user's home (no mount requirement) and TimeoutStopSec is bounded"
  else
    test_fail "service unit template still ties WorkingDirectory to the project dir, or lacks TimeoutStopSec"
  fi
}

echo "== cc-service-terminal.sh =="
test_build_ttyd_args
test_build_ttyd_args_defaults

echo "== project dir on a network mount =="
test_dir_responsive_existing_dir
test_dir_responsive_missing_dir_fails_fast
test_dir_responsive_hung_probe_not_stacked
test_wait_for_project_dir_waits_then_continues
test_unit_template_has_no_mount_dependency

echo "== claude-daemon.sh =="
test_no_conversation_detected
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
