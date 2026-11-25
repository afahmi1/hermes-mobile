"""The chat's queue lives in Hermes's state.db. The bridge shows it and changes it with Hermes's verbs."""
import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as turns


def snap(*rows):
    return {"session_id": "canon", "stored_session_id": "s1", "pending": list(rows), "info": {"execution_state": "running"}}


RUNNING = {"admission_id": "a1", "status": "started", "text": "first", "execution_generation": 3}
LOST = {"admission_id": "a1", "status": "unknown", "text": "first", "execution_generation": 3}
QUEUED = {"admission_id": "a2", "status": "queued", "text": "second", "controls": ["steer", "replace"]}


class FakeClient:
    def __init__(self, snapshots, results):
        self.snapshots, self.results, self.calls = list(snapshots), dict(results), []

    async def rpc(self, method, **params):
        self.calls.append((method, params))
        if method == "session.resume":
            return self.snapshots.pop(0) if len(self.snapshots) > 1 else self.snapshots[0]
        value = self.results[method]
        if isinstance(value, Exception):
            raise value
        return value


class Ctx:
    def __init__(self, client):
        self.client = client

    async def __aenter__(self):
        return self.client

    async def __aexit__(self, *a):
        return False


class QueueTests(unittest.TestCase):
    def test_pending_shape_and_paused_after_restart(self):
        q = turns.public_pending(snap(RUNNING, QUEUED))
        self.assertFalse(q["paused"])
        self.assertEqual([r["status"] for r in q["pending"]], ["started", "queued"])
        self.assertTrue(q["pending"][1]["can_edit"] and q["pending"][1]["can_steer"])
        q = turns.public_pending(snap(LOST, QUEUED))
        self.assertTrue(q["paused"])
        self.assertEqual(q["lost"]["admission_id"], "a1")

    def test_old_gateway_without_controls_can_cancel_not_edit(self):
        row = dict(QUEUED); row.pop("controls")
        r = turns.public_pending(snap(row))["pending"][0]
        self.assertTrue(r["can_cancel"]); self.assertFalse(r["can_edit"])

    def _act(self, client, *args):
        with patch.object(turns, "connect", lambda home: Ctx(client)):
            return asyncio.run(turns._queue_action(Path("/tmp"), "default", "s1", *args))

    def test_edit_repoints_the_follower(self):
        client = FakeClient([snap(RUNNING, QUEUED), snap(RUNNING, {**QUEUED, "admission_id": "a3", "text": "fixed"})],
                            {"prompt.replace_queued": {"status": "queued", "admission_id": "a3"}})
        follower = turns.Turn("default", Path("/tmp"), "s1", "second", {})
        follower.admission = "a2"
        with turns.TURNS_LOCK:
            turns.TURNS[follower.id] = follower
        try:
            out = self._act(client, "a2", "edit", "  fixed ", "0" * 32)
        finally:
            with turns.TURNS_LOCK:
                turns.TURNS.pop(follower.id, None)
        self.assertEqual(out["admission_id"], "a3")
        self.assertEqual((follower.admission, follower.text), ("a3", "fixed"))
        method, params = client.calls[1]
        self.assertEqual(method, "prompt.replace_queued")
        self.assertEqual((params["session_id"], params["text"]), ("canon", "fixed"))

    def test_resolve_uses_the_lost_rows_generation(self):
        client = FakeClient([snap(LOST, QUEUED), snap({**QUEUED, "status": "started"})],
                            {"prompt.resolve_unknown": {"status": "terminal", "outcome": "interrupted"}})
        out = self._act(client, "a1", "resolve")
        self.assertEqual(client.calls[1], ("prompt.resolve_unknown",
                                           {"session_id": "canon", "admission_id": "a1", "execution_generation": 3}))
        self.assertFalse(out["queue"]["paused"])

    def test_cancel_retires_the_follower(self):
        client = FakeClient([snap(RUNNING, QUEUED), snap(RUNNING)],
                            {"prompt.cancel": {"status": "terminal", "outcome": "cancelled"}})
        follower = turns.Turn("default", Path("/tmp"), "s1", "second", {})
        follower.admission = "a2"
        with turns.TURNS_LOCK:
            turns.TURNS[follower.id] = follower
        try:
            self._act(client, "a2", "cancel")
        finally:
            with turns.TURNS_LOCK:
                turns.TURNS.pop(follower.id, None)
        self.assertTrue(follower.retired and follower.done)

    def test_refusal_becomes_plain_words(self):
        client = FakeClient([snap(RUNNING, QUEUED)],
                            {"prompt.replace_queued": turns.TurnError("prompt.replace_queued: admission_started")})
        with self.assertRaises(turns.TurnError) as ctx:
            self._act(client, "a2", "edit", "x", "1" * 32)
        self.assertEqual(ctx.exception.code, 409)
        self.assertIn("already started", str(ctx.exception))

    def test_unknown_admission_is_404(self):
        client = FakeClient([snap(RUNNING)], {})
        with self.assertRaises(turns.TurnError) as ctx:
            self._act(client, "zz", "cancel")
        self.assertEqual(ctx.exception.code, 404)


class QueuedTurnSurvivesGatewayRestart(unittest.TestCase):
    def test_queued_follow_up_reconnects_instead_of_failing(self):
        t = turns.Turn("default", Path("/tmp"), "s1", "second", {})
        t.admission = "a2"          # a queued admission: durable in the gateway's state.db
        calls = []

        async def flaky(turn):
            calls.append(1)
            if len(calls) == 1:
                raise ConnectionError("gateway restarted")
            turn.push("run.completed", output="done", outcome="completed")

        async def no_sleep(_):
            return None

        with patch.object(turns, "_drive_connection", flaky), patch.object(turns.asyncio, "sleep", no_sleep):
            asyncio.run(turns._drive(t))
        self.assertEqual(len(calls), 2, "it must reconnect, not give up")
        self.assertTrue(t.done)
        self.assertEqual(t._terminal["event"], "run.completed")

    def test_unqueued_unjournaled_turn_still_fails_fast(self):
        t = turns.Turn("default", Path("/tmp"), "s1", "x", {})

        async def dead(turn):
            raise ConnectionError("gone")

        with patch.object(turns, "_drive_connection", dead):
            asyncio.run(turns._drive(t))
        self.assertTrue(t.done)
        self.assertEqual(t._terminal["event"], "run.failed")

    def test_retired_turn_stops_reconnecting(self):
        t = turns.Turn("default", Path("/tmp"), "s1", "x", {})
        t.admission = "a9"; t.retired = True
        calls = []

        async def dead(turn):
            calls.append(1)
            raise ConnectionError("gone")

        with patch.object(turns, "_drive_connection", dead):
            asyncio.run(turns._drive(t))
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
