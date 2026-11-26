"""Session search: the trigram path must return exactly the legacy LIKE path's rows."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class SearchProfileTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE sessions(id TEXT PRIMARY KEY, source TEXT, model TEXT, title TEXT,
                started_at INTEGER, ended_at INTEGER, message_count INTEGER, archived INTEGER,
                last_activity_at INTEGER, parent_session_id TEXT, hidden INTEGER DEFAULT 0);
            CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT);
            CREATE VIRTUAL TABLE messages_fts_trigram USING fts5(content, tokenize='trigram');
            CREATE TABLE state_meta(key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO state_meta VALUES('fts_storage_version', '3');
        """)
        rows = [
            ("s1", "cli", None, "Unrelated title", 1, None, 2, 0, 100, None, 0),
            ("s2", "cli", None, "Kubernetes notes", 2, None, 1, 0, 200, None, 0),
            ("s3", "telegram", None, None, 3, None, 1, 0, 300, None, 0),
            ("s4", "cli", None, None, 4, None, 1, 1, 50, None, 0),
        ]
        self.db.executemany("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?)", rows)
        messages = [
            (1, "s1", "user", "please inspect the video"),
            (2, "s3", "user", "refactor plan for the gateway"),
            (3, "s1", "tool", "video output internals"),
            (4, "s4", "user", "archived video mention"),
        ]
        self.db.executemany("INSERT INTO messages VALUES(?,?,?,?)", messages)
        # Hermes indexes non-tool rows; the bridge only searches user rows.
        self.db.executemany("INSERT INTO messages_fts_trigram(rowid, content) VALUES(?,?)",
                            [(1, "please inspect the video"), (2, "refactor plan for the gateway"),
                             (4, "archived video mention")])

    def tearDown(self):
        self.db.close()

    def search(self, term, prefer_fts=True, archived=False, source=None):
        cleaned = term.replace("%", "").replace("_", "")
        like = "%" + cleaned + "%"
        return bridge._search_profile(self.db, "bot", like, bridge._fts_phrase(cleaned),
                                      archived, source, 40, prefer_fts)

    def ids(self, term, **kwargs):
        return {r["id"] for r in self.search(term, **kwargs)}

    def test_indexed_and_legacy_paths_return_the_same_sessions(self):
        for term in ("video", "refactor", "kubernetes", "the", "a", "gateway"):
            self.assertEqual(self.ids(term, prefer_fts=True), self.ids(term, prefer_fts=False), term)

    def test_title_match_is_kept_when_the_index_has_no_message_hit(self):
        self.assertEqual(self.ids("kubernetes"), {"s2"})

    def test_short_and_rebuild_pending_queries_fall_back_to_the_scan(self):
        self.assertIsNone(bridge._fts_phrase("ai"))
        self.assertEqual(self.ids("ai"), self.ids("ai", prefer_fts=False))
        self.db.execute("INSERT INTO state_meta VALUES('fts_rebuild_high_water', '99')")
        self.db.commit()
        self.assertFalse(bridge._fts_ready(self.db))
        self.assertEqual(self.ids("video"), {"s1"})
        self.assertEqual(self.ids("video"), self.ids("video", prefer_fts=False))

    def test_tool_messages_and_archived_sessions_do_not_leak(self):
        self.assertEqual(self.ids("internals"), set())  # indexed tool content is not a user hit
        self.assertEqual(self.ids("video", archived=True), {"s4"})
        self.assertEqual(self.ids("video", source="telegram"), set())

    def test_fts_syntax_characters_are_literal(self):
        self.db.execute("INSERT INTO messages VALUES(5, 's1', 'user', 'a 100 \"quoted\" name')")
        self.db.execute("INSERT INTO messages_fts_trigram(rowid, content) VALUES(5, ?)",
                        ('a 100 "quoted" name',))
        self.db.commit()
        self.assertEqual(self.ids('100 "quoted"'), {"s1"})
        self.assertEqual(self.ids('100 "quoted"'), self.ids('100 "quoted"', prefer_fts=False))
        # LIKE strips wildcard characters from the token; the FTS phrase sees the same token.
        self.assertEqual(self.ids('100%'), self.ids('100%', prefer_fts=False))


if __name__ == "__main__":
    unittest.main()
