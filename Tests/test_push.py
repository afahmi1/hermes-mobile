"""APNs push: token storage, the push decision, payload and collapse id, ES256 JWT, and dead-token cleanup.
No network: the HTTP/2 sender is replaced, and the signing key is a throwaway P-256 key made by openssl."""
import base64
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Bridge"), str(ROOT / "Status"), str(ROOT / "Tests")]

import bridge_devices
import bridge_push

try:
    import bridge_turns
except Exception:  # needs Hermes's venv
    bridge_turns = None

TOKEN = "ab" * 32
ACCOUNT = "9f" * 32


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_key(directory):
    path = Path(directory) / "AuthKey_TEST.p8"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(path)],
                   check=True, capture_output=True)
    return path


class FakeTurn:
    def __init__(self, device="dev1"):
        self.cond = threading.RLock()
        self.device_id, self.watchers, self.alerted, self.notified = device, {}, set(), False
        self.profile, self.sid = "frostbyte", "session-1"


class Store(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.devices = bridge_devices.Devices(Path(self.dir.name))

    def grant(self, did, expires=None):
        self.devices.issue({"did": did, "dev": "Phone", "issued": int(time.time()),
                            "exp": expires or int(time.time()) + 3600, "method": "local"})

    def test_store_replace_and_move(self):
        self.grant("a"); self.grant("b")
        self.devices.set_push_token("a", TOKEN, "sandbox", ACCOUNT)
        self.devices.set_push_token("a", "cd" * 32, "production", ACCOUNT)
        self.assertEqual([("cd" * 32, "production")], [(r["token"], r["env"]) for r in self.devices.push_targets("a")])
        self.devices.set_push_token("b", "cd" * 32, "production", ACCOUNT)  # the token moved grants
        self.assertEqual([], self.devices.push_targets("a"))
        self.assertEqual(["b"], [r["device_id"] for r in self.devices.push_targets()])

    def test_revoked_and_expired_grants_lose_tokens(self):
        self.grant("a"); self.grant("b")
        self.devices.set_push_token("a", TOKEN, "sandbox", ACCOUNT)
        self.devices.set_push_token("b", "cd" * 32, "sandbox", ACCOUNT)
        self.devices.revoke("a")
        self.assertEqual(["b"], [r["device_id"] for r in self.devices.push_targets()])
        with self.devices.connect() as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM push_tokens WHERE device_id='a'").fetchone()[0])
            db.execute("UPDATE devices SET expires=1 WHERE id='b'")
        self.assertEqual([], self.devices.push_targets())
        with self.devices.connect() as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM push_tokens").fetchone()[0])

    def test_issue_purges_orphans(self):
        self.grant("old", expires=int(time.time()) + 1)
        self.devices.set_push_token("old", TOKEN, "sandbox", ACCOUNT)
        with self.devices.connect() as db:
            db.execute("UPDATE devices SET expires=1 WHERE id='old'")
        self.grant("new")
        with self.devices.connect() as db:
            self.assertEqual(0, db.execute("SELECT COUNT(*) FROM push_tokens").fetchone()[0])


class Decision(unittest.TestCase):
    def test_rule(self):
        now = 1000.0
        self.assertTrue(bridge_push.should_push(False, None, now))          # nobody attached
        self.assertFalse(bridge_push.should_push(True, None, now))          # watching in the foreground
        self.assertFalse(bridge_push.should_push(True, now - 10, now))      # inside the app's own grace window
        self.assertTrue(bridge_push.should_push(True, now - 60, now))       # suspended; socket still open
        self.assertTrue(bridge_push.should_push(False, now - 5, now))


class Wire(unittest.TestCase):
    def test_collapse_id_matches_swift_identifier(self):
        ident = bridge_push.destination_identifier("acc", "bot", "ses")
        self.assertEqual("3:acc3:bot3:ses", ident)
        self.assertEqual("2:é1:b1:s", bridge_push.destination_identifier("é", "b", "s"))  # utf-8 byte counts
        # Same vectors as Tests/ReplyDestinationTests.swift: the phone must compute the identical id.
        self.assertEqual("3b1043bc7d2eb559cf842dd27e8ac766", bridge_push.collapse_id("acc", "bot", "ses"))
        self.assertEqual("c6ebd2da4a683766293d4142060abb68", bridge_push.collapse_id("é", "b", "s"))
        cid = bridge_push.collapse_id(ACCOUNT, "frostbyte", "session-1")
        self.assertEqual(hashlib.sha256(bridge_push.destination_identifier(ACCOUNT, "frostbyte", "session-1").encode()).hexdigest()[:32], cid)
        self.assertLessEqual(len(cid.encode()), 64)

    def test_payload_is_generic(self):
        body = bridge_push.payload("run.completed", "Frost", ACCOUNT, "frostbyte", "s1")
        self.assertEqual({"title": "Frost", "body": "Your reply is ready."}, body["aps"]["alert"])
        self.assertEqual((ACCOUNT, "frostbyte", "s1"), (body["account"], body["profile"], body["session"]))
        self.assertEqual(bridge_push.destination_identifier(ACCOUNT, "frostbyte", "s1"), body["aps"]["thread-id"])
        self.assertEqual("Frost needs your approval", bridge_push.payload("approval.request", "Frost", "a", "p", "s")["aps"]["alert"]["title"])
        failed = bridge_push.payload("run.failed", "Frost", "a", "p", "s")["aps"]["alert"]
        self.assertEqual(("Frost could not finish", "Open the chat for details."), (failed["title"], failed["body"]))


@unittest.skipUnless(shutil.which("openssl"), "openssl needed to make a throwaway key")
class Jwt(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.key = make_key(self.dir.name)
        pub = subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout"], check=True, capture_output=True).stdout
        self.pub = Path(self.dir.name) / "pub.pem"
        self.pub.write_bytes(pub)

    def check(self, token):
        head, claims, sig = token.split(".")
        self.assertEqual({"alg": "ES256", "kid": "KEYID12345"}, json.loads(unb64(head)))
        self.assertEqual({"iss": "TEAMID1234", "iat": 1700000000}, json.loads(unb64(claims)))
        raw = unb64(sig)
        self.assertEqual(64, len(raw))
        der = lambda n: (b"\x00" if n[0] & 0x80 else b"") + n.lstrip(b"\x00") if n.lstrip(b"\x00") else b"\x00"
        r, s = der(raw[:32]), der(raw[32:])
        body = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        signature, signed = b"\x30" + bytes([len(body)]) + body, ("%s.%s" % (head, claims)).encode()
        try:
            # Verified in-process when possible: the openssl CLI changes under Homebrew (4.1 refuses this dgst call).
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
        except ImportError:
            sigfile = Path(self.dir.name) / "sig.der"
            sigfile.write_bytes(signature)
            message = Path(self.dir.name) / "msg"
            message.write_bytes(signed)
            done = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(self.pub), "-signature", str(sigfile),
                                   str(message)], capture_output=True)
            self.assertEqual(0, done.returncode, done.stdout + done.stderr)
            return
        key = serialization.load_pem_public_key(Path(self.pub).read_bytes())
        key.verify(signature, signed, ec.ECDSA(hashes.SHA256()))  # raises InvalidSignature on a bad JWT

    def test_signed_with_cryptography_or_default(self):
        self.check(bridge_push.make_jwt(str(self.key), "KEYID12345", "TEAMID1234", 1700000000))

    def test_signed_with_openssl_fallback(self):
        self.check(bridge_push.make_jwt(str(self.key), "KEYID12345", "TEAMID1234", 1700000000, bridge_push._sign_openssl))

    def test_der_conversion_pads_short_integers(self):
        der = bytes([0x30, 0x08, 0x02, 0x02, 0x00, 0xFF, 0x02, 0x02, 0x01, 0x02])
        self.assertEqual((255).to_bytes(32, "big") + (258).to_bytes(32, "big"), bridge_push._der_to_raw(der))


class Delivery(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.devices = bridge_devices.Devices(Path(self.dir.name))
        self.devices.issue({"did": "dev1", "dev": "Phone", "issued": 0, "exp": int(time.time()) + 3600, "method": "local"})
        self.devices.set_push_token("dev1", TOKEN, "sandbox", ACCOUNT)
        self.sent, self.logs, self.answer = [], [], (200, "")
        self.config = bridge_push.Config("/nonexistent.p8", "KEYID12345", "TEAMID1234", "com.example.app")
        self.clock = [1000.0]
        self.signs = []

        def send(url, headers, body):
            self.sent.append((url, headers, json.loads(body)))
            return self.answer

        def sign(key, message):
            self.signs.append(message)
            return b"\x01" * 64

        self.pusher = bridge_push.Pusher(self.devices, config=lambda: self.config, title=lambda p: "Frost", send=send,
                                         sign=sign, clock=lambda: self.clock[0], log=self.logs.append, inline=True)

    def test_pushes_when_away_not_when_attached(self):
        turn = FakeTurn()
        turn.watchers["dev1"] = 1
        self.pusher.notify(turn, "run.completed", {})
        self.assertEqual([], self.sent)
        turn2 = FakeTurn()
        self.pusher.notify(turn2, "run.completed", {})
        self.assertEqual(1, len(self.sent))
        url, headers, body = self.sent[0]
        self.assertEqual("https://api.sandbox.push.apple.com/3/device/" + TOKEN, url)
        self.assertEqual("com.example.app", headers["apns-topic"])
        self.assertEqual("alert", headers["apns-push-type"])
        self.assertEqual(bridge_push.collapse_id(ACCOUNT, "frostbyte", "session-1"), headers["apns-collapse-id"])
        self.assertTrue(headers["authorization"].startswith("bearer "))
        self.assertEqual("session-1", body["session"])

    def test_attached_but_suspended_pushes_after_grace(self):
        turn = FakeTurn()
        turn.watchers["dev1"] = 1
        self.pusher.presence("dev1", True)
        self.clock[0] += 10
        self.pusher.notify(turn, "run.completed", {})
        self.assertEqual([], self.sent)  # the app posts its own local notification in this window
        late = FakeTurn()
        late.watchers["dev1"] = 1
        self.clock[0] += 60
        self.pusher.notify(late, "run.completed", {})
        self.assertEqual(1, len(self.sent))
        self.pusher.presence("dev1", False)
        again = FakeTurn(); again.watchers["dev1"] = 1
        self.pusher.notify(again, "run.completed", {})
        self.assertEqual(1, len(self.sent))

    def test_one_outcome_per_turn_and_approvals_per_prompt(self):
        turn = FakeTurn()
        self.pusher.notify(turn, "run.completed", {})
        self.pusher.notify(turn, "run.failed", {})
        self.assertEqual(1, len(self.sent))
        asks = FakeTurn()
        self.pusher.notify(asks, "approval.request", {"request_id": "p1"})
        self.pusher.notify(asks, "approval.request", {"request_id": "p1"})
        self.pusher.notify(asks, "approval.request", {"request_id": "p2"})
        self.assertEqual(3, len(self.sent))
        self.assertEqual("Frost needs your approval", self.sent[1][2]["aps"]["alert"]["title"])

    def test_only_the_sending_device_is_told(self):
        self.devices.issue({"did": "dev2", "dev": "iPad", "issued": 0, "exp": int(time.time()) + 3600, "method": "local"})
        self.devices.set_push_token("dev2", "cd" * 32, "production", ACCOUNT)
        self.pusher.notify(FakeTurn("dev2"), "run.completed", {})
        self.assertEqual(["https://api.push.apple.com/3/device/" + "cd" * 32], [s[0] for s in self.sent])
        self.sent.clear()
        self.pusher.notify(FakeTurn(None), "run.completed", {})  # unknown origin: every device
        self.assertEqual(2, len(self.sent))

    def test_unconfigured_is_silent(self):
        self.config = None
        turn = FakeTurn()
        self.pusher.notify(turn, "run.completed", {})
        self.assertEqual(([], [], False), (self.sent, self.logs, turn.notified))

    def test_jwt_is_cached_then_refreshed(self):
        for _ in range(3):
            self.pusher.notify(FakeTurn(), "run.completed", {})
        self.assertEqual(1, len(self.signs))
        self.clock[0] += bridge_push.JWT_LIFETIME + 1
        self.pusher.notify(FakeTurn(), "run.completed", {})
        self.assertEqual(2, len(self.signs))

    def test_410_and_bad_token_are_dropped(self):
        for answer in ((410, "Unregistered"), (400, "BadDeviceToken")):
            self.devices.set_push_token("dev1", TOKEN, "sandbox", ACCOUNT)
            self.answer = answer
            self.pusher.notify(FakeTurn(), "run.completed", {})
            self.assertEqual([], self.devices.push_targets(), answer)
        self.devices.set_push_token("dev1", TOKEN, "sandbox", ACCOUNT)
        self.answer = (500, "InternalServerError")
        self.pusher.notify(FakeTurn(), "run.completed", {})
        self.assertEqual(1, len(self.devices.push_targets()))  # transient errors keep the token

    def test_logs_never_hold_secrets(self):
        self.answer = (410, "Unregistered")
        self.pusher.notify(FakeTurn(), "run.completed", {})
        self.assertTrue(self.logs)
        self.assertFalse(any(TOKEN in line or "bearer" in line.lower() for line in self.logs))

    def test_expired_provider_token_resets_the_cache(self):
        self.answer = (403, "ExpiredProviderToken")
        self.pusher.notify(FakeTurn(), "run.completed", {})
        self.pusher.notify(FakeTurn(), "run.completed", {})
        self.assertEqual(2, len(self.signs))


class Config(unittest.TestCase):
    def test_env(self):
        with tempfile.NamedTemporaryFile() as key:
            env = {"HERMES_MOBILE_APNS_KEY_PATH": key.name, "HERMES_MOBILE_APNS_KEY_ID": "K", "HERMES_MOBILE_APNS_TEAM_ID": "T"}
            config = bridge_push.Config.from_env(env)
            self.assertEqual(("K", "T", bridge_push.DEFAULT_TOPIC), (config.key_id, config.team_id, config.topic))
            env["HERMES_MOBILE_APNS_TOPIC"] = "com.me.app"
            self.assertEqual("com.me.app", bridge_push.Config.from_env(env).topic)
            del env["HERMES_MOBILE_APNS_TEAM_ID"]
            self.assertIsNone(bridge_push.Config.from_env(env))
        self.assertIsNone(bridge_push.Config.from_env({}))
        self.assertIsNone(bridge_push.Config.from_env({"HERMES_MOBILE_APNS_KEY_PATH": "/nope", "HERMES_MOBILE_APNS_KEY_ID": "K",
                                                        "HERMES_MOBILE_APNS_TEAM_ID": "T"}))


@unittest.skipUnless(Path("/usr/bin/curl").exists(), "curl needed")
class CurlSender(unittest.TestCase):
    def test_request_reaches_server_with_headers_and_body_and_reason_is_parsed(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        seen = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                seen["path"], seen["headers"] = self.path, dict(self.headers)
                seen["body"] = self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(410)
                self.end_headers()
                self.wfile.write(b'{"reason":"Unregistered"}')

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        body = json.dumps({"aps": {"alert": {"title": 'Q"uote \\ back'}}}, ensure_ascii=True)
        status, reason = bridge_push.curl_send("http://127.0.0.1:%d/3/device/%s" % (server.server_port, TOKEN),
                                               {"authorization": "bearer SECRET", "apns-topic": "com.x"}, body)
        self.assertEqual((410, "Unregistered"), (status, reason))
        self.assertEqual("/3/device/" + TOKEN, seen["path"])
        self.assertEqual("bearer SECRET", seen["headers"]["authorization"])
        self.assertEqual(body, seen["body"].decode())

    def test_unreachable_is_a_transport_failure(self):
        self.assertEqual((0, "transport"), bridge_push.curl_send("http://127.0.0.1:1/x", {}, "{}", timeout=3))


@unittest.skipUnless(bridge_turns, "bridge_turns needs Hermes's venv")
class TurnHook(unittest.TestCase):
    def test_hook_runs_for_outcomes_only_and_cannot_break_a_turn(self):
        seen = []
        old = bridge_turns.EVENT_HOOK
        bridge_turns.EVENT_HOOK = lambda turn, name, fields: seen.append(name)
        self.addCleanup(setattr, bridge_turns, "EVENT_HOOK", old)
        turn = bridge_turns.Turn("p", Path("."), "s", "hi", {})
        turn.push("message.delta", delta="x")
        turn.push("approval.request", request_id="r")
        turn.push("run.completed", output="done")
        self.assertEqual(["approval.request", "run.completed"], seen)
        bridge_turns.EVENT_HOOK = lambda *a: 1 / 0
        turn.push("run.failed", error="x")  # must not raise

    def test_attach_counts_per_device(self):
        turn = bridge_turns.Turn("p", Path("."), "s", "hi", {})
        turn.attach("a"); turn.attach("a"); turn.detach("a")
        self.assertEqual(1, turn.watchers["a"])
        turn.detach("a"); turn.detach("a")
        self.assertEqual(0, turn.watchers["a"])


try:
    import test_device_grants as grants
except Exception:  # pragma: no cover
    grants = None


@unittest.skipUnless(grants and bridge_turns, "needs the bridge HTTP harness and Hermes's venv")
class PushRoutes(unittest.TestCase):
    # Borrow the device-grant fixture without inheriting (and re-running) its tests.
    setUp = grants.DeviceGrantTests.setUp if grants else None
    serve = grants.DeviceGrantTests.serve if grants else None
    request = grants.DeviceGrantTests.request if grants else None
    pair = grants.DeviceGrantTests.pair if grants else None

    def test_register_presence_and_revocation_over_http(self):
        phone = self.pair()
        body = {"token": TOKEN, "environment": "sandbox", "account": ACCOUNT}
        self.assertEqual(401, self.request("POST", "/m/push/token", None, body)[0])  # grant auth required
        self.assertEqual(200, self.request("POST", "/m/push/token", phone, body)[0])
        for bad in ({**body, "token": "nothex"}, {**body, "environment": "dev"}, {**body, "account": ""}, {}):
            self.assertEqual(400, self.request("POST", "/m/push/token", phone, bad)[0], bad)
        self.assertEqual(200, self.request("POST", "/m/push/presence", phone, {"away": True})[0])
        self.assertEqual(400, self.request("POST", "/m/push/presence", phone, {"away": "yes"})[0])
        self.assertIn("push_v1", self.request("GET", "/m/capabilities", phone)[1]["features"])
        self.assertEqual([TOKEN], [r["token"] for r in self.b.devices().push_targets()])
        self.assertEqual(200, self.request("DELETE", "/m/push/token", phone)[0])
        self.assertEqual([], self.b.devices().push_targets())
        self.request("POST", "/m/push/token", phone, body)
        self.assertEqual(200, self.request("DELETE", "/m/devices/current", phone)[0])
        self.assertEqual([], self.b.devices().push_targets())


if __name__ == "__main__":
    unittest.main()
