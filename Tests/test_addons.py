"""Owner-only add-ons: Skills Hub, plugin catalog and MCP catalog (Bridge/bridge_addons.py).

Hermes is mocked throughout: nothing here touches the network or installs anything.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # so `-m unittest Tests.test_addons` works from the repo root
import _isolation  # noqa: F401,E402  (must precede any bridge import; see Tests/_isolation.py)
import json  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import types  # noqa: E402
import unittest  # noqa: E402
from unittest.mock import patch  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_addons as A
import hermes_mobile_bridge as b

ITEM_KEYS = {"id", "name", "description", "source", "trust", "repo", "tags", "installed", "enabled",
             "update_available", "needs_setup", "version"}
SECRET = "sk-test-SUPERSECRET-9137"


def mod(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    return m


class Meta:
    def __init__(self, name, ident, source="official", trust="builtin", tags=(), desc="Does a thing.\nSecond line"):
        self.name, self.identifier, self.source, self.trust_level = name, ident, source, trust
        self.description, self.repo, self.tags = desc, "NousResearch/hermes-agent", list(tags)


def skills_modules(lock=None, official=(), featured=(), search=(), disabled=()):
    lock = lock or {}

    class HubLockFile:
        def by_identifier(self):
            return lock

    class Src:
        def __init__(self, sid):
            self.sid, self.is_available = sid, True

        def source_id(self):
            return self.sid

        def search(self, q, limit=12):
            return list(featured)

    class Official:
        def list_local(self):
            return list(official)

    return {
        "tools.skills_hub": mod("tools.skills_hub", HubLockFile=HubLockFile),
        "tools.skills_hub_official": mod("tools.skills_hub_official", OptionalSkillSource=Official),
        "tools.skills_hub_search": mod("tools.skills_hub_search",
                                       create_source_router=lambda: [Src("hermes-index"), Src("github")],
                                       parallel_search_sources=lambda sources, query, source_filter, overall_timeout:
                                       (list(search), {}, ["github"])),
        "hermes_cli.config": mod("hermes_cli.config", load_config=lambda: {}),
        "hermes_cli.skills_config": mod("hermes_cli.skills_config", get_disabled_skills=lambda c: set(disabled)),
    }


class Spec:
    def __init__(self, name, secret=True, required=True, prompt="Key", default=""):
        self.name, self.secret, self.required, self.prompt, self.default = name, secret, required, prompt, default


def mcp_entry(name, env=(), url=None, command=None, install=None, auth="api_key", examples=()):
    return types.SimpleNamespace(
        name=name, description="Server %s.\nmore" % name, source="https://example.com/%s" % name,
        transport=types.SimpleNamespace(type="http" if url else "stdio", url=url, command=command, args=["-y", name]),
        auth=types.SimpleNamespace(type=auth, env=list(env), provider=None),
        install=install, post_install="", tools=types.SimpleNamespace(default_enabled=None),
        suggest=types.SimpleNamespace(examples=list(examples), keywords=[name]) if examples else None)


def mcp_modules(entries, installed=(), enabled=(), saved=None, env_present=()):
    saved = saved if saved is not None else {}
    by = {e.name: e for e in entries}

    def validate(k):
        if k.startswith("PATH"):
            raise ValueError("Refusing to write %s" % k)

    return {
        "hermes_cli.mcp_catalog": mod("hermes_cli.mcp_catalog", list_catalog=lambda: list(entries),
                                      get_entry=lambda n: by.get(n), is_installed=lambda n: n in installed,
                                      is_enabled=lambda n: n in enabled),
        "hermes_cli.config": mod("hermes_cli.config", save_env_value=lambda k, v: saved.__setitem__(k, v),
                                 validate_env_var_name_for_write=validate,
                                 get_env_value=lambda k: "x" if k in env_present else None),
    }


class CatalogShapeTest(unittest.TestCase):
    def assertItem(self, it):
        self.assertEqual(set(it), ITEM_KEYS)
        self.assertNotIn("\n", it["description"])
        self.assertIn(it["trust"], ("builtin", "trusted", "community", "curated"))

    def test_skills_merge_featured_official_and_installed(self):
        official = [Meta("alpha", "official/x/alpha"), Meta("beta", "official/x/beta")]
        featured = [Meta("hot", "skills-sh/a/hot", source="skills.sh", trust="community"), official[0]]
        lock = {"official/x/beta": {"name": "beta", "trust_level": "builtin"},
                "@me/solo": {"name": "solo", "identifier": "@me/solo", "source": "clawhub", "trust_level": "community"}}
        with patch.dict(sys.modules, skills_modules(lock, official, featured, disabled={"beta"})):
            out = A.w_catalog_skills("")
        ids = [it["id"] for it in out["items"]]
        self.assertEqual(len(ids), len(set(ids)))  # deduped
        self.assertEqual(set(ids), {"official/x/alpha", "official/x/beta", "skills-sh/a/hot", "@me/solo"})
        self.assertEqual(out["featured"], ["skills-sh/a/hot", "official/x/alpha"])
        self.assertEqual(out["kind"], "skills")
        by = {it["id"]: it for it in out["items"]}
        self.assertTrue(by["official/x/beta"]["installed"])
        self.assertFalse(by["official/x/beta"]["enabled"])  # disabled in config
        self.assertIsNone(by["official/x/alpha"]["enabled"])
        self.assertTrue(by["@me/solo"]["installed"])
        self.assertTrue(out["items"][0]["installed"])  # installed first
        for it in out["items"]:
            self.assertItem(it)

    def test_skills_search_dedupes_by_trust_and_caps(self):
        hits = [Meta("k", "id/k", trust="community"), Meta("k", "id/k", trust="trusted")] + \
               [Meta("s%d" % i, "id/s%d" % i, trust="community") for i in range(80)]
        with patch.dict(sys.modules, skills_modules(search=hits)):
            out = A.w_catalog_skills("kube")
        self.assertEqual(len(out["items"]), 50)
        self.assertEqual(out["items"][0]["trust"], "trusted")
        self.assertEqual(out["timed_out"], ["github"])

    def test_plugins_catalog(self):
        entries = [
            {"name": "official-one", "title": "Official One", "description": "x", "tier": "official",
             "category": "tools", "repo": "https://github.com/o/one", "installed": True, "runtime_status": "enabled",
             "update_available": True, "capabilities": {"requires_env": []}, "version": "1.0"},
            {"name": "comm", "title": "", "description": "y", "tier": "community", "category": "fun",
             "repo": "https://github.com/c/comm", "installed": False, "runtime_status": None,
             "update_available": False, "capabilities": {"requires_env": ["API_KEY"]}, "version": None}]
        fake = {"hermes_cli.plugins_cmd_catalog": mod("hermes_cli.plugins_cmd_catalog",
                                                      installed_catalog_state=lambda inst: {"entries": entries},
                                                      catalog_install_record=lambda d: None)}
        rows = [("mine", "0.1", "my own", "user", "/p/mine", "mine")]
        with patch.dict(sys.modules, fake), \
                patch.object(A, "_plugin_locals", lambda: ({"official-one": {"dir": "/p/one", "runtime_status": "enabled"},
                                                            "mine": {"dir": "/p/mine", "runtime_status": "disabled"}}, rows)):
            out = A.w_catalog_plugins("")
            searched = A.w_catalog_plugins("fun")
        by = {it["id"]: it for it in out["items"]}
        self.assertEqual(by["official-one"]["trust"], "trusted")
        self.assertTrue(by["official-one"]["enabled"] and by["official-one"]["update_available"])
        self.assertEqual(by["comm"]["source"], "curated")
        self.assertIsNone(by["comm"]["enabled"])
        self.assertTrue(by["comm"]["needs_setup"])
        self.assertEqual((by["mine"]["source"], by["mine"]["installed"], by["mine"]["enabled"]), ("local", True, False))
        self.assertEqual(out["featured"], ["official-one"])
        self.assertEqual([it["id"] for it in searched["items"]], ["comm"])
        for it in out["items"]:
            self.assertItem(it)

    def test_mcp_catalog(self):
        entries = [mcp_entry("open", url="https://x/mcp", auth="none", examples=["Ask open"]),
                   mcp_entry("keyed", env=[Spec("KEYED_TOKEN")], command="npx"),
                   mcp_entry("have", env=[Spec("HAVE_TOKEN")], url="https://h/mcp")]
        with patch.dict(sys.modules, mcp_modules(entries, installed={"have"}, enabled={"have"})):
            out = A.w_catalog_mcp("")
        by = {it["id"]: it for it in out["items"]}
        self.assertFalse(by["open"]["needs_setup"])
        self.assertTrue(by["keyed"]["needs_setup"])
        self.assertTrue(by["have"]["installed"] and by["have"]["enabled"])
        self.assertTrue(by["have"]["needs_setup"])  # installed but its secret is missing from .env
        self.assertEqual(out["featured"], ["open"])
        self.assertEqual(by["open"]["trust"], "curated")
        for it in out["items"]:
            self.assertItem(it)

    def test_mcp_detail_lists_env_without_values_and_examples(self):
        entries = [mcp_entry("keyed", env=[Spec("KEYED_TOKEN", prompt="Paste a token"), Spec("REGION", secret=False,
                                                                                           required=False)],
                             command="npx", examples=["List my things"])]
        with patch.dict(sys.modules, mcp_modules(entries)):
            d = A.w_detail_mcp("keyed")
            with self.assertRaises(A.AddonError) as cm:
                A.w_detail_mcp("nope")
        self.assertEqual(cm.exception.code, 404)
        self.assertEqual(d["env"], [{"name": "KEYED_TOKEN", "description": "Paste a token", "secret": True, "required": True},
                                    {"name": "REGION", "description": "Key", "secret": False, "required": False}])
        self.assertEqual(d["suggest"], ["List my things"])
        self.assertTrue(any(c.startswith("Runs npx") for c in d["capabilities"]))
        self.assertEqual(set(d), {"item", "readme", "files", "env", "capabilities", "suggest"})


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        A.SCANS.clear()
        A.ACTIONS.clear()
        A.invalidate_catalog()
        self.started = []

        def fake_start(home, profile, **kw):
            self.started.append(kw)
            return "act-1"

        self.enterContext(patch.object(A, "start_action", fake_start))


class ScanGateTest(Base):
    def scan(self, ident="official/x/a", policy="allow", profile="default"):
        with patch.object(A, "run_worker", lambda *a, **k: {"verdict": "safe", "policy": policy, "reason": None,
                                                             "severity_counts": {}, "findings": []}):
            return A.scan(self.home, profile, "skills", ident)["scan_id"]

    def install(self, scan_id, ident="official/x/a", profile="default"):
        return A.install(self.home, profile, "skills", ident, scan_id=scan_id)

    def code(self, fn):
        with self.assertRaises(A.AddonError) as cm:
            fn()
        return cm.exception.code, cm.exception.message

    def test_missing_stale_and_mismatched_scans_are_refused(self):
        self.assertEqual(self.code(lambda: self.install(None)), (409, "Scan it first."))
        self.assertEqual(self.code(lambda: self.install("made-up"))[0], 409)
        other = self.scan(ident="official/x/other")
        self.assertEqual(self.code(lambda: self.install(other))[0], 409)
        other_bot = self.scan(profile="hooke")
        self.assertEqual(self.code(lambda: self.install(other_bot))[0], 409)
        stale = self.scan()
        A.SCANS[stale]["at"] -= A.SCAN_TTL + 1
        self.assertEqual(self.code(lambda: self.install(stale))[0], 409)
        self.assertEqual(self.started, [])

    def test_block_is_forbidden(self):
        sid = self.scan(policy="block")
        self.assertEqual(self.code(lambda: self.install(sid))[0], 403)
        self.assertEqual(self.started, [])

    def test_fresh_scan_installs_through_the_cli_like_the_dashboard(self):
        sid = self.scan(policy="ask")
        out = self.install(sid)
        self.assertEqual(out["status"], "running")
        self.assertEqual(out["action"], "act-1")
        self.assertEqual(out["restart"], "next_session")
        self.assertEqual(set(out), {"status", "action", "message", "restart", "capabilities"})
        self.assertEqual(self.started[0]["cli"], ["skills", "install", "official/x/a", "--yes"])

    def test_scan_shape_for_plugins_and_mcp(self):
        with patch.object(A, "run_worker", lambda *a, **k: {"verdict": "not_scanned", "policy": "ask", "reason": "r",
                                                             "severity_counts": {}, "findings": []}):
            out = A.scan(self.home, "default", "plugins", "comm")
        self.assertEqual(out["verdict"], "not_scanned")
        self.assertTrue(out["scan_id"])
        self.assertIn(out["scan_id"], A.SCANS)

    def test_bad_input(self):
        self.assertEqual(self.code(lambda: A.catalog(self.home, "default", "themes"))[0], 400)
        self.assertEqual(self.code(lambda: A.detail(self.home, "default", "skills", "../etc"))[0], 400)
        self.assertEqual(self.code(lambda: A.enable(self.home, "default", "skills", "x", True))[0], 400)
        self.assertEqual(self.code(lambda: A.enable(self.home, "default", "mcp", "x", "yes"))[0], 400)


class PluginConsentTest(Base):
    def test_install_needs_consent_and_never_forces(self):
        trust = {"policy": "ask", "capabilities": ["Adds tools: a"]}
        with patch.object(A, "run_worker", lambda *a, **k: trust):
            out = A.install(self.home, "default", "plugins", "comm")
        self.assertEqual(out["status"], "consent_required")
        self.assertEqual(out["capabilities"], ["Adds tools: a"])
        self.assertEqual(self.started, [])
        with patch.object(A, "run_worker", lambda *a, **k: trust), patch.object(A, "wait_action", lambda a, s: None):
            out = A.install(self.home, "default", "plugins", "comm", consent=True)
        self.assertEqual(out["status"], "running")
        self.assertEqual(self.started[0]["worker"], ("plugin_install", {"id": "comm"}))
        calls = []
        fake = {"hermes_cli.plugins_cmd": mod("hermes_cli.plugins_cmd", dashboard_install_plugin=lambda *a, **k:
                                              calls.append((a, k)) or {"ok": True, "plugin_name": "comm",
                                                                       "restart_required": True})}
        with patch.dict(sys.modules, fake):
            res = A.w_plugin_install("comm")
        self.assertEqual(calls[0][1]["force"], False)
        self.assertEqual(calls[0][1]["catalog_name"], "comm")
        self.assertEqual(res["restart"], "restart_hermes")

    def test_update_carries_consent_only_when_sent(self):
        seen = []
        fake = {"hermes_cli.plugins_cmd_update": mod("hermes_cli.plugins_cmd_update",
                                                     dashboard_update_user_plugin=lambda n, **k: seen.append(k) or
                                                     {"ok": False, "consent_required": True, "delta_lines": ["+ tool b"]})}
        with patch.dict(sys.modules, fake), patch.object(A, "_plugin_name", lambda i: ("comm", Path("/p"))):
            res = A.w_plugin_update("comm", False)
            A.w_plugin_update("comm", True)
        self.assertEqual(seen, [{"accept_capabilities": False, "force": False},
                                {"accept_capabilities": True, "force": False}])
        self.assertTrue(res["consent_required"])
        self.assertEqual(res["capabilities"], ["+ tool b"])


class McpEnvTest(Base):
    def test_undeclared_env_is_refused(self):
        entries = [mcp_entry("keyed", env=[Spec("KEYED_TOKEN")], command="npx")]
        with patch.dict(sys.modules, mcp_modules(entries)), patch.object(A, "_mcp_plugin_owner", lambda n: None):
            with self.assertRaises(A.AddonError) as cm:
                A.w_mcp_prepare("keyed", {"KEYED_TOKEN": SECRET, "OPENAI_API_KEY": "x"})
        self.assertEqual(cm.exception.code, 400)
        self.assertIn("OPENAI_API_KEY", cm.exception.message)
        self.assertNotIn(SECRET, cm.exception.message)
        with self.assertRaises(A.AddonError) as cm:
            A._clean_env({"bad name": "x"})
        self.assertEqual(cm.exception.code, 400)

    def test_missing_required_env_is_refused(self):
        entries = [mcp_entry("keyed", env=[Spec("KEYED_TOKEN")], command="npx")]
        with patch.dict(sys.modules, mcp_modules(entries)), patch.object(A, "_mcp_plugin_owner", lambda n: None):
            with self.assertRaises(A.AddonError) as cm:
                A.w_mcp_prepare("keyed", {})
        self.assertEqual(cm.exception.code, 400)

    def test_secret_goes_to_env_and_never_into_the_answer_or_the_action(self):
        saved = {}
        entries = [mcp_entry("keyed", env=[Spec("KEYED_TOKEN"), Spec("REGION", secret=False)], command="npx")]
        with patch.dict(sys.modules, mcp_modules(entries, saved=saved)), \
                patch.object(A, "_mcp_plugin_owner", lambda n: None), \
                patch.object(A, "run_worker", lambda op, home, profile, args, timeout=0: A.dispatch(op, args)):
            out = A.install(self.home, "default", "mcp", "keyed", env={"KEYED_TOKEN": SECRET, "REGION": "eu"})
        self.assertEqual(saved, {"KEYED_TOKEN": SECRET})
        self.assertEqual(out["status"], "running")
        self.assertNotIn(SECRET, json.dumps(out))
        self.assertNotIn(SECRET, json.dumps(self.started, default=str))  # only the non-secret value rides to the action
        self.assertEqual(self.started[0]["worker"], ("mcp_install", {"id": "keyed", "env": {"REGION": "eu"}}))

    def test_plugin_provided_mcp_conflicts(self):
        with patch.dict(sys.modules, mcp_modules([])), patch.object(A, "_mcp_plugin_owner", lambda n: "blender"):
            with self.assertRaises(A.AddonError) as cm:
                A.w_uninstall("mcp", "blender-mcp")
        self.assertEqual(cm.exception.code, 409)
        self.assertIn("blender", cm.exception.message)


class ActionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        A.ACTIONS.clear()
        self.enterContext(patch.object(A, "hermes_root", lambda home=None: self.home))

    def run_cli(self, code, verify):
        with patch.object(A, "_cli_command", lambda profile, argv: [sys.executable, "-c", code]):
            return A.start_action(self.home, "default", kind="skills", ident="official/x/a", verb="install",
                                  cli=["skills", "install", "official/x/a", "--yes"], verify=verify)

    def wait(self, action):
        for _ in range(100):
            st = A.action_status(action)
            if st["state"] != "running":
                return st
            time.sleep(0.05)
        self.fail("action never settled")

    def test_running_then_done(self):
        gate = threading.Event()
        action = self.run_cli("import time; print('fetching official/x/a', flush=True); time.sleep(0.4)",
                              lambda r, c: (c == 0, "Installed a."))
        first = A.action_status(action)
        self.assertEqual(first["state"], "running")
        self.assertEqual(set(first), {"state", "log_tail", "message", "restart"})
        st = self.wait(action)
        gate.set()
        self.assertEqual((st["state"], st["message"], st["restart"]), ("done", "Installed a.", "next_session"))
        self.assertIn("fetching official/x/a", st["log_tail"])
        self.assertTrue(str(A.ACTIONS[action]["log"]).startswith(str(self.home / "mobile" / "addons")))

    def test_failure(self):
        action = self.run_cli("import sys; print('nope'); sys.exit(3)", lambda r, c: (c == 0, ""))
        st = self.wait(action)
        self.assertEqual((st["state"], st["restart"]), ("failed", "none"))

    def test_unknown_action(self):
        with self.assertRaises(A.AddonError) as cm:
            A.action_status("missing")
        self.assertEqual(cm.exception.code, 404)

    def test_worker_child_answers_in_json(self):
        """The real child process: Hermes output can't corrupt the answer, and errors keep their code."""
        with patch.object(A, "hermes_root", lambda home=None: Path(__file__).resolve().parents[1]):
            with self.assertRaises(A.AddonError) as cm:
                A.run_worker("no-such-op", self.home, "default", {})
        self.assertEqual((cm.exception.code, cm.exception.message), (400, "Unknown add-on operation."))


class RouteTest(unittest.TestCase):
    def setUp(self):
        import http.client
        from http.server import ThreadingHTTPServer
        self.http = http.client
        self.owner = True
        self.enterContext(patch.object(b.H, "owner_ok", lambda h: self.owner))
        self.enterContext(patch.object(b, "profile_ids", lambda: ["default", "hooke"]))
        self.calls = []
        self.enterContext(patch.object(A, "catalog", lambda home, pid, kind, q="": self.calls.append((pid, kind, q))
                                       or {"kind": kind, "items": [], "featured": [], "timed_out": [], "note": None}))
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), b.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.token = b.make_token("test")

    def req(self, method, path, body=None):
        c = self.http.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        c.request(method, path, body=json.dumps(body) if body is not None else None,
                  headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        r = c.getresponse()
        out = (r.status, json.loads(r.read() or b"null"))
        c.close()
        return out

    def test_capabilities_advertise_addons_for_the_owner_only(self):
        code, doc = self.req("GET", "/m/capabilities")
        self.assertEqual(code, 200)
        self.assertIn("addons_v1", doc["features"])
        self.assertIs(doc["can_manage_addons"], True)
        self.owner = False
        self.assertIs(self.req("GET", "/m/capabilities")[1]["can_manage_addons"], False)

    def test_owner_only(self):
        self.owner = False
        for method, path, body in (("GET", "/m/addons/catalog?kind=skills", None),
                                   ("POST", "/m/addons/install", {"kind": "mcp", "id": "x"}),
                                   ("GET", "/m/addons/action/abc", None)):
            self.assertEqual(self.req(method, path, body),
                             (403, {"error": "Only the phone that owns this Mac can change add-ons."}))
        self.assertEqual(self.calls, [])

    def test_routes_with_profile_and_errors(self):
        code, doc = self.req("GET", "/m/addons/catalog?kind=mcp&q=git&profile=hooke")
        self.assertEqual((code, doc["kind"]), (200, "mcp"))
        self.assertEqual(self.calls, [("hooke", "mcp", "git")])
        self.assertEqual(self.req("GET", "/m/addons/catalog?kind=mcp&profile=ghost")[0], 404)
        self.assertEqual(self.req("POST", "/m/addons/install", {"kind": "skills", "id": "official/x/a"}),
                         (409, {"error": "Scan it first."}))
        self.assertEqual(self.req("GET", "/m/addons/nothing")[0], 404)
        with patch.object(A, "enable", side_effect=A.AddonError(409, "comes with a plugin")):
            self.assertEqual(self.req("POST", "/m/addons/enable", {"kind": "mcp", "id": "x", "enabled": True}),
                             (409, {"error": "comes with a plugin"}))



class BrowsePageTests(unittest.TestCase):
    def test_browsing_a_huge_catalog_sends_a_page_and_says_so(self):
        items = [{"id": f"p{i}", "installed": i in (2000, 2001)} for i in range(2500)]
        out = A._browse_page({"items": items, "featured": ["p1999"], "note": None}, "")
        ids = [it["id"] for it in out["items"]]
        self.assertIn("p2000", ids)
        self.assertIn("p1999", ids)
        self.assertEqual(len(ids), 3 + A.BROWSE_LIMIT)
        self.assertIn("2,500", out["note"])
        self.assertIs(A._browse_page({"items": items}, "x")["items"], items, "a search is never cut")

if __name__ == "__main__":
    unittest.main()
