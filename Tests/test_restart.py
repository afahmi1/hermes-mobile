"""Restarting Hermes and the bridge from the phone."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_restart as br
import hermes_mobile_bridge as b


class GatewayPidTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        self.addCleanup(self.child.wait)
        self.addCleanup(self.child.kill)

    def write(self, text):
        (self.home / "gateway.pid").write_text(text)

    def test_reads_hermes_json_record_for_a_live_process(self):
        self.write(json.dumps({"pid": self.child.pid, "kind": "hermes-gateway", "argv": ["gateway", "run"]}))
        self.assertEqual(br.gateway_pid(self.home), self.child.pid)

    def test_plain_number_record(self):
        self.write(str(self.child.pid))
        self.assertEqual(br.gateway_pid(self.home), self.child.pid)

    def test_never_trusts_a_foreign_dead_or_self_record(self):
        self.write(json.dumps({"pid": self.child.pid, "kind": "something-else"}))
        self.assertIsNone(br.gateway_pid(self.home))
        self.write(json.dumps({"pid": os.getpid(), "kind": "hermes-gateway"}))
        self.assertIsNone(br.gateway_pid(self.home))
        self.write(json.dumps({"pid": 1, "kind": "hermes-gateway"}))
        self.assertIsNone(br.gateway_pid(self.home))
        self.write(json.dumps({"pid": True, "kind": "hermes-gateway"}))
        self.assertIsNone(br.gateway_pid(self.home))
        self.write("garbage")
        self.assertIsNone(br.gateway_pid(self.home))
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        self.write(json.dumps({"pid": dead.pid, "kind": "hermes-gateway"}))
        self.assertIsNone(br.gateway_pid(self.home))

    def test_missing_file(self):
        self.assertIsNone(br.gateway_pid(self.home))


class RestartHermesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.kills, self.spawns = [], []
        self.kill = lambda pid, sig: self.kills.append((pid, sig))
        self.spawn = lambda argv, home: self.spawns.append(argv)
        self.enterContext(patch.object(br, "hermes_command", lambda home: "/x/hermes"))

    def test_gentle_restart_signals_the_gateway_and_runs_nothing(self):
        with patch.object(br, "gateway_pid", lambda home: 4242):
            code, body = br.restart_hermes(self.home, kill=self.kill, spawn=self.spawn)
        self.assertEqual(code, 202)
        self.assertEqual(body["mode"], "when_idle")
        self.assertEqual(self.kills, [(4242, signal.SIGUSR1)])
        self.assertEqual(self.spawns, [])

    def test_now_interrupts_through_the_hermes_cli(self):
        with patch.object(br, "gateway_pid", lambda home: 4242):
            code, body = br.restart_hermes(self.home, now=True, kill=self.kill, spawn=self.spawn)
        self.assertEqual((code, body["mode"]), (202, "now"))
        self.assertEqual(self.kills, [])
        self.assertEqual(self.spawns, [["/x/hermes", "gateway", "restart", "--yes", "--detach"]])

    def test_no_gateway_running_starts_one(self):
        with patch.object(br, "gateway_pid", lambda home: None):
            code, body = br.restart_hermes(self.home, kill=self.kill, spawn=self.spawn)
        self.assertEqual((code, body["mode"]), (202, "start"))
        self.assertEqual(self.spawns, [["/x/hermes", "gateway", "start"]])

    def test_signal_that_fails_falls_back_to_start(self):
        def gone(pid, sig):
            raise ProcessLookupError
        with patch.object(br, "gateway_pid", lambda home: 4242):
            code, body = br.restart_hermes(self.home, kill=gone, spawn=self.spawn)
        self.assertEqual(body["mode"], "start")

    def test_no_hermes_command_is_a_clear_error(self):
        with patch.object(br, "gateway_pid", lambda home: None), patch.object(br, "hermes_command", lambda home: None):
            code, body = br.restart_hermes(self.home, kill=self.kill, spawn=self.spawn)
        self.assertEqual(code, 503)
        self.assertIn("hermes gateway restart", body["error"])


class RestartBridgeTest(unittest.TestCase):
    def test_answers_first_then_exits_non_zero(self):
        done = threading.Event()
        codes = []

        def exit_fn(code):
            codes.append(code)
            done.set()
        code, body = br.restart_bridge(delay=0, exit_fn=exit_fn, sleep=lambda s: None)
        self.assertEqual((code, body["target"]), (202, "bridge"))
        self.assertTrue(done.wait(2))
        self.assertEqual(codes, [br.BRIDGE_EXIT_CODE])
        self.assertNotEqual(br.BRIDGE_EXIT_CODE, 0)


class RestartRouteTest(unittest.TestCase):
    def setUp(self):
        import http.client
        from http.server import ThreadingHTTPServer
        self.http = http.client
        self.owner = True
        self.calls = []
        self.enterContext(patch.object(b.H, "owner_ok", lambda h: self.owner))
        self.enterContext(patch.object(br, "restart_hermes",
                                       lambda home, now=False: (self.calls.append(("hermes", now)) or
                                                                (202, {"ok": True, "mode": "now" if now else "when_idle"}))))
        self.enterContext(patch.object(br, "restart_bridge",
                                       lambda: (self.calls.append(("bridge", None)) or (202, {"ok": True, "mode": "now"}))))
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), b.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.token = b.make_token("test")

    def req(self, method, path, body=None, token=None):
        c = self.http.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        c.request(method, path, body=json.dumps(body) if body is not None else None,
                  headers={"Authorization": "Bearer " + (token or self.token), "Content-Type": "application/json"})
        r = c.getresponse()
        out = (r.status, json.loads(r.read() or b"null"))
        c.close()
        return out

    def test_capabilities_advertise_restart_for_the_owner(self):
        code, doc = self.req("GET", "/m/capabilities")
        self.assertEqual(code, 200)
        self.assertIn("restart_v1", doc["features"])
        self.assertTrue(doc["can_restart"])
        self.owner = False
        self.assertFalse(self.req("GET", "/m/capabilities")[1]["can_restart"])

    def test_restart_hermes_gently_and_now(self):
        self.assertEqual(self.req("POST", "/m/restart", {"target": "hermes"}), (202, {"ok": True, "mode": "when_idle"}))
        self.assertEqual(self.req("POST", "/m/restart", {"target": "hermes", "now": True})[0], 202)
        self.req("POST", "/m/restart", {"target": "hermes", "now": "yes"})  # only a real true interrupts
        self.assertEqual(self.calls, [("hermes", False), ("hermes", True), ("hermes", False)])

    def test_restart_bridge(self):
        self.assertEqual(self.req("POST", "/m/restart", {"target": "bridge"})[0], 202)
        self.assertEqual(self.calls, [("bridge", None)])

    def test_refusals(self):
        self.assertEqual(self.req("POST", "/m/restart", {"target": "mac"})[0], 400)
        self.assertEqual(self.req("GET", "/m/restart")[0], 404)
        self.assertEqual(self.req("POST", "/m/restart", {"target": "hermes"}, token="nope")[0], 401)
        self.owner = False
        self.assertEqual(self.req("POST", "/m/restart", {"target": "hermes"})[0], 403)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
