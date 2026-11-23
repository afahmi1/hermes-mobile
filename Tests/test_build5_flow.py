"""Build 5 end-to-end HTTP flow over the real bridge handler and real stores (synthetic home, doubled gateway).

Two projects (one seeded from the legacy pilot allowlist, one created in the app with zero bots), assignment,
workspace file create/edit, New Project, New Bot (persona) chat, deletion PIN set/archive/restore, and the
fail-closed paths: no auth, ordinary (non-owner) token, missing PIN, wrong PIN. Synthetic PINs only.
"""
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_manage_http as base  # noqa: E402  (its setUpModule builds the synthetic HERMES_HOME and imports the bridge)
from test_manage_http import PIN, WRONG  # noqa: E402


def setUpModule():
    base.setUpModule()

B64_README = "IyBSRUFETUUK"  # "# README\n"


class Build5Flow(base.Base):
    def profiles_snapshot(self):
        return sorted((str(p.relative_to(base.HOME)), p.stat().st_mtime_ns, p.stat().st_size)
                      for p in (base.HOME / "profiles").rglob("*"))

    def wait_turn(self, turn_id):
        import time
        turn = base.turns.get_turn(turn_id)
        for _ in range(250):
            if turn.done:
                break
            time.sleep(0.02)
        self.assertTrue(turn.done)
        sent = [q for m, q in self.gw.calls if m == "prompt.submit"][-1]["text"]
        self.assertIn("App persona for this chat", sent)  # the persona really reaches the host turn

    def test_two_project_owner_flow_and_fail_closed(self):
        snap = self.profiles_snapshot()
        r = self.srv.req

        # --- fail closed before anything: no auth / ordinary token / missing PIN ---
        self.assertEqual(r("GET", "/m/workspaces", who=None)[0], 401)
        self.assertEqual(r("POST", "/m/manage/projects", {"title": "X"}, who="legacy")[1]["code"], "owner_required")
        self.assertEqual(r("PUT", "/m/workspaces/alpha/assignment", {"profiles": [], "revision": 0},
                           who="legacy")[1]["code"], "owner_required")
        self.assertEqual(r("POST", "/m/manage/projects/alpha/archive", {"pin": PIN})[1]["code"], "pin_unset")

        # --- New Project (zero bots) + the pilot project both have workspaces ---
        st, p = r("POST", "/m/manage/projects", {"title": "Synthetic Zero", "summary": "No bots yet"})
        self.assertEqual((st, p["id"]), (201, "synthetic-zero"))
        idx = r("GET", "/m/workspaces")[1]
        self.assertEqual(idx["mode"], "owner")
        self.assertTrue({"alpha", "synthetic-zero"} <= set(idx["projects"]))
        ws = {w["id"]: w for w in idx["workspaces"]}
        self.assertEqual(ws["alpha"]["assigned"], ["bot-a"])        # legacy pilot seed preserved
        self.assertEqual(ws["synthetic-zero"]["assigned"], [])     # no automatic assignment
        zero = r("GET", "/m/workspaces/synthetic-zero")[1]
        self.assertEqual((zero["files"], zero["chats"], zero["assignment"]["editable"]), ([], [], True))

        # --- assign a bot to the zero project; persists across a store reload ---
        st, a = r("PUT", "/m/workspaces/synthetic-zero/assignment", {"profiles": ["bot-a"], "revision": 0})
        self.assertEqual((st, a["assignment"]["assigned"]), (200, ["bot-a"]))
        for bad in (["health-coach"], ["ghost"], ["quiet"], ["nope"]):
            st, d = r("PUT", "/m/workspaces/synthetic-zero/assignment", {"profiles": bad, "revision": 1})
            self.assertEqual((st, d["code"]), (403, "not_eligible"), bad)
        root = self.store.root
        self.store.close()
        self.store = base.bridge.workspaces_mod.WorkspaceStore(root)
        self.addCleanup(self.store.close)
        self.assertEqual(r("GET", "/m/workspaces/synthetic-zero")[1]["assignment"]["assigned"], ["bot-a"])

        # --- workspace file: create, read, edit, stale edit refused ---
        st, f = r("POST", "/m/workspaces/synthetic-zero/files", {"name": "README.md", "data": B64_README})
        self.assertEqual(st, 201)
        st, e = r("PUT", "/m/workspaces/synthetic-zero/files/" + f["id"], {"content": "# Edited\n", "sha": f["sha"]})
        self.assertEqual(st, 200)
        self.assertEqual(r("GET", "/m/workspaces/synthetic-zero/files/" + f["id"])[1]["content"], "# Edited\n")
        self.assertEqual(r("PUT", "/m/workspaces/synthetic-zero/files/" + f["id"],
                           {"content": "lost", "sha": f["sha"]})[1]["code"], "stale")
        self.assertEqual(r("GET", "/m/workspaces/alpha/files/" + f["id"])[0], 404)  # scoped to its project

        # --- New Bot: persona on an operator-listed host, genuinely startable; not a profile ---
        st, bot = r("POST", "/m/manage/bots", {"name": "Synthetic Poet", "persona": "Answer in short verse.", "host": "bot-a"})
        self.assertEqual(st, 201)
        self.assertNotIn(bot["id"], self.bot_ids())
        st, chat = r("POST", "/m/manage/bots/%s/chats" % bot["id"], {"title": "Verse"})
        self.assertEqual((st, chat["profile"]), (201, "bot-a"))
        st, t = r("POST", "/m/chat/bot-a/%s/send" % chat["session_id"], {"text": "hello"})
        self.assertEqual(st, 202)
        self.wait_turn(t["turn_id"])
        self.assertEqual(r("PUT", "/m/workspaces/synthetic-zero/assignment",
                           {"profiles": [bot["id"]], "revision": 1})[1]["code"], "not_eligible")  # personas aren't profiles

        # --- deletion PIN: owner sets it in the app (twice), wrong PIN changes nothing ---
        self.assertEqual(r("POST", "/m/manage/pin", {"pin": PIN, "confirm": PIN}, who="legacy")[1]["code"], "owner_required")
        self.assertEqual(r("POST", "/m/manage/pin", {"pin": PIN, "confirm": PIN})[0], 200)
        self.assertEqual(r("POST", "/m/manage/projects/synthetic-zero/archive", {})[1]["code"], "pin_required")
        self.assertEqual(r("POST", "/m/manage/projects/synthetic-zero/archive", {"pin": WRONG})[1]["code"], "pin_wrong")
        self.assertEqual(r("POST", "/m/manage/bots/%s/archive" % bot["id"], {"pin": WRONG})[1]["code"], "pin_wrong")
        self.assertIn("synthetic-zero", self.project_ids())

        # unassigning is a setting edit, not a deletion: no PIN involved
        self.assertEqual(r("PUT", "/m/workspaces/synthetic-zero/assignment", {"profiles": [], "revision": 1})[0], 200)
        self.assertEqual(r("PUT", "/m/workspaces/synthetic-zero/assignment", {"profiles": ["bot-a"], "revision": 2})[0], 200)

        # --- same PIN archives the project and the bot; archived project authorizes nothing; restore ---
        self.assertEqual(r("POST", "/m/manage/projects/synthetic-zero/archive", {"pin": PIN})[0], 200)
        self.assertNotIn("synthetic-zero", self.project_ids())
        self.assertEqual(r("GET", "/m/workspaces/synthetic-zero")[0], 404)
        self.assertEqual(r("GET", "/m/workspaces/synthetic-zero/files/" + f["id"])[0], 404)
        self.assertEqual(r("POST", "/m/manage/bots/%s/archive" % bot["id"], {"pin": PIN})[0], 200)
        arch = r("GET", "/m/manage/archived")[1]
        self.assertEqual(({x["id"] for x in arch["projects"]}, {x["id"] for x in arch["bots"]}),
                         ({"synthetic-zero"}, {bot["id"]}))
        self.assertEqual(r("POST", "/m/manage/projects/synthetic-zero/restore", {})[0], 200)
        self.assertEqual(r("POST", "/m/manage/bots/%s/restore" % bot["id"], {})[0], 200)
        back = r("GET", "/m/workspaces/synthetic-zero")[1]
        self.assertEqual(([x["name"] for x in back["files"]], back["assignment"]["assigned"]), (["README.md"], ["bot-a"]))
        self.assertEqual(r("GET", "/m/workspaces/synthetic-zero/files/" + f["id"])[1]["content"], "# Edited\n")

        # --- nothing on disk under profiles/, no PIN anywhere in replies or logs ---
        self.assertEqual(self.profiles_snapshot(), snap)
        for raw in self.srv.bodies:
            self.assertNotIn(PIN.encode(), raw)
        self.assertNotIn(PIN, self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
