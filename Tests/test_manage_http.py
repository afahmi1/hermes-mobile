"""Slice B: owner management over HTTP (projects, bots, PIN archive). Synthetic HERMES_HOME, PIN and gateway only."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import asyncio
import base64
import contextlib
import http.client
import importlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parents[1] / "Bridge"
sys.path.insert(0, str(BRIDGE_DIR))

PIN, WRONG = "5807", "1111"
CATALOG = {"schema_version": 1, "roots": [], "projects": [
    {"id": "alpha", "title": "Alpha", "bot_ids": []}, {"id": "beta", "title": "Beta", "bot_ids": []}]}
ALLOW = {"alpha": ["bot-a"], "beta": ["bot-a"]}


def setUpModule():
    global bridge, bo, turns, HOME
    HOME = Path(tempfile.mkdtemp(prefix="bridge-manage-home-")).resolve()
    with patch.dict(os.environ, HERMES_HOME=str(HOME)):
        bridge = importlib.import_module("hermes_mobile_bridge")
    bo, turns = bridge.bridge_owner, bridge.turns
    for pid, extra in (("bot-a", ""), ("bot-b", ""), ("quiet", bridge.OPT_OUT + "\n"), ("health-coach", "")):
        d = HOME / "profiles" / pid
        d.mkdir(parents=True)
        (d / ".env").write_text("API_SERVER_KEY=k-%s\n%s" % (pid, extra))
    (HOME / ".env").write_text("API_SERVER_KEY=k-default\n")


class Clock:
    def __init__(self):
        self.now = time.time()

    def time(self):
        return self.now


class FakeClient:
    def __init__(self):
        self.events = asyncio.Queue()


class FakeGateway:
    def __init__(self):
        self.calls = []

    @contextlib.asynccontextmanager
    async def connect(self, home):
        yield FakeClient()

    async def rpc(self, c, method, **params):
        self.calls.append((method, params))
        if method == "session.create":
            n = sum(1 for m, _ in self.calls if m == "session.create")
            return {"session_id": "rt%d" % n, "stored_session_id": "stored%d" % n}
        if method == "session.resume":
            sid = params["session_id"]
            return {"session_id": sid, "stored_session_id": sid, "revision": 1, "execution_generation": 1, "pending": []}
        if method == "prompt.submit":
            c.events.put_nowait({"method": "event", "params": {"type": "message.complete", "admission_id": "adm-1",
                                 "payload": {"admission_id": "adm-1", "status": "complete", "content": "ok"}}})
            return {"admission_id": "adm-1", "status": "started", "execution_generation": 1}
        return {}


class NoArtifactStore:
    """Any workspace artifact use in a persona-only turn is a bug."""
    def project_for(self, profile, sid):
        return None

    def artifact_dir(self):
        raise AssertionError("persona-only turn created an artifact dir")

    def seed_assignments(self, mapping):  # owner-mode grant evaluation (slice A) on an empty store
        return False

    def all_assignments(self):
        return {}


class Server:
    def __init__(self, tokens):
        self.tokens, self.bodies = tokens, []

    def __enter__(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), bridge.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        return self

    def __exit__(self, *a):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, who="owner", headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        h = dict(headers or {})
        if who:
            h["Authorization"] = "Bearer " + self.tokens[who]
        c.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=h)
        r = c.getresponse()
        raw = r.read()
        c.close()
        self.bodies.append(raw)
        return r.status, (json.loads(raw) if raw else None)


class Base(unittest.TestCase):
    def setUp(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="manage-"))).resolve()
        (tmp / "cat.json").write_text(json.dumps(CATALOG))
        self.state = tmp / "mobile"
        self.state.mkdir(mode=0o700)
        env = {"HERMES_MOBILE_PROJECTS_CATALOG": str(tmp / "cat.json"),
               "HERMES_MOBILE_WORKSPACES": json.dumps(ALLOW),
               "HERMES_MOBILE_OWNER_MANAGED": "1",
               "HERMES_MOBILE_MANAGEABLE_BOTS": json.dumps(["bot-b", "quiet", "default", "ghost"]),
               "HERMES_MOBILE_PERSONA_HOSTS": json.dumps(["bot-a", "quiet", "ghost"])}
        self.enterContext(patch.dict(os.environ, env))
        self.enterContext(patch.object(bridge, "HERMES", HOME))
        self.enterContext(patch.object(bridge, "STATE_DIR", self.state))
        self.clock = Clock()
        self.enterContext(patch.object(bo, "time", self.clock))
        self.log = io.StringIO()
        self.enterContext(patch.object(sys, "stderr", self.log))
        bridge._MANAGE.clear()
        self.gw = FakeGateway()
        self.enterContext(patch.object(turns, "connect", self.gw.connect))
        self.enterContext(patch.object(turns, "_rpc", self.gw.rpc))
        turns.TURNS.clear()
        import bridge_workspaces
        self.store = bridge_workspaces.WorkspaceStore(tmp / "ws")
        self.addCleanup(self.store.close)
        self.enterContext(patch.object(bridge, "workspace_store", lambda: self.store))
        self.srv = self.enterContext(Server({"owner": bridge.make_token("t", owner=True), "legacy": bridge.make_token("t")}))

    def set_pin(self):
        bo.set_pin(self.state / "owner", PIN)

    def archive_project(self, pid="alpha", pin=PIN):
        return self.srv.req("POST", "/m/manage/projects/%s/archive" % pid, {"pin": pin})

    def project_ids(self):
        return [p["id"] for p in self.srv.req("GET", "/m/projects")[1]["projects"]]

    def bot_ids(self):
        return [b["id"] for b in self.srv.req("GET", "/m/bots")[1]["bots"]]

    def overlay_rows(self):
        m = bridge.manage_overlay()
        return (m.archived_projects(), m.archived_bots(), m.managed_projects(), m.personas(), m.personas(archived=True))


MANAGE_ROUTES = [("GET", "/m/manage/archived", None), ("GET", "/m/manage/bots", None),
                 ("POST", "/m/manage/projects", {"title": "X"}), ("PATCH", "/m/manage/projects/x", {"title": "Y"}),
                 ("POST", "/m/manage/projects/alpha/archive", {"pin": PIN}),
                 ("POST", "/m/manage/projects/alpha/restore", {}),
                 ("POST", "/m/manage/bots", {"name": "n", "persona": "p", "host": "bot-a"}),
                 ("POST", "/m/manage/bots/persona-00000000/chats", {}),
                 ("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN}),
                 ("POST", "/m/manage/bots/bot-b/restore", {})]


class GateTests(Base):
    def test_unauthenticated_is_401(self):
        for m, p, b in MANAGE_ROUTES:
            self.assertEqual(self.srv.req(m, p, b, who=None)[0], 401, p)

    def test_build4_token_gets_owner_required_everywhere(self):
        self.set_pin()
        for m, p, b in MANAGE_ROUTES:
            st, d = self.srv.req(m, p, b, who="legacy")
            self.assertEqual((st, d["code"]), (403, "owner_required"), p)
        self.assertEqual(self.srv.req("GET", "/m/projects", who="legacy")[0], 200)  # legacy routes still work
        self.assertEqual(self.srv.req("GET", "/m/bots", who="legacy")[0], 200)
        self.assertEqual(self.overlay_rows()[0], set())

    def test_owner_mode_off_is_403_even_for_owner_token(self):
        with patch.dict(os.environ):
            os.environ.pop("HERMES_MOBILE_OWNER_MANAGED")
            for m, p, b in MANAGE_ROUTES:
                st, d = self.srv.req(m, p, b)
                self.assertEqual((st, d["code"]), (403, "owner_required"), p)
            self.assertEqual(sorted(self.project_ids()), ["alpha", "beta"])  # build-4 behaviour

    def test_rotating_owner_epoch_revokes_owner_tokens(self):
        self.assertEqual(self.srv.req("GET", "/m/manage/archived")[0], 200)
        bo.rotate_epoch(self.state / "owner")
        self.assertEqual(self.srv.req("GET", "/m/manage/archived")[1]["code"], "owner_required")
        self.assertEqual(self.srv.req("GET", "/m/projects")[0], 200)

    def test_login_claims(self):
        """Password login never elevates on its own: owner scope needs the configured identity over the
        trusted loopback/Tailscale Serve path. Every missing or ambiguous condition yields an ordinary token."""
        TS = {"HERMES_MOBILE_OWNER_LOGIN": "Me@Example.com", "HERMES_MOBILE_TRUST_TAILSCALE_SERVE": "1"}
        with patch.object(bridge, "basic_auth", lambda: ("u", "p")):
            def login(headers=None):
                st, d = self.srv.req("POST", "/m/login", {"username": "u", "password": "p"}, who=None, headers=headers)
                self.assertEqual(st, 200)
                return bridge.token_claims(d["token"]), d["token"]
            me = {"Tailscale-User-Login": "me@example.COM"}
            self.assertNotIn("own", login()[0])                      # mode on, no identity configured
            self.assertNotIn("own", login(me)[0])                    # header alone is not enough
            with patch.dict(os.environ, HERMES_MOBILE_OWNER_LOGIN="me@example.com"):
                self.assertNotIn("own", login(me)[0])                # serve trust not asserted
            with patch.dict(os.environ, TS):
                self.assertNotIn("own", login()[0])                  # missing identity header
                self.assertNotIn("own", login({"Tailscale-User-Login": "other@example.com"})[0])
                self.assertNotIn("own", login(dict(me, **{"Tailscale-Funnel-Request": "?1"}))[0])
                with patch.dict(os.environ, HERMES_MOBILE_BIND="0.0.0.0"):
                    self.assertNotIn("own", login(me)[0])            # not loopback-only
                claims, tok = login(me)
                self.assertEqual(claims["own"], 1)
                self.assertLessEqual(claims["iat"], int(time.time()))
                self.srv.tokens["fresh"] = tok
                self.assertEqual(self.srv.req("GET", "/m/manage/archived", who="fresh")[0], 200)
                with patch.dict(os.environ):
                    os.environ.pop("HERMES_MOBILE_OWNER_MANAGED")
                    self.assertNotIn("own", login(me)[0])            # mode off
            _, plain = login()
            self.srv.tokens["plain"] = plain
            self.assertEqual(self.srv.req("GET", "/m/manage/archived", who="plain")[1]["code"], "owner_required")

    def test_duplicate_identity_headers_and_remote_peer_fail_closed(self):
        class FakeHeaders:
            def __init__(self, vals): self.vals = vals
            def get_all(self, k): return self.vals if k == "Tailscale-User-Login" else None
            def get(self, k, d=None): return None
        h = bridge.H.__new__(bridge.H)
        with patch.dict(os.environ, {"HERMES_MOBILE_OWNER_LOGIN": "me@example.com",
                                     "HERMES_MOBILE_TRUST_TAILSCALE_SERVE": "1"}):
            h.client_address = ("127.0.0.1", 5)
            h.headers = FakeHeaders(["me@example.com"])
            self.assertTrue(h.login_elevates_to_owner())
            h.headers = FakeHeaders(["me@example.com", "me@example.com"])
            self.assertFalse(h.login_elevates_to_owner())
            h.headers = FakeHeaders(["me@example.com"])
            h.client_address = ("100.64.0.9", 5)
            self.assertFalse(h.login_elevates_to_owner())


class PinSetupTests(Base):
    NEW = "3916"  # second synthetic PIN

    def pin_post(self, body, who="owner"):
        return self.srv.req("POST", "/m/manage/pin", body, who=who)

    def test_first_set_change_and_fail_closed(self):
        self.assertEqual(self.srv.req("GET", "/m/manage/pin")[1], {"configured": False})
        self.assertEqual(self.pin_post({"pin": PIN, "confirm": "0000"})[1]["code"], "pin_mismatch")
        self.assertEqual(self.pin_post({"pin": "12a4", "confirm": "12a4"})[1]["code"], "pin_invalid")
        self.assertEqual(self.pin_post({"pin": PIN, "confirm": PIN}, who="legacy")[1]["code"], "owner_required")
        self.assertEqual(self.srv.req("GET", "/m/manage/pin")[1], {"configured": False})
        st, d = self.pin_post({"pin": PIN, "confirm": PIN})
        self.assertEqual((st, d), (200, {"ok": True, "configured": True}))
        # change: needs the current PIN; a first-set body no longer works
        self.assertEqual(self.pin_post({"pin": self.NEW, "confirm": self.NEW})[1]["code"], "pin_required")
        self.assertEqual(self.pin_post({"pin": self.NEW, "confirm": self.NEW, "current": "1111"})[1]["code"], "pin_wrong")
        self.assertEqual(self.pin_post({"pin": self.NEW, "confirm": self.NEW, "current": PIN})[0], 200)
        # the old PIN no longer archives; the new one does
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/beta/archive", {"pin": PIN})[1]["code"], "pin_wrong")
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/beta/archive", {"pin": self.NEW})[0], 200)
        for raw in self.srv.bodies:
            self.assertNotIn(self.NEW.encode(), raw)
        self.assertNotIn(self.NEW, self.log.getvalue())
        self.assertNotIn(self.NEW, (self.state / "owner" / "owner_pin.json").read_text())

    def test_change_shares_the_lockout_with_archive(self):
        self.set_pin()
        for _ in range(4):
            self.srv.req("POST", "/m/manage/projects/beta/archive", {"pin": "1111"})
        st, d = self.pin_post({"pin": self.NEW, "confirm": self.NEW, "current": "1112"})
        self.assertEqual((st, d["code"]), (429, "pin_locked"))
        self.assertEqual(self.pin_post({"pin": self.NEW, "confirm": self.NEW, "current": PIN})[1]["code"], "pin_locked")

    def test_tampered_verifier_is_never_overwritten_from_the_app(self):
        self.set_pin()
        f = self.state / "owner" / "owner_pin.json"
        f.write_text("{not json")
        st, d = self.pin_post({"pin": self.NEW, "confirm": self.NEW, "current": PIN})
        self.assertEqual((st, d["code"]), (503, "pin_unset"))
        self.assertEqual(f.read_text(), "{not json")
        self.assertEqual(self.srv.req("GET", "/m/manage/pin")[1], {"configured": False})


class ProjectTests(Base):
    def test_create_patch_and_persist(self):
        st, p = self.srv.req("POST", "/m/manage/projects", {"title": "My New Project", "summary": "S"})
        self.assertEqual((st, p["id"], p["managed"], p["summary"]), (201, "my-new-project", True, "S"))
        self.assertEqual(self.srv.req("POST", "/m/manage/projects", {"title": "My New Project"})[1]["id"], "my-new-project-2")
        self.assertEqual(self.srv.req("POST", "/m/manage/projects", {"title": "T", "id": "custom_1"})[1]["id"], "custom_1")
        self.assertIn("my-new-project", self.project_ids())
        bridge._MANAGE.clear()  # reload from disk
        self.assertIn("my-new-project", self.project_ids())
        st, d = self.srv.req("PATCH", "/m/manage/projects/my-new-project", {"title": "Renamed"})
        self.assertEqual((st, d["title"], d["summary"]), (200, "Renamed", "S"))
        titles = {p["id"]: p["title"] for p in self.srv.req("GET", "/m/projects")[1]["projects"]}
        self.assertEqual(titles["my-new-project"], "Renamed")
        self.assertEqual(titles["alpha"], "Alpha")
        st, d = self.srv.req("PATCH", "/m/manage/projects/alpha", {"title": "Hack"})
        self.assertEqual((st, d["code"]), (403, "read_only"))
        self.assertEqual(self.srv.req("PATCH", "/m/manage/projects/nope", {"title": "x"})[0], 404)
        cat = json.loads(Path(os.environ["HERMES_MOBILE_PROJECTS_CATALOG"]).read_text())
        self.assertEqual(cat, CATALOG)  # catalog file never written

    def test_validation_and_uniqueness(self):
        def req(b):
            return self.srv.req("POST", "/m/manage/projects", b)
        for bad in ({}, {"title": ""}, {"title": "x" * 121}, {"title": "ok", "summary": "s" * 1001}, {"title": 5},
                    {"title": "ok", "id": "Bad Id"}, {"title": "ok", "id": "../x"}, {"title": "a\x00b"}):
            self.assertEqual(req(bad)[0], 400, bad)
        self.assertEqual(req({"title": "x" * 120, "summary": "s" * 1000})[0], 201)
        st, d = req({"title": "Dup", "id": "alpha"})  # catalog id
        self.assertEqual((st, d["code"]), (409, "id_taken"))
        self.assertEqual(req({"title": "A", "id": "mine"})[0], 201)
        self.assertEqual(req({"title": "A", "id": "mine"})[0], 409)  # managed id
        self.set_pin()
        self.assertEqual(self.archive_project("alpha")[0], 200)
        self.assertEqual(req({"title": "A", "id": "alpha"})[0], 409)  # archived id stays reserved

    def test_cap_of_64_managed(self):
        for i in range(64):
            self.assertEqual(self.srv.req("POST", "/m/manage/projects", {"title": "p", "id": "p%d" % i})[0], 201)
        st, d = self.srv.req("POST", "/m/manage/projects", {"title": "p", "id": "extra"})
        self.assertEqual((st, d["code"]), (409, "limit"))

    def test_managed_projects_alone_form_a_catalog(self):
        with patch.dict(os.environ):
            os.environ.pop("HERMES_MOBILE_PROJECTS_CATALOG")
            self.assertFalse(self.srv.req("GET", "/m/projects")[1]["configured"])
            self.srv.req("POST", "/m/manage/projects", {"title": "Solo"})
            doc = self.srv.req("GET", "/m/projects")[1]
            self.assertTrue(doc["configured"])
            self.assertEqual([p["id"] for p in doc["projects"]], ["solo"])

    def test_archive_restore_round_trip_keeps_workspace_data(self):
        self.set_pin()
        self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "Be brief."})
        before = self.srv.req("GET", "/m/workspaces/alpha")
        self.assertEqual((before[0], before[1]["instructions"]), (200, "Be brief."))
        self.assertIn("alpha", self.srv.req("GET", "/m/workspaces")[1]["projects"])
        self.assertEqual(self.archive_project("alpha")[0], 200)
        self.assertEqual(self.project_ids(), ["beta"])
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha")[0], 404)
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "x"})[0], 404)
        self.assertNotIn("alpha", self.srv.req("GET", "/m/workspaces")[1]["projects"])
        self.assertEqual(self.srv.req("GET", "/m/manage/archived")[1]["projects"],
                         [{"id": "alpha", "title": "Alpha", "managed": False}])
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/alpha/restore", {})[0], 200)
        self.assertEqual(sorted(self.project_ids()), ["alpha", "beta"])
        after = self.srv.req("GET", "/m/workspaces/alpha")
        self.assertEqual((after[0], after[1]["instructions"]), (200, "Be brief."))
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/alpha/restore", {})[0], 404)

    def test_archive_managed_project_and_no_turn_scoping(self):
        self.set_pin()
        self.srv.req("POST", "/m/manage/projects", {"title": "Mine", "id": "mine"})
        self.assertEqual(self.archive_project("mine")[0], 200)
        self.assertNotIn("mine", self.project_ids())
        self.assertEqual(self.archive_project("mine")[0], 404)  # already archived
        self.assertEqual(self.archive_project("ghost")[0], 404)
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/mine/restore", {})[0], 200)
        self.assertIn("mine", self.project_ids())
        # An archived catalog project no longer scopes turns for its chats.
        self.store.link_chat("alpha", "bot-a", "stored1", "t")
        self.assertIn("bot-a", bridge.workspace_grants()["alpha"])
        self.archive_project("alpha")
        self.assertNotIn("alpha", bridge.workspace_grants())
        self.assertIsNone(bridge.prepare_workspace_turn("bot-a", "stored1", {}))  # linked to archived alpha: no scope
        with self.assertRaises(bridge.WorkspaceError):
            bridge.prepare_workspace_turn("bot-a", "stored1", {"project_context": "alpha"})


class PinTests(Base):
    def test_wrong_pin_changes_nothing(self):
        self.set_pin()
        before = self.overlay_rows()
        st, d = self.archive_project("alpha", WRONG)
        self.assertEqual((st, d["code"]), (403, "pin_wrong"))
        st, d = self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": WRONG})
        self.assertEqual((st, d["code"]), (403, "pin_wrong"))
        self.assertEqual(self.overlay_rows(), before)
        self.assertEqual(sorted(self.project_ids()), ["alpha", "beta"])
        self.assertIn("bot-b", self.bot_ids())
        st, d = self.srv.req("POST", "/m/manage/projects/alpha/archive", {})
        self.assertEqual((st, d["code"]), (400, "pin_required"))
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/alpha/archive", {"pin": 5807})[0], 403)
        self.assertEqual(self.srv.req("POST", "/m/manage/projects/alpha/archive", {"pin": "58070"})[0], 403)
        self.assertEqual(self.overlay_rows(), before)
        # The PIN is only read from the JSON body, never the URL or query string.
        st, d = self.srv.req("POST", "/m/manage/projects/alpha/archive?pin=%s" % PIN, {})
        self.assertEqual((st, d["code"]), (400, "pin_required"))
        self.assertEqual(self.overlay_rows(), before)

    def test_same_pin_guards_both_archives(self):
        self.set_pin()
        self.assertEqual(self.archive_project("alpha")[0], 200)
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})[0], 200)
        self.assertNotIn("bot-b", self.bot_ids())

    def test_lockout_is_shared_persisted_and_expires(self):
        self.set_pin()
        for _ in range(3):
            self.assertEqual(self.archive_project("alpha", WRONG)[0], 403)
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": WRONG})[0], 403)
        st, d = self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": WRONG})
        self.assertEqual((st, d["code"]), (429, "pin_locked"))
        self.assertGreater(d["retry_after"], 0)
        # Both routes are now locked, even with the right PIN.
        self.assertEqual(self.archive_project("alpha")[1]["code"], "pin_locked")
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})[0], 429)
        self.assertEqual(self.overlay_rows()[:2], (set(), set()))
        bridge._MANAGE.clear()  # restart: a fresh handler/limiter reads the file
        with Server(self.srv.tokens) as fresh:
            self.assertEqual(fresh.req("POST", "/m/manage/projects/alpha/archive", {"pin": PIN})[0], 429)
        self.clock.now += 301
        self.assertEqual(self.archive_project("alpha")[0], 200)
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})[0], 200)  # success reset it

    def test_missing_loose_or_symlinked_verifier_fails_closed(self):
        st, d = self.archive_project("alpha")
        self.assertEqual((st, d["code"]), (503, "pin_unset"))
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})[1]["code"], "pin_unset")
        self.set_pin()
        f = self.state / "owner" / "owner_pin.json"
        os.chmod(f, 0o644)
        self.assertEqual(self.archive_project("alpha")[1]["code"], "pin_unset")
        os.chmod(f, 0o600)
        real = self.state / "elsewhere.json"
        f.rename(real)
        os.symlink(real, f)
        self.assertEqual(self.archive_project("alpha")[1]["code"], "pin_unset")
        self.assertEqual(self.overlay_rows()[:2], (set(), set()))
        self.assertEqual(sorted(self.project_ids()), ["alpha", "beta"])

    def test_unauthenticated_and_legacy_never_reach_the_pin(self):
        self.set_pin()
        self.srv.req("POST", "/m/manage/projects/alpha/archive", {"pin": WRONG}, who="legacy")
        self.srv.req("POST", "/m/manage/projects/alpha/archive", {"pin": WRONG}, who=None)
        self.assertEqual(json.loads((self.state / "owner" / "owner_pin_attempts.json").read_text())["fails"], 0)


class BotTests(Base):
    def profiles_snapshot(self):
        return sorted((str(p.relative_to(HOME)), p.stat().st_mtime_ns, p.stat().st_size)
                      for p in (HOME / "profiles").rglob("*"))

    def test_live_bot_archive_restore_and_protection(self):
        self.set_pin()
        snap = self.profiles_snapshot()
        self.assertTrue(all(b["managed"] is False for b in self.srv.req("GET", "/m/bots")[1]["bots"]))
        self.assertEqual(self.srv.req("GET", "/m/manage/bots")[1]["manageable"], ["bot-b"])
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})[0], 200)
        self.assertNotIn("bot-b", self.bot_ids())
        self.assertEqual(self.srv.req("GET", "/m/manage/archived")[1]["bots"][0]["id"], "bot-b")
        self.assertNotIn("bot-b", self.srv.req("GET", "/m/manage/bots")[1]["manageable"])
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-b/restore", {})[0], 200)
        self.assertIn("bot-b", self.bot_ids())
        self.assertEqual(self.profiles_snapshot(), snap)  # nothing under profiles/ touched

    def test_protected_default_and_unlisted_bots_refuse_even_with_correct_pin(self):
        self.set_pin()
        for bid in ("default", "quiet", "health-coach", "bot-a", "ghost", "nope"):
            st, d = self.srv.req("POST", "/m/manage/bots/%s/archive" % bid, {"pin": PIN})
            self.assertEqual((st, d["code"]), (403, "not_manageable"), bid)
        self.assertEqual(self.overlay_rows()[1], set())
        self.assertIn("default", self.bot_ids())

    def test_archived_live_bot_loses_workspace_grants(self):
        self.set_pin()
        self.assertIn("bot-a", bridge.workspace_grants()["alpha"])
        with patch.dict(os.environ, HERMES_MOBILE_MANAGEABLE_BOTS=json.dumps(["bot-a"])):
            self.assertEqual(self.srv.req("POST", "/m/manage/bots/bot-a/archive", {"pin": PIN})[0], 200)
        self.assertEqual(bridge.workspace_grants(), {})
        self.assertNotIn("bot-a", self.bot_ids())
        self.srv.req("POST", "/m/manage/bots/bot-a/restore", {})
        self.assertIn("bot-a", bridge.workspace_grants()["alpha"])

    def test_persona_create_needs_operator_host(self):
        body = {"name": "Poet", "persona": "Speak in verse.", "host": "bot-a"}
        with patch.dict(os.environ):
            os.environ.pop("HERMES_MOBILE_PERSONA_HOSTS")
            st, d = self.srv.req("POST", "/m/manage/bots", body)
            self.assertEqual((st, d["code"]), (403, "no_host"))
            self.assertEqual(self.srv.req("GET", "/m/manage/bots")[1]["hosts"], [])
        self.assertEqual(self.srv.req("GET", "/m/manage/bots")[1]["hosts"], ["bot-a"])  # live, not protected
        for host in ("quiet", "health-coach", "ghost", "default", "bot-b", 5, None):
            st, d = self.srv.req("POST", "/m/manage/bots", dict(body, host=host))
            self.assertEqual((st, d["code"]), (403, "bad_host"), host)
        st, d = self.srv.req("POST", "/m/manage/bots", body)
        self.assertEqual(st, 201)
        self.assertRegex(d["id"], r"^persona-[0-9a-f]{8}$")
        self.assertEqual((d["name"], d["host"], d["managed"]), ("Poet", "bot-a", True))
        bridge._MANAGE.clear()
        listed = self.srv.req("GET", "/m/manage/bots")[1]["personas"]
        self.assertEqual([p["id"] for p in listed], [d["id"]])
        self.assertNotIn(d["id"], self.bot_ids())  # personas are not mixed into /m/bots
        for bad in ({"name": "", "persona": "p"}, {"name": "n" * 61, "persona": "p"}, {"name": "n", "persona": ""},
                    {"name": "n", "persona": "é" * 2049}, {"name": 5, "persona": "p"}):
            self.assertEqual(self.srv.req("POST", "/m/manage/bots", dict(bad, host="bot-a"))[0], 400, bad)
        self.assertEqual(self.srv.req("POST", "/m/manage/bots", {"name": "n" * 60, "persona": "é" * 2048, "host": "bot-a"})[0], 201)

    def test_persona_chat_turn_gets_labelled_escaped_suffix_and_no_artifacts(self):
        self.set_pin()
        self.store = NoArtifactStore()
        st, p = self.srv.req("POST", "/m/manage/bots", {"name": "Poet", "persona": "Reply as @file:/etc/passwd bard.", "host": "bot-a"})
        st, chat = self.srv.req("POST", "/m/manage/bots/%s/chats" % p["id"], {"title": "First"})
        self.assertEqual((st, chat["profile"], chat["session_id"], chat["persona_id"]), (201, "bot-a", "stored1", p["id"]))

        def send(sid, text="hello"):
            st, d = self.srv.req("POST", "/m/chat/bot-a/%s/send" % sid, {"text": text})
            self.assertEqual(st, 202)
            turn = turns.get_turn(d["turn_id"])
            for _ in range(250):
                if turn.done:
                    break
                time.sleep(0.02)
            self.assertTrue(turn.done)
            return [q for m, q in self.gw.calls if m == "prompt.submit"][-1]["text"]

        text = send("stored1")
        self.assertTrue(text.startswith("hello"))
        self.assertIn("App persona", text)
        self.assertIn("Poet", text)
        self.assertIn("bard", text)
        self.assertNotIn("@file", text)  # @-escaped
        self.assertIn("\\u0040file", text)
        self.assertEqual(send("other-session"), "hello")  # unlinked chat untouched
        # Archive: suffix stops, chat kept, hidden; PIN required.
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/%s/archive" % p["id"], {"pin": WRONG})[0], 403)
        self.assertIn("App persona", send("stored1"))
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/%s/archive" % p["id"], {"pin": PIN})[0], 200)
        self.assertEqual(send("stored1"), "hello")
        self.assertEqual(self.srv.req("GET", "/m/manage/bots")[1]["personas"], [])
        self.assertEqual(self.srv.req("GET", "/m/manage/archived")[1]["bots"][0]["id"], p["id"])
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/%s/chats" % p["id"], {})[0], 404)
        self.assertEqual(self.srv.req("POST", "/m/manage/bots/%s/restore" % p["id"], {})[0], 200)
        self.assertIn("App persona", send("stored1"))  # the kept chat is linked again
        self.assertEqual(bridge.manage_overlay().persona_for("bot-a", "stored1")["id"], p["id"])


class LeakTests(Base):
    def test_pin_never_in_logs_responses_or_files(self):
        self.set_pin()
        self.archive_project("alpha", WRONG)
        self.archive_project("alpha", PIN)
        self.srv.req("POST", "/m/manage/bots/bot-b/archive", {"pin": PIN})
        self.srv.req("POST", "/m/manage/projects/beta/archive", {"pin": "bad"})
        self.srv.req("GET", "/m/manage/archived")
        self.assertNotIn(PIN, self.log.getvalue())
        self.assertNotIn(WRONG, self.log.getvalue())
        for body in self.srv.bodies:
            self.assertNotIn(PIN.encode(), body)
            self.assertNotIn(WRONG.encode(), body)
        self.assertNotIn(PIN, (self.state / "owner" / "owner_pin.json").read_text())
        for p in (self.state / "manage").iterdir():
            self.assertNotIn(PIN.encode(), p.read_bytes())
        self.assertEqual(stat.S_IMODE((self.state / "manage" / "manage.db").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.state / "manage").stat().st_mode), 0o700)
        self.assertNotIn(PIN, repr(bo.OwnerError("pin_wrong", 403)))

    def test_oversized_manage_body_rejected(self):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.srv.server_address[1], timeout=5)
        c.request("POST", "/m/manage/projects", body=b"x" * (bridge.WS_MAX_BODY + 1),
                  headers={"Authorization": "Bearer " + self.srv.tokens["owner"]})
        self.assertEqual(c.getresponse().status, 413)


class CliTests(unittest.TestCase):
    def test_issue_owner_token_and_rotate(self):
        home = Path(tempfile.mkdtemp(prefix="manage-cli-")).resolve()
        env = dict(os.environ, HERMES_HOME=str(home), HERMES_MOBILE_STATE_DIR=str(home / "mobile"))
        script = str(BRIDGE_DIR / "hermes_mobile_bridge.py")

        def run(*args):
            r = subprocess.run([sys.executable, script, *args], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.strip()

        def claims_of(tok):
            return json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))
        claims = claims_of(run("--issue-token", "mac", "--owner"))
        self.assertEqual((claims["own"], claims["dev"]), (1, "mac"))
        self.assertGreaterEqual(claims["iat"], int((home / "mobile" / "owner" / "owner_epoch").read_text()))
        self.assertNotIn("own", claims_of(run("--issue-token", "mac")))
        run("--rotate-owner-sessions")
        self.assertGreater(int((home / "mobile" / "owner" / "owner_epoch").read_text()), claims["iat"])
        self.assertEqual(stat.S_IMODE((home / "mobile" / "owner" / "owner_epoch").stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
