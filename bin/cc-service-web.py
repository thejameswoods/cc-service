#!/usr/bin/env python3
"""cc-service-web — status and login page for one cc-service instance.

Why: an expired or missing Claude Code login is the one failure the watchdog
cannot heal, and fixing it means an SSH session plus an interactive /login.
This page shows the instance's health and drives that login from a browser.

How: it never handles credentials. Login happens inside the daemon's own tmux
pane: the page types /login, shows the sign-in URL it reads back, and types the
code you paste. You sign in on claude.ai in your own browser.

Security: every request needs HTTP Basic auth (user "cc", password from
CC_WEB_PASSWORD_FILE). The page can only run a fixed set of actions: start
/login, submit a login code, press one of a few menu keys, and restart claude.
It never sends free text. It serves plain HTTP, so bind it to localhost or a
trusted LAN only. See README.md.

Invoked by the cc-service-web@<instance>.service systemd unit with the config
file path as $1. Python standard library only.
"""
import base64
import hmac
import html
import http.server
import json
import os
import re
import secrets
import signal
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

# Literal substrings from Claude Code's TUI. Keep in sync with
# bin/claude-rc-watchdog.sh and docs/remote-control-failure-modes.md.
BUSY_PATTERN = re.compile(r"esc to interrupt|Thinking[.…]|[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]")
RC_OK_PATTERN = re.compile(r"/rc active|Remote Control active")
CODE_PROMPT = "Paste code here"

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
CODE_RE = re.compile(r"^[A-Za-z0-9._~#:/+=-]{8,512}$")

# The only keys the page can press. Menu navigation for the first-run wizard,
# login-method choice and permission prompts; nothing that types text.
KEYS = {
    "enter": ("Enter", False),
    "escape": ("Escape", False),
    "up": ("Up", False),
    "down": ("Down", False),
    "1": ("1", True),
    "2": ("2", True),
    "3": ("3", True),
    "y": ("y", True),
    "n": ("n", True),
}

USER = "cc"
MIN_PASSWORD_LEN = 12
FAIL_LIMIT = 10
FAIL_WINDOW_SEC = 300


def log(level, msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    print("[%s] [%s] [cc-service-web] %s" % (ts, level, msg), file=sys.stderr, flush=True)


def parse_env_file(path):
    """Read KEY=value / KEY="value" lines from a cc-service env file.

    The file is also sourced by bash, so values are only taken literally here;
    nothing is expanded.
    """
    out = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
            if not m:
                continue
            key, val = m.group(1), m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            else:
                val = re.split(r"\s+#", val, maxsplit=1)[0].strip()
            out[key] = val
    return out


class Config:
    def __init__(self, env):
        self.instance = env.get("CC_INSTANCE_NAME", "default")
        self.session = env.get("CC_TMUX_SESSION", "claude")
        self.socket = env.get("CC_TMUX_SOCKET", "")
        self.bind = env.get("CC_WEB_BIND", "127.0.0.1")
        self.port = int(env.get("CC_WEB_PORT", "8787"))
        self.password_file = env.get("CC_WEB_PASSWORD_FILE", "")
        # TLS: both set => serve HTTPS. The browser terminal (ttyd) needs it, and
        # the page shares its password, so the page must not send that in clear.
        self.tls_cert = env.get("CC_TLS_CERT", "")
        self.tls_key = env.get("CC_TLS_KEY", "")
        self.terminal_enabled = env.get("CC_TERMINAL_ENABLED", "false") == "true"
        self.terminal_port = int(env.get("CC_TERMINAL_PORT", "7681"))
        self.log_dir = env.get("CC_LOG_DIR", "/var/log/cc-service")
        self.pane_lines = int(env.get("CC_WATCHDOG_PANE_LINES", "60"))
        # Indirected like the shell scripts' CC_*_CMD, so tests can stub them.
        self.tmux = os.environ.get("CC_TMUX_CMD", "tmux")
        self.systemctl = os.environ.get("CC_SYSTEMCTL_CMD", "systemctl")
        self.claude = os.environ.get("CC_CLAUDE_CMD", "claude")
        self.pgrep = os.environ.get("CC_PGREP_CMD", "pgrep")
        self.settle_sec = float(os.environ.get("CC_WEB_SETTLE_SEC", "2"))

    def load_password(self):
        if not self.password_file:
            raise SystemExit("CC_WEB_PASSWORD_FILE is not set; refusing to start without a password")
        try:
            st = os.stat(self.password_file)
            with open(self.password_file, encoding="utf-8") as fh:
                pw = fh.read().strip()
        except OSError as exc:
            raise SystemExit("cannot read CC_WEB_PASSWORD_FILE %s: %s" % (self.password_file, exc))
        if len(pw) < MIN_PASSWORD_LEN:
            raise SystemExit("password in %s is shorter than %d characters" % (self.password_file, MIN_PASSWORD_LEN))
        if st.st_mode & 0o077:
            log("warn", "%s is readable by other users; chmod 0400 it" % self.password_file)
        return pw


def run(cmd, timeout=10):
    """Run a command; return (returncode, stdout). A missing command is rc 127."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return res.returncode, res.stdout
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""


class Instance:
    """Everything the page reads from or does to one cc-service instance."""

    def __init__(self, cfg):
        self.cfg = cfg

    def tmux(self, *args):
        base = [self.cfg.tmux]
        if self.cfg.socket:
            base += ["-L", self.cfg.socket]
        return run(base + list(args))

    def pane(self, lines=None):
        """Pane scrollback with wrapped lines joined, or None if there is no session."""
        n = lines or self.cfg.pane_lines
        rc, out = self.tmux("capture-pane", "-p", "-J", "-t", self.cfg.session, "-S", "-%d" % n)
        if rc != 0:
            return None
        return ANSI_RE.sub("", out)

    def unit_state(self, unit):
        rc, out = run([self.cfg.systemctl, "is-active", unit])
        if rc == 127:
            return "unknown"
        return out.strip() or "unknown"

    def auth_status(self):
        # `claude auth status` prints JSON but exits 1 when logged out, so
        # read stdout whatever the exit code is.
        rc, out = run([self.cfg.claude, "auth", "status"], timeout=15)
        try:
            data = json.loads(out)
        except ValueError:
            return {"loggedIn": None, "error": "claude auth status gave no JSON (rc=%d)" % rc}
        return data if isinstance(data, dict) else {"loggedIn": None}

    def log_tail(self, n=15):
        path = os.path.join(self.cfg.log_dir, "%s.watchdog.log" % self.cfg.instance)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                return "".join(fh.readlines()[-n:])
        except OSError:
            return "(no watchdog log at %s)" % path

    # --- actions: each returns a one-line message for the page ---

    def _safe_to_type(self):
        """Refuse to type into a pane that is working or missing."""
        first = self.pane()
        if first is None:
            return "no tmux session '%s'; is cc-service@%s running?" % (self.cfg.session, self.cfg.instance)
        if BUSY_PATTERN.search(first):
            return "claude looks busy (mid-turn); try again when it is idle"
        time.sleep(1)
        if self.pane() != first:
            return "the pane is still changing; try again in a few seconds"
        return None

    def _send(self, text, literal):
        args = ["send-keys", "-t", self.cfg.session]
        if literal:
            args.append("-l")
        rc, _ = self.tmux(*(args + [text]))
        return rc == 0

    def start_login(self):
        refusal = self._safe_to_type()
        if refusal:
            return refusal
        ok = self._send("/login", True) and self._send("Enter", False)
        time.sleep(self.cfg.settle_sec)
        return "sent /login" if ok else "tmux send-keys failed"

    def press_key(self, name):
        if name not in KEYS:
            return None
        refusal = self._safe_to_type()
        if refusal:
            return refusal
        key, literal = KEYS[name]
        ok = self._send(key, literal)
        time.sleep(self.cfg.settle_sec)
        return "pressed %s" % name if ok else "tmux send-keys failed"

    def submit_code(self, code):
        code = code.strip()
        if not CODE_RE.match(code):
            return "that does not look like a login code"
        pane = self.pane()
        if pane is None or CODE_PROMPT not in pane:
            return "claude is not asking for a code; start the login first"
        ok = self._send(code, True) and self._send("Enter", False)
        time.sleep(self.cfg.settle_sec * 2)
        return "code sent" if ok else "tmux send-keys failed"

    def restart_claude(self):
        """Stop claude; the daemon script's loop starts a new one with --continue."""
        rc, out = self.tmux("list-panes", "-t", self.cfg.session, "-F", "#{pane_pid}")
        pane_pid = out.split()[0] if rc == 0 and out.split() else ""
        if not pane_pid.isdigit():
            return "no tmux session '%s'" % self.cfg.session
        rc, out = run([self.cfg.pgrep, "-P", pane_pid])
        pids = [int(p) for p in out.split() if p.isdigit()]
        if not pids:
            return "claude is not running under the daemon (it may be restarting)"
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        return "stopped claude; the daemon will start it again in a few seconds"


URL_START_RE = re.compile(r"^\s*(https://claude\.(?:com|ai)/\S*)$")
URL_PART_RE = re.compile(r"^[A-Za-z0-9%._~:/?#\[\]@!$&'()*+,;=-]+$")


def linkify_urls(pane):
    """Sign-in URLs in the pane.

    Claude Code's TUI wraps the long URL itself, one hard line per pane width,
    so tmux's own line joining does not help. A URL line is followed by more of
    the URL while the line before it ran to full width and the next line has no
    spaces.
    """
    lines = (pane or "").splitlines()
    seen, urls = set(), []
    i = 0
    while i < len(lines):
        m = URL_START_RE.match(lines[i])
        if not m:
            i += 1
            continue
        url, prev = m.group(1), lines[i]
        i += 1
        while i < len(lines) and len(prev) >= 40 and URL_PART_RE.match(lines[i]):
            url += lines[i]
            prev = lines[i]
            i += 1
        url = url.rstrip(".,)")
        if url not in seen:
            seen.add(url)
            urls.append(url)
    return urls


STYLE = """
:root{color-scheme:light dark;--bg:#fafaf9;--fg:#1c1917;--mut:#78716c;--card:#fff;--line:#e7e5e4;--ok:#15803d;--bad:#b91c1c;--warn:#a16207;--acc:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--fg:#fafaf9;--mut:#a8a29e;--card:#292524;--line:#44403c;--ok:#4ade80;--bad:#f87171;--warn:#facc15;--acc:#60a5fa}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px}
h1{font-size:20px;margin:8px 0 16px}h2{font-size:15px;margin:0 0 8px}
section{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px;margin:0 0 14px}
dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;margin:0}dt{color:var(--mut)}dd{margin:0}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:10px;overflow:auto;font-size:12.5px;max-height:340px;margin:8px 0 0}
form{display:inline-block;margin:4px 6px 4px 0}
button{font:inherit;padding:6px 12px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);cursor:pointer}
button.primary{background:var(--acc);border-color:var(--acc);color:#fff}
input[type=text]{font:inherit;padding:6px 8px;width:min(420px,100%);border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}
.flash{border-left:4px solid var(--acc);padding:8px 12px;margin:0 0 14px;background:var(--card)}
.small{color:var(--mut);font-size:13px}a{color:var(--acc);word-break:break-all}
"""


def state_class(state):
    return {"active": "ok", "failed": "bad", "unknown": "warn"}.get(state, "warn")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "cc-service-web"
    sys_version = ""
    timeout = 30  # a stalled client (or TLS handshake) must not hold a thread forever

    # Set by serve().
    inst = None
    password = ""
    csrf_secret = b""
    fails = {}
    fails_lock = threading.Lock()

    def log_message(self, fmt, *args):  # no query strings or headers in logs
        log("info", "%s %s" % (self.address_string(), fmt % args if args else fmt))

    # --- auth ---

    def _locked_out(self):
        now = time.time()
        with self.fails_lock:
            recent = [t for t in self.fails.get(self.client_address[0], []) if now - t < FAIL_WINDOW_SEC]
            self.fails[self.client_address[0]] = recent
            return len(recent) >= FAIL_LIMIT

    def _note_failure(self):
        with self.fails_lock:
            self.fails.setdefault(self.client_address[0], []).append(time.time())

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(header[6:]).decode("utf-8").partition(":")
        except (ValueError, UnicodeDecodeError):
            return False
        ok_user = hmac.compare_digest(user.encode(), USER.encode())
        ok_pw = hmac.compare_digest(pw.encode(), self.password.encode())
        return ok_user and ok_pw

    def _csrf_token(self):
        return hmac.new(self.csrf_secret, b"csrf", "sha256").hexdigest()

    def _gate(self):
        """True if the request may proceed; otherwise a response was sent."""
        if self._locked_out():
            self._send(429, "Too many failed attempts. Try again in a few minutes.", "text/plain")
            return False
        if not self._authorized():
            self._note_failure()
            time.sleep(1)
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="cc-service", charset="UTF-8"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True

    # --- responses ---

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        # same-origin, not no-referrer: with no-referrer browsers send "Origin: null"
        # on form posts, which the cross-origin check in do_POST would then refuse.
        # Nothing is sent to other sites either way.
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, msg):
        self.send_response(303)
        self.send_header("Location", "/?" + urllib.parse.urlencode({"msg": msg}))
        self.send_header("Content-Length", "0")
        self.end_headers()

    # --- routes ---

    def do_GET(self):  # noqa: N802
        if not self._gate():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/status.json":
            self._send(200, json.dumps(self._snapshot(), indent=2), "application/json")
        elif parsed.path == "/":
            msg = urllib.parse.parse_qs(parsed.query).get("msg", [""])[0][:200]
            self._send(200, self._page(msg))
        else:
            self._send(404, "Not found", "text/plain")

    def do_POST(self):  # noqa: N802
        if not self._gate():
            return
        host, origin = self.headers.get("Host", ""), self.headers.get("Origin")
        if origin and urllib.parse.urlparse(origin).netloc != host:
            self._send(403, "Cross-origin request refused", "text/plain")
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
        except ValueError:
            length = 0
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        token = form.get("csrf", [""])[0]
        if not hmac.compare_digest(token, self._csrf_token()):
            self._send(403, "Bad or missing form token; reload the page", "text/plain")
            return

        path = urllib.parse.urlparse(self.path).path
        if path == "/login":
            msg = self.inst.start_login()
        elif path == "/code":
            msg = self.inst.submit_code(form.get("code", [""])[0])
        elif path == "/key":
            msg = self.inst.press_key(form.get("key", [""])[0])
            if msg is None:
                self._send(400, "Unknown key", "text/plain")
                return
        elif path == "/restart":
            msg = self.inst.restart_claude()
        else:
            self._send(404, "Not found", "text/plain")
            return
        log("info", "action %s: %s" % (path, msg))
        self._redirect(msg)

    # --- rendering ---

    def _snapshot(self):
        pane = self.inst.pane()
        auth = self.inst.auth_status()
        return {
            "instance": self.inst.cfg.instance,
            "daemon": self.inst.unit_state("cc-service@%s.service" % self.inst.cfg.instance),
            "watchdog": self.inst.unit_state("cc-service-watchdog@%s.service" % self.inst.cfg.instance),
            "tmux_session": pane is not None,
            "auth": auth,
            "remote_control_active": bool(pane and RC_OK_PATTERN.search(pane)),
            "waiting_for_code": bool(pane and CODE_PROMPT in pane),
            "login_urls": linkify_urls(pane),
        }

    def _form(self, action, label, fields="", primary=False):
        cls = ' class="primary"' if primary else ""
        return (
            '<form method="post" action="%s"><input type="hidden" name="csrf" value="%s">%s'
            "<button%s>%s</button></form>" % (action, self._csrf_token(), fields, cls, html.escape(label))
        )

    def _terminal_section(self):
        cfg = self.inst.cfg
        if not cfg.terminal_enabled:
            return ""
        host = urllib.parse.urlsplit("//" + self.headers.get("Host", "")).hostname or ""
        url = "https://%s:%d/" % (host, cfg.terminal_port)
        return (
            '<section><h2>Terminal</h2><p class="small">A real terminal attached to the running session, '
            'with the same password. It accepts free text, so it can instruct the agent. '
            'The certificate is self-signed; your browser will ask once.</p>'
            '<p><a href="%s" target="_blank" rel="noreferrer noopener">Open the terminal</a></p></section>'
            % html.escape(url, quote=True)
        )

    def _page(self, msg):
        snap = self._snapshot()
        pane = self.inst.pane() or "(no tmux session)"
        auth = snap["auth"]
        logged = auth.get("loggedIn")
        if logged is True:
            auth_html = '<span class="ok">logged in</span> (%s)' % html.escape(str(auth.get("authMethod", "?")))
        elif logged is False:
            auth_html = '<span class="bad">not logged in</span>'
        else:
            auth_html = '<span class="warn">unknown</span> %s' % html.escape(str(auth.get("error", "")))
        rc_html = '<span class="ok">active</span>' if snap["remote_control_active"] else '<span class="warn">not seen in pane</span>'

        urls = "".join(
            '<p>Open this link, sign in, then paste the code it shows below:<br><a href="%s" target="_blank" rel="noreferrer noopener">%s</a></p>'
            % (html.escape(u, quote=True), html.escape(u))
            for u in snap["login_urls"]
        )
        code_form = ""
        if snap["waiting_for_code"]:
            code_form = self._form("/code", "Submit code", '<input type="text" name="code" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="paste code here">', True)
        keys = "".join(self._form("/key", k.upper() if len(k) > 1 else k, '<input type="hidden" name="key" value="%s">' % k) for k in KEYS)

        flash = '<div class="flash">%s</div>' % html.escape(msg) if msg else ""
        return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>cc-service %(inst)s</title>
<style>%(style)s</style></head><body><main>
<h1>cc-service · %(inst)s</h1>%(flash)s
<section><h2>Status</h2><dl>
<dt>Daemon</dt><dd class="%(dc)s">%(daemon)s</dd>
<dt>Watchdog</dt><dd class="%(wc)s">%(watchdog)s</dd>
<dt>Login</dt><dd>%(auth)s</dd>
<dt>Remote Control</dt><dd>%(rc)s</dd></dl>
<p class="small"><a href="/">Refresh</a> · <a href="/status.json">status.json</a></p></section>
<section><h2>Login</h2>
<p class="small">Starts /login in the daemon's own session. Your Google or Claude credentials are entered on claude.ai in your browser, never here.</p>
%(login)s%(urls)s%(code)s</section>
<section><h2>Session</h2>
<p class="small">Menu keys, for the first-run wizard and login-method choice. Refused while claude is working.</p>%(keys)s
<p>%(restart)s</p>
<p class="small">Restart stops claude; the daemon starts it again with --continue. It interrupts any turn in progress.</p>
<pre>%(pane)s</pre></section>
%(terminal)s<section><h2>Watchdog log</h2><pre>%(wlog)s</pre></section>
</main></body></html>""" % {
            "inst": html.escape(snap["instance"]),
            "style": STYLE,
            "flash": flash,
            "daemon": html.escape(snap["daemon"]),
            "dc": state_class(snap["daemon"]),
            "watchdog": html.escape(snap["watchdog"]),
            "wc": state_class(snap["watchdog"]),
            "auth": auth_html,
            "rc": rc_html,
            "login": self._form("/login", "Start login", primary=True),
            "urls": urls,
            "code": code_form,
            "keys": keys,
            "restart": self._form("/restart", "Restart claude"),
            "pane": html.escape(pane.rstrip()),
            "wlog": html.escape(self.inst.log_tail()),
            "terminal": self._terminal_section(),
        }


class Server(http.server.ThreadingHTTPServer):
    """ThreadingHTTPServer with optional TLS.

    The TLS handshake is deferred to the handler thread (do_handshake_on_connect
    is off), so a client that connects and says nothing cannot block accept().
    """

    ssl_context = None

    def get_request(self):
        sock, addr = super().get_request()
        if self.ssl_context is not None:
            sock = self.ssl_context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        return sock, addr

    def handle_error(self, request, client_address):
        # A plain-HTTP client on the HTTPS port, a scanner, a timeout: one line, no traceback.
        log("warn", "connection from %s dropped: %s" % (client_address[0], sys.exc_info()[1]))


def make_server(cfg, password):
    handler = type("BoundHandler", (Handler,), {
        "inst": Instance(cfg),
        "password": password,
        "csrf_secret": secrets.token_bytes(32),
        "fails": {},
        "fails_lock": threading.Lock(),
    })
    server = Server((cfg.bind, cfg.port), handler)
    if cfg.tls_cert or cfg.tls_key:
        if not (cfg.tls_cert and cfg.tls_key):
            server.server_close()
            raise SystemExit("CC_TLS_CERT and CC_TLS_KEY must both be set")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        try:
            ctx.load_cert_chain(cfg.tls_cert, cfg.tls_key)
        except (OSError, ssl.SSLError) as exc:
            server.server_close()
            raise SystemExit("cannot load TLS certificate/key (%s, %s): %s" % (cfg.tls_cert, cfg.tls_key, exc))
        server.ssl_context = ctx
    return server


def main(argv):
    path = argv[1] if len(argv) > 1 else os.environ.get("CC_CONFIG_PATH", "")
    if not path:
        print("usage: cc-service-web.py <config-path>  (or set CC_CONFIG_PATH)", file=sys.stderr)
        return 1
    cfg = Config(parse_env_file(path))
    password = cfg.load_password()
    server = make_server(cfg, password)
    scheme = "https" if server.ssl_context is not None else "http"
    log("info", "listening on %s://%s:%d (instance=%s session=%s)" % (scheme, cfg.bind, cfg.port, cfg.instance, cfg.session))
    if scheme == "http" and cfg.bind not in ("127.0.0.1", "::1", "localhost"):
        log("warn", "serving plain HTTP beyond localhost; the password crosses the network in clear. Use TLS (install.sh --tls) or a trusted network")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
