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
