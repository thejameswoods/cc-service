#!/bin/bash
# lib/conflict-detect.sh — detects other always-on Claude Code setups on this
# machine before install.sh makes any changes. Sourced by install.sh and by
# test/run-fixture-tests.sh (which stubs $CC_SYSTEMCTL_CMD/$CC_PS_CMD/$CC_TMUX_CMD
# on PATH to exercise this logic against fixture data with no real system
# access required).
#
# Not meant to be executed directly.

# --- Heuristic A: systemd units whose ExecStart references both tmux and claude ---
# Excludes our own cc-service@*/cc-service-watchdog@* units (those are handled
# by scan_own_package_instances, not treated as "foreign").
scan_systemd_units() {
  "$CC_SYSTEMCTL_CMD" list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | while read -r unit; do
        [ -z "$unit" ] && continue
        case "$unit" in
          cc-service@*.service|cc-service-watchdog@*.service) continue ;;
        esac
        exec_start=$("$CC_SYSTEMCTL_CMD" show -p ExecStart --value "$unit" 2>/dev/null)
        if [[ "$exec_start" == *tmux* && "$exec_start" == *claude* ]]; then
          echo "UNIT|$unit|$exec_start"
        fi
      done
}

# Returns success if the script contains a `claude` invocation *inside* a
# `while true ... done` block, rather than just containing both substrings
# anywhere in the file. Plain "file has 'while true' AND file has 'claude'
# somewhere" false-positives on any one-off script that merely mentions
# claude in passing and happens to have an unrelated while-true loop
# elsewhere -- install.sh itself is exactly such a case (its interactive
# conflict-resolution retry loop is a `while true`, and it references
# `claude` as a required command), so this proximity check is required, not
# just a nicety.
script_has_claude_respawn_loop() {
  local f="$1"
  awk '
    /while[ \t]+true/ { inloop=1; next }
    inloop && /claude/ { found=1 }
    /done/ { inloop=0 }
    END { exit !found }
  ' "$f" 2>/dev/null
}

# --- Heuristic B: a running claude process whose parent script wraps it in a
#     `while true` respawn loop. This is what distinguishes an always-on
#     daemon from a developer's one-off interactive `claude` session (which
#     has no such wrapper, so it is never flagged). ---
scan_loop_processes() {
  # shellcheck disable=SC2034  # comm is part of the fixed ps column layout, unused by name
  "$CC_PS_CMD" -eo pid,ppid,comm,args --no-headers 2>/dev/null | while read -r pid ppid comm args; do
    [ -z "$pid" ] && continue
    case "$args" in
      *claude*)
        parent_args=$("$CC_PS_CMD" -o args= -p "$ppid" 2>/dev/null)
        case "$parent_args" in
          *.sh*|bash*|sh*)
            script_path=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /\.sh$/) print $i}' <<<"$parent_args" | head -1)
            if [ -n "$script_path" ] && [ -r "$script_path" ] \
               && script_has_claude_respawn_loop "$script_path"; then
              echo "LOOP_PROC|pid=$pid|script=$script_path"
            fi
            ;;
        esac
        ;;
    esac
  done
}

# --- Heuristic C: an existing tmux session with the exact name this install
#     intends to use. Only a collision *candidate* -- disposition (foreign vs.
#     our own previous install) is decided by the caller. ---
scan_tmux_name_collision() {
  local intended="$1"
  if tmux_run has-session -t "$intended" 2>/dev/null; then
    local owning_pid
    owning_pid=$(tmux_run list-panes -t "$intended" -F '#{pane_pid}' 2>/dev/null | head -1)
    echo "TMUX_NAME|$intended|pane_pid=$owning_pid"
  fi
}

# --- Heuristic D: any existing installs of THIS package, any instance name.
#     Used to recognize a re-run of install.sh as an idempotent upgrade
#     rather than a foreign conflict. ---
scan_own_package_instances() {
  "$CC_SYSTEMCTL_CMD" list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^cc-service(-watchdog)?@.*\.service$' || true
}

# classify_own_instance_state <instance-name>
# Prints one of: absent | active | inactive
classify_own_instance_state() {
  local instance="$1"
  local unit="cc-service@${instance}.service"
  if ! "$CC_SYSTEMCTL_CMD" list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
    echo absent
    return
  fi
  if "$CC_SYSTEMCTL_CMD" is-active --quiet "$unit" 2>/dev/null; then
    echo active
  else
    echo inactive
  fi
}

# scan_for_conflicts <intended-tmux-session> <intended-instance-name>
# Populates the caller's environment with newline-delimited results in the
# variables CC_SCAN_OWN, CC_SCAN_FOREIGN_UNITS, CC_SCAN_LOOP_PROCS,
# CC_SCAN_TMUX_COLLISION. Caller (install.sh) decides prompt/abort/proceed.
scan_for_conflicts() {
  local intended_tmux="$1" intended_instance="$2"
  # shellcheck disable=SC2034  # consumed by callers (install.sh), not within this file
  CC_SCAN_OWN=$(scan_own_package_instances)
  # shellcheck disable=SC2034
  CC_SCAN_FOREIGN_UNITS=$(scan_systemd_units)
  # shellcheck disable=SC2034
  CC_SCAN_LOOP_PROCS=$(scan_loop_processes)
  # shellcheck disable=SC2034
  CC_SCAN_TMUX_COLLISION=$(scan_tmux_name_collision "$intended_tmux")
  # shellcheck disable=SC2034
  CC_SCAN_OWN_INSTANCE_STATE=$(classify_own_instance_state "$intended_instance")
}
