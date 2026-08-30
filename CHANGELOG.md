# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-08-30

### Added
- Initial release: `claude-daemon.sh` (persistent tmux + `claude --continue` loop),
  `claude-rc-watchdog.sh` (Remote Control failure detection and self-heal),
  `install.sh` / `uninstall.sh` with pre-flight conflict detection against other
  always-on Claude Code setups on the same machine, systemd template units,
  fixture-based test suite, and CI.
