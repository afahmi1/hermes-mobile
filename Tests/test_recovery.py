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

    def test_stop_cannot_interrupt_another_execution_before_admission(self):
        self.turn.admission = None
        rpc = AsyncMock()
        with patch.object(engine, "_rpc", rpc), self.assertRaises(engine.TurnError):
            asyncio.run(engine._interrupt(self.turn))
        rpc.assert_not_called()

    def test_stop_never_borrows_the_session_execution_generation(self):
        self.turn.client = object()
        self.turn.generation = None
        rpc = AsyncMock()
        with patch.object(engine, "_resume", AsyncMock(return_value={"execution_generation": 99, "pending": []})), patch.object(engine, "_rpc", rpc), self.assertRaises(engine.TurnError):
            asyncio.run(engine._interrupt(self.turn))
        rpc.assert_not_called()

    def test_stop_cancels_its_own_queued_admission(self):
        self.turn.client = object()
        rpc = AsyncMock()
        with patch.object(engine, "_resume", AsyncMock(return_value={"execution_generation": 99, "pending": [{"admission_id": "admission", "status": "queued"}]})), patch.object(engine, "_rpc", rpc):
            asyncio.run(engine._interrupt(self.turn))
        self.assertEqual(rpc.call_args.args[1], "prompt.cancel")
        self.assertEqual(rpc.call_args.kwargs["admission_id"], "admission")

    def test_receipt_outcomes(self):
        cases = [("completed", "run.completed"), ("interrupted", "run.cancelled"),
                 ("failed", "run.failed"), ("unknown", "run.failed"), (None, "run.failed")]
        for outcome, event in cases:
            with self.subTest(outcome=outcome):
                self.assertTrue(self.recover({"status": "terminal", "outcome": outcome}))
                self.assertEqual(self.turn.events[-1]["event"], event)

    def test_fallback_keeps_policy_and_usage_separate(self):
        self.turn.choice = {"model":"selected", "provider":"policy-provider"}
        engine._record_runtime(self.turn,{"model":"selected","provider":"old"})
        engine._settle(self.turn,{"status":"complete","usage":{"model":"selected","fallback_model":"served"}})
        receipt = self.turn.events[-1]
        self.assertEqual(receipt["requested_model"],"selected")
        self.assertEqual(receipt["runtime"],{"model":"served","fallback":True})

    def test_native_receipt_reports_actual_provider_and_model(self):
        engine._settle(self.turn,{"outcome":"completed", "model":"actual", "provider":"served-provider"})
        self.assertEqual(self.turn.events[-1]["runtime"], {"model":"actual", "provider":"served-provider"})

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
            self.assertEqual(result, {"status": "queued", "turn_id": queued.id, "attachments": 0, "admission_id": None})
            rpc.assert_not_awaited()
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "queue", "different", queued.submission)

    async def test_queued_runtime_is_frozen_at_admission_and_exact_retry_does_not_submit(self):
        from uuid import uuid4
        turn = engine.Turn("default", Path("."), "chat", "first", {"model":"current"})
        turn.client, turn.generation = object(), 5
        request = uuid4().hex
        pick = dict(model="next-model", provider="relay", effort="low")
        with patch.dict(engine.TURNS, {turn.id:turn}, clear=True), patch.object(engine, "_drive", AsyncMock()), \
                patch.object(engine, "_rpc", AsyncMock(return_value={"status":"queued","admission_id":"new"})) as rpc:
            receipt = await engine._follow_up(turn,"queue","next",request,pick)
            rpc.assert_awaited_once_with(turn.client,"prompt.submit",session_id="chat",text="next",
                                         submission_id=request,model_override={"model":"next-model","provider":"relay","reasoning":"low"})
            self.assertEqual(engine.TURNS[receipt["turn_id"]].choice, pick)
            self.assertEqual(turn.choice, {"model":"current"})
            self.assertEqual(await engine._follow_up(turn,"queue","next",request,pick),receipt)
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn,"queue","next",request,{"model":"another"})
            self.assertEqual(rpc.await_count,1)

    async def test_busy_model_and_effort_share_one_native_mutation_receipt(self):
        with patch.object(engine, "_mutate", AsyncMock(return_value={"status":"deferred"})) as mutate:
            result = await engine._apply(None,"chat",{"model":"new","provider":"p","effort":"high"})
            mutate.assert_awaited_once_with(None,"chat","model",{"model":"new","provider":"p","reasoning":"high"},ask=False)
            self.assertEqual(result["model"]["status"],"deferred")

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
