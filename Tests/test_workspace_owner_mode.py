"""Build 5 slice A: owner-managed workspaces over HTTP, against the REAL WorkspaceStore.

Synthetic HERMES_HOME, synthetic catalog, ephemeral loopback port. No network, no live bridge.
"""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import base64
import hashlib
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

CATALOG = {"schema_version": 1, "roots": [], "projects": [
    {"id": "alpha", "title": "Alpha", "bot_ids": ["default", "bot-a", "quiet", "nokey"]},
    {"id": "delta", "title": "Delta", "bot_ids": []},
    {"id": "zero", "title": "Zero", "bot_ids": ["bot-z"]},
]}
ELIGIBLE = ["bot-a", "bot-b", "quiet", "nokey", "robinhood-cli", "ghost"]
OWNER_ENV = {"HERMES_MOBILE_OWNER_MANAGED": "1", "HERMES_MOBILE_WORKSPACE_BOTS": json.dumps(ELIGIBLE)}


def b64(s):
    return base64.b64encode(s.encode()).decode()


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def setUpModule():
    global bridge, HOME
    HOME = Path(tempfile.mkdtemp(prefix="bridge-own-home-")).resolve()
    with patch.dict(os.environ, HERMES_HOME=str(HOME)):
        bridge = importlib.import_module("hermes_mobile_bridge")
    for pid, extra, key in (("bot-a", "", True), ("bot-b", "", True), ("quiet", bridge.OPT_OUT + "\n", True),
                            ("nokey", "", False), ("robinhood-cli", "", True)):
        d = HOME / "profiles" / pid
        d.mkdir(parents=True)
        (d / ".env").write_text(("API_SERVER_KEY=k-%s\n" % pid if key else "") + extra)
    (HOME / ".env").write_text("API_SERVER_KEY=k-default\n")


class Server:
    def __enter__(self):
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), bridge.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.token = bridge.make_token("test", owner=True)  # explicit local owner issuance
        return self

    def __exit__(self, *a):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, auth=True):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        h = {"Authorization": "Bearer " + self.token} if auth else {}
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, (json.loads(data) if data else None)


class Base(unittest.TestCase):
    env = OWNER_ENV
    legacy = {}

    def setUp(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ws-own-"))).resolve()
        (tmp / "cat.json").write_text(json.dumps(CATALOG))
        self.root = tmp / "ws"
        env = {"HERMES_MOBILE_PROJECTS_CATALOG": str(tmp / "cat.json"), **self.env}
        if self.legacy:
            env["HERMES_MOBILE_WORKSPACES"] = json.dumps(self.legacy)
        self.enterContext(patch.dict(os.environ, env))
        for k in ("HERMES_MOBILE_WORKSPACES", "HERMES_MOBILE_WORKSPACE_BOTS", "HERMES_MOBILE_OWNER_MANAGED"):
            if k not in env:
                os.environ.pop(k, None)
        self.enterContext(patch.object(bridge, "HERMES", HOME))
        self.use_store(bridge.workspaces_mod.WorkspaceStore(self.root))
        self.srv = self.enterContext(Server())

    def use_store(self, store):
        self.store = store
        self.addCleanup(store.close)
        p = patch.object(bridge, "workspace_store", lambda: store)
        p.start()
        self.addCleanup(p.stop)

    def reload(self):
        """Fresh store + a fresh handler server, as after a bridge restart."""
        self.store.close()
        self.srv.__exit__()
        self.use_store(bridge.workspaces_mod.WorkspaceStore(self.root))
        self.srv = Server().__enter__()

    def put_assign(self, p, profiles, revision):
        return self.srv.req("PUT", "/m/workspaces/%s/assignment" % p, {"profiles": profiles, "revision": revision})

    def detail(self, p):
        st, d = self.srv.req("GET", "/m/workspaces/" + p)
        self.assertEqual(st, 200)
        return d


class OwnerVisibility(Base):
    def test_every_catalog_project_visible_and_editable_including_zero_bots(self):
        st, d = self.srv.req("GET", "/m/workspaces")
        self.assertEqual(st, 200)
        self.assertEqual((d["mode"], d["projects"], d["profiles"]), ("owner", ["alpha", "delta", "zero"], []))
        by = {w["id"]: w for w in d["workspaces"]}
        self.assertEqual(by["alpha"]["eligible"], ["bot-a"])
        self.assertEqual(by["delta"]["eligible"], ["bot-a", "bot-b"])
        self.assertEqual(by["zero"]["eligible"], [])
        for p in ("alpha", "delta", "zero"):
            det = self.detail(p)
            self.assertEqual((det["mode"], det["chats"], det["profiles"]), ("owner", [], []))
            self.assertEqual(self.srv.req("PUT", "/m/workspaces/%s/instructions" % p, {"instructions": "hi " + p})[0], 200)
            st, row = self.srv.req("POST", "/m/workspaces/%s/files" % p, {"name": "n.txt", "data": b64("body " + p)})
            self.assertEqual((st, row["sha"]), (201, sha("body " + p)))
            det = self.detail(p)
            self.assertEqual(det["instructions"], "hi " + p)
            self.assertEqual(det["instructions_revision"], sha("hi " + p))
            self.assertEqual(det["files"][0]["editable"], True)
            self.assertEqual(det["files"][0]["sha"], sha("body " + p))
            self.assertEqual(det["assignment"]["editable"], True)

    def test_no_default_assignments_and_chat_creation_needs_active_grant(self):
        for p in ("alpha", "delta"):
            self.assertEqual(self.detail(p)["assignment"]["assigned"], [])
            st, d = self.srv.req("POST", "/m/workspaces/%s/chats" % p, {"profile": "bot-a"})
            self.assertEqual(st, 403)
        self.put_assign("alpha", ["bot-a"], 0)
        with patch.object(bridge.turns, "create_session", lambda *a, **k: {"stored_session_id": "s1"}):
            st, d = self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-a", "title": "T"})
            self.assertEqual(st, 201)
            self.assertEqual(self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-b"})[0], 403)

    def test_archived_or_non_catalog_project_404(self):
        for p in ("nowhere", "BAD"):
            self.assertEqual(self.srv.req("GET", "/m/workspaces/" + p)[0], 404)
            self.assertEqual(self.srv.req("PUT", "/m/workspaces/%s/instructions" % p, {"instructions": "x"})[0], 404)
            self.assertEqual(self.put_assign(p, [], 0)[0], 404)

    def test_malformed_bot_setting_is_empty_eligible_but_workspaces_visible(self):
        for bad in ("not json", "{}", json.dumps([1]), ""):
            with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACE_BOTS": bad}):
                st, d = self.srv.req("GET", "/m/workspaces")
                self.assertEqual(d["projects"], ["alpha", "delta", "zero"])
                self.assertEqual([w["eligible"] for w in d["workspaces"]], [[], [], []])
                self.assertEqual(self.put_assign("alpha", ["bot-a"], 0)[0], 403)

    def test_eligible_defaults_to_union_of_legacy_allowlist(self):
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACES": json.dumps({"alpha": ["bot-a"], "delta": ["bot-b"]})}):
            os.environ.pop("HERMES_MOBILE_WORKSPACE_BOTS")
            st, d = self.srv.req("GET", "/m/workspaces")
            by = {w["id"]: w["eligible"] for w in d["workspaces"]}
            self.assertEqual(by, {"alpha": ["bot-a"], "delta": ["bot-a", "bot-b"], "zero": []})

    def test_unauthenticated(self):
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/assignment", {"profiles": [], "revision": 0}, auth=False)[0], 401)
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/files/x", auth=False)[0], 401)


class AssignmentTests(Base):
    def test_put_persists_across_new_store_and_handler(self):
        st, d = self.put_assign("alpha", ["bot-a"], 0)
        self.assertEqual(st, 200)
        self.assertEqual((d["assignment"]["assigned"], d["assignment"]["revision"]), (["bot-a"], 1))
        self.reload()
        det = self.detail("alpha")
        self.assertEqual((det["assignment"]["assigned"], det["assignment"]["revision"], det["profiles"]), (["bot-a"], 1, ["bot-a"]))
        self.assertEqual(self.srv.req("GET", "/m/workspaces")[1]["profiles"], ["bot-a"])

    def test_rejections_change_nothing(self):
        # ghost unknown, robinhood-cli protected name, quiet opted out, nokey no key, bot-b not in alpha's catalog list
        for bad in ("ghost", "robinhood-cli", "quiet", "nokey", "bot-b", "default", "bot-zz", "../x"):
            st, d = self.put_assign("alpha", ["bot-a", bad], 0)
            self.assertEqual((st, d.get("code")), (403, "not_eligible"), bad)
        self.assertEqual(self.put_assign("alpha", ["bot-a"], 0)[0], 200)
        self.assertEqual(self.detail("alpha")["assignment"]["assigned"], ["bot-a"])
        self.assertEqual(self.detail("alpha")["assignment"]["revision"], 1)
        self.assertEqual(self.detail("delta")["assignment"]["revision"], 0)
        # bot-a assigned to alpha is another project's bot for zero (catalog lists only bot-z)
        st, d = self.put_assign("zero", ["bot-a"], 0)
        self.assertEqual((st, d.get("code")), (403, "not_eligible"))

    def test_bad_bodies(self):
        for body in ({"profiles": "bot-a", "revision": 0}, {"profiles": [1], "revision": 0}, {"profiles": []},
                     {"profiles": [], "revision": "0"}, {"profiles": [], "revision": True}, {"revision": 0},
                     {"profiles": ["bot-a"] * 33, "revision": 0}):
            self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/assignment", body)[0], 400, body)
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/assignment")[0], 405)

    def test_non_owner_rejected_without_state_change(self):
        with patch.object(bridge.H, "owner_ok", lambda self: False):
            st, d = self.put_assign("alpha", ["bot-a"], 0)
        self.assertEqual((st, d.get("code")), (403, "owner_required"))
        self.assertEqual(self.detail("alpha")["assignment"]["revision"], 0)

    def test_stale_revision_409_with_assignment(self):
        self.put_assign("alpha", ["bot-a"], 0)
        st, d = self.put_assign("alpha", [], 0)
        self.assertEqual((st, d["code"]), (409, "stale"))
        self.assertEqual((d["assignment"]["revision"], d["assignment"]["assigned"]), (1, ["bot-a"]))

    def test_empty_allowed_and_removal_keeps_then_restores_chats_and_artifacts(self):
        self.put_assign("alpha", ["bot-a"], 0)
        self.store.link_chat("alpha", "bot-a", "s1", "Chat")
        d = self.store.artifact_dir()
        (d / "o.txt").write_bytes(b"out")
        self.store.capture("alpha", "bot-a", "s1", d, "x\nMEDIA:%s" % (d / "o.txt"))
        det = self.detail("alpha")
        self.assertEqual((len(det["chats"]), len(det["artifacts"]), det["hidden_chats"]), (1, 1, 0))
        st, d = self.put_assign("alpha", [], 1)
        self.assertEqual((st, d["assignment"]["assigned"]), (200, []))
        det = self.detail("alpha")
        self.assertEqual((det["chats"], det["artifacts"], det["hidden_chats"], det["profiles"]), ([], [], 1, []))
        self.assertIsNone(bridge.prepare_workspace_turn("bot-a", "s1", {}))
        st, d = self.put_assign("alpha", ["bot-a"], 2)
        det = self.detail("alpha")
        self.assertEqual((len(det["chats"]), len(det["artifacts"]), det["hidden_chats"]), (1, 1, 0))
        scope = bridge.prepare_workspace_turn("bot-a", "s1", {})
        self.assertEqual(scope["project"], "alpha")
        self.assertIsNone(scope["summary"])  # per-send project_context stays opt-in
        self.store.discard_output(scope["output_dir"])

    def test_inactive_stored_assignment_reported(self):
        self.put_assign("alpha", ["bot-a"], 0)
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACE_BOTS": json.dumps(["bot-b"])}):
            a = self.detail("alpha")["assignment"]
            self.assertEqual((a["assigned"], a["inactive"], a["eligible"]), ([], ["bot-a"], []))
            self.assertEqual(self.put_assign("alpha", ["bot-a"], 1)[0], 200)  # keeping is not granting
            self.assertEqual(self.put_assign("alpha", ["bot-a", "bot-b"], 1)[0], 403)

    def test_explicit_project_context_still_opt_in(self):
        self.put_assign("alpha", ["bot-a"], 0)
        self.store.link_chat("alpha", "bot-a", "s2", "Chat")
        self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "Be brief."})
        scope = bridge.prepare_workspace_turn("bot-a", "s2", {"project_context": "alpha"})
        self.assertTrue(scope["summary"]["instructions"])
        self.assertIn("Be brief.", scope["suffix"])
        self.store.discard_output(scope["output_dir"])
        with self.assertRaises(bridge.WorkspaceError):
            bridge.prepare_workspace_turn("bot-a", "s2", {"project_context": "delta"})


class PilotMigration(Base):
    legacy = {"alpha": ["bot-a"]}

    def setUp(self):
        # Build a build-4 era DB before the bridge ever opens it in owner mode.
        root = Path(tempfile.mkdtemp(prefix="ws-pilot-")).resolve() / "ws"
        old = bridge.workspaces_mod.WorkspaceStore(root)
        old.save_instructions("alpha", "pilot instructions")
        old.link_chat("alpha", "bot-a", "pilot1", "Pilot chat")
        d = old.artifact_dir()
        (d / "p.txt").write_bytes(b"pilot")
        old.capture("alpha", "bot-a", "pilot1", d, "MEDIA:%s" % (d / "p.txt"))
        import sqlite3
        old.close()
        db = sqlite3.connect(str(root / "workspaces.db"))
        for t in ("meta", "assignments", "assignment_state"):
            db.execute("DROP TABLE IF EXISTS " + t)
        db.commit()
        db.close()
        self.pilot_root = root
        super().setUp()
        self.store.close()
        self.srv.__exit__()
        self.root = root
        self.use_store(bridge.workspaces_mod.WorkspaceStore(root))
        self.srv = Server().__enter__()

    def test_pilot_data_preserved_and_seed_applied_once(self):
        det = self.detail("alpha")
        self.assertEqual(det["instructions"], "pilot instructions")
        self.assertEqual([c["session_id"] for c in det["chats"]], ["pilot1"])
        self.assertEqual(len(det["artifacts"]), 1)
        self.assertEqual(det["assignment"]["assigned"], ["bot-a"])
        self.assertEqual(self.detail("delta")["assignment"]["assigned"], [])  # no automatic assignments
        self.assertEqual(self.put_assign("alpha", [], det["assignment"]["revision"])[0], 200)
        self.reload()
        self.assertEqual(self.detail("alpha")["assignment"]["assigned"], [])  # not re-seeded
        self.assertEqual(self.detail("alpha")["hidden_chats"], 1)


    def test_allowlist_changed_after_first_owner_use_is_not_reseeded(self):
        self.detail("alpha")  # first owner-mode use: seed applied, guard set
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACES": json.dumps({"alpha": ["bot-a"], "delta": ["bot-a"]})}):
            self.reload()
            self.assertEqual(self.detail("delta")["assignment"]["assigned"], [])


class OwnerScopeOnEveryWorkspaceWrite(Base):
    def test_non_owner_bearer_cannot_write_in_owner_mode(self):
        st, f = self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "README.md", "data": "IyBoaQ=="})
        self.assertEqual(st, 201)
        with patch.object(bridge.H, "owner_ok", lambda self: False):
            for method, path, body in (
                    ("PUT", "/m/workspaces/alpha/instructions", {"instructions": "x"}),
                    ("POST", "/m/workspaces/alpha/files", {"name": "SOUL.md", "data": "eA=="}),
                    ("PUT", "/m/workspaces/alpha/files/" + f["id"], {"content": "y", "sha": f["sha"]}),
                    ("DELETE", "/m/workspaces/alpha/files/" + f["id"], None),
                    ("PUT", "/m/workspaces/alpha/assignment", {"profiles": [], "revision": 0})):
                st, d = self.srv.req(method, path, body)
                self.assertEqual((st, d.get("code")), (403, "owner_required"), path)
            self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha")[0], 200)  # reads stay open to the bearer
        det = self.detail("alpha")
        self.assertEqual((det["instructions"], [x["name"] for x in det["files"]]), ("", ["README.md"]))
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/files/" + f["id"])[1]["content"], "# hi")


class RealOwnerGate(Base):
    def test_ordinary_bearer_reads_but_cannot_write_in_owner_mode(self):
        self.srv.token = bridge.make_token("ordinary")  # build-4 style token: no owner scope
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha")[0], 200)
        for m, p, b in (("PUT", "/m/workspaces/alpha/assignment", {"profiles": ["bot-a"], "revision": 0}),
                        ("PUT", "/m/workspaces/alpha/instructions", {"instructions": "x"}),
                        ("POST", "/m/workspaces/alpha/files", {"name": "README.md", "data": "eA=="})):
            st, d = self.srv.req(m, p, b)
            self.assertEqual((st, d.get("code")), (403, "owner_required"), p)
        self.assertEqual(self.store.assignment("alpha")[0], 0)

class EditTests(Base):
    def setUp(self):
        super().setUp()
        self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "a.txt", "data": b64("one")})
        self.fid = self.detail("alpha")["files"][0]["id"]

    def test_file_put_then_get_returns_new_bytes(self):
        st, d = self.srv.req("GET", "/m/workspaces/alpha/files/" + self.fid)
        self.assertEqual((st, d["content"], d["sha"]), (200, "one", sha("one")))
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": "two é", "sha": sha("one")})
        self.assertEqual((st, d["sha"], d["size"], d["name"]), (200, sha("two é"), len("two é".encode()), "a.txt"))
        st, d = self.srv.req("GET", "/m/workspaces/alpha/files/" + self.fid)
        self.assertEqual((d["content"], d["sha"]), ("two é", sha("two é")))
        self.assertEqual(self.detail("alpha")["files"][0]["sha"], sha("two é"))

    def test_stale_sha_409_leaves_bytes(self):
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": "x", "sha": sha("other")})
        self.assertEqual((st, d["code"], d["current"]["sha"]), (409, "stale", sha("one")))
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/files/" + self.fid)[1]["content"], "one")
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": "x"})[0], 400)

    def test_cross_project_file_id_404(self):
        self.assertEqual(self.srv.req("GET", "/m/workspaces/delta/files/" + self.fid)[0], 404)
        st, d = self.srv.req("PUT", "/m/workspaces/delta/files/" + self.fid, {"content": "x", "sha": sha("one")})
        self.assertEqual(st, 404)
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/files/" + self.fid)[1]["content"], "one")

    def test_duplicate_and_validation(self):
        self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "b.json", "data": b64('{"a":1}')})
        j = [f for f in self.detail("alpha")["files"] if f["name"] == "b.json"][0]
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": '{"a":1}', "sha": sha("one")})
        self.assertEqual((st, d["code"]), (409, "duplicate"))
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/files/" + j["id"], {"content": "{x", "sha": j["sha"]})[0], 400)
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": "a" * 8193, "sha": sha("one")})[0], 413)
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": "", "sha": sha("one")})[0], 400)

    def test_64k_body_cap(self):
        self.assertEqual(bridge.WS_MAX_BODY, 64 * 1024)
        content = "\n" * 8192  # JSON-escaped: ~16 KiB, over the build-4 cap would not be, but nearly 2x
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/files/" + self.fid, {"content": content, "sha": sha("one")})
        self.assertEqual(st, 200)

    def test_instruction_revision(self):
        r = self.detail("alpha")["instructions_revision"]
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "v1", "revision": r})
        self.assertEqual((st, d), (200, {"ok": True, "revision": sha("v1")}))
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "v2", "revision": r})
        self.assertEqual((st, d["code"], d["revision"]), (409, "stale", sha("v1")))
        self.assertEqual(self.detail("alpha")["instructions"], "v1")
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "v3"})  # revision optional
        self.assertEqual((st, d["revision"]), (200, sha("v3")))
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "v4", "revision": 5})[0], 400)


class OperatorModeTests(Base):
    env = {}
    legacy = {"alpha": ["bot-a"]}

    def test_assignment_put_403_operator_managed(self):
        st, d = self.put_assign("alpha", ["bot-a"], 0)
        self.assertEqual((st, d["code"]), (403, "operator_managed"))

    def test_operator_detail_additive_and_edits_work(self):
        self.assertEqual(self.srv.req("GET", "/m/workspaces")[1], {"projects": ["alpha"], "profiles": ["bot-a"]})
        st, d = self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "x", "revision": sha("")})
        self.assertEqual((st, d["revision"]), (200, sha("x")))
        self.assertEqual(self.srv.req("GET", "/m/workspaces/delta")[0], 404)
        det = self.detail("alpha")
        self.assertEqual((det["mode"], det["profiles"], det["assignment"]["editable"]), ("operator", ["bot-a"], False))
        self.assertEqual(det["assignment"]["assigned"], ["bot-a"])
        self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "a.txt", "data": b64("one")})
        fid = self.detail("alpha")["files"][0]["id"]
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/files/" + fid, {"content": "two", "sha": sha("one")})[0], 200)
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha/files/" + fid)[1]["content"], "two")
        self.assertEqual(self.store.assignment("alpha"), (0, []))  # operator mode never touches assignments


if __name__ == "__main__":
    unittest.main()
