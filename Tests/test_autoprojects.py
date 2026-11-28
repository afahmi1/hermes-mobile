"""Build 54: projects that make themselves. Detection thresholds, dismissed fingerprints, protected bots,
secret-file exclusion, idempotent drafting, and the local signature the CLI uses.

The LLM call is always mocked (the tests must not talk to Hermes). State lands in temp dirs; the real
~/.hermes/mobile is never touched (see _isolation.py, imported first).
"""
import _isolation  # noqa: F401  (must precede any bridge import)
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_autoprojects as ap  # noqa: E402
import bridge_manage  # noqa: E402
import bridge_workspaces  # noqa: E402

DAY = 86400


def _make_state_db(path):
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript("""
    CREATE TABLE sessions(id TEXT PRIMARY KEY, title TEXT, source TEXT DEFAULT 'gui', started_at REAL,
      last_activity_at REAL, parent_session_id TEXT, end_reason TEXT, cwd TEXT, message_count INTEGER DEFAULT 2,
      hidden INTEGER DEFAULT 0, archived INTEGER DEFAULT 0);
    CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
    """)
    return con


def _seed_chat(con, sid, title, words, days, source="gui", now=None):
    """One conversation: a session plus one user message per active day, each a distinct recent calendar day."""
    now = now or time.time()
    con.execute("INSERT INTO sessions(id,title,source,started_at,last_activity_at,cwd) VALUES(?,?,?,?,?,?)",
                (sid, title, source, now - 30 * DAY, now, None))
    for i, day in enumerate(days):
        ts = now - (30 - day) * DAY + i  # distinct days for distinct `day` values; same day for equal ones
        con.execute("INSERT INTO messages(session_id,role,content,timestamp) VALUES(?,?,?,?)",
                    (sid, "user", " ".join(words) + " on day %d" % i, ts))


def _chats(db, since, profile="default"):
    return ap.list_chats(db, profile, since)


class FakeEnv:
    """The parts of the live bridge bridge_autoprojects needs, all under test control."""

    lock = __import__("threading").Lock()

    def __init__(self, state_dir, db, profiles=("default",), projects=(), eligible=("default",), owned=()):
        self.state_dir = Path(state_dir)
        self.db = db
        self._profiles = list(profiles)
        self._projects = list(projects)
        self._eligible = list(eligible)
        self._owned = set(owned)
        self.llm_replies = []
        self.logs = []
        self.now_value = time.time()
        self._manage = bridge_manage.Manage(self.state_dir)
        self._store = bridge_workspaces.WorkspaceStore(self.state_dir / "workspaces")
        self._store.seed_assignments({})

    def now(self):
        return self.now_value

    def profiles(self):
        return self._profiles

    def ro(self, pid):
        con = sqlite3.connect(Path(self.db).resolve().as_uri() + "?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        return con

    def manage(self):
        return self._manage

    def store(self):
        return self._store

    def projects(self):
        return self._projects

    def catalog_ids(self):
        return {p["id"] for p in self._projects}

    def eligible(self, project):
        return list(self._eligible)

    def owned(self, pid, cwd):
        return (pid, cwd) in self._owned

    def bodies(self, pid, sid):
        con = self.ro(pid)
        try:
            rows = con.execute("SELECT role, content FROM messages WHERE session_id=? ORDER BY id", (sid,)).fetchall()
            return [(r["role"], r["content"]) for r in rows]
        finally:
            con.close()

    def llm(self, profile, system, user):
        return self.llm_replies.pop(0)

    def log(self, message):
        self.logs.append(message)

    def file_roots(self):
        return [str(self.state_dir)]


def _draft(chats=(), title="Widget project", summary="Build the widget.", instructions="- Do the widget.\n- Verify it.",
           context="## Key facts\n- widget\n## Decisions\n- none", files=(), is_project=True, existing=""):
    return json.dumps({"is_project": is_project, "reason": "same work", "existing": existing, "title": title,
                       "summary": summary, "instructions": instructions, "context": context,
                       "files": list(files), "chats": [i + 1 for i in range(len(chats) or 1)]})


class DetectionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.db = self.state / "state.db"
        self.con = _make_state_db(self.db)
        self.con.commit()

    def tearDown(self):
        self.con.close()
        self.tmp.cleanup()

    def test_clusters_need_three_chats_three_days_and_two_titles(self):
        now = time.time()
        since = now - 30 * DAY
        _seed_chat(self.con, "s1", "Widget work", ["widget", "grip"], [1, 2, 3])
        _seed_chat(self.con, "s2", "Widget redesign", ["widget", "grip"], [4, 5, 6])
        _seed_chat(self.con, "s3", "More widget", ["widget", "grip"], [7, 8, 9])
        chats = _chats(self.con, since)
        cl = ap.clusters(chats)
        self.assertTrue(cl)
        self.assertTrue(any("widget" in c.terms for c in cl))
        self.assertTrue(all(c.days >= 3 for c in cl))

    def test_two_chats_is_not_a_topic(self):
        now = time.time()
        since = now - 30 * DAY
        _seed_chat(self.con, "s1", "Widget work", ["widget", "grip"], [1, 2, 3])
        _seed_chat(self.con, "s2", "Widget redesign", ["widget", "grip"], [4, 5, 6])
        self.assertEqual(ap.clusters(_chats(self.con, since)), [])

    def test_days_must_span_three_distinct_days(self):
        now = time.time()
        since = now - 30 * DAY
        # All three chats on the same calendar day: three chats but not three distinct days.
        _seed_chat(self.con, "s1", "Widget work", ["widget", "grip"], [3, 3, 3], now=now)
        _seed_chat(self.con, "s2", "Widget redesign", ["widget", "grip"], [3, 3, 3], now=now)
        _seed_chat(self.con, "s3", "More widget", ["widget", "grip"], [3, 3, 3], now=now)
        self.assertEqual(ap.clusters(_chats(self.con, since)), [])

    def test_a_common_word_spread_across_history_is_not_a_topic(self):
        now = time.time()
        since = now - 30 * DAY
        for i, sid in enumerate(("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9")):
            _seed_chat(self.con, sid, "Chat %d" % i, ["model"], [1 + i, 2 + i, 3 + i])
        chats = _chats(self.con, since)
        self.assertEqual(ap.generic_terms(chats, chats), set())  # history == window: no background to discount
        # With a longer, varied history the word is everywhere and should not anchor a topic.
        history = chats + [ap.Chat("default", "old%d" % i, "Old %d" % i, ["model", "topic%d" % i], {1}, now, [], 3)
                           for i in range(20)]
        generic = ap.generic_terms(history, chats)
        self.assertIn("model", generic)
        self.assertEqual(ap.clusters(chats, generic=generic), [])


class FingerprintTest(unittest.TestCase):
    def test_fingerprint_ignores_order(self):
        self.assertEqual(bridge_manage.topic_fp(["a", "b", "c"]), bridge_manage.topic_fp(["c", "a", "b"]))

    def test_dismissed_topic_matches_by_terms_or_chats(self):
        # By overlapping terms, and by holding the same chat even when the words differ.
        dismissed = [{"terms": {"widget", "grip"}, "chats": {("default", "s1")}}]
        cl = ap.Cluster({"widget", "grip"}, [ap.Chat("default", "s1", "", [], {1}, 0, [], 3)], 1, 1.0)
        self.assertTrue(ap.dismissed_match(cl, dismissed))
        cl2 = ap.Cluster({"other"}, [ap.Chat("default", "s1", "", [], {1}, 0, [], 3)], 1, 1.0)
        self.assertTrue(ap.dismissed_match(cl2, dismissed))  # same chats


class DraftingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.db = self.state / "state.db"
        self.con = _make_state_db(self.db)
        self.con.commit()
        self.env = FakeEnv(self.state, self.db)

    def tearDown(self):
        self.con.close()
        self.tmp.cleanup()

    def _seed(self):
        now = time.time()
        _seed_chat(self.con, "s1", "Widget work", ["widget", "grip"], [1, 2, 3])
        _seed_chat(self.con, "s2", "Widget redesign", ["widget", "grip"], [4, 5, 6])
        _seed_chat(self.con, "s3", "More widget", ["widget", "grip"], [7, 8, 9])
        chats = _chats(self.con, now - 30 * DAY)
        self.env.llm_replies = [_draft(chats)]
        return chats

    def test_apply_draft_creates_populated_project(self):
        chats = self._seed()
        draft = ap.parse_draft(_draft(chats), len(chats), [], explicit=True)
        result = ap.apply_draft(self.env, draft, chats, "chat", {"widget", "grip"})
        self.assertEqual(result["action"], "created")
        self.assertTrue(result["project_id"])
        m, store = self.env.manage(), self.env.store()
        detail = store.detail(result["project_id"])
        self.assertTrue(detail["instructions"])
        self.assertEqual(len(detail["chats"]), 3)
        self.assertEqual([f["name"] for f in detail["files"]], [ap.CONTEXT_NAME])
        self.assertIn("Widget project", m.meta(result["project_id"])["title"] if False else result["title"])

    def test_reapply_is_idempotent(self):
        chats = self._seed()
        draft = ap.parse_draft(_draft(chats), len(chats), [], explicit=True)
        one = ap.apply_draft(self.env, draft, chats, "chat", {"widget", "grip"})
        # A second draft of the same chats updates the same project, not a duplicate.
        self.env.llm_replies = [_draft(chats, title="Widget project")]  # same title
        two = ap.apply_draft(self.env, draft, chats, "chat", {"widget", "grip"})
        self.assertEqual(one["project_id"], two["project_id"])
        ids = {p["id"] for p in self.env.manage().managed_projects()}
        self.assertEqual(len(ids), 1)

    def test_draft_redacts_secret_content(self):
        chats = self._seed()
        secret_context = "## Key facts\n- token AKIA1234567890ABCDEF used"
        reply = _draft(chats, context=secret_context)
        draft = ap.parse_draft(reply, len(chats), [], explicit=True)
        self.assertNotIn("AKIA1234567890ABCDEF", draft["context"])

    def test_secret_files_are_excluded(self):
        secret = self.state / "secret.env"
        secret.write_text("export API_KEY=abcdefgh12345678\n")
        chats = self._seed()
        got = ap.read_file(str(secret), [str(self.state)])
        self.assertIsNone(got)  # name + content both mark it a secret


class LocalSignatureTest(unittest.TestCase):
    def test_signature_round_trips_and_rejects_replay(self):
        secret = b"s" * 32
        now = 1000000.0
        header = ap.local_header(secret, "POST", "/m/local/autoprojects/from-chat", b'{"a":1}', now=now)
        nonces = ap.Nonces()
        self.assertTrue(nonces.check(secret, header, "POST", "/m/local/autoprojects/from-chat", b'{"a":1}', now))
        self.assertFalse(nonces.check(secret, header, "POST", "/m/local/autoprojects/from-chat", b'{"a":1}', now))
        # Wrong body or stale timestamp fails.
        header2 = ap.local_header(secret, "POST", "/m/local/autoprojects/from-chat", b'{"a":2}', now=now)
        self.assertFalse(nonces.check(secret, header2, "POST", "/m/local/autoprojects/from-chat", b'{"a":1}', now))
        self.assertFalse(nonces.check(secret, header2, "POST", "/m/local/autoprojects/from-chat", b'{"a":2}', now - 500))


class DetectPassTest(unittest.TestCase):
    """The full background pass, with the LLM mocked: linked chats are excluded, and one spotted project is made."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.db = self.state / "state.db"
        self.con = _make_state_db(self.db)
        self.con.commit()
        self.env = FakeEnv(self.state, self.db)

    def tearDown(self):
        self.con.close()
        self.tmp.cleanup()

    def _seed_cluster(self):
        now = time.time()
        _seed_chat(self.con, "s1", "Widget work", ["widget", "grip"], [1, 2, 3], now=now)
        _seed_chat(self.con, "s2", "Widget redesign", ["widget", "grip"], [4, 5, 6], now=now)
        _seed_chat(self.con, "s3", "More widget", ["widget", "grip"], [7, 8, 9], now=now)
        self.con.commit()  # the detector opens its own read-only connection; it must see these rows
        return _chats(self.con, now - 30 * DAY)

    def test_a_chat_already_in_a_project_is_not_suggested(self):
        chats = self._seed_cluster()
        made = self.env.manage().create_project("Widget", None, None, set())
        self.env.store().link_chat(made["id"], "default", "s1", "Widget work")
        report = ap.detect(self.env, dry_run=True)
        # The cluster's chat s1 is linked, so nothing should be created or offered.
        self.assertEqual(report["would_create"], [])
        self.assertFalse(self.env.llm_replies)  # the LLM was never asked

    def test_detect_creates_one_spotted_project(self):
        chats = self._seed_cluster()
        self.env.llm_replies = [_draft(chats)]
        report = ap.detect(self.env, dry_run=False, force=True)
        self.assertEqual(len(report["created"]), 1)
        created = report["created"][0]
        self.assertEqual(created["action"], "created")
        meta = self.env.manage().meta(created["project_id"])
        self.assertEqual(meta["state"], "spotted")
        self.assertEqual(meta["origin"], "spotted")
        # Keeping clears the badge.
        self.assertTrue(self.env.manage().keep_project(created["project_id"]))
        self.assertEqual(self.env.manage().meta(created["project_id"])["state"], "kept")

    def test_dismissing_archives_and_remembers_the_topic(self):
        chats = self._seed_cluster()
        self.env.llm_replies = [_draft(chats)]
        created = ap.detect(self.env, dry_run=False, force=True)["created"][0]
        pid = created["project_id"]
        self.assertTrue(self.env.manage().dismiss_project(pid))
        self.assertIn(pid, self.env.manage().archived_projects())
        self.assertEqual(self.env.manage().meta(pid)["state"], "dismissed")
        self.assertTrue(self.env.manage().dismissed_topics())


class MoneyBotTest(unittest.TestCase):
    def test_money_and_private_bots_never_pool(self):
        for pid in ("trading", "robinhood-cli", "portfolio-tracker", "captains-log", "bacta-protocol"):
            self.assertTrue(ap.is_money_bot(pid), pid)
        for pid in ("default", "research", "career", "3d-printing", "mentat"):
            self.assertFalse(ap.is_money_bot(pid), pid)


if __name__ == "__main__":
    unittest.main()
