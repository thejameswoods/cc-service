"""Tests for bin/cc-service-web.py against stubbed tmux, claude and systemctl.

Never needs root and never touches real tmux or systemd state. Run via
test/run-web-tests.sh.
"""
import base64
import importlib.util
import os
import re
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("ccweb", os.path.join(ROOT, "bin", "cc-service-web.py"))
ccweb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ccweb)

PASSWORD = "correct-horse-battery"

TMUX_STUB = """#!/bin/bash
# Records every call; serves the pane from $STUB_PANE.
echo "$*" >> "$STUB_LOG"
args=("$@")
while [ "${args[0]:-}" = "-L" ]; do args=("${args[@]:2}"); done
case "${args[0]}" in
  capture-pane) cat "$STUB_PANE" ;;
  list-panes) echo "${STUB_PANE_PID:-}" ;;
  *) ;;
esac
"""
# Like the real CLI: JSON on stdout, exit 1 when logged out.
CLAUDE_STUB = """#!/bin/bash
[ "$1 $2" = "auth status" ] || exit 0
cat "$STUB_AUTH"
grep -q '"loggedIn": true' "$STUB_AUTH"
"""
SYSTEMCTL_STUB = """#!/bin/bash
echo active
"""

LOGIN_PANE = """Select login method:
 ❯ 1. Claude account with subscription
Browser didn't open? Use the url below to sign in
https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.co
m%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%$
3Aplugins&code_challenge=CHAL&code_challenge_method=S256&state=STATE
 Paste code here if prompted >
"""
IDLE_PANE = "● ready\n\n❯ \n  ⏵⏵ auto mode on\n"
BUSY_PANE = "✻ Thinking…\n  esc to interrupt\n"


def write_exec(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


class Harness:
    def __init__(self, test):
        self.dir = tempfile.mkdtemp()
        test.addCleanup(self.cleanup)
        d = self.dir
        for name, body in (("tmux", TMUX_STUB), ("claude", CLAUDE_STUB), ("systemctl", SYSTEMCTL_STUB)):
            write_exec(os.path.join(d, name), body)
        self.log = os.path.join(d, "tmux.log")
        self.pane = os.path.join(d, "pane.txt")
        self.auth = os.path.join(d, "auth.json")
        self.pwfile = os.path.join(d, "password")
        open(self.log, "w").close()
        self.set_pane(IDLE_PANE)
        self.set_auth(False)
        with open(self.pwfile, "w") as fh:
            fh.write(PASSWORD + "\n")
        os.chmod(self.pwfile, 0o400)
        env = {
            "STUB_LOG": self.log, "STUB_PANE": self.pane, "STUB_AUTH": self.auth,
            "CC_TMUX_CMD": os.path.join(d, "tmux"), "CC_CLAUDE_CMD": os.path.join(d, "claude"),
            "CC_SYSTEMCTL_CMD": os.path.join(d, "systemctl"), "CC_WEB_SETTLE_SEC": "0",
        }
        self.env_backup = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        test.addCleanup(self.restore_env)
        self.cfg = ccweb.Config({
            "CC_INSTANCE_NAME": "t", "CC_TMUX_SESSION": "claude", "CC_TMUX_SOCKET": "sock",
            "CC_WEB_BIND": "127.0.0.1", "CC_WEB_PORT": "0", "CC_WEB_PASSWORD_FILE": self.pwfile,
            "CC_LOG_DIR": d,
        })
        # The busy/quiet check sleeps a real second; keep the suite quick.
        self.server = ccweb.make_server(self.cfg, self.cfg.load_password())
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        test.addCleanup(self.server.shutdown)
        test.addCleanup(self.server.server_close)

    def restore_env(self):
        for k, v in self.env_backup.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def cleanup(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def set_pane(self, text):
        with open(self.pane, "w", encoding="utf-8") as fh:
            fh.write(text)

    def set_auth(self, logged_in):
        with open(self.auth, "w") as fh:
            fh.write('{"loggedIn": %s, "authMethod": "claude.ai"}' % ("true" if logged_in else "false"))

    def tmux_calls(self):
        with open(self.log) as fh:
            return [line.strip() for line in fh if "send-keys" in line]

    def request(self, path, method="GET", data=None, auth=True, headers=None):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method,
                                     data=data.encode() if data is not None else None)
        if auth is True:
            req.add_header("Authorization", "Basic " + base64.b64encode(("cc:" + PASSWORD).encode()).decode())
        elif auth:
            req.add_header("Authorization", auth)
        for k, v in (headers or {}).items():
            req.add_header(k, v)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **kw):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=15) as resp:
                return resp.status, resp.read().decode(), resp.headers
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode(), exc.headers

    def token(self):
        _, body, _ = self.request("/")
        return re.search(r'name="csrf" value="([0-9a-f]+)"', body).group(1)

    def post(self, path, **fields):
        fields.setdefault("csrf", self.token())
        body = "&".join("%s=%s" % (k, v) for k, v in fields.items())
        return self.request(path, "POST", body, headers={"Content-Type": "application/x-www-form-urlencoded"})


class ParsingTests(unittest.TestCase):
    def test_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
            fh.write('# c\nCC_INSTANCE_NAME="x"\nCC_WEB_PORT=9000   # note\nCC_CLAUDE_NAME="${HOSTNAME}"\n\n')
        self.addCleanup(os.unlink, fh.name)
        env = ccweb.parse_env_file(fh.name)
        self.assertEqual(env["CC_INSTANCE_NAME"], "x")
        self.assertEqual(env["CC_WEB_PORT"], "9000")
        self.assertEqual(env["CC_CLAUDE_NAME"], "${HOSTNAME}")

    def test_urls_found_and_deduplicated(self):
        urls = ccweb.linkify_urls(LOGIN_PANE + LOGIN_PANE)
        self.assertEqual(len(urls), 1)
        self.assertTrue(urls[0].startswith("https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c"))
        self.assertIn("redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback", urls[0])
        self.assertTrue(urls[0].endswith("code_challenge=CHAL&code_challenge_method=S256&state=STATE"), urls[0])

    def test_urls_not_swallowing_following_text_or_foreign_hosts(self):
        pane = "https://claude.ai/login\nDone\nhttps://evil.example/x\n"
        self.assertEqual(ccweb.linkify_urls(pane), ["https://claude.ai/login"])

    def test_ansi_stripped(self):
        self.assertEqual(ccweb.ANSI_RE.sub("", "\x1b[1mhi\x1b[0m"), "hi")

    def test_refuses_without_password(self):
        cfg = ccweb.Config({"CC_WEB_PASSWORD_FILE": ""})
        with self.assertRaises(SystemExit):
            cfg.load_password()

    def test_refuses_short_password(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("short\n")
        self.addCleanup(os.unlink, fh.name)
        with self.assertRaises(SystemExit):
            ccweb.Config({"CC_WEB_PASSWORD_FILE": fh.name}).load_password()


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)

    def test_requires_auth(self):
        status, _, headers = self.h.request("/", auth=False)
        self.assertEqual(status, 401)
        self.assertIn("Basic", headers["WWW-Authenticate"])

    def test_rejects_wrong_password(self):
        bad = "Basic " + base64.b64encode(b"cc:wrong-password-here").decode()
        self.assertEqual(self.h.request("/", auth=bad)[0], 401)

    def test_rejects_wrong_user(self):
        bad = "Basic " + base64.b64encode(("root:" + PASSWORD).encode()).decode()
        self.assertEqual(self.h.request("/", auth=bad)[0], 401)

    def test_lockout_after_repeated_failures(self):
        for _ in range(ccweb.FAIL_LIMIT):
            self.h.request("/", auth="Basic " + base64.b64encode(b"cc:nope-nope-nope").decode())
        self.assertEqual(self.h.request("/")[0], 429)

    def test_page_shows_status_and_login_url(self):
        self.h.set_pane(LOGIN_PANE)
        status, body, headers = self.h.request("/")
        self.assertEqual(status, 200)
        self.assertIn("not logged in", body)
        self.assertIn("https://claude.com/cai/oauth/authorize", body)
        self.assertIn('name="code"', body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])

    def test_no_code_box_when_not_prompted(self):
        _, body, _ = self.h.request("/")
        self.assertNotIn('name="code"', body)

    def test_status_json(self):
        self.h.set_auth(True)
        self.h.set_pane("Remote Control active\n")
        status, body, _ = self.h.request("/status.json")
        self.assertEqual(status, 200)
        self.assertIn('"remote_control_active": true', body)
        self.assertIn('"loggedIn": true', body)

    def test_post_needs_csrf_token(self):
        status, _, _ = self.h.request("/login", "POST", "csrf=bad", headers={"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 403)
        self.assertEqual(self.h.tmux_calls(), [])

    def test_post_refuses_cross_origin(self):
        status, _, _ = self.h.request("/login", "POST", "csrf=" + self.h.token(),
                                      headers={"Origin": "http://evil.example", "Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 403)
        self.assertEqual(self.h.tmux_calls(), [])

    def test_post_accepts_same_origin(self):
        # Browsers send the page's own origin on form posts.
        status, _, _ = self.h.request(
            "/login", "POST", "csrf=" + self.h.token(),
            headers={"Origin": "http://127.0.0.1:%d" % self.h.port, "Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 303)

    def test_referrer_policy_lets_browsers_send_origin(self):
        # "no-referrer" makes browsers send "Origin: null" on form posts.
        _, _, headers = self.h.request("/")
        self.assertEqual(headers["Referrer-Policy"], "same-origin")

    def test_start_login_types_slash_login(self):
        status, _, _ = self.h.post("/login")
        self.assertEqual(status, 303)
        calls = self.h.tmux_calls()
        self.assertTrue(any("send-keys -t claude -l /login" in c for c in calls), calls)
        self.assertTrue(any(c.endswith("send-keys -t claude Enter") for c in calls), calls)

    def test_start_login_refused_when_busy(self):
        self.h.set_pane(BUSY_PANE)
        status, _, headers = self.h.post("/login")
        self.assertEqual(status, 303)
        self.assertIn("busy", urllib_unquote(headers["Location"]))
        self.assertEqual(self.h.tmux_calls(), [])

    def test_code_refused_unless_prompted(self):
        self.h.post("/code", code="abcdefgh12345678")
        self.assertEqual(self.h.tmux_calls(), [])

    def test_code_sent_when_prompted(self):
        self.h.set_pane(LOGIN_PANE)
        self.h.post("/code", code="abcdefgh12345678%23xyz")
        calls = self.h.tmux_calls()
        self.assertTrue(any("-l abcdefgh12345678#xyz" in c for c in calls), calls)

    def test_code_with_bad_characters_refused(self):
        self.h.set_pane(LOGIN_PANE)
        for bad in ("rm%20-rf%20%2F", "abc", "a" * 600, "abcdefgh%3Bls%20-la"):
            self.h.post("/code", code=bad)
        self.assertEqual(self.h.tmux_calls(), [])

    def test_key_allowlist(self):
        self.assertEqual(self.h.post("/key", key="enter")[0], 303)
        self.assertEqual(self.h.post("/key", key="C-c")[0], 400)
        self.assertEqual(self.h.post("/key", key="x")[0], 400)
        calls = self.h.tmux_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].endswith("send-keys -t claude Enter"))

    def test_unknown_path(self):
        self.assertEqual(self.h.post("/shell", cmd="id")[0], 404)

    def test_restart_stops_claude_child(self):
        parent = subprocess.Popen(["bash", "-c", "sleep 60 & wait"])
        self.addCleanup(parent.kill)
        time.sleep(0.5)
        os.environ["STUB_PANE_PID"] = str(parent.pid)
        self.addCleanup(os.environ.pop, "STUB_PANE_PID", None)
        child = subprocess.run(["pgrep", "-P", str(parent.pid)], capture_output=True, text=True).stdout.split()
        self.assertTrue(child, "test setup: no child process")
        self.h.post("/restart")
        deadline = time.time() + 5
        while time.time() < deadline and subprocess.run(["pgrep", "-P", str(parent.pid)], capture_output=True).returncode == 0:
            time.sleep(0.1)
        self.assertNotEqual(subprocess.run(["pgrep", "-P", str(parent.pid)], capture_output=True).returncode, 0)


def urllib_unquote(s):
    import urllib.parse
    return urllib.parse.unquote_plus(s)


if __name__ == "__main__":
    unittest.main()
