from contextlib import closing
import importlib
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))


class SessionSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        with patch.dict(os.environ, HERMES_HOME=str(self.home)):
            self.bridge = importlib.import_module("hermes_mobile_bridge")
        self.enterContext(patch.object(self.bridge, "HERMES", self.home))
        self.enterContext(patch.object(self.bridge, "key_for", return_value="test"))
        for name, count in [("default", 65), ("secondary", 8)]:
            home = self.home if name == "default" else self.home / "profiles" / name
            home.mkdir(parents=True, exist_ok=True)
            with closing(sqlite3.connect(home / "state.db")) as db, db:
                db.execute("CREATE TABLE sessions(id, source, model, title, started_at, ended_at, "
                           "message_count, archived, last_activity_at, parent_session_id, hidden)")
                db.execute("CREATE TABLE messages(id, session_id, role, content)")
                for i in range(count):
                    db.execute("INSERT INTO sessions VALUES(?,?,'test','matching',0,0,1,0,?,null,0)",
                               (str(i), "telegram" if i % 2 == 0 else "gui", i))

    def test_archive_pages_include_automation_and_pinned_rows_without_duplicates(self):
        for home in (self.home, self.home / "profiles" / "secondary"):
            with closing(sqlite3.connect(home / "state.db")) as db, db:
                db.execute("ALTER TABLE sessions ADD COLUMN pinned INTEGER DEFAULT 0")
                db.execute("UPDATE sessions SET archived=1, pinned=1, source='tool'")
        cursor, rows = None, []
        for _ in range(30):
            page = self.bridge.all_sessions(5, cursor, source="archived")
            rows.extend(page["data"])
            cursor = page["next"]
            if cursor is None: break
        self.assertIsNone(cursor)
        self.assertEqual(len(rows), 73)
        self.assertEqual(len({(r["profile"], r["id"]) for r in rows}), 73)
        self.assertTrue(all(r["pinned"] is True and r["archived"] is True for r in rows))

    def test_merge_telegram_pages(self):
        cursor = None
        seen = []
        for _ in range(20):
            page = self.bridge.all_sessions(5, cursor, telegram=True)
            self.assertFalse(page["errors"])
            for row in page["data"]:
                self.assertEqual(row["source"], "telegram")
                seen.append((row["profile"], row["id"]))
            cursor = page["next"]
            if cursor is None:
                break
        self.assertIsNone(cursor)
        self.assertEqual(len(seen), 37)
        self.assertEqual(len(set(seen)), len(seen))

    def test_search_scopes_before_the_limit(self):
        rows = self.bridge.search_sessions("matching", profile="secondary", source="telegram", limit=2)
        self.assertEqual([(r["profile"], r["id"]) for r in rows], [("secondary", "6"), ("secondary", "4")])

    def test_desktop_scope_matches_source_aliases_and_preserves_bot_identity(self):
        with closing(sqlite3.connect(self.home / "profiles" / "secondary" / "state.db")) as db, db:
            for source, activity in [("local",80), ("desktop",90), ("cli",100)]:
                db.execute("INSERT INTO sessions VALUES(?,?,'test','matching',0,0,1,0,?,null,0)",
                           (source,source,activity))
        seen = []
        cursor = None
        while True:
            page = self.bridge.all_sessions(2, cursor, only=["secondary"], source="desktop")
            self.assertFalse(page["errors"])
            seen.extend((row["profile"], row["id"]) for row in page["data"])
            cursor = page["next"]
            if not cursor:
                break
        self.assertEqual(seen, [("secondary", sid) for sid in ("desktop","local","7","5","3","1")])
        found = self.bridge.search_sessions("matching", profile="secondary", source="desktop")
        self.assertEqual([(r["profile"], r["id"]) for r in found], seen)

    def test_first_page_cache_invalidates_after_mutation(self):
        b = self.bridge
        b.invalidate_pages()
        with patch.object(b, "all_sessions", return_value={"data": [], "next": None, "errors": {}}) as fetch:
            for _ in range(2):
                b.session_page(16, None, None, (), False)
            self.assertEqual(fetch.call_count, 1)
            b.session_page(16, None, None, (), True)
            self.assertEqual(fetch.call_count, 2)
            b.invalidate_pages()
            b.session_page(16, None, None, (), False)
            self.assertEqual(fetch.call_count, 3)

    def test_filtered_capsule_preserves_pin_visibility_and_cursor_offsets(self):
        b = self.bridge
        data = {pid: [dict(id=str(i), pinned=False, source="gui", last_active=i) for i in range(n,0,-1)]
                for pid,n in [("default",15),("secondary",8)]}
        def native(pid, offset, limit, exclude, first):
            self.assertEqual(exclude, ("cron",))
            src = data[pid]
            return ([r.copy() for r in src[offset:offset+limit]],
                    [dict(id="pin", pinned=True, source="gui", last_active=0)] if first else [],
                    offset+limit < len(src))
        with patch.object(b, "NATIVE_INBOX", True), patch.object(b, "served_profiles", return_value=set(data)), patch.object(b, "native_inbox_window", side_effect=native):
            cursor, seen = None, []
            while True:
                page = b.all_sessions(4, cursor, exclude=("cron",), compact=True)
                seen.extend((r["profile"], r["id"]) for r in page["data"])
                cursor = page["next"]
                if not cursor: break
            self.assertEqual(len(seen), 25)
            self.assertEqual(len(set(seen)),25)

    def test_new_cursor_restarts_after_bridge_downgrade(self):
        b = self.bridge
        with patch.object(b, "NATIVE_INBOX", False), patch.object(b, "profile_ids", return_value=[]):
            page = b.all_sessions(4, b._cursor_encode({"default":40, "_native":1}), compact=True)
            self.assertTrue(page["reset"])

    def test_restart_signal_expires_and_health_is_independent(self):
        from datetime import datetime, timezone
        now = 1740000000
        fresh = datetime.fromtimestamp(now-3,timezone.utc).isoformat()
        stale = datetime.fromtimestamp(now-500,timezone.utc).isoformat()
        phase = self.bridge.gateway_phase
        self.assertEqual(phase(False,None,{"restart_requested":True,"updated_at":fresh},{},now),"restarting")
        self.assertEqual(phase(False,None,{"restart_requested":True,"updated_at":stale},{},now),"unavailable")
        self.assertEqual(phase(False,None,{},{"phase":"running","started_at":fresh},now),"starting")
        self.assertEqual(phase(True,"running",{},{},now),"running")
