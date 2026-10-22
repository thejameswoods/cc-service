#!/bin/bash
# cc-service-terminal.sh — a browser terminal attached to the daemon's tmux
# session, served by ttyd over TLS with HTTP Basic auth. Invoked by the
# cc-service-terminal@<instance>.service systemd unit with the config file path
# as $1. Optional: only installed by `install.sh --terminal`.
#
# What it gives: a real terminal on the running session, the same as
# `tmux attach` over SSH, with the same password as the status page (user "cc").
# That includes free text, so anyone who can sign in can instruct the agent.
# Treat the password like a shell login.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# build_ttyd_args <out-array-name> <password>
# Pure so tests can check the flags without running ttyd.
#   -W            writable (ttyd is read-only without it)
#   -O            refuse WebSocket connections whose Origin is not this host.
#                 Without it any web page you visit could drive the terminal
#                 through your browser's cached credentials.
#   -m 2          at most two browser terminals at once
#   -i <iface>    bind to one network interface (ttyd takes an interface name
#                 or a socket path, not an address); default lo
#   --ssl ...     TLS from CC_TLS_CERT / CC_TLS_KEY
# The session is attached with plain `tmux attach`, so the window follows the
# browser's size while the browser is attached, like an SSH client would.
build_ttyd_args() {
  local -n out_arr=$1
  local password="$2"
  out_arr=(
    -W -O -m 2
    -p "${CC_TERMINAL_PORT:-7681}"
    -i "${CC_TERMINAL_IFACE:-lo}"
    --ssl --ssl-cert "$CC_TLS_CERT" --ssl-key "$CC_TLS_KEY"
    -c "cc:$password"
  )
  local tmux_args=(attach-session -t "${CC_TMUX_SESSION:-claude}")
  [ -n "${CC_TMUX_SOCKET:-}" ] && tmux_args=(-L "$CC_TMUX_SOCKET" "${tmux_args[@]}")
  out_arr+=("${CC_TMUX_CMD:-tmux}" "${tmux_args[@]}")
}

main() {
  CONFIG_PATH="${1:-${CC_CONFIG_PATH:-}}"
  [ -n "$CONFIG_PATH" ] || { echo "usage: cc-service-terminal.sh <config-path>  (or set CC_CONFIG_PATH)" >&2; exit 1; }
  load_config "$CONFIG_PATH" || exit 1

  require_cmd ttyd tmux || exit 1
  [ -n "${CC_TLS_CERT:-}" ] && [ -r "${CC_TLS_CERT:-}" ] && [ -n "${CC_TLS_KEY:-}" ] && [ -r "${CC_TLS_KEY:-}" ] \
    || fail "the terminal needs TLS: CC_TLS_CERT and CC_TLS_KEY must be set and readable"
  [ -n "${CC_WEB_PASSWORD_FILE:-}" ] && [ -r "$CC_WEB_PASSWORD_FILE" ] \
    || fail "CC_WEB_PASSWORD_FILE must be set and readable: the terminal shares the page's password"

  local password
  password=$(<"$CC_WEB_PASSWORD_FILE")
  password="${password%$'\n'}"
  [ "${#password}" -ge 12 ] || fail "the password in $CC_WEB_PASSWORD_FILE is shorter than 12 characters"

  local args=()
  build_ttyd_args args "$password"
  log info "terminal listening on https, interface ${CC_TERMINAL_IFACE:-lo} port ${CC_TERMINAL_PORT:-7681} (instance=${CC_INSTANCE_NAME:-default} session=${CC_TMUX_SESSION:-claude})"
  # ttyd takes the credential as an argument, so it is visible to local users in
  # the process list while this runs. See README.md.
  exec ttyd "${args[@]}"
}

# Only run when executed directly -- sourcing this file (as the tests do, to
# check build_ttyd_args) must not start ttyd.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
