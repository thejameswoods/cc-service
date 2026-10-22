# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Optional browser terminal (`install.sh --terminal`, `bin/cc-service-terminal.sh`,
  `cc-service-terminal@.service`): ttyd attached to the daemon's tmux session, over
  TLS, with the status page's user and password, bound to one network interface,
  with its WebSocket origin checked. Needs ttyd, `--web` and `--tls`.
- `install.sh --tls` (and `--tls-san`): the status page is served over HTTPS with a
  self-signed certificate created in `/etc/cc-service`. The page shares its password
  with the terminal, so it must not send it in clear.

### Fixed
- The daemon starts a fresh session whenever `claude --continue` reports
  "No conversation found to continue", not only once per daemon lifetime. A new
  install whose first claude only logged in looped on `--continue` forever and
  never registered with Remote Control.
- `install.sh` no longer leaves `~/.claude` root-owned when it has to create it,
  and no longer turns an existing `settings.json` into a root-owned 0600 file
  when merging `remoteControlAtStartup`. Either made `claude` unable to save
  its login ("credentials could not be saved to the credentials file").

### Added
- Optional status and login page (`install.sh --web`, `bin/cc-service-web.py`,
  `cc-service-web@.service`): shows daemon, watchdog, login and Remote Control
  state, and drives `/login` from a browser by typing into the daemon's tmux
  pane and showing the sign-in URL it reads back. Basic-auth protected, fixed
  action set, standard library only.

## [0.1.0] - 2026-08-30

### Added
- Initial release: `claude-daemon.sh` (persistent tmux + `claude --continue` loop),
  `claude-rc-watchdog.sh` (Remote Control failure detection and self-heal),
  `install.sh` / `uninstall.sh` with pre-flight conflict detection against other
  always-on Claude Code setups on the same machine, systemd template units,
  fixture-based test suite, and CI.
