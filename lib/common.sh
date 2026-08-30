#!/bin/bash
# lib/common.sh — shared logging/util functions, sourced by every cc-service script.
# Not meant to be executed directly.

CC_LOG_LEVEL="${CC_LOG_LEVEL:-info}"

_cc_log_level_num() {
  case "$1" in
    debug) echo 0 ;;
    info) echo 1 ;;
    warn) echo 2 ;;
    error) echo 3 ;;
    *) echo 1 ;;
  esac
}

log() {
  # log <level> <message...>
  local level="$1"; shift
  local msg="$*"
  local threshold this
  threshold=$(_cc_log_level_num "$CC_LOG_LEVEL")
  this=$(_cc_log_level_num "$level")
  [ "$this" -lt "$threshold" ] && return 0
  local ts line
  ts=$(date -Is)
  line="[$ts] [$level] [${CC_INSTANCE_NAME:-cc-service}] $msg"
  echo "$line" >&2
  if [ -n "${CC_LOG_FILE:-}" ]; then
    echo "$line" >> "$CC_LOG_FILE" 2>/dev/null || true
  fi
}

fail() {
  log error "$*"
  exit 1
}

require_cmd() {
  # require_cmd tmux claude systemctl ...
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log error "missing required commands: ${missing[*]}"
    return 1
  fi
}

load_config() {
  # load_config <path-to-env-file>
  local f="$1"
  [ -f "$f" ] || { log error "config file not found: $f"; return 1; }
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

# Command runners are indirected through these variables so tests can stub
# them on PATH without touching the real system. Scripts should call
# "$CC_TMUX_CMD" / "$CC_SYSTEMCTL_CMD" / "$CC_PS_CMD" rather than the bare
# command names.
CC_TMUX_CMD="${CC_TMUX_CMD:-tmux}"
CC_SYSTEMCTL_CMD="${CC_SYSTEMCTL_CMD:-systemctl}"
CC_PS_CMD="${CC_PS_CMD:-ps}"

tmux_session_exists() {
  "$CC_TMUX_CMD" has-session -t "$1" 2>/dev/null
}

# Returns 0 (true) if the pane's tail has been byte-identical across two
# captures taken $quiet_sec apart -- a cheap "nothing is actively rendering"
# check, used before the watchdog sends any keystrokes.
pane_is_quiet() {
  local session="$1" quiet_sec="$2" lines="$3"
  local a b
  a=$("$CC_TMUX_CMD" capture-pane -p -t "$session" -S "-${lines}" 2>/dev/null) || return 1
  sleep "$quiet_sec"
  b=$("$CC_TMUX_CMD" capture-pane -p -t "$session" -S "-${lines}" 2>/dev/null) || return 1
  [ "$a" = "$b" ]
}
