# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
