#!/bin/bash
# claude-daemon.sh — persistent tmux+claude loop for one cc-service instance.
# Invoked by the cc-service@<instance>.service systemd unit, inside a
# `tmux new-session`. CC_CONFIG_PATH must be set in the environment (the
# systemd unit does this via Environment=).
set -uo pipefail   # NOT -e: a nonzero exit from `claude` must not kill the loop

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

CONFIG_PATH="${CC_CONFIG_PATH:?CC_CONFIG_PATH env var must be set (normally by the systemd unit)}"
load_config "$CONFIG_PATH" || exit 1

CC_LOG_FILE="${CC_LOG_DIR:-/var/log/cc-service}/${CC_INSTANCE_NAME:-default}.daemon.log"
mkdir -p "$(dirname "$CC_LOG_FILE")" 2>/dev/null || true

require_cmd claude || exit 1
[ -d "$CC_PROJECT_DIR" ] || fail "CC_PROJECT_DIR does not exist: $CC_PROJECT_DIR"
cd "$CC_PROJECT_DIR" || exit 1

if [ -n "${CC_CRED_HOOK:-}" ]; then
  if [ -r "$CC_CRED_HOOK" ]; then
    log info "sourcing credential hook: $CC_CRED_HOOK"
    # shellcheck disable=SC1090
    source "$CC_CRED_HOOK"
  else
    log error "CC_CRED_HOOK set but not readable: $CC_CRED_HOOK (continuing without it)"
  fi
fi

# Build the argv dynamically so empty config values cleanly omit flags,
# rather than passing e.g. --permission-mode "" which claude would reject.
build_claude_args() {
  local -n out_arr=$1
  out_arr=(--continue)
  [ -n "${CC_PERMISSION_MODE:-}" ] && out_arr+=(--permission-mode "$CC_PERMISSION_MODE")
  [ -n "${CC_CLAUDE_NAME:-}" ] && out_arr+=(--name "$CC_CLAUDE_NAME")
  if [ -n "${CC_CLAUDE_EXTRA_ARGS:-}" ]; then
    # word-split intentionally; documented as an advanced/opaque escape hatch
    # shellcheck disable=SC2206
    out_arr+=($CC_CLAUDE_EXTRA_ARGS)
  fi
}

first_launch=true
while true; do
  if $first_launch; then
    delay="${CC_STARTUP_DELAY_SEC:-15}"
    log info "startup delay: sleeping ${delay}s to let the server expire any stale pre-reboot Remote Control registration before resuming the conversation"
    sleep "$delay"
    first_launch=false
  fi

  claude_args=()
  build_claude_args claude_args
  log info "launching: claude ${claude_args[*]}"
  claude "${claude_args[@]}"
  exit_code=$?
  log warn "claude exited (code=$exit_code); respawning in ${CC_RESPAWN_DELAY_SEC:-3}s"
  sleep "${CC_RESPAWN_DELAY_SEC:-3}"
done
