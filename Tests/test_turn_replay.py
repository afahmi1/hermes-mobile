"""Replay retention, checkpoint boundaries and shared fanout bytes."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import http.client
import importlib
import json
import os
import tempfile
import threading
from http.server import ThreadingHTTPServer
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as turns


def decode(frame):
    return json.loads(frame.split(b"\ndata: ", 1)[1])


class TurnReplayTests(unittest.TestCase):
    def setUp(self):
        self.turn = turns.Turn("default", Path("."), "session", "", {})

    def test_readers_share_encoded_frames_and_start_after_last_seen(self):
        for i in range(9):
            self.turn.push("message.delta", delta=str(i))
        self.turn.finish()
        a, next_seq, done, gap = self.turn.replay(2)
        b, *_ = self.turn.replay(2)
        self.assertEqual((next_seq, done, gap), (9, True, False))
        self.assertTrue(all(x is y for x, y in zip(a, b)))
        self.assertEqual([decode(frame)["seq"] for frame in a], list(range(2, 9)))

    def test_time_eviction_preserves_only_pending_approvals_and_terminal_outcome(self):
        with patch.object(turns.time, "monotonic", return_value=1.0):
            self.turn.push("approval.request", request_id="old", command="old")
            self.turn.push("approval.resolved", request_id="old")
            self.turn.push("approval.request", request_id="active", command="review", execution_generation=4)
        with patch.object(turns.time, "monotonic", return_value=turns.REPLAY_SECONDS + 1.0):
            frames, cursor, done, gap = self.turn.replay(0)
            checkpoint = decode(frames[0])
            self.assertEqual((cursor, done, gap, checkpoint["seq"]), (3, False, True, 2))
            self.assertEqual([(x["request_id"], x["command"], x["execution_generation"])
                              for x in checkpoint["approvals"]], [("active", "review", 4)])
            self.assertEqual(self.turn._wire_bytes, 0)
            self.turn.push("approval.resolved", request_id="active")
            self.turn.push("run.failed", error="lost worker")
            self.turn.finish()
            frames, _, done, gap = self.turn.replay(cursor)
            self.assertTrue(done)
            self.assertFalse(gap)
            self.assertEqual([decode(f)["seq"] for f in frames], [3, 4])
            frames, _, _, gap = self.turn.replay(0)
            cp = decode(frames[0])
            self.assertTrue(gap)
            self.assertEqual(cp["approvals"], [])
            self.assertEqual(cp["terminal"], {"event": "run.failed", "error": "lost worker"})

    def test_reader_falling_behind_or_reconnecting_ahead_gets_current_watermark(self):
        # Simulate a slow connected reader after it consumed the first event.
        self.turn.push("status", text="Starting")
        _, cursor, _, _ = self.turn.replay(0)
        with patch.object(turns, "REPLAY_BYTES", 512):
            self.turn.push("message.delta", delta="large" * 300)
            self.turn.push("approval.request", request_id="approval", choices=["once", "deny"])
            for offset in (0, cursor, 10000):
                frames, resume, done, gap = self.turn.replay(offset)
                self.assertTrue(gap)
                self.assertFalse(done)
                self.assertEqual(resume, decode(frames[0])["seq"] + 1)
                self.assertEqual(decode(frames[0])["approvals"][0]["request_id"], "approval")
            self.assertLessEqual(self.turn._wire_bytes, 512)
            self.turn.push("message.delta", delta="new")
            frames, _, _, gap = self.turn.replay(resume)
            self.assertFalse(gap)
            self.assertEqual(decode(frames[0])["delta"], "new")

    def test_batch_budget_and_done_only_at_end(self):
        with patch.object(turns, "REPLAY_BATCH_FRAMES", 2):
            for i in range(5):
                self.turn.push("message.delta", delta=str(i))
            self.turn.finish()
            offset = 0
            for expected, expected_done in ((2, False), (2, False), (1, True)):
                batch, offset, done, gap = self.turn.replay(offset)
                self.assertFalse(gap)
                self.assertEqual((len(batch), done), (expected, expected_done))

class ReplayHTTPTests(unittest.TestCase):
    def setUp(self):
        self.turn = turns.Turn("default", Path("."), "session", "", {})
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, HERMES_HOME=home):
            bridge = importlib.import_module("hermes_mobile_bridge")
        turn = self.turn

        class Handler(bridge.H):
            def do_GET(self):
                last = int(self.headers.get("Last-Event-ID", -1))
                self._authorized_tail(turn, last + 1)

            def log_message(self, fmt, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.http = http.client.HTTPConnection(*server.server_address, timeout=3)
        self.addCleanup(self.http.close)

    def test_old_epoch_at_numerically_valid_cursor_then_live_resolution(self):
        for i in range(3):
            self.turn.push("message.delta", delta=str(i))
        self.turn.push("approval.request", request_id="open", command="print result")
        self.http.request("GET", "/", headers={"Last-Event-ID": "0", "X-Hermes-Replay": "checkpoint-v1",
                                             "X-Hermes-Replay-Epoch": "previous-process"})
        response = self.http.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("X-Hermes-Replay-Epoch"), self.turn.replay_epoch)
        self.assertEqual(response.readline(), b"id: 3\n")
        cp = json.loads(response.readline()[6:])
        self.assertEqual(cp["event"], "stream.checkpoint")
        self.assertEqual([ev["request_id"] for ev in cp["approvals"]], ["open"])
        self.assertEqual(response.readline(), b"\n")
        self.turn.push("approval.resolved", request_id="open")
        self.turn.push("run.completed", output="done")
        self.turn.finish()
        remaining = [decode(frame) for frame in response.read().split(b"\n\n") if frame]
        self.assertEqual([(ev["seq"], ev["event"]) for ev in remaining],
                         [(4, "approval.resolved"), (5, "run.completed")])

    def test_legacy_client_gets_explicit_http_error_on_expired_history(self):
        with patch.object(turns, "REPLAY_BYTES", 1):
            self.turn.push("message.delta", delta="evicted")
        self.http.request("GET", "/")
        response = self.http.getresponse()
        self.assertEqual(response.status, 410)
        self.assertIn("expired", json.loads(response.read())["error"])
