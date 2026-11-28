"""A chat's own model never blocks a send.

The phone re-sends a chat's pick (provider, model, effort) with every message. The bridge used to re-apply it with
``session.mutate`` each time, and Hermes resolves the model's credentials afresh for that: while the ChatGPT/Codex
plan behind it is in a quota cooldown (HTTP 429, "credentials are still valid"), Hermes refuses even the chat's
current model with ``model_resolution_failed`` and the whole send failed with "Hermes refused this request.
(session.mutate: model_resolution_failed)". A turn without the pick runs and falls back on its own.
"""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import asyncio
import http.client
import importlib
import io
import json
import os
import sqlite3
import sys
import threading
import unittest
import uuid
from contextlib import asynccontextmanager, closing
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory, mkdtemp
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as engine

# What the phone sent from Abduel's trading chat ("GPT 6.2 Astra · High"): exactly the bot's own setting.
PICK = {"provider": "openai-codex", "model": "gpt-6.2-Astra", "effort": "high"}


HERMES_POLICY_KEY = "gateway.local_policy.v1:"  # persistence/sqlite/conversation/_store/local.py POLICY_PREFIX


def write_policy(home, sid, model, provider, effort=None, *, config=None, request=None, source="gui", agent=None):
    """A state.db holding one chat's route record, shaped like Hermes's own (``gateway.local_policy.v1:<sid>``)."""
    frozen = {"model": {"default": model, "provider": provider, "base_url": "https://chatgpt.com/backend-api/codex"}}
    if effort is not None or agent:
        frozen["agent"] = {**({"reasoning_effort": effort} if effort is not None else {}), **(agent or {})}
    frozen.update(config or {})
    policy = {"model": model, "source": source, "platform": "desktop", "config_json": json.dumps(frozen),
              "request_json": json.dumps(request or {"source": source})}
    with closing(sqlite3.connect(Path(home) / "state.db")) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS state_meta(key TEXT PRIMARY KEY, value TEXT)")
        db.execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, model TEXT, billing_provider TEXT, "
                   "model_config TEXT, reasoning_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER, "
                   "api_call_count INTEGER, last_activity_at REAL, started_at REAL)")
        db.execute("INSERT OR REPLACE INTO state_meta VALUES (?, ?)",
                   (HERMES_POLICY_KEY + sid, json.dumps({"session_id": sid, "policy": policy})))


class Gateway:
    """The session protocol as the turn engine drives it. ``resolvable=False`` is Hermes during a plan's quota
    cooldown: every ``model`` mutation is refused (prepare_model: switch_model(...).success is False), while
    ``reasoning`` mutations and turns still go through."""

    def __init__(self, resolvable=True, lose_first_ack=False):
        self.resolvable, self.lose_first_ack = resolvable, lose_first_ack
        self.calls = []

    @asynccontextmanager
    async def connect(self, _home):
        yield self

    async def rpc(self, client, method, **params):
        self.calls.append((method, params))
        if method == "session.resume":
            return {"session_id": "chat", "stored_session_id": "chat", "revision": 7,
                    "execution_generation": 1, "pending": []}
        if method == "session.mutate":
            if params["operation"] == "model" and not self.resolvable:
                raise engine.TurnError(engine.refusal_text(method, "model_resolution_failed"))
            return {"session_id": "chat", "operation": params["operation"], "revision": 8}
        if method == "prompt.submit":
            if self.lose_first_ack:
                self.lose_first_ack = False
                raise ConnectionError("socket lost after admission")
            return {"admission_id": "admission", "status": "terminal", "execution_generation": 2}
        if method == "prompt.receipt":
            return {"admission_id": "admission", "status": "terminal", "outcome": "completed",
                    "result": {"final_response": "done"}}
        raise AssertionError("unexpected %s" % method)

    def sent(self, method, operation=None):
        return [p for m, p in self.calls if m == method and (operation is None or p.get("operation") == operation)]


class SessionSettingTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(self.enterContext(TemporaryDirectory()))

    def test_reads_the_route_hermes_committed(self):
        write_policy(self.home, "chat", "gpt-6.2-Astra", "openai-codex", "high")
        self.assertEqual(engine._session_setting(self.home, "chat"),
                         {"model": "gpt-6.2-Astra", "provider": "openai-codex", "effort": "high"})

    def test_the_record_key_is_hermes_own(self):
        self.assertEqual(engine.POLICY_KEY, HERMES_POLICY_KEY)
        try:
            from persistence.sqlite.conversation._store.local import POLICY_PREFIX
        except ImportError:
            self.skipTest("Hermes's persistence package isn't importable from this interpreter")
        self.assertEqual(engine.POLICY_KEY, POLICY_PREFIX)

    def test_falls_back_to_the_stored_id_and_is_unknown_without_a_record(self):
        write_policy(self.home, "stored", "deepseek-v4-flash", "deepseek")
        self.assertEqual(engine._session_setting(self.home, "canonical", "stored")["model"], "deepseek-v4-flash")
        self.assertIsNone(engine._session_setting(self.home, "elsewhere"))
        self.assertIsNone(engine._session_setting(self.home / "no-such-profile", "stored"))

    def test_only_hermes_can_tell_for_chats_that_follow_their_profile(self):
        write_policy(self.home, "a", "m", "p", request={"follow_profile_config": True})
        write_policy(self.home, "b", "m", "p", config={"follow_adopted": True})
        write_policy(self.home, "c", "m", "p", source="bot_room")
        for sid in "abc":
            self.assertIsNone(engine._session_setting(self.home, sid), sid)

    def test_a_per_model_default_leaves_the_effort_unknown(self):
        write_policy(self.home, "chat", "m", "p", "high", agent={"reasoning_overrides": {"m": "low"}})
        self.assertIsNone(engine._session_setting(self.home, "chat")["effort"])

    def test_a_damaged_record_is_unknown(self):
        write_policy(self.home, "chat", "m", "p")
        with closing(sqlite3.connect(self.home / "state.db")) as db, db:
            db.execute("UPDATE state_meta SET value='[1, 2'")
        self.assertIsNone(engine._session_setting(self.home, "chat"))

    def test_only_the_changed_part_of_a_pick_stands(self):
        setting = {"model": "gpt-6.2-Astra", "provider": "openai-codex", "effort": "high"}
        self.assertEqual(engine._real_change(PICK, setting), {})
        self.assertEqual(engine._real_change({"model": "gpt-6.2-Astra", "effort": "high"}, setting), {})
        self.assertEqual(engine._real_change(dict(PICK, effort="low"), setting), {"effort": "low"})
        self.assertEqual(engine._real_change(dict(PICK, model="gpt-6.1-sol"), setting),
                         {"provider": "openai-codex", "model": "gpt-6.1-sol"})
        self.assertEqual(engine._real_change(dict(PICK, provider="openrouter"), setting),
                         {"provider": "openrouter", "model": "gpt-6.2-Astra"})
        # A respelled id is a real change (Hermes's catalogs key it lower case): the pick can repair the chat.
        self.assertEqual(engine._real_change(dict(PICK, model="gpt-6.2-astra"), setting),
                         {"provider": "openai-codex", "model": "gpt-6.2-astra"})
        self.assertEqual(engine._real_change(PICK, None), PICK)
        self.assertEqual(engine._real_change(PICK, dict(setting, effort=None)), {"effort": "high"})

    def test_the_refusal_reads_as_a_sentence_and_keeps_its_code(self):
        text = engine.refusal_text("session.mutate", "model_resolution_failed")
        self.assertTrue(text.startswith("Hermes couldn't switch to that model right now."), text)
        self.assertTrue(text.endswith("(session.mutate: model_resolution_failed)"), text)
        self.assertTrue(engine._unresolvable(engine.TurnError(text)))
        self.assertFalse(engine._unresolvable(engine.TurnError(engine.refusal_text("session.mutate", "session_busy"))))


class SendTests(unittest.TestCase):
    """Journaled sends (the phone's send-once) driven end to end against the fake gateway."""

    def setUp(self):
        self.home = Path(self.enterContext(TemporaryDirectory()))
        self.directory = Path(self.enterContext(TemporaryDirectory()))
        self.enterContext(patch.dict(engine.TURNS, clear=True))
        self.enterContext(patch.object(engine.asyncio, "run_coroutine_threadsafe",
                                       side_effect=lambda coro, loop: coro.close()))
        self.stderr = self.enterContext(patch.object(sys, "stderr", io.StringIO()))
        engine.primary_journal.cache_clear()
        self.submission = uuid.uuid4().hex

    def send(self, gateway, choice=PICK):
        turn = engine.start_primary("trading", self.home, "chat", "hello", choice, self.submission, None,
                                    self.directory, lambda: None, lambda *a: None)
        with patch.object(engine, "connect", gateway.connect), patch.object(engine, "_rpc", gateway.rpc):
            asyncio.run(engine._drive(turn))
        return turn

    def events(self, turn, name):
        return [e for e in turn.events if e["event"] == name]

    def test_the_chats_own_model_sends_during_a_quota_cooldown(self):
        write_policy(self.home, "chat", "gpt-6.2-Astra", "openai-codex", "high")
        gateway = Gateway(resolvable=False)
        turn = self.send(gateway)
        self.assertEqual(turn._terminal, {"event": "run.completed", "error": ""})
        self.assertEqual(gateway.sent("session.mutate"), [])  # nothing to change, nothing re-resolved
        self.assertNotIn("model_override", gateway.sent("prompt.submit")[0])
        self.assertEqual(self.events(turn, "notice"), [])

    def test_an_unresolvable_change_still_sends_on_the_chats_model(self):
        write_policy(self.home, "chat", "gpt-6.2-astra", "openai-codex", "high")
        gateway = Gateway(resolvable=False)
        turn = self.send(gateway, dict(PICK, model="gpt-6.1-sol"))
        self.assertEqual(turn._terminal["event"], "run.completed")
        self.assertEqual(len(gateway.sent("session.mutate", "model")), 1)
        self.assertNotIn("model_override", gateway.sent("prompt.submit")[0])
        notice, = self.events(turn, "notice")
        self.assertIn("gpt-6.1-sol", notice["text"])
        self.assertNotIn("refused", notice["text"])
        self.assertIn("model_resolution_failed", self.stderr.getvalue())
        self.assertEqual(json.loads(engine.primary_journal(self.directory).get(turn.id)["runtime"]), {})

    def test_a_change_hermes_resolves_still_switches_and_rides_the_turn(self):
        write_policy(self.home, "chat", "gpt-6.2-astra", "openai-codex", "high")
        gateway = Gateway()
        turn = self.send(gateway, dict(PICK, model="gpt-6.1-sol", effort="xhigh"))
        self.assertEqual(turn._terminal["event"], "run.completed")
        mutate, = gateway.sent("session.mutate")
        self.assertEqual(mutate["payload"], {"model": "gpt-6.1-sol", "provider": "openai-codex", "reasoning": "xhigh"})
        self.assertEqual(gateway.sent("prompt.submit")[0]["model_override"],
                         {"model": "gpt-6.1-sol", "provider": "openai-codex", "reasoning": "xhigh"})

    def test_a_new_effort_on_the_chats_model_needs_no_model_resolution(self):
        write_policy(self.home, "chat", "gpt-6.2-Astra", "openai-codex", "medium")
        gateway = Gateway(resolvable=False)
        turn = self.send(gateway)
        self.assertEqual(turn._terminal["event"], "run.completed")
        self.assertEqual(gateway.sent("session.mutate", "model"), [])
        reasoning, = gateway.sent("session.mutate", "reasoning")
        self.assertEqual(reasoning["payload"], {"effort": "high"})
        self.assertNotIn("model_override", gateway.sent("prompt.submit")[0])

    def test_an_unknown_setting_keeps_the_old_path_and_never_blocks(self):
        gateway = Gateway(resolvable=False)  # no state.db: a messaging chat, or Hermes moved its records
        turn = self.send(gateway)
        self.assertEqual(turn._terminal["event"], "run.completed")
        self.assertEqual(len(gateway.sent("session.mutate", "model")), 1)
        self.assertNotIn("model_override", gateway.sent("prompt.submit")[0])

    def test_other_refusals_still_fail_the_send(self):
        write_policy(self.home, "chat", "gpt-6.2-astra", "openai-codex")
        gateway = Gateway()

        async def busy(client, method, **params):
            if method == "session.mutate":
                raise engine.TurnError(engine.refusal_text(method, "permission_denied"), 400)
            return await gateway.rpc(client, method, **params)
        turn = engine.start_primary("trading", self.home, "chat", "hello", dict(PICK, model="gpt-6.1-sol"),
                                    self.submission, None, self.directory, lambda: None, lambda *a: None)
        with patch.object(engine, "connect", gateway.connect), patch.object(engine, "_rpc", busy):
            asyncio.run(engine._drive(turn))
        self.assertEqual(turn._terminal["event"], "run.failed")
        self.assertIn("permission_denied", turn._terminal["error"])

    def test_a_recovered_send_repeats_its_first_submit(self):
        write_policy(self.home, "chat", "gpt-6.2-Astra", "openai-codex", "high")
        gateway = Gateway(resolvable=False, lose_first_ack=True)
        first = engine.start_primary("trading", self.home, "chat", "hello", PICK, self.submission, None,
                                     self.directory, lambda: None, lambda *a: None)
        with patch.object(engine, "connect", gateway.connect), patch.object(engine, "_rpc", gateway.rpc):
            with self.assertRaises(ConnectionError):
                asyncio.run(engine._drive_connection(first))
            engine.TURNS.clear()  # the bridge restarts before Hermes's receipt is recorded
            # Meanwhile the chat's record changed: the restored send must not re-decide its route.
            write_policy(self.home, "chat", "gpt-6.1-sol", "openai-codex", "high")
            restored = engine.start_primary("trading", self.home, "chat", "hello", PICK, self.submission, None,
                                            self.directory, lambda: None, lambda *a: None)
            self.assertEqual(restored.runtime, {})
            asyncio.run(engine._drive(restored))
        first_submit, retry = gateway.sent("prompt.submit")
        self.assertEqual(first_submit, retry)
        self.assertEqual(restored._terminal["event"], "run.completed")
        self.assertEqual(gateway.sent("session.mutate"), [])

    def test_receipts_from_older_bridges_keep_deriving_the_override(self):
        turn = engine.Turn("trading", self.home, "chat", "", dict(PICK))
        turn.id = "turn_" + self.submission
        journal = engine.primary_journal(self.directory)
        journal.create(turn, "digest", "hello")
        with closing(journal.open()) as db, db:  # a row an older bridge prepared: no runtime recorded
            db.execute("UPDATE receipts SET canonical='chat' WHERE id=?", (turn.id,))
        restored = engine.restored_turn(journal.get(turn.id), self.home, journal, None)
        self.assertIsNone(restored.runtime)
        self.assertEqual(engine._admission_runtime(restored.choice)["model_override"]["model"], "gpt-6.2-Astra")


class PickerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.home = Path(self.enterContext(TemporaryDirectory()))

    async def pick(self, gateway, choice, ask=True):
        with patch.object(engine, "connect", gateway.connect), patch.object(engine, "_rpc", gateway.rpc):
            return await engine._set_runtime(self.home, "chat", choice, ask)

    async def test_picking_the_chats_own_model_writes_nothing(self):
        write_policy(self.home, "chat", "gpt-6.2-Astra", "openai-codex", "high")
        gateway = Gateway(resolvable=False)
        self.assertEqual(await self.pick(gateway, PICK), {})
        self.assertEqual(gateway.calls, [])

    async def test_an_unresolvable_pick_waits_for_the_next_send(self):
        write_policy(self.home, "chat", "gpt-6.2-astra", "openai-codex", "high")
        gateway = Gateway(resolvable=False)
        self.assertEqual(await self.pick(gateway, dict(PICK, model="gpt-6.1-sol")), {"model": {"status": "next_send"}})

    async def test_a_reset_hermes_refuses_still_says_so(self):
        write_policy(self.home, "chat", "gpt-6.1-sol", "openai-codex")
        with self.assertRaises(engine.TurnError) as refused:
            await self.pick(Gateway(resolvable=False), {"reset_model": True})
        self.assertIn("Hermes couldn't switch to that model right now", str(refused.exception))


class QueueTests(unittest.IsolatedAsyncioTestCase):
    async def queue(self, setting, choice):
        home = Path(self.enterContext(TemporaryDirectory()))
        if setting:
            write_policy(home, "chat", *setting)
        turn = engine.Turn("trading", home, "chat", "first", dict(PICK))
        turn.client, turn.generation = object(), 5
        gateway = Gateway()
        with patch.dict(engine.TURNS, {turn.id: turn}, clear=True), patch.object(engine, "_drive", lambda t: asyncio.sleep(0)), \
                patch.object(engine, "_rpc", gateway.rpc):
            await engine._follow_up(turn, "queue", "next", uuid.uuid4().hex, choice)
        submit, = gateway.sent("prompt.submit")
        return submit

    async def test_a_queued_message_on_the_chats_own_pick_carries_no_override(self):
        submit = await self.queue(("gpt-6.2-Astra", "openai-codex", "high"), PICK)
        self.assertNotIn("model_override", submit)

    async def test_a_queued_message_with_a_different_pick_keeps_it(self):
        submit = await self.queue(("gpt-6.2-astra", "openai-codex", "high"), dict(PICK, model="gpt-6.1-sol"))
        self.assertEqual(submit["model_override"], {"model": "gpt-6.1-sol", "provider": "openai-codex", "reasoning": "high"})
        self.assertEqual((await self.queue(None, PICK))["model_override"]["model"], "gpt-6.2-Astra")


class RuntimeRouteTests(unittest.TestCase):
    """POST /m/chat/<bot>/<chat>/runtime, the phone's model picker."""

    @classmethod
    def setUpClass(cls):
        cls.hermes = Path(mkdtemp(prefix="bridge-model-home-")).resolve()
        (cls.hermes / ".env").write_text("API_SERVER_KEY=k-default\n")
        with patch.dict(os.environ, HERMES_HOME=str(cls.hermes)):
            cls.bridge = importlib.import_module("hermes_mobile_bridge")

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.hermes, ignore_errors=True)

    def setUp(self):
        bridge = self.bridge
        state = Path(self.enterContext(TemporaryDirectory(prefix="model-state-"))).resolve()
        self.enterContext(patch.object(bridge, "HERMES", self.hermes))
        self.enterContext(patch.object(bridge, "STATE_DIR", state))
        self.enterContext(patch.object(sys, "stderr", io.StringIO()))
        self.gateway = Gateway(resolvable=False)
        self.enterContext(patch.object(bridge.turns, "connect", self.gateway.connect))
        self.enterContext(patch.object(bridge.turns, "_rpc", self.gateway.rpc))
        self.token = bridge.make_token("t", owner=True)
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), bridge.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)

    def post(self, body):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        c.request("POST", "/m/chat/default/chat/runtime", body=json.dumps(body).encode(),
                  headers={"Authorization": "Bearer " + self.token})
        r = c.getresponse()
        raw = r.read()
        c.close()
        return r.status, json.loads(raw)

    def test_picker_never_shows_the_refusal(self):
        write_policy(self.hermes, "chat", "gpt-6.2-Astra", "openai-codex", "high")
        status, body = self.post(PICK)
        self.assertEqual((status, body["timing"]), (200, "saved"))
        status, body = self.post(dict(PICK, model="gpt-6.1-sol"))
        self.assertEqual((status, body["timing"]), (200, "next_turn"))
        self.assertNotIn("refused", json.dumps(body))


if __name__ == "__main__":
    unittest.main()
