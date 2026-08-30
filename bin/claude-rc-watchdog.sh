#!/bin/bash
# claude-rc-watchdog.sh — polls the daemon's tmux pane for Remote Control
# failure banners and self-heals by sending /remote-control, with safety
# gates so it never injects keystrokes into a busy or mid-turn pane.
# See docs/remote-control-failure-modes.md for the banner reference.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# Literal substrings from Claude Code's Remote Control TUI banners.
# Keep in sync with docs/remote-control-failure-modes.md.
RC_FAIL_PATTERNS=(
  'Remote Control not started here'
  "Couldn.t reconnect to your Remote Control session"
  'Remote credentials fetch failed'
  'Previous session is unavailable'
  'could not reach the Remote Control server'
)

# NOT self-healable by /remote-control -- needs a human to run /login.
AUTH_FAIL_PATTERNS=(
  'Invalid API key'
  'Please run /login'
  'Your credentials have expired'
  'Not logged in'
)

RC_OK_PATTERNS=(
  '/rc active'
  'Remote Control active'
)

# Signals Claude is actively rendering/working (spinner glyphs, "Thinking…",
# "esc to interrupt"). Absence of this anywhere in the capture, combined with
# pane_is_quiet(), is our "safe to send keystrokes" signal. Checking for
# busy-ness (rather than matching an exact idle-prompt line position) is more
# robust: the prompt box and the footer status bar can each land on different
# lines depending on terminal width/chrome, but a busy indicator reliably
# appears somewhere in the capture while a turn is running.
BUSY_PATTERN='esc to interrupt|Thinking[.…]|[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'

consecutive_attempts=0
backoff_until_epoch=0

reset_backoff() { consecutive_attempts=0; backoff_until_epoch=0; }

compute_backoff_sec() {
  local n=$1 base="${CC_WATCHDOG_BACKOFF_BASE_SEC:-30}" cap="${CC_WATCHDOG_BACKOFF_MAX_SEC:-1800}"
  local shift_amt=$((n > 20 ? 20 : n - 1))
  local val=$((base * (1 << shift_amt)))
  [ "$val" -gt "$cap" ] && val=$cap
  echo "$val"
}

attempt_self_heal() {
  local session="$1"
  log warn "attempting self-heal: sending /remote-control to session '$session'"
  # Deliberately no blind C-u clear first: we only get here after
  # confirming the pane is idle+quiet, so the input line should already be
  # empty. Blind-clearing could destroy a human's legitimately half-typed
  # command if someone is concurrently attached via `tmux attach`.
  tmux_run send-keys -t "$session" "/remote-control" Enter
}

poll_once() {
  local session="${CC_TMUX_SESSION:?CC_TMUX_SESSION must be set}"

  if ! tmux_session_exists "$session"; then
    log debug "tmux session '$session' not present (daemon likely between restarts); skipping this poll"
    return 0
  fi

  local capture
  capture=$(tmux_run capture-pane -p -t "$session" -S "-${CC_WATCHDOG_PANE_LINES:-60}" 2>/dev/null) || {
    log warn "capture-pane failed for session '$session'"
    return 0
  }
  log debug "pane capture ($session): $capture"

  local pat
  for pat in "${AUTH_FAIL_PATTERNS[@]}"; do
    if grep -qE "$pat" <<<"$capture"; then
      log error "AUTH FAILURE detected (pattern: '$pat') -- cannot self-heal headlessly. Manual /login required on session '$session'. Backing off."
      consecutive_attempts=$((consecutive_attempts + 1))
      backoff_until_epoch=$(($(date +%s) + $(compute_backoff_sec "$consecutive_attempts")))
      return 0
    fi
  done

  for pat in "${RC_OK_PATTERNS[@]}"; do
    if grep -qE "$pat" <<<"$capture"; then
      [ "$consecutive_attempts" -gt 0 ] && log info "Remote Control appears healthy again (pattern: '$pat'); resetting backoff state"
      reset_backoff
      return 0
    fi
  done

  local matched=""
  for pat in "${RC_FAIL_PATTERNS[@]}"; do
    if grep -qE "$pat" <<<"$capture"; then matched="$pat"; break; fi
  done
  [ -z "$matched" ] && return 0

  log warn "Remote Control failure banner detected (pattern: '$matched')"

  local now
  now=$(date +%s)
  if [ "$now" -lt "$backoff_until_epoch" ]; then
    log info "in backoff window ($((backoff_until_epoch - now))s remaining); not attempting self-heal yet"
    return 0
  fi

  if [ "$consecutive_attempts" -ge "${CC_WATCHDOG_MAX_CONSECUTIVE_ATTEMPTS:-6}" ]; then
    log error "reached CC_WATCHDOG_MAX_CONSECUTIVE_ATTEMPTS (${CC_WATCHDOG_MAX_CONSECUTIVE_ATTEMPTS:-6}) without recovery. Giving up automatic retries; will keep polling and logging at ERROR every ${CC_WATCHDOG_INTERVAL_SEC:-60}s until state changes. Manual intervention likely required: tmux attach -t $session"
    return 0
  fi

  if grep -qE "$BUSY_PATTERN" <<<"$capture"; then
    log info "pane appears busy (matched a working/spinner indicator); deferring self-heal to next poll"
    return 0
  fi
  if ! pane_is_quiet "$session" "${CC_WATCHDOG_IDLE_QUIET_SEC:-5}" "${CC_WATCHDOG_PANE_LINES:-60}"; then
    log info "pane content still changing; deferring self-heal to next poll"
    return 0
  fi

  consecutive_attempts=$((consecutive_attempts + 1))
  attempt_self_heal "$session"
  backoff_until_epoch=$(($(date +%s) + $(compute_backoff_sec "$consecutive_attempts")))
  log info "self-heal attempt #$consecutive_attempts sent; next eligible retry in $(compute_backoff_sec "$consecutive_attempts")s if unresolved"
}

main() {
  # Accepts the config path as $1 too, matching claude-daemon.sh's
  # interface (this unit is Type=simple, directly execed by systemd, so
  # its own Environment= is reliable -- but the argument form is accepted
  # here as well for a consistent, documented interface between the two).
  CONFIG_PATH="${1:-${CC_CONFIG_PATH:-}}"
  [ -n "$CONFIG_PATH" ] || { echo "usage: claude-rc-watchdog.sh <config-path>  (or set CC_CONFIG_PATH)" >&2; exit 1; }
  load_config "$CONFIG_PATH" || exit 1

  CC_LOG_FILE="${CC_LOG_DIR:-/var/log/cc-service}/${CC_INSTANCE_NAME:-default}.watchdog.log"
  mkdir -p "$(dirname "$CC_LOG_FILE")" 2>/dev/null || true

  require_cmd tmux || exit 1

  log info "watchdog starting (session=${CC_TMUX_SESSION:-?} interval=${CC_WATCHDOG_INTERVAL_SEC:-60}s)"
  while true; do
    poll_once
    sleep "${CC_WATCHDOG_INTERVAL_SEC:-60}"
  done
}

# Only run the live loop when executed directly -- sourcing this file (as
# test/run-fixture-tests.sh does, to exercise the pattern arrays and pure
# functions above) must not require CC_CONFIG_PATH or start polling.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
