# Remote Control failure modes reference

`cc-service`'s watchdog (`bin/claude-rc-watchdog.sh`) works by grepping the tmux
pane's scrollback for literal banner text that Claude Code's TUI prints. That
text is owned by Claude Code, not by us — if a future release rewords a
banner, detection for that banner silently stops working until this file (and
the `RC_FAIL_PATTERNS` / `AUTH_FAIL_PATTERNS` arrays in the script) are
updated. This is the single most fragile part of the design; if self-heal
stops firing after a `claude` update, start here.

Set `CC_LOG_LEVEL=debug` in your instance config to have the watchdog log the
raw pane capture on every poll, not just on a match — that's the fastest way
to see whether wording drifted.

| Banner text (substring match) | Self-healable? | Watchdog action |
|---|---|---|
| `Remote Control not started here` | Yes | Send `/remote-control` (once idle-prompt + quiet-pane gates pass) |
| `Couldn't reconnect to your Remote Control session` | Yes | Same |
| `Remote credentials fetch failed` | Yes | Same |
| `Previous session is unavailable` | Yes | Same |
| `could not reach the Remote Control server` | Yes | Same |
| `/rc active` / `Remote Control active` | n/a (healthy) | Reset backoff/attempt counters |
| `Please run /login` | **No** | Log ERROR, back off — needs a human to run `/login` |
| `Your credentials have expired` | **No** | Same |
| `Not logged in` | **No** | Same |
| `Invalid API key` | **No** | Same |

Source: [code.claude.com/docs/en/remote-control](https://code.claude.com/docs/en/remote-control),
Troubleshooting and Limitations sections, as of Claude Code v2.1.251.
