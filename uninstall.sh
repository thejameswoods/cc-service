#!/bin/bash
# uninstall.sh — remove one (or all) cc-service instance(s).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

INSTALL_DIR="/opt/cc-service"
CONFIG_DIR="/etc/cc-service"
UNIT_DIR="/etc/systemd/system"
LOG_DIR="/var/log/cc-service"

SERVICE_NAME="default"
ALL=false
PURGE=false
DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: sudo ./uninstall.sh [--service-name <name> | --all] [options]

Options:
  --service-name <name>   Instance to remove. Default: "default".
  --all                   Remove every cc-service instance found on this box.
  --purge                 Also remove config (/etc/cc-service/<name>.env) and logs.
  --dry-run               Print planned actions; make no changes.
  --yes                   Non-interactive; assume "yes" to prompts.
  --help                  Show this help.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --all) ALL=true; shift ;;
      --purge) PURGE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
  done
}

run_or_dry() {
  local desc="$1"; shift
  if $DRY_RUN; then
    log info "[dry-run] would: $desc  ($*)"
  else
    log info "$desc"
    "$@" || true
  fi
}

list_instances() {
  "$CC_SYSTEMCTL_CMD" list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^cc-service@.*\.service$' \
    | sed -E 's/^cc-service@(.*)\.service$/\1/'
}

remove_instance() {
  local name="$1"
  local unit="cc-service@$name.service"
  local watchdog_unit="cc-service-watchdog@$name.service"
  local config_file="$CONFIG_DIR/$name.env"

  local tmux_session=""
  [ -f "$config_file" ] && tmux_session=$(grep -E '^CC_TMUX_SESSION=' "$config_file" | head -1 | cut -d'"' -f2)

  run_or_dry "disable+stop $watchdog_unit" "$CC_SYSTEMCTL_CMD" disable --now "$watchdog_unit"
  run_or_dry "disable+stop $unit" "$CC_SYSTEMCTL_CMD" disable --now "$unit"
  run_or_dry "remove unit file $UNIT_DIR/$watchdog_unit" rm -f "$UNIT_DIR/$watchdog_unit"
  run_or_dry "remove unit file $UNIT_DIR/$unit" rm -f "$UNIT_DIR/$unit"
  run_or_dry "systemctl daemon-reload" "$CC_SYSTEMCTL_CMD" daemon-reload

  if [ -n "$tmux_session" ] && tmux_session_exists "$tmux_session"; then
    run_or_dry "kill tmux session $tmux_session" "$CC_TMUX_CMD" kill-session -t "$tmux_session"
  fi

  if $PURGE; then
    run_or_dry "remove config $config_file" rm -f "$config_file"
    run_or_dry "remove logs $LOG_DIR/$name.*" bash -c "rm -f '$LOG_DIR/$name'.*.log"
  fi

  log info "instance '$name' removed"
}

main() {
  parse_args "$@"
  require_cmd "$CC_SYSTEMCTL_CMD" tmux || exit 1
  [ "$(id -u)" -eq 0 ] || $DRY_RUN || fail "uninstall.sh must be run as root (sudo), except with --dry-run"

  local targets=()
  if $ALL; then
    mapfile -t targets < <(list_instances)
    [ "${#targets[@]}" -eq 0 ] && { log info "no cc-service instances found"; exit 0; }
  else
    targets=("$SERVICE_NAME")
  fi

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo "About to remove instance(s): ${targets[*]}"
    $PURGE && echo "(--purge: config and logs will also be deleted)"
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log info "aborted"; exit 3; }
  fi

  for t in "${targets[@]}"; do
    remove_instance "$t"
  done

  if $ALL || [ "$(list_instances | wc -l)" -eq 0 ]; then
    if [ -d "$INSTALL_DIR" ]; then
      if ! $ASSUME_YES && ! $DRY_RUN; then
        read -r -p "No cc-service instances remain. Remove $INSTALL_DIR entirely? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] && run_or_dry "remove $INSTALL_DIR" rm -rf "$INSTALL_DIR"
      elif $ASSUME_YES; then
        run_or_dry "remove $INSTALL_DIR" rm -rf "$INSTALL_DIR"
      fi
    fi
  fi
}

main "$@"
