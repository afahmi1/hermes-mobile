import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as engine


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.turn = engine.Turn("default", Path("."), "session", "", {})
        self.turn.admission = "admission"

    def recover(self, receipt):
        rpc = AsyncMock(side_effect=[{"pending": []}, receipt])
        with patch.object(engine, "_rpc", rpc):
            return asyncio.run(engine._recover_gap(None, self.turn))

    def test_receipt_outcomes(self):
        cases = [("completed", "run.completed"), ("interrupted", "run.cancelled"),
                 ("failed", "run.failed"), ("unknown", "run.failed"), (None, "run.failed")]
        for outcome, event in cases:
            with self.subTest(outcome=outcome):
                self.assertTrue(self.recover({"status": "terminal", "outcome": outcome}))
                self.assertEqual(self.turn.events[-1]["event"], event)

    def test_receipt_still_running(self):
        self.assertFalse(self.recover({"status": "started"}))
        self.assertEqual(self.turn.events, [])

    def test_unconfirmed_completion(self):
        for fields in [{}, {"status": "complete", "outcome": "unknown"},
                       {"status": "error", "outcome": "completed"}]:
            engine._settle(self.turn, fields)
            self.assertEqual(self.turn.events[-1]["event"], "run.failed")


class GatewayCompatibilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_supported_gateway_signatures(self):
        from contextlib import asynccontextmanager
        from types import ModuleType

        @asynccontextmanager
        async def previous(endpoint):
            yield endpoint, None

        @asynccontextmanager
        async def current(endpoint, *, max_size):
            yield endpoint, max_size

        for connector, expected in [(previous, None), (current, 64 * 1024 * 1024)]:
            module = ModuleType("hermes_cli.gateway_client")
            module.connect_gateway = connector
            with patch.dict(sys.modules, {"hermes_cli": ModuleType("hermes_cli"), module.__name__: module}), \
                 patch.object(engine, "_endpoint", return_value="local"):
                async with engine.connect(Path(".")) as connection:
                    self.assertEqual(connection, ("local", expected))


class FollowUpTests(unittest.IsolatedAsyncioTestCase):
    async def test_steer_rejection_keeps_failure_visible(self):
        turn = engine.Turn("default", Path("."), "chat", "", {})
        turn.client = object()
        turn.generation = 17
        rpc = AsyncMock(return_value={"status": "rejected"})
        with patch.object(engine, "_rpc", rpc), self.assertRaises(engine.TurnError):
            await engine._follow_up(turn, "steer", "change direction", None)
        rpc.assert_awaited_once_with(turn.client, "session.steer", session_id="chat",
                                     execution_generation=17, text="change direction")

    async def test_queue_retry_returns_existing_receipt(self):
        from uuid import uuid4
        turn = engine.Turn("default", Path("."), "chat", "", {})
        queued = engine.Turn("default", Path("."), "chat", "next", {})
        queued.submission = uuid4().hex
        with patch.dict(engine.TURNS, {queued.id: queued}, clear=True), patch.object(engine, "_rpc", AsyncMock()) as rpc:
            result = await engine._follow_up(turn, "queue", "next", queued.submission)
            self.assertEqual(result, {"status": "queued", "turn_id": queued.id})
            rpc.assert_not_awaited()
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "queue", "different", queued.submission)

    async def test_simultaneous_steers_share_the_gateway_ack(self):
        import asyncio
        from uuid import uuid4
        turn = engine.Turn("default", Path("."), "chat", "", {})
        turn.client, turn.generation = object(), 3
        submission = uuid4().hex
        with patch.object(engine, "_rpc", AsyncMock(return_value={"status":"queued"})) as rpc:
            a,b = await asyncio.gather(*(engine._follow_up(turn, "steer","guide",submission) for _ in range(2)))
            self.assertEqual(a,b)
            self.assertEqual(a["execution_generation"],3)
            self.assertEqual(rpc.await_count,1)
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "steer","changed",submission)
