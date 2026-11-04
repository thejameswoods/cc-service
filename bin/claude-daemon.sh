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

# Literal text Claude Code prints when `claude --continue` has no conversation
# to resume. Keep in sync with docs/remote-control-failure-modes.md.
NO_CONVERSATION_PATTERN='No conversation found to continue'

# no_conversation_to_continue <text>: true if <text> (this run's pane output)
# shows claude exited because there was nothing to continue.
no_conversation_to_continue() {
  grep -qF "$NO_CONVERSATION_PATTERN" <<<"$1"
}

# Empty this pane's screen and scrollback, so what is in the pane afterwards
# is only the next claude run's output and a stale message from an earlier
# run cannot be mistaken for this one's.
clear_pane() {
  [ -t 1 ] || return 0
  printf '\033[3J\033[H\033[2J'
  tmux_run clear-history -t "${CC_TMUX_SESSION:-}" 2>/dev/null || true
}

# wait_for_project_dir <dir>: block until <dir> answers a stat(), then return.
# CC_PROJECT_DIR is often a network mount (NFS, SMB). If its server is down at
# boot, or drops while the daemon is up, the daemon must neither exit (nothing
# restarts it once the server is back) nor hang on the mount (a hard NFS mount
# never times out). It waits here, logging once a minute, and carries on by
# itself as soon as the directory answers. Deliberately never gives up: a
# mistyped path waits forever and says so in the log every minute.
wait_for_project_dir() {
  local dir="$1" interval="${CC_PROJECT_DIR_POLL_SEC:-10}" attempts=0 waited=0
  while ! dir_responsive "$dir" 30; do
    if [ $((attempts % 6)) -eq 0 ]; then
      log warn "project dir not available: $dir (network mount down, or the path is wrong?); waiting, retrying every ${interval}s"
    fi
    attempts=$((attempts + 1))
    sleep "$interval"
    waited=$((waited + interval))
  done
  if [ "$attempts" -gt 0 ]; then
    log info "project dir available again after ~${waited}s: $dir"
  fi
}

main() {
  CONFIG_PATH="${1:-${CC_CONFIG_PATH:-}}"
  [ -n "$CONFIG_PATH" ] || { echo "usage: claude-daemon.sh <config-path>  (or set CC_CONFIG_PATH)" >&2; exit 1; }
  load_config "$CONFIG_PATH" || exit 1

  CC_LOG_FILE="${CC_LOG_DIR:-/var/log/cc-service}/${CC_INSTANCE_NAME:-default}.daemon.log"
  mkdir -p "$(dirname "$CC_LOG_FILE")" 2>/dev/null || true

  require_cmd claude || exit 1
  [ -n "${CC_PROJECT_DIR:-}" ] || fail "CC_PROJECT_DIR is not set in $CONFIG_PATH"
  wait_for_project_dir "$CC_PROJECT_DIR"
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

  local first_launch=true
  while true; do
    if $first_launch; then
      local delay="${CC_STARTUP_DELAY_SEC:-15}"
      log info "startup delay: sleeping ${delay}s to let the server expire any stale pre-reboot Remote Control registration before resuming the conversation"
      sleep "$delay"
      first_launch=false
    fi

    # Not only at start: if the mount dropped while claude ran, claude exits
    # (or is killed) and must not be relaunched into a dead directory.
    wait_for_project_dir "$CC_PROJECT_DIR"

    local claude_args=() exit_code
    build_claude_args claude_args
    log info "launching: claude ${claude_args[*]}"
    clear_pane
    claude "${claude_args[@]}"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
      # --continue exits at once with "No conversation found to continue" when
      # this directory has nothing to resume: every brand-new install, and a
      # first session that was only ever used to log in. Start a fresh session
      # then. This is decided on every launch from what claude itself printed,
      # not once per daemon lifetime: the first claude of a new install can
      # spend the daemon's whole first iteration in the login wizard, and a
      # one-shot fallback was then gone when it was needed (confirmed live: the
      # daemon looped on --continue every few seconds after the login worked).
      # Any other failure (network, auth) keeps retrying --continue, so a real
      # conversation is never abandoned for a fresh one.
      local pane_text=""
      pane_text=$(tmux_run capture-pane -p -t "${CC_TMUX_SESSION:-}" 2>/dev/null) || pane_text=""
      if no_conversation_to_continue "$pane_text"; then
        log warn "claude --continue exited $exit_code: no conversation to continue yet; starting a fresh session instead"
        claude_args=()
        build_claude_args claude_args --no-continue
        log info "launching: claude ${claude_args[*]}"
        clear_pane
        claude "${claude_args[@]}"
        exit_code=$?
      fi
    fi

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
