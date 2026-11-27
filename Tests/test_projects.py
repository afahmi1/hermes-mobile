import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import copy
import http.client
import importlib
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parents[1] / "Bridge"
sys.path.insert(0, str(BRIDGE_DIR))
import bridge_projects  # noqa: E402

SETTING = "HERMES_MOBILE_PROJECTS_CATALOG"
UNAVAILABLE = {"error": "Project catalog unavailable."}
GOOD = {
    "schema_version": 1,
    "roots": [{"id": "code", "label": "Code", "kind": "repo"}, {"id": "notes", "label": "Notes", "kind": "vault"}],
    "projects": [
        {"id": "alpha", "title": "Alpha", "summary": "First", "bot_ids": ["default", "bot-a"],
         "sources": [{"provider": "demo", "source": "Thread 1"}],
         "related_files": [{"root": "code", "path": "src/a b/é.txt"}]},
        {"id": "beta", "title": "Beta", "bot_ids": ["bot-a"]},
        {"id": "gamma", "title": "Gamma"},
    ],
}


def setUpModule():
    global bridge
    # Bridge generates a bearer signing key at import. Keep it in a synthetic home.
    with tempfile.TemporaryDirectory(prefix="bridge-projects-test-") as home:
        with patch.dict(os.environ, HERMES_HOME=home):
            bridge = importlib.import_module("hermes_mobile_bridge")


def mutated(fn):
    d = copy.deepcopy(GOOD)
    fn(d)
    return d


class Server:
    def __enter__(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), bridge.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.token = bridge.make_token("test")
        return self

    def __exit__(self, *a):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method="GET", path="/m/projects", body=None, auth=True, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        h = dict(headers or {})
        if auth:
            h["Authorization"] = "Bearer " + self.token
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        out = (r.status, r.getheader("Cache-Control"), json.loads(data) if data else None)
        c.close()
        return out


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="catalog-"))).resolve()
        self.enterContext(patch.dict(os.environ))
        os.environ.pop(SETTING, None)
        # The bridge may already be imported against the real ~/.hermes, whose projects.db would add
        # Hermes's own Projects to the catalog. These tests are about the operator catalog alone.
        self.enterContext(patch.object(bridge, "HERMES", self.tmp))

    def write(self, doc, name="cat.json", raw=None):
        p = self.tmp / name
        p.write_bytes(raw if raw is not None else json.dumps(doc).encode())
        return p

    def get(self, p):
        os.environ[SETTING] = str(p)
        with Server() as s:
            return s.req()


class HandlerTests(Base):
    def test_unconfigured(self):
        with Server() as s:
            code, cc, body = s.req()
        self.assertEqual((code, cc), (200, "no-store"))
        self.assertEqual(body, {"schema_version": 1, "configured": False, "roots": [], "projects": []})

    def test_auth_before_load(self):
        os.environ[SETTING] = str(self.tmp / "missing.json")
        called = []
        orig = bridge_projects.catalog_response
        bridge_projects.catalog_response = lambda: called.append(1) or orig()
        try:
            with Server() as s:
                self.assertEqual(s.req(auth=False)[0], 401)
                self.assertEqual(s.req(headers={"Authorization": "Bearer nope"}, auth=False)[0], 401)
                self.assertEqual(s.req("POST", auth=False, body=b"")[0], 401)
        finally:
            bridge_projects.catalog_response = orig
        self.assertEqual(called, [])

    def test_valid_normalized_zero_one_many_and_shared_bots(self):
        code, cc, body = self.get(self.write(GOOD))
        self.assertEqual((code, cc), (200, "no-store"))
        self.assertTrue(body["configured"])
        self.assertEqual(body["roots"], GOOD["roots"])
        a, b, g = body["projects"]
        self.assertEqual(a["bot_ids"], ["default", "bot-a"])
        self.assertEqual(b["bot_ids"], ["bot-a"])  # shared across projects
        self.assertNotIn("summary", b)
        self.assertEqual((g["bot_ids"], g["sources"], g["related_files"]), ([], [], []))
        self.assertEqual(a["related_files"][0]["path"], "src/a b/é.txt")

    def test_empty_catalog_and_null_summary(self):
        code, _, body = self.get(self.write({"schema_version": 1, "roots": [], "projects": [
            {"id": "x", "title": "X", "summary": None}]}))
        self.assertEqual(code, 200)
        self.assertIsNone(body["projects"][0]["summary"])

    def test_query_body_and_methods(self):
        p = self.write(GOOD)
        os.environ[SETTING] = str(p)
        calls = []
        orig = bridge_projects.catalog_response
        bridge_projects.catalog_response = lambda: calls.append(1) or orig()
        try:
            with Server() as s:
                for path in ("/m/projects?x=1", "/m/projects?"):
                    self.assertEqual(s.req(path=path)[0], 400)
                self.assertEqual(s.req(body=b"{}", headers={"Content-Type": "application/json"})[0], 400)
                self.assertEqual(calls, [])
                for m in ("POST", "PATCH", "DELETE"):
                    self.assertEqual(s.req(m, body=b"")[0], 405, m)
                self.assertEqual(calls, [])
                self.assertEqual(s.req()[0], 200)
        finally:
            bridge_projects.catalog_response = orig
        self.assertEqual(calls, [1])

    def test_unavailable_has_no_leak(self):
        p = self.write(None, raw=b"{not json SECRETWORD")
        code, cc, body = self.get(p)
        self.assertEqual((code, cc, body), (503, "no-store", UNAVAILABLE))
        self.assertNotIn(str(self.tmp), json.dumps(body))
        os.environ[SETTING] = "relative.json"
        with Server() as s:
            self.assertEqual(s.req()[2], UNAVAILABLE)
        os.environ[SETTING] = ""
        with Server() as s:
            self.assertEqual(s.req()[2], UNAVAILABLE)
        self.assertEqual(self.get(self.tmp / "nope.json")[2], UNAVAILABLE)

    def test_windows_like_platform_disabled(self):
        orig = bridge_projects.supported
        bridge_projects.supported = lambda: False
        try:
            self.assertEqual(self.get(self.write(GOOD))[0], 503)
            os.environ.pop(SETTING)
            with Server() as s:  # unset setting still answers normally
                self.assertEqual(s.req()[0], 200)
        finally:
            bridge_projects.supported = orig


class SchemaTests(Base):
    def assert_rejected(self, doc=None, raw=None):
        code, _, body = self.get(self.write(doc, raw=raw))
        self.assertEqual((code, body), (503, UNAVAILABLE), str((doc, raw))[:200])

    def test_bad_documents(self):
        cases = [
            mutated(lambda d: d.update(extra=1)),
            mutated(lambda d: d.update(configured=True)),
            mutated(lambda d: d.update(schema_version=2)),
            mutated(lambda d: d.update(schema_version=True)),
            mutated(lambda d: d.pop("roots")),
            mutated(lambda d: d.pop("projects")),
            mutated(lambda d: d.update(roots={})),
            mutated(lambda d: d["roots"][0].update(kind="disk")),
            mutated(lambda d: d["roots"][0].update(path="/etc")),
            mutated(lambda d: d["roots"][0].pop("label")),
            mutated(lambda d: d["roots"][0].update(id="Code")),
            mutated(lambda d: d["roots"][1].update(id="code")),
            mutated(lambda d: d["projects"][0].update(id="a" * 65)),
            mutated(lambda d: d["projects"][1].update(id="alpha")),
            mutated(lambda d: d["projects"][0].update(bot_ids=["a", "a"])),
            mutated(lambda d: d["projects"][0].update(bot_ids=["B"])),
            mutated(lambda d: d["projects"][0].update(bot_ids=["a" * 42])),
            mutated(lambda d: d["projects"][0].update(bot_ids=[1])),
            mutated(lambda d: d["projects"][0].update(bot_ids=["x"] * 1 + [str(i) for i in range(32)])),
            mutated(lambda d: d["projects"][0].update(sources=[{"provider": "p"}])),
            mutated(lambda d: d["projects"][0].update(sources=[{"provider": "p", "source": "s", "url": "u"}])),
            mutated(lambda d: d["projects"][0].update(sources=[{"provider": "p", "source": "s"}] * 2)),
            mutated(lambda d: d["projects"][0].update(related_files=[{"root": "nope", "path": "a"}])),
            mutated(lambda d: d["projects"][0].update(related_files=[{"root": ["code"], "path": "a"}])),
            mutated(lambda d: d["projects"][0].update(related_files=[{"root": "code", "path": "a"}] * 2)),
            mutated(lambda d: d["projects"][0].update(title=" Alpha")),
            mutated(lambda d: d["projects"][0].update(title="Al\u0000pha")),
            mutated(lambda d: d["projects"][0].update(title="Al\u202epha")),
            mutated(lambda d: d["projects"][0].update(title="")),
            mutated(lambda d: d["projects"][0].update(title=5)),
            mutated(lambda d: d["projects"][0].update(summary="x\ny")),
            mutated(lambda d: d["projects"][0].update(summary="é" * 501)),
            mutated(lambda d: d["projects"][0].update(title="é" * 61)),
            mutated(lambda d: d["projects"][0].update(title="\ud800")),
        ]
        for c in cases:
            with self.subTest(c=str(c)[:120]):
                self.assert_rejected(c)

    def test_ids_do_not_accept_trailing_linebreaks(self):
        for change in (lambda d: d["roots"][1].update(id="notes\n"),
                       lambda d: d["projects"][0].update(id="alpha\n"),
                       lambda d: d["projects"][0].update(bot_ids=["bot-a\n"])):
            self.assert_rejected(mutated(change))

    def test_bad_relative_paths(self):
        bad = ["", "/abs", "a//b", "a/", "./a", "a/./b", "../a", "a/../b", "a\\b", "C:/x", "file:x", "a%2eb",
               "a#b", "a?b", "~/a", "~", "a\tb", "a" * 513, "é" * 257]
        for path in bad:
            with self.subTest(path=path):
                self.assert_rejected(mutated(lambda d: d["projects"][0].update(
                    related_files=[{"root": "code", "path": path}])))
        for ok in ["a", "a b/c d", "é/ü.md", "a~", ".hidden/x", "a..b", "a" * 512]:
            with self.subTest(ok=ok):
                code, _, _ = self.get(self.write(mutated(lambda d: d["projects"][0].update(
                    related_files=[{"root": "code", "path": ok}]))))
                self.assertEqual(code, 200)

    def test_bounds(self):
        def n_projects(n):
            return mutated(lambda d: d.update(projects=[{"id": "p%d" % i, "title": "t"} for i in range(n)]))
        self.assertEqual(self.get(self.write(n_projects(300)))[0], 200)
        self.assert_rejected(n_projects(301))
        roots = lambda n: mutated(lambda d: d.update(roots=[{"id": "r%d" % i, "label": "l", "kind": "repo"} for i in range(n)], projects=[]))
        self.assertEqual(self.get(self.write(roots(64)))[0], 200)
        self.assert_rejected(roots(65))
        for key, item, cap in (("bot_ids", lambda i: "b%d" % i, 32),
                               ("sources", lambda i: {"provider": "p", "source": "s%d" % i}, 32),
                               ("related_files", lambda i: {"root": "code", "path": "f%d" % i}, 64)):
            self.assertEqual(self.get(self.write(mutated(lambda d: d["projects"][0].update({key: [item(i) for i in range(cap)]}))))[0], 200, key)
            self.assert_rejected(mutated(lambda d: d["projects"][0].update({key: [item(i) for i in range(cap + 1)]})))
        self.assertEqual(self.get(self.write(mutated(lambda d: d["projects"][0].update(title="é" * 60))))[0], 200)

    def test_raw_json_failures(self):
        for raw in [b"", b"[]", b"null", b"\xff\xfe", b'{"schema_version":1,"schema_version":1,"roots":[],"projects":[]}',
                    b'{"schema_version":NaN,"roots":[],"projects":[]}',
                    b"[" * 100000, b'{"a":' * 50000, b'{"schema_version":1,"roots":[],"projects":[],"x":"\\ud800"}',
                    b" " * (256 * 1024 + 1)]:
            with self.subTest(raw=raw[:30]):
                self.assert_rejected(raw=raw)

    def test_response_cap(self):
        # Valid input, but more than 256 KiB once normalized/serialized is refused.
        d = {"schema_version": 1, "roots": [], "projects": [
            {"id": "p%d" % i, "title": "t", "summary": "s" * 1000} for i in range(250)]}
        raw = json.dumps(d, separators=(",", ":")).encode()
        self.assertLess(len(raw), bridge_projects.MAX_BYTES)
        self.assertGreater(len(json.dumps(bridge_projects.normalize(d), separators=(",", ":")).encode()),
                           bridge_projects.MAX_BYTES)
        self.assert_rejected(raw=raw)


class FileSafetyTests(Base):
    def test_symlink_file_and_parent_rejected(self):
        real = self.write(GOOD)
        (self.tmp / "link.json").symlink_to(real)
        (self.tmp / "dirlink").symlink_to(self.tmp)
        self.assertEqual(self.get(self.tmp / "link.json")[0], 503)
        self.assertEqual(self.get(self.tmp / "dirlink" / "cat.json")[0], 503)
        self.assertEqual(self.get(real)[0], 200)

    def test_hardlink_rejected(self):
        real = self.write(GOOD)
        os.link(real, self.tmp / "hard.json")
        self.assertEqual(self.get(real)[0], 503)

    def test_non_regular_rejected_without_blocking(self):
        os.mkfifo(self.tmp / "fifo")
        (self.tmp / "dir").mkdir()
        for name in ("fifo", "dir"):
            self.assertEqual(self.get(self.tmp / name)[0], 503, name)
        self.assertEqual(self.get(Path("/dev/null"))[0], 503)
        self.assertEqual(self.get(Path("/dev/zero"))[0], 503)

    def test_inside_bridge_repo_rejected(self):
        checkout = self.tmp / "checkout"
        checkout.mkdir()
        catalog = self.write(GOOD, name="checkout/catalog.json")
        self.assertEqual(self.get(catalog)[0], 200)
        with patch.object(bridge_projects, "REPO_ROOT", str(checkout)):
            self.assertEqual(self.get(catalog)[0], 503)

    def test_path_forms_rejected(self):
        real = self.write(GOOD)
        for p in (str(self.tmp) + "/../" + self.tmp.name + "/cat.json", str(self.tmp) + "//cat.json",
                  str(self.tmp) + "/./cat.json", "cat.json", "~/cat.json"):
            with self.subTest(p=p):
                os.environ[SETTING] = p
                with Server() as s:
                    self.assertEqual(s.req()[2], UNAVAILABLE)
        self.assertEqual(self.get(real)[0], 200)
        with self.assertRaises(bridge_projects.CatalogError):
            bridge_projects.read_catalog_bytes(str(real) + "\0x")

    def test_install_script_uses_plutil_insert_string(self):
        s = (BRIDGE_DIR / "install.sh").read_text()
        self.assertIn('plutil -insert "EnvironmentVariables.$_name" -string "${!_name}"', s)
        self.assertLess(s.index("-insert"), s.index("plutil -lint"))


if __name__ == "__main__":
    unittest.main()
