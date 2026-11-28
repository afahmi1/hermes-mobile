"""A busy device registry must never sign the phone out: 503 (retry), not 401, and live streams stay up."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import json
import sqlite3
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_devices
import hermes_mobile_bridge as b


def _hold_lock(seconds):
    """Another request mid-write (push token, presence, pairing) holding the registry."""
    db = sqlite3.connect(b.devices().path, isolation_level=None, check_same_thread=False)
    db.execute("BEGIN EXCLUSIVE")
    timer = threading.Timer(seconds, lambda: (db.execute("ROLLBACK"), db.close()))
    timer.start()
    return timer


class RegistryBusyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), b.H)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def get(self, path, token):
        req = urllib.request.Request(self.base + path, headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def test_registry_is_wal_so_reads_do_not_wait_for_writes(self):
        with sqlite3.connect(b.devices().path) as db:
            self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0].lower(), "wal")

    def test_valid_token_survives_a_concurrent_write(self):
        token = b.make_token("busy-phone")
        timer = _hold_lock(1.0)
        try:
            self.assertIsNotNone(b.token_claims(token))
        finally:
            timer.join()

    def test_unreadable_registry_answers_503_not_401(self):
        token = b.make_token("busy-phone-2")
        with patch.object(bridge_devices.Devices, "accepts", side_effect=sqlite3.OperationalError("database is locked")):
            code, body = self.get("/m/capabilities", token)
        self.assertEqual(code, 503)
        self.assertTrue(body.get("retry"))
        self.assertNotIn("Sign in", body.get("error", ""))

    def test_bad_token_is_still_401(self):
        code, _ = self.get("/m/capabilities", "hm2.bogus.sig")
        self.assertEqual(code, 401)

    def test_revoked_token_is_still_401(self):
        token = b.make_token("revoked-phone")
        did = b.token_claims(token)["did"]
        self.assertTrue(b.devices().revoke(did))
        code, _ = self.get("/m/capabilities", token)
        self.assertEqual(code, 401)

    def test_stream_monitor_keeps_streams_when_registry_errors(self):
        closed = []
        streams = bridge_devices.Streams(lambda ids: (_ for _ in ()).throw(sqlite3.OperationalError("locked")))
        streams._disconnect = closed.append
        live = object()
        expired = object()
        streams._check([(live, ("did-a", time.time() + 60, ())), (expired, ("did-b", time.time() - 1, ()))])
        self.assertEqual(closed, [expired])
        streams.failing_since = time.time() - bridge_devices.REGISTRY_GRACE - 1
        streams._check([(live, ("did-a", time.time() + 60, ()))])
        self.assertEqual(closed, [expired, live])


if __name__ == "__main__":
    unittest.main()
