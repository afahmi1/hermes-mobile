import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_schedule as bs


class ScheduleStore(unittest.TestCase):
    def setUp(self):
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.s = bs.Schedule(self.dir)

    def test_files_are_private(self):
        self.assertEqual((self.dir / "schedule").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.dir / "schedule" / "schedule.db").stat().st_mode & 0o777, 0o600)

    def test_sends_once_when_due(self):
        row = self.s.add("default", "s1", "continue please", 1000, reason="limits", now=900)
        sent = []
        self.assertEqual(self.s.tick(sent.append, now=999), 0)
        self.assertEqual(self.s.tick(sent.append, now=1001), 1)
        self.assertEqual([r["id"] for r in sent], [row["id"]])
        self.assertEqual(self.s.tick(sent.append, now=2000), 0)  # never twice
        self.assertEqual(self.s.list("default", "s1"), [])
        self.assertEqual(self.s.list("default", "s1", include_done=True)[0]["status"], "sent")

    def test_busy_or_failing_retries_then_gives_up(self):
        self.s.add("default", "s1", "x", 1000, now=900)
        self.assertEqual(self.s.tick(lambda r: None, busy=lambda p, s: True, now=1000), 0)
        self.assertEqual(self.s.tick(lambda r: None, now=1050), 0)        # waiting out RETRY_AFTER
        def boom(r):
            raise ConnectionRefusedError("gateway down")
        self.assertEqual(self.s.tick(boom, now=1000 + bs.RETRY_AFTER), 0)
        self.assertIn("gateway down", self.s.list("default", "s1")[0]["error"])
        self.s.tick(boom, now=1000 + bs.GIVE_UP_AFTER + 1)
        self.assertEqual(self.s.list("default", "s1", include_done=True)[0]["status"], "failed")

    def test_cancel_and_limits(self):
        row = self.s.add("default", "s1", "x", 1000, now=900)
        self.assertFalse(self.s.cancel("default", "other", row["id"]))
        self.assertTrue(self.s.cancel("default", "s1", row["id"]))
        self.assertEqual(self.s.tick(lambda r: self.fail("cancelled row sent"), now=5000), 0)
        with self.assertRaises(bs.ScheduleError):
            self.s.add("default", "s1", "   ", 1000, now=900)
        with self.assertRaises(bs.ScheduleError):
            self.s.add("default", "s1", "x", 900 + bs.MAX_AHEAD + 10, now=900)
        self.assertEqual(self.s.add("default", "s1", "x", 10, now=900)["due"], 900)  # past -> now


class ScheduleEndpoint(unittest.TestCase):
    """The chat route's schedule actions, driven without a socket, and the sender using the durable send."""

    def test_route_and_send(self):
        import hermes_mobile_bridge as b
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        old = (b.STATE_DIR, b._SCHEDULE)
        b.STATE_DIR, b._SCHEDULE = tmp, None
        self.addCleanup(lambda: setattr(b, "STATE_DIR", old[0]) or setattr(b, "_SCHEDULE", old[1]))

        class Fake:
            out = None
            def send(self, code, body):
                self.out = (code, body)
        f = Fake()
        b.H._schedule(f, "default", "sess", "schedule", {"text": "continue", "at": 0, "reason": "limits"})
        self.assertEqual(f.out[0], 201)
        sid = f.out[1]["scheduled"]["id"]
        b.H._schedule(f, "default", "sess", "scheduled", {})
        self.assertEqual([r["id"] for r in f.out[1]["waiting"]], [sid])

        calls = []
        orig = (b.turns.start_primary, b.profile_ids, b.profile_home)
        b.turns.start_primary = lambda *a, **k: calls.append(a)
        b.profile_ids = lambda: ["default"]
        b.profile_home = lambda p: tmp
        self.addCleanup(lambda: (setattr(b.turns, "start_primary", orig[0]), setattr(b, "profile_ids", orig[1]),
                                 setattr(b, "profile_home", orig[2])))
        self.assertEqual(b.schedule_store().tick(b._send_scheduled, busy=lambda p, s: False), 1)
        self.assertEqual(calls[0][3], "continue")
        self.assertEqual(calls[0][5], sid)  # keyed by the schedule id: idempotent in the admissions journal

        b.H._schedule(f, "default", "sess", "unschedule", {"id": sid})
        self.assertEqual(f.out[0], 404)  # already sent


if __name__ == "__main__":
    unittest.main()
