# cc-service

Keep a [Claude Code](https://claude.com/product/claude-code) session running
24/7 on a machine you control, reachable at any time via [Remote
Control](https://code.claude.com/docs/en/remote-control) from
claude.ai/code or the mobile app — with systemd-level process supervision
*and* an active watchdog that detects a broken Remote Control connection and
self-heals it, without you having to notice or intervene.

[![CI](https://github.com/thejameswoods/cc-service/actions/workflows/ci.yml/badge.svg)](https://github.com/thejameswoods/cc-service/actions/workflows/ci.yml)

## What this is (and isn't)

`cc-service` wraps `claude --continue` in a persistent tmux session under
systemd — the same interactive-loop pattern you'd use to keep one continuous
24/7 conversation alive, as opposed to `claude remote-control` (server mode),
which spins up separate on-demand sessions per connection. If you want one
long-lived assistant you can always reach from your phone, this is the
pattern; if you want many short-lived on-demand sessions, use server mode
directly instead.

It does **not** handle your initial `claude` login — run `claude` and
`/login` once, interactively, as the user this will run as, before
installing.

## Why

After an ungraceful restart (e.g. a host reboot), a `claude --continue`
process resuming a Remote Control session can hit:

> Remote Control not started here · another Claude Code on this machine
> already has Remote Control for this conversation... run /remote-control to
> move it to this terminal

— and just sit there, silently missing from your device list, until someone
notices and runs `/remote-control` by hand. `cc-service`'s watchdog detects
this (and a handful of other known Remote Control failure banners — see
[`docs/remote-control-failure-modes.md`](docs/remote-control-failure-modes.md))
and sends the recovery command for you.

## Prerequisites

- Linux with `systemd` and `tmux`
- `claude` CLI installed, in `PATH`, and already logged in (`claude` → `/login`)
  as the user this will run as, on a Pro/Max/Team/Enterprise plan
- `jq` (used to safely merge settings, never to clobber your `settings.json`)

## Quick start

```bash
git clone https://github.com/thejameswoods/cc-service
cd cc-service
sudo ./install.sh --project-dir /path/to/your/project
```

That's it. Check status:

```bash
journalctl -u cc-service@default -f
journalctl -u cc-service-watchdog@default -f
tmux attach -t claude   # Ctrl-b d to detach without killing it
```

### Before installing: it checks for conflicts first

`install.sh` scans for other always-on Claude Code setups on the machine
before touching anything — another systemd unit whose `ExecStart` wraps
`tmux` + `claude`, a running `while true; do claude ...; done`-shaped
process, or a tmux session name collision. A match with no actual resource
collision is just noted informationally; a real collision (e.g. you're both
trying to use the tmux session name `claude`) stops and asks:

```
[1] Stop & disable the foreign service, free the tmux name
[2] Keep it running; install cc-service under a different name instead
[3] Abort
```

A previous install of `cc-service` itself (re-running the installer) is
recognized as an upgrade, not a conflict — always safe to re-run.

## Configuration

`install.sh` writes `/etc/cc-service/<service-name>.env`. See
[`config.env.example`](config.env.example) for the full list with defaults
and comments. The ones worth knowing about:

| Variable | Default | Notes |
|---|---|---|
| `CC_PERMISSION_MODE` | *(empty = normal prompting)* | **Security note:** only set to `auto` if you understand it removes tool-use confirmation prompts. Never do this on a box that could receive untrusted input. |
| `CC_CRED_HOOK` | *(empty)* | Path to a script sourced before each `claude` launch, e.g. to `export` a secret your project needs. |
| `CC_WATCHDOG_*` | see example | Poll interval, backoff, and max-attempts tuning for the self-heal watchdog. |

## Self-healing, precisely

Two independent layers:

1. **Process supervision** (systemd): `Restart=always`, `RestartSec=5`,
   `StartLimitIntervalSec=0` — the daemon respawns no matter how it exits,
   and systemd never gives up rate-limiting restarts during a flapping
   outage. A `CC_STARTUP_DELAY_SEC` (default 15s) pause before the very
   first post-boot launch gives the server time to expire a stale
   pre-reboot Remote Control registration before resuming the conversation.
2. **Remote Control watchdog** (separate systemd unit): polls the tmux pane
   every `CC_WATCHDOG_INTERVAL_SEC` (default 60s) for known failure banners.
   Before sending anything, it checks the pane isn't mid-render (no
   spinner/"Thinking…"/"esc to interrupt" indicators) and has been stable
   for a few seconds — only then does it send `/remote-control`, with
   exponential backoff and a max-attempts cap so it never hammers a stuck
   session forever.

**What it can't fix**: an expired login (`/login` required) is detected and
logged loudly, but never auto-recovered — that needs a human. There is no
external alerting (no webhook/notification integration) in this version;
watch for it via `journalctl -u cc-service-watchdog@<name> -p err`.

The single biggest fragility: the watchdog matches literal banner text from
Claude Code's TUI, which could be reworded in a future release. Set
`CC_LOG_LEVEL=debug` to log the raw pane capture on every poll if self-heal
seems to have stopped firing.

## Multiple instances

Everything is instance-scoped via `--service-name` (default `default`) —
run several independent `cc-service` daemons on one box, each with its own
project dir, tmux session, and config:

```bash
sudo ./install.sh --project-dir /path/a --service-name a --tmux-session claude-a
sudo ./install.sh --project-dir /path/b --service-name b --tmux-session claude-b
```

## Uninstall

```bash
sudo ./uninstall.sh --service-name default --purge
```

`--all` removes every instance found; see `--help` for the full flag list.
Your `~/.claude/settings.json` is never touched by uninstall.

## Full flag reference

```
./install.sh --help
./uninstall.sh --help
```

## Contributing

Two test suites, both run in CI on every push/PR and neither needs root or
touches real systemd/tmux state:

- `test/run-fixture-tests.sh` — conflict-detection heuristics and watchdog
  pattern-matching, against static fixture data.
- `test/run-cli-tests.sh` — `install.sh`/`uninstall.sh` argument parsing and
  `--dry-run` behavior, against stubbed `tmux`/`claude`/`systemctl`.

Run both plus `shellcheck` before opening a PR:

```bash
shellcheck -S warning bin/*.sh lib/*.sh install.sh uninstall.sh test/*.sh
bash test/run-fixture-tests.sh
bash test/run-cli-tests.sh
```

## License

MIT — see [LICENSE](LICENSE).
