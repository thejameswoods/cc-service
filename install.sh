#!/bin/bash
# install.sh — install or upgrade one cc-service instance.
# See README.md for full documentation. Run with --help for flag reference.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/conflict-detect.sh
source "$SCRIPT_DIR/lib/conflict-detect.sh"

INSTALL_DIR="/opt/cc-service"
CONFIG_DIR="/etc/cc-service"
UNIT_DIR="/etc/systemd/system"
BACKUP_DIR="$CONFIG_DIR/backups"

# --- defaults ---
PROJECT_DIR=""
SERVICE_NAME="default"
TMUX_SESSION="claude"
PERMISSION_MODE=""
CRED_HOOK=""
CONFIG_PATH=""
STARTUP_DELAY=15
WATCHDOG_INTERVAL=60
RUN_AS_USER="${SUDO_USER:-$(id -un)}"
DRY_RUN=false
ASSUME_YES=false
FORCE_REMOVE_CONFLICTS=false
WATCHDOG_ENABLED=true

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh --project-dir <path> [options]

Required:
  --project-dir <path>       Directory claude-daemon.sh cds into before launching claude.

Options:
  --service-name <name>      Instance name, used to derive unit/config names. Default: "default".
  --tmux-session <name>      tmux session name. Default: "claude".
  --permission-mode <mode>   Passed as --permission-mode to claude. Default: unset (normal prompting).
  --cred-hook <path>         Script sourced before each claude launch (e.g. to export secrets).
  --config-path <path>       Override the rendered config file location.
  --startup-delay <sec>      Delay before the first launch after boot. Default: 15.
  --watchdog-interval <sec>  Watchdog poll interval. Default: 60.
  --user <name>              System user to run the service as. Default: invoking user.
  --no-watchdog              Do not install the Remote Control watchdog unit.
  --dry-run                  Print planned actions; make no changes.
  --yes                      Non-interactive; assume "yes" to safe prompts.
  --force-remove-conflicts   Required together with --yes to auto-remove a foreign
                              conflicting service non-interactively.
  --help                     Show this help.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --project-dir) PROJECT_DIR="$2"; shift 2 ;;
      --service-name) SERVICE_NAME="$2"; shift 2 ;;
      --tmux-session) TMUX_SESSION="$2"; shift 2 ;;
      --permission-mode) PERMISSION_MODE="$2"; shift 2 ;;
      --cred-hook) CRED_HOOK="$2"; shift 2 ;;
      --config-path) CONFIG_PATH="$2"; shift 2 ;;
      --startup-delay) STARTUP_DELAY="$2"; shift 2 ;;
      --watchdog-interval) WATCHDOG_INTERVAL="$2"; shift 2 ;;
      --user) RUN_AS_USER="$2"; shift 2 ;;
      --no-watchdog) WATCHDOG_ENABLED=false; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --force-remove-conflicts) FORCE_REMOVE_CONFLICTS=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$CONFIG_PATH" ] || CONFIG_PATH="$CONFIG_DIR/$SERVICE_NAME.env"
}

run_or_dry() {
  # run_or_dry "description" cmd arg1 arg2 ...
  local desc="$1"; shift
  if $DRY_RUN; then
    log info "[dry-run] would: $desc  ($*)"
  else
    log info "$desc"
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Conflict detection / resolution
# ---------------------------------------------------------------------------

print_conflict_report() {
  [ -n "$CC_SCAN_FOREIGN_UNITS" ] && {
    echo "[!] Found potentially conflicting systemd unit(s) (tmux+claude in ExecStart):"
    while IFS='|' read -r _ unit exec_start; do
      [ -z "$unit" ] && continue
      echo "      unit:      $unit"
      echo "      ExecStart: $exec_start"
    done <<<"$CC_SCAN_FOREIGN_UNITS"
  }
  [ -n "$CC_SCAN_LOOP_PROCS" ] && {
    echo "[!] Found running always-on-shaped process(es) (while-true loop wrapping claude):"
    while IFS='|' read -r _ pidpart scriptpart; do
      [ -z "$pidpart" ] && continue
      echo "      $pidpart  $scriptpart"
    done <<<"$CC_SCAN_LOOP_PROCS"
  }
  [ -n "$CC_SCAN_TMUX_COLLISION" ] && {
    echo "[!] tmux session name collision:"
    while IFS='|' read -r _ name pidpart; do
      [ -z "$name" ] && continue
      echo "      session '$name' already exists ($pidpart)"
    done <<<"$CC_SCAN_TMUX_COLLISION"
  }
}

remove_foreign_conflicts() {
  mkdir -p "$BACKUP_DIR"
  if [ -n "$CC_SCAN_FOREIGN_UNITS" ]; then
    while IFS='|' read -r _ unit _; do
      [ -z "$unit" ] && continue
      run_or_dry "disable+stop foreign unit $unit" "$CC_SYSTEMCTL_CMD" disable --now "$unit"
      local unit_file="$UNIT_DIR/$unit"
      if [ -f "$unit_file" ]; then
        run_or_dry "back up $unit_file to $BACKUP_DIR/" cp "$unit_file" "$BACKUP_DIR/${unit}.bak.$(date +%s)"
        run_or_dry "remove $unit_file" rm -f "$unit_file"
      fi
    done <<<"$CC_SCAN_FOREIGN_UNITS"
    run_or_dry "systemctl daemon-reload" "$CC_SYSTEMCTL_CMD" daemon-reload
  fi
  if [ -n "$CC_SCAN_LOOP_PROCS" ]; then
    while IFS='|' read -r _ pidpart _; do
      [ -z "$pidpart" ] && continue
      local pid="${pidpart#pid=}"
      run_or_dry "kill loop process pid $pid" kill "$pid"
    done <<<"$CC_SCAN_LOOP_PROCS"
  fi
  if [ -n "$CC_SCAN_TMUX_COLLISION" ] && tmux_session_exists "$TMUX_SESSION"; then
    run_or_dry "kill tmux session $TMUX_SESSION" "$CC_TMUX_CMD" kill-session -t "$TMUX_SESSION"
  fi
}

run_conflict_scan_and_resolve() {
  while true; do
    scan_for_conflicts "$TMUX_SESSION" "$SERVICE_NAME"

    if [ "$CC_SCAN_OWN_INSTANCE_STATE" != "absent" ]; then
      log info "existing cc-service instance '$SERVICE_NAME' found (state: $CC_SCAN_OWN_INSTANCE_STATE) — treating this run as an upgrade, not a conflict"
    fi

    local has_real_collision=false
    [ -n "$CC_SCAN_TMUX_COLLISION" ] && has_real_collision=true
    # A foreign unit/process match with NO tmux-name collision is informational only.
    if ! $has_real_collision; then
      if [ -n "$CC_SCAN_FOREIGN_UNITS$CC_SCAN_LOOP_PROCS" ]; then
        echo "[i] Detected other always-on Claude Code daemon(s) on this box, but none collide with the"
        echo "    tmux session name you requested ('$TMUX_SESSION') — no action needed, proceeding."
        print_conflict_report
      fi
      return 0
    fi

    echo
    print_conflict_report
    echo
    echo "Running two independent daemons against the same tmux session name will collide."
    echo

    if $ASSUME_YES; then
      if $FORCE_REMOVE_CONFLICTS; then
        remove_foreign_conflicts
        return 0
      else
        log error "refusing to proceed non-interactively: a real conflict was found and --force-remove-conflicts was not passed. Re-run with --force-remove-conflicts, or pick a different --tmux-session/--service-name, or resolve manually."
        exit 3
      fi
    fi

    echo "What would you like to do?"
    echo "  [1] Stop and disable the foreign service, and free up the tmux session name"
    echo "  [2] Keep it running, and install cc-service under a DIFFERENT tmux session name / service name instead"
    echo "  [3] Abort installation"
    read -r -p "Choice [1/2/3]: " choice
    case "$choice" in
      1) remove_foreign_conflicts; return 0 ;;
      2)
        read -r -p "New --tmux-session value: " TMUX_SESSION
        read -r -p "New --service-name value: " SERVICE_NAME
        [ -n "$CONFIG_PATH" ] && CONFIG_PATH="$CONFIG_DIR/$SERVICE_NAME.env"
        continue
        ;;
      3|*) log info "aborted by user"; exit 3 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

ensure_service_user() {
  id "$RUN_AS_USER" >/dev/null 2>&1 || fail "user '$RUN_AS_USER' does not exist; create it first or pass --user"
  RUN_AS_HOME=$(getent passwd "$RUN_AS_USER" | cut -d: -f6)
  [ -n "$RUN_AS_HOME" ] || fail "could not determine home directory for user '$RUN_AS_USER'"
}

ensure_log_dir() {
  # /var/log/cc-service needs root to create, but the daemon/watchdog run
  # as RUN_AS_USER (non-root) and can't create it themselves on first boot
  # -- confirmed by a live install where logging silently failed with
  # "No such file or directory" because of exactly this. install.sh runs
  # as root, so it creates and hands over ownership here.
  local log_dir="/var/log/cc-service"
  run_or_dry "create $log_dir owned by $RUN_AS_USER" mkdir -p "$log_dir"
  $DRY_RUN || chown "$RUN_AS_USER" "$log_dir" 2>/dev/null || true
}

install_files() {
  local release_id
  if [ -d "$SCRIPT_DIR/.git" ] && command -v git >/dev/null 2>&1; then
    release_id=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || date +%s)
  else
    release_id=$(date +%s)
  fi
  local release_dir="$INSTALL_DIR/rel-$release_id"
  run_or_dry "install package files to $release_dir" mkdir -p "$release_dir"
  if ! $DRY_RUN; then
    cp -r "$SCRIPT_DIR/bin" "$SCRIPT_DIR/lib" "$release_dir/"
    chmod +x "$release_dir"/bin/*.sh
    ln -sfn "$release_dir" "$INSTALL_DIR/current"
  else
    log info "[dry-run] would symlink $INSTALL_DIR/current -> $release_dir"
  fi
}

write_config() {
  run_or_dry "write config to $CONFIG_PATH" true
  $DRY_RUN && return 0
  mkdir -p "$(dirname "$CONFIG_PATH")"
  # Default --name disambiguates multiple instances on one host: plain
  # $HOSTNAME for the common single-instance case, $HOSTNAME-<instance>
  # otherwise -- otherwise a second instance would silently share its
  # Remote Control display name with an unrelated one (e.g. production),
  # confirmed by a live install where a "default"-less second instance
  # rendered CC_CLAUDE_NAME identical to the box's existing daemon.
  local default_claude_name
  if [ "$SERVICE_NAME" = "default" ]; then
    default_claude_name='${HOSTNAME}'
  else
    default_claude_name="\${HOSTNAME}-$SERVICE_NAME"
  fi
  cat > "$CONFIG_PATH" <<EOF
CC_INSTANCE_NAME="$SERVICE_NAME"
CC_PROJECT_DIR="$PROJECT_DIR"
CC_TMUX_SESSION="$TMUX_SESSION"
CC_TMUX_SOCKET="$TMUX_SOCKET"
CC_CLAUDE_NAME="$default_claude_name"
CC_PERMISSION_MODE="$PERMISSION_MODE"
CC_CRED_HOOK="$CRED_HOOK"
CC_STARTUP_DELAY_SEC=$STARTUP_DELAY
CC_RESPAWN_DELAY_SEC=3
CC_CLAUDE_EXTRA_ARGS=""
CC_WATCHDOG_ENABLED="$WATCHDOG_ENABLED"
CC_WATCHDOG_INTERVAL_SEC=$WATCHDOG_INTERVAL
CC_WATCHDOG_PANE_LINES=60
CC_WATCHDOG_BACKOFF_BASE_SEC=30
CC_WATCHDOG_BACKOFF_MAX_SEC=1800
CC_WATCHDOG_MAX_CONSECUTIVE_ATTEMPTS=6
CC_WATCHDOG_IDLE_QUIET_SEC=5
CC_LOG_DIR="/var/log/cc-service"
CC_LOG_LEVEL="info"
EOF
  if [ -n "$CRED_HOOK" ] && [ -f "$CRED_HOOK" ]; then
    chmod 0500 "$CRED_HOOK" 2>/dev/null || true
  fi
}

merge_remote_control_setting() {
  local settings_file="$RUN_AS_HOME/.claude/settings.json"
  require_cmd jq || fail "jq is required (used to safely merge remoteControlAtStartup into your existing settings.json)"

  if $DRY_RUN; then
    log info "[dry-run] would ensure remoteControlAtStartup=true in $settings_file"
    return 0
  fi

  if [ ! -f "$settings_file" ]; then
    log warn "$settings_file does not exist; creating minimal one with remoteControlAtStartup=true"
    mkdir -p "$(dirname "$settings_file")"
    echo '{"remoteControlAtStartup": true}' > "$settings_file"
    chown "$RUN_AS_USER" "$settings_file" 2>/dev/null || true
    return 0
  fi

  if jq -e '.remoteControlAtStartup == true' "$settings_file" >/dev/null 2>&1; then
    log info "remoteControlAtStartup already true in $settings_file; leaving it untouched"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  jq '.remoteControlAtStartup = true' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
  log info "set remoteControlAtStartup=true in $settings_file (all other keys preserved)"
}

render_unit() {
  # render_unit <template-path> <output-path>
  local tmpl="$1" out="$2"
  local content
  content=$(cat "$tmpl")
  content="${content//\{\{RUN_AS_USER\}\}/$RUN_AS_USER}"
  content="${content//\{\{RUN_AS_HOME\}\}/$RUN_AS_HOME}"
  content="${content//\{\{CC_PROJECT_DIR\}\}/$PROJECT_DIR}"
  content="${content//\{\{CC_TMUX_SESSION\}\}/$TMUX_SESSION}"
  content="${content//\{\{CC_TMUX_SOCKET\}\}/$TMUX_SOCKET}"
  content="${content//\{\{INSTALL_DIR\}\}/$INSTALL_DIR}"
  if $DRY_RUN; then
    log info "[dry-run] would write $out"
  else
    printf '%s\n' "$content" > "$out"
  fi
}

render_systemd_units() {
  run_or_dry "render systemd units for instance '$SERVICE_NAME'" true
  render_unit "$SCRIPT_DIR/systemd/cc-service@.service.tmpl" "$UNIT_DIR/cc-service@$SERVICE_NAME.service"
  if $WATCHDOG_ENABLED; then
    render_unit "$SCRIPT_DIR/systemd/cc-service-watchdog@.service.tmpl" "$UNIT_DIR/cc-service-watchdog@$SERVICE_NAME.service"
  fi
}

enable_and_start() {
  # enable + restart (not `enable --now`): on an upgrade the unit may
  # already be active, and `enable --now` is a no-op start on an
  # already-running unit -- it would never pick up a changed ExecStart.
  # `restart` works correctly whether the unit was stopped or active.
  run_or_dry "systemctl daemon-reload" "$CC_SYSTEMCTL_CMD" daemon-reload
  run_or_dry "enable cc-service@$SERVICE_NAME" "$CC_SYSTEMCTL_CMD" enable "cc-service@$SERVICE_NAME.service"
  run_or_dry "restart cc-service@$SERVICE_NAME" "$CC_SYSTEMCTL_CMD" restart "cc-service@$SERVICE_NAME.service"
  if $WATCHDOG_ENABLED; then
    run_or_dry "enable cc-service-watchdog@$SERVICE_NAME" "$CC_SYSTEMCTL_CMD" enable "cc-service-watchdog@$SERVICE_NAME.service"
    run_or_dry "restart cc-service-watchdog@$SERVICE_NAME" "$CC_SYSTEMCTL_CMD" restart "cc-service-watchdog@$SERVICE_NAME.service"
  fi
}

verify_install() {
  $DRY_RUN && { log info "[dry-run] skipping verification"; return 0; }
  sleep 2
  local ok=true
  if "$CC_SYSTEMCTL_CMD" is-active --quiet "cc-service@$SERVICE_NAME.service"; then
    log info "cc-service@$SERVICE_NAME.service is active"
  else
    log error "cc-service@$SERVICE_NAME.service is NOT active"
    ok=false
  fi
  if $WATCHDOG_ENABLED; then
    if "$CC_SYSTEMCTL_CMD" is-active --quiet "cc-service-watchdog@$SERVICE_NAME.service"; then
      log info "cc-service-watchdog@$SERVICE_NAME.service is active"
    else
      log error "cc-service-watchdog@$SERVICE_NAME.service is NOT active"
      ok=false
    fi
  fi
  if tmux_session_exists "$TMUX_SESSION"; then
    log info "tmux session '$TMUX_SESSION' is up"
  else
    log error "tmux session '$TMUX_SESSION' not found"
    ok=false
  fi
  echo
  echo "Logs: journalctl -u cc-service@$SERVICE_NAME -f"
  $WATCHDOG_ENABLED && echo "       journalctl -u cc-service-watchdog@$SERVICE_NAME -f"
  echo "Attach: tmux attach -t $TMUX_SESSION   (detach with Ctrl-b d)"
  $ok || { log error "install completed with warnings above"; exit 1; }
}

main() {
  parse_args "$@"
  [ -n "$PROJECT_DIR" ] || { echo "--project-dir is required" >&2; usage; exit 2; }
  require_cmd tmux claude "$CC_SYSTEMCTL_CMD" jq || exit 1
  if [ "$(id -u)" -ne 0 ] && ! $DRY_RUN; then
    fail "install.sh must be run as root (sudo), except with --dry-run"
  fi

  ensure_service_user
  run_conflict_scan_and_resolve
  # Computed after conflict resolution settles SERVICE_NAME (option [2] in
  # the interactive prompt can change it). Every instance gets its own
  # dedicated tmux socket -- see the tmux_run comment in lib/common.sh for
  # why sharing the OS user's default server breaks Type=forking.
  TMUX_SOCKET="cc-service-$SERVICE_NAME"
  # shellcheck disable=SC2034  # consumed by tmux_run() in lib/common.sh, a separately sourced file
  CC_TMUX_SOCKET="$TMUX_SOCKET"
  ensure_log_dir
  install_files
  write_config
  merge_remote_control_setting
  render_systemd_units
  enable_and_start
  verify_install
}

main "$@"
