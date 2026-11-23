"""Exercise device grants at the HTTP boundary with an isolated signing key and registry."""
import base64
import hashlib
import hmac
import http.client
import importlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Bridge"), str(ROOT / "Status")]


class IdleTurn:
    replay_epoch = "fixture"

    def __init__(self, finish):
        self.finish = finish

    def replay(self, offset, timeout=None, reset=False):
        if offset == 0:
            return [b": fixture\n\n"], 1, False, False
        return [], offset, self.finish.wait(4), False


class DeviceGrantTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.home = Path(directory)
        self.enterContext(patch.dict(os.environ, HERMES_HOME=directory, HERMES_MOBILE_OWNER_MANAGED="1"))
        self.b = importlib.import_module("hermes_mobile_bridge")
        self.enterContext(patch.object(self.b, "STATE_DIR", self.home / "mobile"))
        self.enterContext(patch.object(self.b, "HERMES", self.home))
        self.enterContext(patch.object(self.b, "SECRET", os.urandom(32)))
        self.enterContext(patch.object(self.b, "STREAMS", self.b.bridge_devices.Streams()))
        self.server = self.serve(self.b.H)
        self.owner = self.b.make_token("Host", owner=True)

    def serve(self, handler):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def request(self, method, path, token=None, data=None):
        headers = {"Authorization": "Bearer " + token} if token else {}
        with closing(http.client.HTTPConnection(*self.server.server_address, timeout=5)) as client:
            client.request(method, path, json.dumps(data) if data is not None else None, headers)
            response = client.getresponse()
            return response.status, json.loads(response.read())

    def pair(self):
        code, reply = self.request("POST", "/m/devices/pair-code", self.owner)
        self.assertEqual(code, 201)
        return self.request("POST", "/m/pair", data={"code": reply["code"], "device": "Phone"})[1]["token"]

    def test_one_time_pairing_concurrent_exchange_and_privileges(self):
        offer = self.request("POST", "/m/devices/pair-code", self.owner)[1]
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.request("POST", "/m/pair", data={"code": offer["code"]}), range(2)))
        self.assertEqual(sorted(s for s, _ in results), [200, 401])
        token = next(d["token"] for s, d in results if s == 200)
        own = self.request("GET", "/m/capabilities", self.owner)[1]
        paired = self.request("GET", "/m/capabilities", token)[1]
        self.assertTrue(own["manage_devices"])
        self.assertFalse(paired["manage_devices"])
        self.assertNotEqual(own["device_id"], paired["device_id"])
        self.assertIn("pair_code", paired["features"])
        self.assertEqual(self.request("GET", "/m/devices", token)[0], 403)
        self.assertEqual(self.request("POST", "/m/devices/pair-code", token)[0], 403)
        self.assertEqual(self.request("DELETE", "/m/devices/" + own["device_id"], token)[0], 403)
        self.assertEqual(self.request("POST", "/m/manage/projects", token, {})[0], 403)
        with patch.dict(os.environ, HERMES_MOBILE_OWNER_MANAGED="0"):
            for path in ("instructions", "files", "assignment"):
                self.assertEqual(self.request("PUT", "/m/workspaces/alpha/" + path, token, {})[0], 403)
        self.assertEqual(self.request("DELETE", "/m/devices/current", token)[0], 200)
        self.assertEqual(self.request("GET", "/m/capabilities", token)[0], 401)
        devices = self.request("GET", "/m/devices", self.owner)[1]["devices"]
        self.assertEqual([d["id"] for d in devices], [own["device_id"]])

    def test_workspace_detail_offers_edits_only_to_the_authorized_grant(self):
        paired = self.pair()
        store = SimpleNamespace(detail=lambda _: {"instructions": "", "files": [{"name": "reference"}]},
                                assignment=lambda _: (0, []))
        self.enterContext(patch.object(self.b, "workspace_grants", return_value={"alpha": {"bot"}}))
        self.enterContext(patch.object(self.b, "workspace_store", return_value=store))
        self.enterContext(patch.object(self.b, "workspace_catalog", return_value={"alpha": {}}))
        self.enterContext(patch.object(self.b, "workspace_eligible", return_value=["bot"]))
        for owner_mode in (True, False):
            with patch.object(self.b, "workspace_owner_mode", return_value=owner_mode):
                for token, editable in ((self.owner, True), (paired, False)):
                    status, detail = self.request("GET", "/m/workspaces/alpha", token)
                    self.assertEqual(status, 200)
                    self.assertEqual(detail["editable"], editable)
                    self.assertEqual(detail["files"][0]["editable"], editable)
                    self.assertEqual(detail["assignment"]["editable"], editable and owner_mode)

    def test_new_grants_cannot_be_reinterpreted_by_an_older_bridge(self):
        token = self.pair()
        version, payload, sig = token.split(".")
        self.assertEqual(version, "hm2")
        legacy_signature = hmac.new(self.b.SECRET, payload.encode(), hashlib.sha256).hexdigest()
        self.assertFalse(hmac.compare_digest(legacy_signature, sig))
        self.assertFalse(self.b.token_ok("hm1." + payload + "." + sig))

    def test_pair_consumption_rolls_back_if_the_grant_cannot_be_written(self):
        store = self.b.devices()
        code = store.offer()["code"]
        with closing(store.connect()) as db, db:
            db.execute("CREATE TRIGGER fail BEFORE INSERT ON devices BEGIN SELECT RAISE(ABORT,'test failure'); END")
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError):
            self.b.make_token("Phone", method="pair", pair_code=code)
        with closing(store.connect()) as db, db:
            db.execute("DROP TRIGGER fail")
        self.assertIsNotNone(self.b.make_token("Phone", method="pair", pair_code=code))
        self.assertIsNone(self.b.make_token("Phone", method="pair", pair_code=code))

    def test_concurrent_cold_start_reads_one_complete_host_signing_secret(self):
        with ThreadPoolExecutor(8) as workers:
            readings = list(workers.map(lambda _: self.b._secret(), range(16)))
        self.assertEqual(len(set(readings)), 1)
        self.assertEqual(len(readings[0]), 64)

    def test_attachment_capability_follows_the_installed_ingress(self):
        for enabled in (True, False):
            with patch.object(self.b, "image_attachments_supported", return_value=enabled):
                result = self.request("GET", "/m/capabilities", self.owner)
                self.assertEqual(result[0], 200)
                self.assertEqual("image_attachments_v1" in result[1]["features"], enabled)

    def test_expired_code_and_legacy_device_registration_survive_reopen(self):
        store = self.b.devices()
        code = store.offer()["code"]
        with closing(store.connect()) as db, db:
            db.execute("UPDATE pairing SET expires=0")
        self.assertEqual(self.request("POST", "/m/pair", data={"code": code})[0], 401)
        payload = base64.urlsafe_b64encode(json.dumps({"exp": int(time.time()) + 120, "dev": "Before update", "n": "fixture"}).encode()).decode().rstrip("=")
        token = "hm1." + payload + "." + hmac.new(self.b.SECRET, payload.encode(), hashlib.sha256).hexdigest()
        s, first = self.request("GET", "/m/capabilities", token)
        self.assertEqual(s, 200)
        self.b._devices.cache_clear()
        s, second = self.request("GET", "/m/capabilities", token)
        self.assertEqual((s, second["device_id"]), (200, first["device_id"]))
        self.assertEqual(self.request("DELETE", "/m/devices/" + first["device_id"], self.owner)[0], 200)
        self.b._devices.cache_clear()
        self.assertEqual(self.request("GET", "/m/capabilities", token)[0], 401)

    def stream(self, path, token):
        client = http.client.HTTPConnection(*self.server.server_address, timeout=4)
        self.addCleanup(client.close)
        client.request("GET", path, headers={"Authorization": "Bearer " + token})
        response = client.getresponse()
        self.addCleanup(response.close)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.readline(), b": fixture\n")
        self.assertEqual(response.readline(), b"\n")
        return response

    def test_revoking_device_closes_live_and_idle_streams_only_for_that_device(self):
        ended = threading.Event()
        self.addCleanup(ended.set)
        turn = IdleTurn(ended)
        token = self.pair()
        other = self.pair()
        self.enterContext(patch.object(self.b, "turns", SimpleNamespace(get_turn=lambda _: turn)))
        path = "/m/turns/turn_" + "a" * 32 + "/events"
        stream = self.stream(path, token)
        unaffected = self.stream(path, other)
        self.assertEqual(self.request("DELETE", "/m/devices/" + self.b.token_claims(token)["did"], self.owner)[0], 200)
        started = time.monotonic()
        self.assertEqual(stream.read(), b"")
        self.assertLess(time.monotonic() - started, 1)
        with self.b.STREAMS.lock:
            self.assertEqual([entry[0] for entry in self.b.STREAMS.live.values()], [self.b.token_claims(other)["did"]])
        ended.set()
        self.assertEqual(unaffected.read(), b"")

    def test_out_of_process_revocation_disconnects_idle_proxied_stream(self):
        end = threading.Event()
        self.addCleanup(end.set)

        class Upstream(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(b": fixture\n\n")
                self.wfile.flush()
                end.wait(4)

        upstream = self.serve(Upstream)
        self.enterContext(patch.object(self.b, "UPSTREAM", upstream.server_address))
        self.enterContext(patch.object(self.b, "key_for", return_value="gateway-fixture"))
        token = self.pair()
        response = self.stream("/m/p/default/v1/runs/test/events", token)
        registry = self.b.bridge_devices.Devices(self.home / "mobile" / "devices")
        registry.revoke(self.b.token_claims(token)["did"])
        started = time.monotonic()
        self.assertEqual(response.read(), b"")
        self.assertLess(time.monotonic() - started, 2)
        end.set()

    def test_expiry_disconnects_active_stream(self):
        end = threading.Event()
        self.addCleanup(end.set)
        with patch.object(self.b, "TOKEN_TTL", 2):
            token = self.b.make_token("Transient")
        self.enterContext(patch.object(self.b, "turns", SimpleNamespace(get_turn=lambda _: IdleTurn(end))))
        response = self.stream("/m/turns/turn_" + "c" * 32 + "/events", token)
        self.assertEqual(response.read(), b"")
        self.assertEqual(self.request("GET", "/m/capabilities", token)[0], 401)
        end.set()

    def test_dead_recorded_pid_and_replacement_heartbeat(self):
        import hermes_status_server as status
        with subprocess.Popen([sys.executable, "-c", "pass"]) as child:
            child.wait()
        fresh = datetime.now(timezone.utc).isoformat()
        lifecycle = {"phase": "running", "pid": child.pid, "started_at": fresh}
        self.assertEqual(self.b.gateway_phase(False, None, {}, lifecycle, time.time()), "stopped")
        self.assertEqual(self.b.gateway_phase(True, "ok", {}, lifecycle, time.time()), "running")
        (self.home / "state").mkdir()
        (self.home / "gateway_state.json").write_text(json.dumps({"gateway_state":"running", "pid":child.pid}))
        with patch.object(status, "HOME", self.home):
            down = status.gateway_status()
            self.assertEqual(down["health"], "down")
            self.assertIn("has exited", " ".join(down["reasons"]))
            (self.home / "state/gateway.heartbeat").write_text(json.dumps({"updated_at":fresh, "pid":os.getpid()}))
            replacement = status.gateway_status()
            self.assertTrue(replacement["alive"])
            self.assertEqual(replacement["pid"], os.getpid())
