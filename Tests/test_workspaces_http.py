"""Projects workspaces: HTTP glue and turn hooks, against a fake store and a fake gateway transport.

Only the outside edges are mocked (WorkspaceStore, turns.connect / turns._rpc); the bridge handler, the
allowlist/catalog/profile gates and the real turn engine run unmodified. HERMES_HOME is synthetic.
"""
import asyncio
import base64
import contextlib
import http.client
import importlib
import json
import os
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

CATALOG = {"schema_version": 1, "roots": [], "projects": [
    {"id": "alpha", "title": "Alpha", "bot_ids": ["default", "bot-a", "quiet"]},
    {"id": "beta", "title": "Beta", "bot_ids": ["bot-a"]},
    {"id": "gamma", "title": "Gamma", "bot_ids": []}]}
ALLOW = {"alpha": ["bot-a", "quiet", "ghost"], "beta": ["bot-a"], "gamma": ["bot-a"]}


def setUpModule():
    global bridge, turns, HOME
    HOME = Path(tempfile.mkdtemp(prefix="bridge-ws-home-")).resolve()
    with patch.dict(os.environ, HERMES_HOME=str(HOME)):
        bridge = importlib.import_module("hermes_mobile_bridge")
        turns = bridge.turns
    for pid, extra in (("bot-a", ""), ("quiet", bridge.OPT_OUT + "\n")):
        d = HOME / "profiles" / pid
        d.mkdir(parents=True)
        (d / ".env").write_text("API_SERVER_KEY=k-%s\n%s" % (pid, extra))
    (HOME / ".env").write_text("API_SERVER_KEY=k-default\n")


class FakeStore:
    def __init__(self):
        self.chats, self.files, self.arts, self.calls = {}, {}, {}, []
        self.instructions = {}
        self.n = 0

    def detail(self, project):
        return {"instructions": self.instructions.get(project, ""), "files": list(self.files.get(project, [])),
                "chats": [dict(profile=p, session_id=s, title="t") for (p, s), pr in self.chats.items() if pr == project],
                "artifacts": [a for a in self.arts.values() if a["project_id"] == project]}

    def save_instructions(self, project, value):
        self.instructions[project] = value

    def add_file(self, project, name, data):
        self.n += 1
        row = {"id": "f%d" % self.n, "name": name, "size": len(base64.b64decode(data))}
        self.files.setdefault(project, []).append(row)
        return row

    def delete_file(self, project, fid):
        self.files[project] = [f for f in self.files.get(project, []) if f["id"] != fid]

    def link_chat(self, project, profile, sid, title):
        self.chats[(profile, sid)] = project
        return {"profile": profile, "session_id": sid, "title": title}

    def project_for(self, profile, sid):
        return self.chats.get((profile, sid))

    def context(self, project):
        return "[Project context]\nDo X.", {"instructions": True, "files": ["/etc/a.txt", "b.md"]}

    def artifact_dir(self):
        self.n += 1
        return Path("/synthetic/out%d" % self.n)

    def capture(self, *a):
        self.calls.append(("capture",) + a)

    def discard_output(self, d):
        self.calls.append(("discard", d))

    def list_artifacts(self, profile, sid=None, project=None):
        return [a for a in self.arts.values() if a["profile"] == profile and (sid is None or a["session_id"] == sid)
                and (project is None or a["project_id"] == project)]

    def read_artifact(self, aid):
        return self.arts[aid], b"BYTES"


class FakeClient:
    def __init__(self):
        self.events = asyncio.Queue()


class FakeGateway:
    """Stands in for the gateway transport. `mode` shapes what the turn sees."""
    def __init__(self):
        self.calls, self.mode, self.stored = [], "ok", "stored1"

    @contextlib.asynccontextmanager
    async def connect(self, home):
        yield FakeClient()

    async def rpc(self, c, method, **params):
        self.calls.append((method, params))
        if method == "session.create":
            if "profile" in params:
                raise turns.TurnError("unknown create field", 400)
            return {"session_id": "runtime1", "stored_session_id": "stored1"}
        if method == "session.resume":
            return {"session_id": self.stored, "stored_session_id": self.stored, "revision": 1,
                    "execution_generation": 1, "pending": []}
        if method == "prompt.submit":
            adm = "adm-1"
            if self.mode == "gap":
                c.events.put_nowait({"method": "event", "params": {"type": "session.replay_gap"}})
                return {"admission_id": adm, "status": "started", "execution_generation": 1}
            done_adm = "other" if self.mode == "foreign" else adm
            status = "failed" if self.mode == "failed" else "complete"
            if self.mode != "hang":
                c.events.put_nowait({"method": "event", "params": {"type": "message.complete", "admission_id": done_adm,
                                     "payload": {"admission_id": done_adm, "status": status, "content": "answer MEDIA:/synthetic/out1/x"}}})
            return {"admission_id": adm, "status": "started", "execution_generation": 1}
        if method == "prompt.receipt" and self.mode == "gap":
            return {"admission_id": "adm-1", "status": "terminal", "outcome": "completed",
                    "result": {"final_response": "Recovered response"}}
        return {}


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

    def raw(self, method, path, body=None, auth=True, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=5)
        h = dict(headers or {})
        if auth:
            h["Authorization"] = "Bearer " + self.token
        if body is not None and not isinstance(body, bytes):
            body = json.dumps(body).encode()
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        hdrs = dict(r.getheaders())
        c.close()
        return r.status, hdrs, data

    def req(self, method, path, body=None, **kw):
        st, h, data = self.raw(method, path, body, **kw)
        return st, (json.loads(data) if data else None)


class Base(unittest.TestCase):
    def setUp(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ws-cat-"))).resolve()
        (tmp / "cat.json").write_text(json.dumps(CATALOG))
        self.enterContext(patch.dict(os.environ, {"HERMES_MOBILE_PROJECTS_CATALOG": str(tmp / "cat.json"),
                                                  "HERMES_MOBILE_WORKSPACES": json.dumps(ALLOW)}))
        self.enterContext(patch.object(bridge, "HERMES", HOME))
        self.store, self.gw = FakeStore(), FakeGateway()
        self.enterContext(patch.object(bridge, "workspace_store", lambda: self.store))
        self.enterContext(patch.object(turns, "connect", self.gw.connect))
        self.enterContext(patch.object(turns, "_rpc", self.gw.rpc))
        self.srv = self.enterContext(Server())
        turns.TURNS.clear()

    def link(self, project="alpha", profile="bot-a", sid="stored1"):
        self.store.link_chat(project, profile, sid, "t")

    def send(self, body, sid="stored1", profile="bot-a"):
        st, d = self.srv.req("POST", "/m/chat/%s/%s/send" % (profile, sid), body)
        if st != 202:
            return st, d, None
        turn = turns.get_turn(d["turn_id"])
        deadline = time.time() + 5
        while not turn.done and time.time() < deadline:
            time.sleep(0.02)
        self.assertTrue(turn.done)
        return st, d, turn

    def submitted(self):
        return [p for m, p in self.gw.calls if m == "prompt.submit"]


class GateTests(Base):
    def test_auth_required_everywhere(self):
        for m, p in (("GET", "/m/workspaces"), ("GET", "/m/workspaces/alpha"), ("PUT", "/m/workspaces/alpha/instructions"),
                     ("POST", "/m/workspaces/alpha/files"), ("DELETE", "/m/workspaces/alpha/files/f1"),
                     ("POST", "/m/workspaces/alpha/chats"), ("GET", "/m/workspace-artifacts/bot-a"),
                     ("GET", "/m/workspace-file/a1")):
            self.assertEqual(self.srv.req(m, p, b"{}", auth=False)[0], 401, p)

    def test_off_by_default_and_malformed_is_off(self):
        for value in (None, "", "not json", "[]", json.dumps({"alpha": "bot-a"}), json.dumps({"BAD ID": ["bot-a"]})):
            with patch.dict(os.environ):
                os.environ.pop("HERMES_MOBILE_WORKSPACES", None)
                if value is not None:
                    os.environ["HERMES_MOBILE_WORKSPACES"] = value
                self.assertEqual(self.srv.req("GET", "/m/workspaces"), (200, {"projects": [], "profiles": []}))
                self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha")[0], 404)

    def test_grants_are_intersection_of_allowlist_catalog_and_live_unprotected_profiles(self):
        st, d = self.srv.req("GET", "/m/workspaces")
        # ghost isn't a profile, quiet opted out, default was never allowlisted; gamma's catalog lists no
        # bot_ids, so the owner's allowlist alone authorises bot-a there.
        self.assertEqual(d, {"projects": ["alpha", "beta", "gamma"], "profiles": ["bot-a"]})

    def test_catalog_bot_ids_only_narrow(self):
        # beta lists only bot-a; allowlisting another live bot for beta must not grant it.
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACES": json.dumps({"beta": ["bot-a", "default"]})}):
            self.assertEqual(self.srv.req("GET", "/m/workspaces")[1], {"projects": ["beta"], "profiles": ["bot-a"]})

    def test_unknown_project_and_protected_names_never_granted(self):
        d = HOME / "profiles" / "robinhood-cli"
        d.mkdir(parents=True, exist_ok=True)
        (d / ".env").write_text("API_SERVER_KEY=k\n")
        self.addCleanup(lambda: (d / ".env").unlink() or d.rmdir())
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACES": json.dumps(
                {"alpha": ["robinhood-cli"], "nope": ["bot-a"]})}):
            self.assertEqual(self.srv.req("GET", "/m/workspaces")[1], {"projects": [], "profiles": []})

    def test_detail_filters_and_lists_profiles(self):
        self.link()
        self.store.link_chat("alpha", "quiet", "s9", "x")
        self.store.arts["a1"] = {"id": "a1", "name": "n", "size": 1, "project_id": "alpha", "profile": "quiet", "session_id": "s9", "mime": "x"}
        self.store.arts["a2"] = {"id": "a2", "name": "n", "size": 1, "project_id": "alpha", "profile": "bot-a", "session_id": "stored1", "mime": "x"}
        st, d = self.srv.req("GET", "/m/workspaces/alpha")
        self.assertEqual([c["profile"] for c in d["chats"]], ["bot-a"])
        self.assertEqual([a["id"] for a in d["artifacts"]], ["a2"])
        self.assertEqual(d["profiles"], ["bot-a"])
        self.assertEqual(self.srv.req("GET", "/m/workspaces/nowhere")[0], 404)

    def test_crud(self):
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "hi"}), (200, {"ok": True}))
        self.assertEqual(self.store.instructions["alpha"], "hi")
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": 3})[0], 400)
        st, row = self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "../../etc/pw.txt", "data": base64.b64encode(b"abc").decode()})
        self.assertEqual((st, row["name"], row["size"]), (201, "pw.txt", 3))
        self.assertEqual(self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "..", "data": ""})[0], 400)
        self.assertEqual(self.srv.req("DELETE", "/m/workspaces/alpha/files/" + row["id"]), (200, {"ok": True}))
        self.assertEqual(self.srv.req("PUT", "/m/workspaces/nowhere/instructions", {"instructions": "x"})[0], 404)

    def test_body_cap_and_store_error_code(self):
        st, _, _ = self.srv.raw("POST", "/m/workspaces/alpha/files", b"", headers={"Content-Length": str(bridge.WS_MAX_BODY + 1)})
        self.assertEqual(st, 413)
        self.store.add_file = lambda *a: (_ for _ in ()).throw(bridge.WorkspaceError("Too big.", 413))
        self.assertEqual(self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "a", "data": ""}), (413, {"error": "Too big."}))

    def test_unexpected_error_leaks_nothing(self):
        self.store.detail = lambda p: (_ for _ in ()).throw(RuntimeError("/secret/path hunter2"))
        st, d = self.srv.req("GET", "/m/workspaces/alpha")
        self.assertEqual(st, 502)
        self.assertNotIn("secret", json.dumps(d))


class ChatTests(Base):
    def test_create_chat_uses_canonical_stored_id_only(self):
        st, row = self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-a", "title": "Plan"})
        self.assertEqual((st, row), (201, {"profile": "bot-a", "session_id": "stored1", "title": "Plan"}))
        self.assertEqual(self.store.project_for("bot-a", "stored1"), "alpha")
        self.assertEqual(self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-a", "session_id": "evil"})[0], 201)
        self.assertNotIn("evil", [s for (_, s) in self.store.chats])
        self.assertEqual(self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "quiet"})[0], 403)
        self.assertEqual(self.srv.req("POST", "/m/workspaces/beta/chats", {"profile": "default"})[0], 403)

    def test_missing_stored_id_is_refused(self):
        async def rpc(c, method, **p):
            return {"session_id": "runtime-only"}
        with patch.object(turns, "_rpc", rpc):
            st, _ = self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-a"})
        self.assertEqual(st, 502)
        self.assertEqual(self.store.chats, {})


class TurnTests(Base):
    def test_off_leaves_turns_untouched(self):
        with patch.dict(os.environ):
            os.environ.pop("HERMES_MOBILE_WORKSPACES")
            st, d, turn = self.send({"text": "hello"})
        self.assertEqual(self.submitted()[0]["text"], "hello")
        self.assertEqual(self.store.calls, [])
        self.assertNotIn("project_context", [e for e in turn.events if e["event"] == "run.started"][0])

    def test_unlinked_chat_untouched_even_when_enabled(self):
        st, d, turn = self.send({"text": "hello"})
        self.assertEqual(self.submitted()[0]["text"], "hello")
        self.assertEqual(self.store.calls, [])

    def test_context_turn_captures_on_matched_terminal(self):
        self.link()
        st, d, turn = self.send({"text": "do it", "project_context": "alpha"})
        text = self.submitted()[0]["text"]
        self.assertTrue(text.startswith("do it\n\n[Project context]\nDo X."))
        self.assertIn("Project output:", text)
        started = [e for e in turn.events if e["event"] == "run.started"][0]
        self.assertEqual(started["project_context"], {"project": "alpha", "instructions": True, "files": ["a.txt", "b.md"]})
        self.assertNotIn("Do X", json.dumps(started))
        self.assertEqual(self.store.calls, [("capture", "alpha", "bot-a", "stored1", Path("/synthetic/out1"), "answer MEDIA:/synthetic/out1/x"),
                                            ("discard", Path("/synthetic/out1"))])

    def test_associated_turn_without_context_gets_artifacts_only(self):
        self.link()
        st, d, turn = self.send({"text": "do it"})
        text = self.submitted()[0]["text"]
        self.assertIn("Project output:", text)
        self.assertNotIn("Do X", text)
        self.assertNotIn("project_context", [e for e in turn.events if e["event"] == "run.started"][0])
        self.assertEqual(self.store.calls[0][0], "capture")

    def test_artifacts_not_applied_when_pair_no_longer_allowed(self):
        self.link(profile="quiet")
        st, d, turn = self.send({"text": "hi"}, profile="quiet")
        self.assertEqual(self.submitted()[0]["text"], "hi")
        self.assertEqual(self.store.calls, [])

    def test_bad_context_rejected_before_any_gateway_call(self):
        self.link()
        for body in ({"text": "x", "project_context": "beta"},      # not the stored relation
                     {"text": "x", "project_context": "gamma"},     # no grant
                     {"text": "x", "project_context": {"project": 5}}):
            st, d, _ = self.send(body)
            self.assertIn(st, (400, 403), body)
        self.assertEqual(self.gw.calls, [])
        st, _, _ = self.send({"text": "x", "project_context": "alpha"}, sid="other")  # unlinked chat
        self.assertEqual(st, 403)
        with patch.dict(os.environ):
            os.environ.pop("HERMES_MOBILE_WORKSPACES")
            self.assertEqual(self.send({"text": "x", "project_context": "alpha"})[0], 403)
        self.assertEqual(self.gw.calls, [])

    def test_wrong_canonical_resume_sends_and_attaches_nothing(self):
        self.link()
        self.gw.stored = "someone-else"
        st, d, turn = self.send({"text": "x", "project_context": "alpha"})
        self.assertEqual([e["event"] for e in turn.events], ["run.failed"])
        self.assertEqual(self.submitted(), [])
        self.assertNotIn("file.attach", [m for m, _ in self.gw.calls])
        self.assertEqual([c[0] for c in self.store.calls], ["discard"])

    def test_unmatched_or_failed_terminal_never_captured(self):
        self.link()
        for mode in ("foreign", "failed"):
            self.store.calls.clear()
            turns.TURNS.clear()
            self.gw.mode = mode
            if mode == "foreign":
                # the foreign completion is ignored by the engine's admission filter; end the turn with a failure
                orig = self.gw.rpc

                async def rpc(c, method, _orig=orig, **p):
                    r = await _orig(c, method, **p)
                    if method == "prompt.submit":
                        c.events.put_nowait({"method": "event", "params": {"type": "message.complete", "admission_id": "adm-1",
                                             "payload": {"admission_id": "adm-1", "status": "failed", "content": "no"}}})
                    return r
                with patch.object(turns, "_rpc", rpc):
                    self.send({"text": "x"})
            else:
                self.send({"text": "x"})
            self.assertEqual([c[0] for c in self.store.calls], ["discard"], mode)

    def test_steered_turn_discarded_not_captured(self):
        self.link()
        self.gw.mode = "hang"
        st, d = self.srv.req("POST", "/m/chat/bot-a/stored1/send", {"text": "x"})
        turn = turns.get_turn(d["turn_id"])
        for _ in range(100):
            if turn.client is not None:
                break
            time.sleep(0.02)
        turn.steered = True
        turns.LOOP.call_soon_threadsafe(turn.client.events.put_nowait, {"method": "event", "params": {
            "type": "message.complete", "admission_id": "adm-1",
            "payload": {"admission_id": "adm-1", "status": "complete", "content": "blend"}}})
        for _ in range(100):
            if turn.done:
                break
            time.sleep(0.02)
        self.assertEqual([c[0] for c in self.store.calls], ["discard"])

    def test_replay_gap_recovers_final_answer_for_capture(self):
        self.link()
        self.gw.mode = "gap"
        _, _, turn = self.send({"text": "hello"})
        assert turn is not None
        self.assertEqual(turn.events[-1]["output"], "Recovered response")
        self.assertEqual(self.store.calls[0][-1], "Recovered response")

    def test_busy_chat_discards_new_output_dir(self):
        self.link()
        self.gw.mode = "hang"
        st, d = self.srv.req("POST", "/m/chat/bot-a/stored1/send", {"text": "x"})
        self.assertEqual(st, 202)
        st, d = self.srv.req("POST", "/m/chat/bot-a/stored1/send", {"text": "y"})
        self.assertEqual(st, 409)
        self.assertEqual([c[0] for c in self.store.calls], ["discard"])


class ArtifactTests(Base):
    def setUp(self):
        super().setUp()
        self.store.arts["a1"] = {"id": "a1", "name": 'we"ird\r\nñ/../n.html', "size": 5, "project_id": "alpha",
                                 "profile": "bot-a", "session_id": "stored1", "mime": "text/html"}
        self.store.arts["a2"] = {"id": "a2", "name": "q", "size": 5, "project_id": "alpha", "profile": "quiet",
                                 "session_id": "s", "mime": "text/plain"}

    def test_list_filters_current_permission(self):
        self.link()
        L = lambda p: self.srv.req("GET", p)
        self.assertEqual([a["id"] for a in L("/m/workspace-artifacts/bot-a?project=alpha")[1]["artifacts"]], ["a1"])
        self.assertEqual(L("/m/workspace-artifacts/quiet?project=alpha")[1], {"artifacts": []})
        self.assertEqual(L("/m/workspace-artifacts/bot-a/stored1")[1]["artifacts"][0]["id"], "a1")
        self.assertEqual(L("/m/workspace-artifacts/bot-a/stored2")[1], {"artifacts": []})
        self.assertEqual(L("/m/workspace-artifacts/BAD!?project=alpha")[0], 404)

    def test_library_requires_project_and_never_crosses_projects(self):
        self.link()
        self.store.arts["b1"] = {"id": "b1", "name": "b", "size": 1, "project_id": "beta", "profile": "bot-a",
                                 "session_id": "s5", "mime": "text/plain"}
        L = lambda p: self.srv.req("GET", p)
        self.assertEqual(L("/m/workspace-artifacts/bot-a")[0], 400)
        self.assertEqual([a["id"] for a in L("/m/workspace-artifacts/bot-a?project=beta")[1]["artifacts"]], ["b1"])
        self.assertEqual([a["id"] for a in L("/m/workspace-artifacts/bot-a?project=alpha")[1]["artifacts"]], ["a1"])
        self.assertEqual(L("/m/workspace-artifacts/bot-a?project=zzz")[1], {"artifacts": []})
        self.assertEqual(L("/m/workspace-artifacts/bot-a?project=alpha&x=1")[0], 400)

    def test_disabled_project_reveals_nothing(self):
        self.link()
        with patch.dict(os.environ, {"HERMES_MOBILE_WORKSPACES": json.dumps({"beta": ["bot-a"]})}):
            L = lambda p: self.srv.req("GET", p)
            self.assertEqual(L("/m/workspace-artifacts/bot-a?project=alpha")[1], {"artifacts": []})
            self.assertEqual(L("/m/workspace-artifacts/bot-a/stored1")[1], {"artifacts": []})
            self.assertEqual(L("/m/workspaces/alpha")[0], 404)
            self.assertEqual(self.srv.raw("GET", "/m/workspace-file/a1")[0], 404)

    def test_chat_view_scoped_to_originating_conversation(self):
        self.link()
        self.store.arts["c2"] = {"id": "c2", "name": "x", "size": 1, "project_id": "alpha", "profile": "bot-a",
                                 "session_id": "other", "mime": "text/plain"}
        ids = lambda p: [a["id"] for a in self.srv.req("GET", p)[1]["artifacts"]]
        self.assertEqual(ids("/m/workspace-artifacts/bot-a/stored1"), ["a1"])
        self.assertEqual(ids("/m/workspace-artifacts/bot-a/other"), [])  # chat not linked

    def test_download_headers_and_revocation(self):
        st, h, data = self.srv.raw("GET", "/m/workspace-file/a1")
        self.assertEqual((st, data), (200, b"BYTES"))
        self.assertEqual(h["Content-Type"], "application/octet-stream")
        self.assertEqual(h["Cache-Control"], "no-store")
        self.assertEqual(h["X-Content-Type-Options"], "nosniff")
        cd = h["Content-Disposition"]
        self.assertTrue(cd.startswith("attachment;"))
        self.assertNotIn("\n", cd)
        self.assertNotIn("/", cd.split("filename=")[1].split(";")[0])
        self.assertEqual(self.srv.raw("GET", "/m/workspace-file/a2")[0], 404)   # protected profile
        with patch.dict(os.environ):
            os.environ["HERMES_MOBILE_WORKSPACES"] = json.dumps({"alpha": []})
            st, h, data = self.srv.raw("GET", "/m/workspace-file/a1")
        self.assertEqual(st, 404)
        self.assertNotIn(b"BYTES", data)


@unittest.skipUnless((BRIDGE_DIR / "bridge_workspaces.py").exists(), "bridge_workspaces.py not in this tree")
class RealStoreTests(Base):
    def test_flow_with_real_store(self):
        import bridge_workspaces
        root = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ws-real-"))).resolve()
        real = bridge_workspaces.WorkspaceStore(root)
        self.addCleanup(real.close)
        self.enterContext(patch.object(bridge, "workspace_store", lambda: real))
        st, row = self.srv.req("POST", "/m/workspaces/alpha/chats", {"profile": "bot-a", "title": "T"})
        self.assertEqual(st, 201)
        self.srv.req("PUT", "/m/workspaces/alpha/instructions", {"instructions": "Be brief."})
        self.srv.req("POST", "/m/workspaces/alpha/files", {"name": "a.txt", "data": base64.b64encode(b"hi").decode()})
        st, d, turn = self.send({"text": "go", "project_context": "alpha"}, sid=row["session_id"])
        self.assertEqual(st, 202)
        self.assertIn("Be brief.", self.submitted()[0]["text"])
        self.assertEqual(self.srv.req("GET", "/m/workspaces/alpha")[1]["chats"][0]["session_id"], row["session_id"])


if __name__ == "__main__":
    unittest.main()
