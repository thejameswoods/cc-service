#!/bin/bash
# claude-daemon.sh — persistent tmux+claude loop for one cc-service instance.
# Invoked by the cc-service@<instance>.service systemd unit, inside a
# `tmux new-session`, with the config file path as $1.
#
# Deliberately takes the config path as a positional argument rather than
# relying solely on the CC_CONFIG_PATH environment variable: when a tmux
# server for this OS user already exists (e.g. another cc-service instance,
# or the box's own always-on session), `tmux new-session` on it inherits
# THAT SERVER's environment captured at its own start time, not this unit's
# `Environment=` -- confirmed by a live install where CC_CONFIG_PATH never
# reached the script and the empty session self-destructed instantly.
# Argv, unlike environment, is always passed through exactly as given.
set -uo pipefail   # NOT -e: a nonzero exit from `claude` must not kill the loop

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Build the argv dynamically so empty config values cleanly omit flags,
# rather than passing e.g. --permission-mode "" which claude would reject.
# build_claude_args <out-array-name> [--no-continue]
build_claude_args() {
  local -n out_arr=$1
  out_arr=()
  [ "${2:-}" != "--no-continue" ] && out_arr+=(--continue)
  [ -n "${CC_PERMISSION_MODE:-}" ] && out_arr+=(--permission-mode "$CC_PERMISSION_MODE")
  [ -n "${CC_CLAUDE_NAME:-}" ] && out_arr+=(--name "$CC_CLAUDE_NAME")
  if [ -n "${CC_CLAUDE_EXTRA_ARGS:-}" ]; then
    # word-split intentionally; documented as an advanced/opaque escape hatch
    # shellcheck disable=SC2206
    out_arr+=($CC_CLAUDE_EXTRA_ARGS)
  fi
}

main() {
  CONFIG_PATH="${1:-${CC_CONFIG_PATH:-}}"
  [ -n "$CONFIG_PATH" ] || { echo "usage: claude-daemon.sh <config-path>  (or set CC_CONFIG_PATH)" >&2; exit 1; }
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

  local first_launch=true bootstrapped=false
  while true; do
    if $first_launch; then
      local delay="${CC_STARTUP_DELAY_SEC:-15}"
      log info "startup delay: sleeping ${delay}s to let the server expire any stale pre-reboot Remote Control registration before resuming the conversation"
      sleep "$delay"
      first_launch=false
    fi

    local claude_args=() exit_code
    build_claude_args claude_args
    log info "launching: claude ${claude_args[*]}"
    claude "${claude_args[@]}"
    exit_code=$?

    if [ "$exit_code" -ne 0 ] && ! $bootstrapped; then
      # --continue fails immediately with no prior conversation in this
      # directory -- the case for every brand-new install, confirmed live:
      # a fresh project dir looped "No conversation found to continue"
      # forever. Fall back to a fresh session exactly once per daemon
      # lifetime; every restart after a successful run has a conversation
      # to continue, so this only ever fires on true first-time bootstrap.
      log warn "claude --continue exited $exit_code; no prior conversation likely exists yet, starting a fresh session instead"
      claude_args=()
      build_claude_args claude_args --no-continue
      log info "launching: claude ${claude_args[*]}"
      claude "${claude_args[@]}"
      exit_code=$?
    fi
    bootstrapped=true

    log warn "claude exited (code=$exit_code); respawning in ${CC_RESPAWN_DELAY_SEC:-3}s"
    sleep "${CC_RESPAWN_DELAY_SEC:-3}"
  done
}

# Only run the live loop when executed directly -- sourcing this file (as
# test/run-fixture-tests.sh does, to exercise build_claude_args) must not
# require a config path or start launching claude.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
