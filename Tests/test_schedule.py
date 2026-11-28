import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace
from unittest.mock import patch
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

    def test_failing_handoff_retries_then_gives_up(self):
        self.s.add("default", "s1", "x", 1000, now=900)
        def boom(r):
            raise ConnectionRefusedError("gateway down")
        self.assertEqual(self.s.tick(boom, now=1000), 0)
        self.assertEqual(self.s.tick(lambda r: None, now=1050), 0)  # waiting out RETRY_AFTER
        self.assertEqual(self.s.tick(boom, now=1000 + bs.RETRY_AFTER), 0)
        self.assertIn("gateway down", self.s.list("default", "s1")[0]["error"])
        self.s.tick(boom, now=1000 + bs.GIVE_UP_AFTER + 1)
        self.assertEqual(self.s.list("default", "s1", include_done=True)[0]["status"], "failed")

    def test_reopens_due_row_with_send_options(self):
        row = self.s.add("default", "s1", "x", 1000, reason="reset", now=900,
                         options={"provider": "anthropic", "model": "claude-sonnet"})
        reopened = bs.Schedule(self.dir)
        sent = []
        self.assertEqual(reopened.tick(sent.append, now=1000), 1)
        self.assertEqual(sent[0]["id"], row["id"])
        self.assertEqual(sent[0]["options"], {"provider": "anthropic", "model": "claude-sonnet"})

    def test_rejects_invalid_or_past_new_schedules(self):
        for date in (float("nan"), float("inf"), 900, 899):
            with self.subTest(date=date), self.assertRaises(bs.ScheduleError):
                self.s.add("default", "s1", "x", date, reason="scheduled", now=900)

    def test_concurrent_ticks_send_once(self):
        import threading
        row = self.s.add("default", "s1", "x", 100, now=50)
        other, sent = bs.Schedule(self.dir), []
        ts = [threading.Thread(target=lambda st=st: st.tick(sent.append, now=200)) for st in (self.s, other) * 3]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual([r["id"] for r in sent], [row["id"]])

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

    def test_new_chat_schedules_lists_and_cancels_without_sending(self):
        import hermes_mobile_bridge as b
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))

        class Fake:
            command = "POST"
            payload = {}
            _schedule = b.H._schedule

            def json_body(self):
                return self.payload

            def send(self, code, body):
                return code, body

        f = Fake()
        with patch.multiple(b, STATE_DIR=tmp, _SCHEDULE=None), patch.object(b, "profile_ids", return_value=["default"]), \
                patch.object(b, "profile_home", return_value=tmp), \
                patch.object(b.turns, "create_session", return_value={"session_id": "new-chat"}), \
                patch.object(b.turns, "start_primary") as start:
            code, created = b.H.chat_route(f, "/m/chat/default/new", {})
            self.assertEqual(code, 201)
            path = "/m/chat/default/" + created["session_id"]
            f.payload = {"text": "first message", "at": bs.time.time() + 3600, "reason": "scheduled"}
            with patch.object(f, "payload", {**f.payload, "attachments": ["attachment"]}):
                self.assertEqual(b.H.chat_route(f, path + "/schedule", {})[0], 400)
            code, result = b.H.chat_route(f, path + "/schedule", {})
            self.assertEqual(code, 201)
            self.assertEqual(result["waiting"][0]["reason"], "scheduled")
            f.payload = {}
            self.assertEqual(b.H.chat_route(f, path + "/scheduled", {})[1]["waiting"], result["waiting"])
            f.payload = {"id": result["scheduled"]["id"]}
            self.assertEqual(b.H.chat_route(f, path + "/unschedule", {}), (200, {"cancelled": True, "waiting": []}))
            start.assert_not_called()

    def test_due_schedule_uses_gateway_queue_while_a_phone_turn_runs(self):
        import hermes_mobile_bridge as b
        engine = b.turns
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        active = engine.Turn("default", tmp, "sess", "earlier", {})
        active.admission = "earlier"
        active.generation = 1
        store = bs.Schedule(tmp)
        row = store.add("default", "sess", "next", 100, now=50)
        turn_id = "turn_" + row["id"].replace("-", "")
        with patch.multiple(b, STATE_DIR=tmp), patch.object(b, "profile_ids", return_value=["default"]), \
                patch.object(b, "profile_home", return_value=tmp), \
                patch.object(b, "prepare_workspace_turn", return_value=None), \
                patch.object(b, "persona_scope", return_value=None), \
                patch.dict(engine.TURNS, {active.id: active}, clear=True), \
                patch.object(engine.asyncio, "run_coroutine_threadsafe", side_effect=lambda coro, loop: coro.close()):
            self.assertEqual(store.tick(b._send_scheduled, now=100), 1)
            queued = engine.get_turn(turn_id)
            self.assertIsNotNone(queued)
            self.assertFalse(active.done)

            @asynccontextmanager
            async def connect(_home):
                yield SimpleNamespace(events=asyncio.Queue())

            async def rpc(client, method, **params):
                if method == "session.resume":
                    return {"session_id": "sess", "running": True, "pending": [{"admission_id": "earlier"}]}
                self.assertEqual(method, "prompt.submit")
                self.assertEqual(params["submission_id"], turn_id[5:])
                self.assertEqual(params["text"], "next")
                client.events.put_nowait({"params": {"type": "message.delta", "execution_generation": 1,
                                                     "payload": {"text": "earlier reply"}}})
                client.events.put_nowait({"params": {"type": "message.complete", "admission_id": "next",
                                                     "execution_generation": 2,
                                                     "payload": {"outcome": "completed", "text": "new reply"}}})
                return {"admission_id": "next", "status": "queued"}

            with patch.object(engine, "connect", connect), patch.object(engine, "_rpc", rpc):
                asyncio.run(engine._drive_connection(queued))
            self.assertEqual(engine.primary_journal(tmp / "admissions").get(turn_id)["admission"], "next")
            self.assertFalse(any(e["event"] == "message.delta" for e in queued.events))
            self.assertEqual(queued.events[-1]["output"], "new reply")

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
        self.assertEqual(b.schedule_store().tick(b._send_scheduled), 1)
        self.assertEqual(calls[0][3], "continue")
        self.assertEqual(calls[0][5], sid)  # keyed by the schedule id: idempotent in the admissions journal

        b.H._schedule(f, "default", "sess", "unschedule", {"id": sid})
        self.assertEqual(f.out[0], 404)  # already sent


if __name__ == "__main__":
    unittest.main()
