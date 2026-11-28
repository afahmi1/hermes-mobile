import json
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Status"))
import hermes_status_server as status_server
from hermes_status_server import parse_auth_list


class RunningAgentTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (self.home / "runtime").mkdir()
        self.enterContext(patch.object(status_server, "HOME", self.home))
        self.db = self.enterContext(closing(sqlite3.connect(self.home / "state.db")))
        self.db.executescript("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, session_key TEXT, source TEXT, title TEXT,
                model TEXT, billing_provider TEXT, model_config TEXT, parent_session_id TEXT,
                end_reason TEXT, ended_at REAL, started_at REAL, last_activity_at REAL, message_count INT);
            CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT);
            CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT,
                task TEXT, last_seen REAL);
        """)
        self.now = time.time()

    def session(self, sid, *, key=None, title=None, source="local", parent=None, ended=None,
                model="openai/base", provider="openai", config=None, start=None):
        self.db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (sid, key, source, title, model, provider, json.dumps(config), parent, ended,
                         self.now if ended else None, start or self.now, self.now, 2))

    def message(self, sid, content, role="user"):
        self.db.execute("INSERT INTO messages (session_id, role, content) VALUES (?,?,?)", (sid, role, content))

    def running(self, sid=None, *, surface="desktop", jobs=None, **metadata):
        if sid is not None:
            lease = {"session_id": sid, "surface": surface, "metadata": metadata, "started_at": self.now}
            (self.home / "runtime" / "active_sessions.json").write_text(json.dumps({"entries": [lease]}))
        self.db.commit()
        return status_server.agents_status(jobs or {})

    def test_desktop_live_id_wins_over_older_row_sharing_lease_key(self):
        key = "agent:main:local:dm:local-route"
        self.session("previous", key=key, title="Previous chat", start=self.now - 10)
        self.session("stored-id", title="Actual chat")
        [chat] = self.running(key, live_session_id="stored-id")
        self.assertEqual((chat["session_id"], chat["title"]), ("stored-id", "Actual chat"))

    def test_gateway_key_and_untitled_compression_child_use_parent_title(self):
        key = "agent:main:bluebubbles:dm:42"
        self.session("root", key=key, title="Quarterly notes", source="bluebubbles",
                     ended="compression", start=self.now - 20)
        self.session("middle", title=" ", parent="root", ended="compression", start=self.now - 10)
        self.session("child", key=key, parent="middle", source="bluebubbles")
        [chat] = self.running(key, surface="gateway:bluebubbles", platform="bluebubbles", chat_id="42")
        self.assertEqual((chat["session_id"], chat["title"], chat["source_label"]),
                         ("child", "Quarterly notes", "iMessage"))

    def test_untitled_branch_uses_first_user_message_not_original_chat(self):
        self.session("original", title="Unrelated branch root")
        self.session("branch", title="  ", parent="original")
        self.message("branch", "Ignore this", role="assistant")
        self.message("branch", "  Compare\n the two schedules. ")
        self.message("branch", "Not the first request")
        [chat] = self.running("branch")
        self.assertEqual(chat["title"], "Compare the two schedules.")

    def test_missing_chat_uses_surface_and_default_model(self):
        (self.home / "config.yaml").write_text("model:\n  default: anthropic/sonnet\n  provider: anthropic\n")
        [chat] = self.running("missing")
        self.assertIsNone(chat["session_id"])
        self.assertEqual((chat["title"], chat["model"], chat["provider"]),
                         ("Desktop chat", "anthropic/sonnet", "anthropic"))

    def test_live_model_prefers_lease_then_current_chat_usage_not_title_generator(self):
        self.session("chat", config={"gateway_runtime": {"model": "runtime", "provider": "route"}})
        self.db.executemany("INSERT INTO session_model_usage VALUES (?,?,?,?,?)", [
            ("chat", "actual", "actual-provider", "", self.now + 1),
            ("chat", "aux", "aux-provider", "title_generation", self.now + 2),
        ])
        [chat] = self.running("chat", model="override", provider="override-provider")
        self.assertEqual((chat["model"], chat["provider"]), ("override", "override-provider"))
        [chat] = self.running("chat")
        self.assertEqual((chat["model"], chat["provider"]), ("actual", "actual-provider"))

    def test_nested_subagents_resolve_the_chat_and_keep_their_own_goals(self):
        self.session("root", title="Plan the release", ended="compression")
        self.session("child", parent="root")
        self.session("worker", source="subagent", title="Subagent: Run checks", parent="child")
        self.session("nested", source="subagent", parent="worker", model="test/worker", provider="test")
        self.message("nested", "Verify the simulator build.")
        agents = {a["session_id"]: a for a in self.running()}
        self.assertEqual(agents["worker"]["title"], "Run checks")
        self.assertEqual((agents["nested"]["kind"], agents["nested"]["title"], agents["nested"]["parent_title"],
                          agents["nested"]["model"], agents["nested"]["provider"]),
                         ("subagent", "Verify the simulator build.", "Plan the release", "test/worker", "test"))

    def test_phone_turn_without_a_lease_uses_the_same_chat_title_and_model(self):
        from bridge_agent_status import with_phone_turns

        self.session("phone-session", title="Phone planning",
                     config={"gateway_runtime": {"model": "routed", "provider": "provider"}})
        self.db.execute("INSERT INTO session_model_usage VALUES (?,?,?,?,?)",
                        ("phone-session", "older-route", "older", "", self.now - 10))
        payload = {"agents": self.running(), "bots": [{"id": "default"}]}
        turn = {"profile": "default", "session_id": "phone-session", "done": False, "age": 5,
                "started_at": self.now}
        [phone] = with_phone_turns(payload, [turn, turn], lambda _: self.home)["agents"]
        self.assertEqual((phone["kind"], phone["title"], phone["model"], phone["provider"], phone["source_label"]),
                         ("phone", "Phone planning", "routed", "provider", "Phone"))
        self.assertEqual(payload["bots"][0]["running"], 1)

    def test_untitled_cli_with_no_messages_uses_surface(self):
        self.session("cli-id", source="cli")
        [chat] = self.running("cli-id", surface="cli")
        self.assertEqual(chat["title"], "CLI")

    def test_compression_title_fallback_uses_root_user_text(self):
        self.session("root", ended="compression")
        self.session("child", parent="root")
        self.message("root", "\t \n")
        self.message("root", "Find the best checklist.")
        self.message("child", "[Conversation summary]")
        [chat] = self.running("child")
        self.assertEqual(chat["title"], "Find the best checklist.")

    def test_cron_uses_configured_job_model(self):
        job = {"profile": "default", "id": "job", "model": "test/cron", "provider": "test"}
        [cron] = self.running(jobs={"jobs": [job], "live": [{"profile": "default", "job_id": "job"}]})
        self.assertEqual((cron["kind"], cron["model"], cron["provider"]), ("cron", "test/cron", "test"))


class ProviderTests(unittest.TestCase):
    def test_platform_report_from_previous_process_is_not_a_live_incident(self):
        from hermes_status_server import prior_platform_observation
        lifecycle = {"pid": 3, "phase": "running", "started_at": "2026-11-23T12:00:00+00:00"}
        stale = {"updated_at": "2026-04-28T12:00:00+00:00", "state": "retrying"}
        fresh = dict(stale, updated_at="2026-11-23T12:01:00+00:00")
        self.assertTrue(prior_platform_observation(stale, lifecycle, 3))
        self.assertFalse(prior_platform_observation(fresh, lifecycle, 3))
        self.assertFalse(prior_platform_observation(stale, lifecycle, 4))
        self.assertFalse(prior_platform_observation({}, lifecycle, 3))

    def test_labels_with_spaces_count_towards_the_pool(self):
        rows = ["openrouter (12 credentials):"]
        for i in range(12):
            rows.append(f"  #{i} Integration key {i} api_key id=fixture{i} priority={i}")
        self.assertEqual(len(parse_auth_list("\n".join(rows))["openrouter"]["credentials"]), 12)

    def test_ledger_aggregates_by_provider_and_skips_old_schemas(self):
        import sqlite3
        import tempfile
        from contextlib import closing
        from hermes_status_server import provider_ledger
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / "old"
            old.mkdir()
            (old / "state.db").touch()
            with closing(sqlite3.connect(root / "state.db")) as db, db:
                db.execute("CREATE TABLE session_model_usage(session_id,billing_provider,api_call_count,"
                           "input_tokens,output_tokens,last_seen)")
                db.executemany("INSERT INTO session_model_usage VALUES(?,?,?,?,?,?)",
                               [("1","test",1,50,4,10),("1","test",2,70,8,15),("2","",3,10,1,14)])
            data, scope = provider_ledger([("first",root),("alias",root),("old",old)])
            self.assertEqual(data["test"], dict(sessions=1,calls=3,input_tokens=120,output_tokens=12,last_seen=15))
            self.assertEqual(data["unattributed"]["calls"], 3)
            self.assertEqual(scope, dict(profiles_read=1, profiles_unavailable=1))

    def test_openrouter_deduplicates_and_labels_partial_readings(self):
        from unittest.mock import patch
        import hermes_status_server as server

        def check(url, key, **kwargs):
            if url.endswith("credits"):
                return {"data": {"total_credits": 10, "total_usage": 4}}
            if key == "unavailable":
                raise OSError()
            return {"data": {"usage_daily": 0, "usage_monthly": 2.5}}

        pool = {"credential_pool": {"openrouter": [{"access_token": s} for s in ["configured","unavailable"]]}}
        with patch.object(server, "env_value", return_value="configured"), patch.object(server, "read_json", return_value=pool), patch.object(server, "http_json", side_effect=check):
            data = server.openrouter_usage()
        self.assertEqual((data["keys_reporting"],data["key_count"]), (1,2))
        self.assertEqual(data["spend"]["usage_daily"], dict(usd=0,reporting=1))
        self.assertEqual(data["balance"]["remaining"], 6)
        self.assertNotIn("configured", str(data))

    def test_primary_provider_wins_over_nested_fallback(self):
        import tempfile
        from hermes_status_server import _model_default
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "config.yaml"
            p.write_text("model:\n  default: fast\n  fallbacks:\n    - provider: alternate\n  provider: primary\n")
            self.assertEqual(_model_default(p), ("fast","primary"))
