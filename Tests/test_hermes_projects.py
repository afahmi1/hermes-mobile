"""Hermes's own Projects on the phone: listed read-only, their chats found by folder, new chats started there."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_hermes_projects as hp
import hermes_mobile_bridge as b

# hermes_cli/projects_db.py SCHEMA_SQL, the tables this reader uses.
PROJECTS_SCHEMA = """
CREATE TABLE projects (id TEXT PRIMARY KEY, slug TEXT NOT NULL UNIQUE, name TEXT NOT NULL, description TEXT,
  icon TEXT, color TEXT, board_slug TEXT, primary_path TEXT, created_at INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
CREATE TABLE project_folders (project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, path TEXT NOT NULL,
  label TEXT, is_primary INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL, PRIMARY KEY (project_id, path));
"""


class HermesProjectsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "hermes"
        self.home.mkdir()
        self.work = Path(self.tmp.name) / "work"
        (self.work / "app" / "ios").mkdir(parents=True)
        (self.work / "site").mkdir(parents=True)
        con = sqlite3.connect(self.home / "projects.db")
        con.executescript(PROJECTS_SCHEMA)
        app, ios, site = str(self.work / "app"), str(self.work / "app" / "ios"), str(self.work / "site")
        rows = [("p1", "hermes-mobile", "Hermes Mobile", "The phone app", app, 1, 0),
                ("p2", "ios-shell", "iOS shell", None, ios, 2, 0),
                ("p3", "old-site", "Old site", None, site, 3, 1),
                ("p4", "gone", "Gone", None, str(self.work / "missing"), 4, 0)]
        for pid, slug, name, desc, path, created, archived in rows:
            con.execute("INSERT INTO projects(id,slug,name,description,primary_path,created_at,archived) VALUES(?,?,?,?,?,?,?)",
                        (pid, slug, name, desc, path, created, archived))
            con.execute("INSERT INTO project_folders VALUES(?,?,?,?,?)", (pid, path, None, 1, created))
        con.commit()
        con.close()
        self.state = sqlite3.connect(":memory:")
        self.state.execute("CREATE TABLE sessions(id TEXT, source TEXT, model TEXT, title TEXT, started_at REAL, "
                           "ended_at REAL, message_count INT, archived INT DEFAULT 0, last_activity_at REAL, "
                           "parent_session_id TEXT, cwd TEXT, hidden INT DEFAULT 0)")
        chats = [("a", app, 10, "cli"), ("b", app + "/Bridge", 30, "gui"), ("c", ios, 20, "gui"),
                 ("d", str(self.work / "application"), 40, "gui"), ("e", app, 50, "subagent"), ("f", "/Users/x", 60, "gui"),
                 ("g", site, 70, "gui")]
        for sid, cwd, ts, source in chats:
            self.state.execute("INSERT INTO sessions(id,source,title,started_at,last_activity_at,cwd) VALUES(?,?,?,?,?,?)",
                               (sid, source, sid.upper(), ts, ts, cwd))
        self.projects = hp.load(self.home)

    def tearDown(self):
        self.state.close()
        self.tmp.cleanup()

    def test_lists_live_projects_oldest_first_without_archived_ones(self):
        self.assertEqual([p["slug"] for p in self.projects], ["hermes-mobile", "ios-shell", "gone"])
        self.assertEqual(self.projects[0]["description"], "The phone app")

    def test_a_nested_project_keeps_its_own_chats(self):
        self.assertEqual(hp.owner(self.projects, str(self.work / "app" / "ios" / "Sources")), "ios-shell")
        self.assertEqual(hp.owner(self.projects, str(self.work / "app" / "Bridge")), "hermes-mobile")

    def test_a_sibling_folder_with_the_same_prefix_is_not_inside(self):
        self.assertIsNone(hp.owner(self.projects, str(self.work / "application")))

    def test_project_chats_newest_first_without_helpers(self):
        self.assertEqual(hp.session_ids(self.state, self.projects, "hermes-mobile"), ["b", "a"])
        self.assertEqual(hp.session_ids(self.state, self.projects, "ios-shell"), ["c"])
        self.assertEqual(hp.session_ids(self.state, self.projects, "old-site"), [])

    def test_counts_match_the_lists(self):
        self.assertEqual(hp.chat_counts(self.state, self.projects), {"hermes-mobile": 2, "ios-shell": 1, "gone": 0})

    def test_new_chats_start_in_the_main_folder_only_while_it_exists(self):
        self.assertEqual(hp.start_folder(hp.find(self.projects, "hermes-mobile")), str(self.work / "app"))
        self.assertIsNone(hp.start_folder(hp.find(self.projects, "gone")))

    def test_the_phone_sees_a_folder_name_never_a_path(self):
        entry = hp.catalog_entry(hp.find(self.projects, "hermes-mobile"), 2)
        self.assertEqual(entry["hermes"], {"folder": "app", "folders": 1, "chats": 2})
        self.assertFalse(entry["managed"])
        self.assertNotIn(str(self.work), json.dumps(entry))

    def test_reads_a_quiet_wal_database_without_its_side_files(self):
        # The real ~/.hermes/projects.db: WAL mode, last written months ago, no -shm or -wal on disk.
        con = sqlite3.connect(self.home / "projects.db")
        con.execute("PRAGMA journal_mode=wal")
        con.close()
        for side in ("-wal", "-shm"):
            try:
                os.remove(str(self.home / "projects.db") + side)
            except FileNotFoundError:
                pass
        os.chmod(self.home, 0o555)  # a read-only open can't create -shm here
        try:
            self.assertEqual([p["slug"] for p in hp.load(self.home)], ["hermes-mobile", "ios-shell", "gone"])
        finally:
            os.chmod(self.home, 0o755)

    def test_missing_or_foreign_database_reads_as_no_projects(self):
        self.assertEqual(hp.load(Path(self.tmp.name) / "nowhere"), [])
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        sqlite3.connect(other / "projects.db").execute("CREATE TABLE projects(x TEXT)").connection.commit()
        self.assertEqual(hp.load(other), [])

    def test_the_catalog_lists_hermes_projects_and_keeps_operator_ids(self):
        catalog = {"schema_version": 1, "configured": True, "roots": [],
                   "projects": [{"id": "ios-shell", "title": "Operator's iOS", "bot_ids": [], "sources": [], "related_files": []}]}
        with patch.object(b, "HERMES", self.home), patch.object(b, "_ro", return_value=None):
            code, body = b.with_hermes_projects(200, json.dumps(catalog).encode())
        doc = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual([p["id"] for p in doc["projects"]], ["ios-shell", "hermes-mobile", "gone"])
        self.assertEqual(doc["projects"][0]["title"], "Operator's iOS")

    def test_hermes_with_projects_but_none_made_shows_an_empty_list_not_setup(self):
        empty = Path(self.tmp.name) / "empty"
        empty.mkdir()
        sqlite3.connect(empty / "projects.db").executescript(PROJECTS_SCHEMA)
        unconfigured = json.dumps({"schema_version": 1, "configured": False, "roots": [], "projects": []}).encode()
        with patch.object(b, "HERMES", empty):
            doc = json.loads(b.with_hermes_projects(200, unconfigured)[1])
        self.assertEqual((doc["configured"], doc["projects"]), (True, []))

    def test_no_projects_database_leaves_the_catalog_alone(self):
        unconfigured = json.dumps({"configured": False, "projects": []}).encode()
        with patch.object(b, "HERMES", Path(self.tmp.name) / "nowhere"):
            self.assertEqual(b.with_hermes_projects(200, unconfigured), (200, unconfigured))


class HttpRoutesTest(HermesProjectsTest):
    """The phone's routes, through the real handler."""

    def setUp(self):
        super().setUp()
        import http.client
        import threading
        from http.server import ThreadingHTTPServer
        disk = Path(self.tmp.name) / "state.db"
        dump = sqlite3.connect(disk)
        self.state.commit()
        self.state.backup(dump)
        dump.close()

        def ro(pid):
            con = sqlite3.connect(disk)
            con.row_factory = sqlite3.Row
            return con
        self.enterContext(patch.object(b, "HERMES", self.home))
        self.enterContext(patch.object(b, "_ro", ro))
        self.enterContext(patch.dict(os.environ))
        os.environ.pop("HERMES_MOBILE_PROJECTS_CATALOG", None)
        os.environ.pop("HERMES_MOBILE_OWNER_MANAGED", None)
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), b.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.token = b.make_token("test")
        self.http = http.client

    def req(self, method, path, body=None):
        c = self.http.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        c.request(method, path, body=json.dumps(body) if body is not None else None,
                  headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        r = c.getresponse()
        out = (r.status, json.loads(r.read() or b"null"))
        c.close()
        return out

    def test_the_projects_tab_lists_hermes_projects_with_chat_counts(self):
        code, doc = self.req("GET", "/m/projects")
        self.assertEqual(code, 200)
        self.assertTrue(doc["configured"])
        self.assertEqual({p["id"]: p["hermes"]["chats"] for p in doc["projects"]},
                         {"hermes-mobile": 2, "ios-shell": 1, "gone": 0})

    def test_a_project_page_lists_its_chats(self):
        code, page = self.req("GET", "/m/projects/hermes-mobile/chats")
        self.assertEqual(code, 200)
        self.assertEqual([r["id"] for r in page["data"]], ["b", "a"])
        self.assertEqual({r["profile"] for r in page["data"]}, {"default"})
        self.assertTrue(page["can_start"])
        self.assertEqual(page["folder"], "app")
        self.assertFalse(self.req("GET", "/m/projects/gone/chats")[1]["can_start"])
        self.assertEqual(self.req("GET", "/m/projects/old-site/chats")[0], 404)

    def test_a_new_chat_starts_in_the_folder_the_mac_resolves(self):
        if b.turns is None:
            self.skipTest("turn engine unavailable")
        seen = {}

        def create(home, profile, title=None, request_id=None, cwd=None):
            seen.update(profile=profile, cwd=cwd)
            return {"session_id": "new1"}
        with patch.object(b.turns, "create_session", create), patch.object(b, "profile_ids", lambda: ["default"]), \
                patch.object(b.turns, "primary_journal", side_effect=OSError):
            self.assertEqual(self.req("POST", "/m/chat/default/new", {"project": "hermes-mobile"})[0], 201)
            self.assertEqual(seen, {"profile": "default", "cwd": str(self.work / "app")})
            code, body = self.req("POST", "/m/chat/default/new", {"project": "gone"})
            self.assertEqual((code, body["code"]), (409, "no_folder"))
            code, body = self.req("POST", "/m/chat/default/new", {"project": "../../etc"})
            self.assertEqual((code, body["code"]), (404, "no_project"))


class StartInFolderTest(unittest.IsolatedAsyncioTestCase):
    async def test_create_passes_the_folder_to_hermes(self):
        import bridge_turns as t
        seen = {}

        class Conn:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return False

        async def rpc(c, method, **params):
            seen.update(params)
            return {"session_id": "s1"}

        with patch.object(t, "connect", lambda home: Conn()), patch.object(t, "_rpc", rpc):
            out = await t._create("/tmp", "default", None, None, cwd="/Users/me/app")
        self.assertEqual(seen["cwd"], "/Users/me/app")
        self.assertEqual(out["session_id"], "s1")


if __name__ == "__main__":
    unittest.main()
