"""Push end to end: the real bridge, a real HTTP/2 + TLS connection, a local mock of Apple's push service.

The bridge runs as its own process (Tests/push_e2e_bridge.py: the shipped code with only Hermes's gateway scripted)
on a spare port with throwaway state, a throwaway P-256 APNs key and HERMES_MOBILE_APNS_HOST pointing at
Tests/mock_apns.mjs. A phone is played over HTTP with a real device grant. Proves what APNs receives (path, topic,
push type, collapse id, payload, an ES256 JWT that verifies), presence suppression, one push per reply, a push for
Hermes's questions, a 410 dropping the token, `--push-test` and `--doctor`, and no secret in any output.

Set HERMES_PUSH_E2E_EVIDENCE=<dir> to keep a redacted copy of every request APNs saw and the bridge's log."""
import sys
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / "Bridge")]
import _isolation  # noqa: F401,E402  (must precede any bridge import; see Tests/_isolation.py)
import base64  # noqa: E402
import hashlib  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import socket  # noqa: E402
import sqlite3  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import unittest  # noqa: E402
from contextlib import closing  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
import bridge_push  # noqa: E402

try:  # the bridge process needs Hermes's venv; so does this test
    import bridge_turns  # noqa: F401
    import cryptography  # noqa: F401
    READY = True
except Exception:
    READY = False

NODE = shutil.which("node")
KEY_ID, TEAM_ID = "E2EKEY0001", "E2ETEAM001"
TOPIC = "com.example.prometheus.e2e"
PHONE_TOKEN = "a1" * 32
DEAD_TOKEN = "d0" * 32
ACCOUNT = hashlib.sha256(b"https://mac.example.ts.net:10001|grant").hexdigest()


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def free_port():
    with closing(socket.socket()) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(predicate, timeout=15, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


@unittest.skipUnless(READY and NODE and shutil.which("openssl") and Path("/usr/bin/curl").exists(),
                     "needs Hermes's venv (cryptography), node, openssl and /usr/bin/curl")
class PushEndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="hermes-push-e2e-")
        root = cls.root = Path(cls.tmp.name)
        run = lambda *a, **k: subprocess.run(*a, check=True, capture_output=True, **k)
        # The APNs auth key, in the PKCS#8 form Apple's AuthKey_<id>.p8 has, and its public half.
        ec = run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"]).stdout
        cls.key = root / ("AuthKey_%s.p8" % KEY_ID)
        cls.key.write_bytes(run(["openssl", "pkcs8", "-topk8", "-nocrypt"], input=ec).stdout)
        cls.key.chmod(0o600)
        cls.public = run(["openssl", "pkey", "-in", str(cls.key), "-pubout"]).stdout
        # TLS for the mock: a self-signed certificate curl is told to trust (CURL_CA_BUNDLE), nothing else.
        (root / "san.cnf").write_text("[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=localhost\n"
                                      "[v3]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n"
                                      "keyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=serverAuth\n")
        run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(root / "tls.key")])
        run(["openssl", "req", "-x509", "-new", "-key", str(root / "tls.key"), "-out", str(root / "tls.crt"),
             "-days", "2", "-config", str(root / "san.cnf")])
        cls.requests_log, cls.rules = root / "apns-requests.jsonl", root / "apns-rules.json"
        cls.requests_log.touch()
        cls.rules.write_text(json.dumps({DEAD_TOKEN: [410, "Unregistered"]}))
        cls.mock = subprocess.Popen([NODE, str(ROOT / "Tests" / "mock_apns.mjs"), str(root / "tls.key"),
                                     str(root / "tls.crt"), str(cls.requests_log), str(cls.rules)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = cls.mock.stdout.readline()
        assert line.startswith("PORT "), line
        cls.mock_port = int(line.split()[1])
        cls.port = free_port()
        cls.state = root / "state"
        cls.env = {**os.environ,
                   "HERMES_HOME": str(root / "hermes"), "HERMES_MOBILE_STATE_DIR": str(cls.state),
                   "HERMES_MOBILE_PORT": str(cls.port), "HERMES_API_PORT": "9", "HERMES_MOBILE_AUTO_KEYS": "0",
                   "HERMES_STATUS_URL": "http://127.0.0.1:9/api/status",
                   "HERMES_MOBILE_APNS_KEY_PATH": str(cls.key), "HERMES_MOBILE_APNS_KEY_ID": KEY_ID,
                   "HERMES_MOBILE_APNS_TEAM_ID": TEAM_ID,
                   "HERMES_MOBILE_APNS_HOST": "https://localhost:%d" % cls.mock_port,
                   "CURL_CA_BUNDLE": str(root / "tls.crt")}
        for name in ("HERMES_MOBILE_APNS_TOPIC",):  # the phone names its own topic in this run
            cls.env.pop(name, None)
        (root / "hermes").mkdir()
        cls.bridge_log = (root / "bridge.log").open("w")
        cls.bridge = subprocess.Popen([sys.executable, str(ROOT / "Tests" / "push_e2e_bridge.py")], env=cls.env,
                                      stdout=cls.bridge_log, stderr=subprocess.STDOUT)
        up = wait_for(lambda: cls._ping(), timeout=60, step=0.2)
        assert up, "the bridge didn't start: " + (root / "bridge.log").read_text()[-2000:]
        cls.phone = cls.cli("--issue-token", "E2E iPhone").strip()
        cls.second = cls.cli("--issue-token", "Old iPad").strip()

    @classmethod
    def tearDownClass(cls):
        for proc in (getattr(cls, "bridge", None), getattr(cls, "mock", None)):
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
        if getattr(cls, "mock", None) and cls.mock.stdout:
            cls.mock.stdout.close()
        if getattr(cls, "bridge_log", None):
            cls.bridge_log.close()
        evidence = os.environ.get("HERMES_PUSH_E2E_EVIDENCE")
        if evidence and getattr(cls, "root", None):
            cls._keep_evidence(Path(evidence))
        cls.tmp.cleanup()

    # ---- helpers ----

    @classmethod
    def _ping(cls):
        try:
            with closing(http.client.HTTPConnection("127.0.0.1", cls.port, timeout=2)) as c:
                c.request("GET", "/m/ping")
                r = c.getresponse()
                r.read()
                return r.status == 200
        except OSError:
            return False

    @classmethod
    def cli(cls, *args):
        done = subprocess.run([sys.executable, str(ROOT / "Bridge" / "hermes_mobile_bridge.py"), *args], env=cls.env,
                              capture_output=True, text=True, timeout=120)
        cls.cli_output = done.stdout + done.stderr
        cls.cli_code = done.returncode
        return done.stdout

    def call(self, method, path, body=None, token=None):
        headers = {"Authorization": "Bearer " + (token or self.phone), "Content-Type": "application/json"}
        with closing(http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)) as c:
            c.request(method, path, json.dumps(body) if body is not None else None, headers)
            r = c.getresponse()
            raw = r.read()
            return r.status, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw)

    def apns(self):
        return [json.loads(line) for line in self.requests_log.read_text().splitlines() if line.strip()]

    def since(self, mark):
        return self.apns()[mark:]

    def send(self, chat, text, token=None):
        code, turn = self.call("POST", "/m/chat/default/%s/send" % chat, {"text": text}, token)
        self.assertEqual(202, code, turn)
        return turn["turn_id"]

    def wait_done(self, turn_id, token=None):
        self.assertTrue(wait_for(lambda: self.call("GET", "/m/turns/" + turn_id, token=token)[1].get("done")),
                        "the turn never finished")

    def watch(self, turn_id, token=None):
        """Follow the reply's live stream, as the app does while it's open. Returns the thread reading it."""
        seen = threading.Event()

        def read():
            with closing(http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)) as c:
                c.request("GET", "/m/turns/%s/events" % turn_id, headers={
                    "Authorization": "Bearer " + (token or self.phone), "X-Hermes-Replay": "checkpoint-v1"})
                r = c.getresponse()
                seen.set()
                while r.read1(4096):
                    pass

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        self.assertTrue(seen.wait(10))
        time.sleep(0.2)  # the bridge counts the watcher once the stream is open
        return thread

    def register(self, token=None, push_token=PHONE_TOKEN, topic=TOPIC):
        body = {"token": push_token, "environment": "sandbox", "account": ACCOUNT}
        if topic:
            body["topic"] = topic
        code, reply = self.call("POST", "/m/push/token", body, token)
        self.assertEqual((200, True), (code, reply.get("enabled")))

    def presence(self, away, following=True, token=None):
        self.assertEqual(200, self.call("POST", "/m/push/presence", {"away": away, "following": following}, token)[0])

    def verify_jwt(self, bearer):
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
        self.assertTrue(bearer.startswith("bearer "))
        head, claims, signature = bearer[len("bearer "):].split(".")
        self.assertEqual({"alg": "ES256", "kid": KEY_ID}, json.loads(unb64(head)))
        claims_json = json.loads(unb64(claims))
        self.assertEqual(TEAM_ID, claims_json["iss"])
        self.assertLess(abs(time.time() - claims_json["iat"]), 120)
        raw = unb64(signature)
        self.assertEqual(64, len(raw))
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        serialization.load_pem_public_key(self.public).verify(der, ("%s.%s" % (head, claims)).encode(),
                                                               ec.ECDSA(hashes.SHA256()))  # raises if forged
        return claims_json

    # ---- the cases (named in order: they share one bridge and one phone) ----

    def test_1_reply_while_away_is_one_push_shaped_like_apple_wants(self):
        self.register()
        mark = len(self.apns())
        turn = self.send("e2e-away", "Summarize the build [after 0.3]")
        self.wait_done(turn)
        got = wait_for(lambda: self.since(mark), timeout=10)
        time.sleep(1.5)  # nothing else may follow
        got = self.since(mark)
        self.assertEqual(1, len(got), got)
        r = got[0]
        self.assertEqual(("h2", "POST", "https", "/3/device/" + PHONE_TOKEN), (r["alpn"], r["method"], r["scheme"], r["path"]))
        h = r["headers"]
        self.assertEqual((TOPIC, "alert", "10", "application/json"),
                         (h["apns-topic"], h["apns-push-type"], h["apns-priority"], h["content-type"]))
        self.assertEqual(bridge_push.collapse_id(ACCOUNT, "default", "e2e-away"), h["apns-collapse-id"])
        self.verify_jwt(h["authorization"])
        self.assertEqual({"aps": {"alert": {"title": "Hermes", "body": "Your reply is ready."}, "sound": "default",
                                  "thread-id": bridge_push.destination_identifier(ACCOUNT, "default", "e2e-away")},
                          "account": ACCOUNT, "profile": "default", "session": "e2e-away"}, json.loads(r["body"]))

    def test_2_watching_in_the_foreground_gets_no_push(self):
        self.register()
        self.presence(False)
        mark = len(self.apns())
        turn = self.send("e2e-present", "Run the tests [after 1.0]")
        reader = self.watch(turn)
        self.wait_done(turn)
        reader.join(10)
        time.sleep(1.5)
        self.assertEqual([], self.since(mark))

    def test_3_attached_but_no_longer_following_is_pushed_and_grace_is_respected(self):
        self.register()
        self.presence(True, following=False)  # the app's background time ran out; its socket still looks open
        mark = len(self.apns())
        turn = self.send("e2e-handoff", "Long job [after 1.0]")
        reader = self.watch(turn)
        self.wait_done(turn)
        reader.join(10)
        self.assertEqual(1, len(wait_for(lambda: self.since(mark), timeout=10)))
        self.presence(True)  # just left, still following: the app notifies on its own inside the grace window
        mark = len(self.apns())
        turn = self.send("e2e-grace", "Quick one [after 0.5]")
        reader = self.watch(turn)
        self.wait_done(turn)
        reader.join(10)
        time.sleep(1.5)
        self.assertEqual([], self.since(mark))
        self.presence(False)

    def test_4_a_question_from_hermes_pushes_too(self):
        self.register()
        mark = len(self.apns())
        turn = self.send("e2e-ask", "[ask] Merge it? [after 0.4]")
        self.wait_done(turn)
        got = wait_for(lambda: len(self.since(mark)) >= 2 and self.since(mark), timeout=10)
        time.sleep(1)
        got = self.since(mark)
        self.assertEqual(["Hermes has a question", "Hermes"],
                         [json.loads(r["body"])["aps"]["alert"]["title"] for r in got])
        self.assertEqual(1, len({r["headers"]["apns-collapse-id"] for r in got}))  # one notification per chat

    def test_5_unregistered_token_is_dropped(self):
        self.register(token=self.second, push_token=DEAD_TOKEN)
        mark = len(self.apns())
        turn = self.send("e2e-dead", "Ping [after 0.2]", token=self.second)
        self.wait_done(turn, token=self.second)
        got = wait_for(lambda: self.since(mark), timeout=10)
        self.assertEqual(["/3/device/" + DEAD_TOKEN], [r["path"] for r in got])

        def remaining():
            with closing(sqlite3.connect(self.state / "devices" / "devices.sqlite3")) as db:
                return [row[0] for row in db.execute("SELECT token FROM push_tokens")]
        self.assertTrue(wait_for(lambda: DEAD_TOKEN not in remaining(), timeout=5))
        self.assertIn(PHONE_TOKEN, remaining())

    def test_6_push_test_and_doctor_report_without_secrets(self):
        self.register()
        mark = len(self.apns())
        out = self.cli("--push-test")
        self.assertEqual(0, self.cli_code, self.cli_output)
        self.assertIn("E2E iPhone (sandbox): delivered", out)
        got = self.since(mark)
        self.assertEqual(1, len(got))
        self.assertEqual(bridge_push.TEST_COLLAPSE_ID, got[0]["headers"]["apns-collapse-id"])
        self.assertEqual("Push notifications from your Mac work.", json.loads(got[0]["body"])["aps"]["alert"]["body"])
        self.verify_jwt(got[0]["headers"]["authorization"])
        doctor = json.loads(self.cli("--doctor", "--json"))
        checks = {c["check"]: c for c in doctor["checks"]}
        self.assertEqual("warn", checks["push"]["status"])  # configured, and flagged: this is a test server
        self.assertIn("test server", checks["push"]["detail"])
        self.assertEqual("ok", checks["push-phones"]["status"])
        self.assertIn("1 phone(s) registered for push (sandbox 1)", checks["push-phones"]["detail"])
        self.assertEqual("ok", checks["push-last"]["status"])
        everything = self.cli_output + out + json.dumps(doctor) + (self.root / "bridge.log").read_text()
        for secret in (KEY_ID, TEAM_ID, str(self.key), PHONE_TOKEN, DEAD_TOKEN, self.phone):
            self.assertNotIn(secret, everything)
        self.assertNotIn("bearer", (self.root / "bridge.log").read_text().lower())

    # ---- evidence ----

    @classmethod
    def _keep_evidence(cls, out):
        out.mkdir(parents=True, exist_ok=True)
        redacted = []
        for line in cls.requests_log.read_text().splitlines():
            r = json.loads(line)
            bearer = r["headers"].get("authorization", "")
            if bearer.startswith("bearer "):
                head, claims, _ = bearer[len("bearer "):].split(".")
                r["headers"]["authorization"] = "bearer <ES256 JWT, signature verified by the test> header=%s claims=%s" % (
                    unb64(head).decode(), unb64(claims).decode())
            r["path"] = r["path"].replace(PHONE_TOKEN, "<phone token>").replace(DEAD_TOKEN, "<dead token>")
            redacted.append(r)
        (out / "mock-apns-requests.json").write_text(json.dumps(redacted, indent=2))
        log = (cls.root / "bridge.log").read_text()
        (out / "e2e-bridge.log").write_text(log.replace(cls.phone, "<grant>").replace(cls.second, "<grant>"))


if __name__ == "__main__":
    unittest.main()
