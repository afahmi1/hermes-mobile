"""An operator-named bot skips the NAME privacy heuristic; key and opt-out checks still apply.

Synthetic HERMES_HOME, no network, no live bridge."""
import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BRIDGE_DIR = Path(__file__).resolve().parents[1] / "Bridge"
sys.path.insert(0, str(BRIDGE_DIR))

CATALOG = {"schema_version": 1, "roots": [], "projects": [{"id": "alpha", "title": "Alpha", "bot_ids": []}]}
NAMED = ["bacta-protocol", "captains-log", "vault-optout", "wellness-nokey", "plain-bot"]


def setUpModule():
    global bridge, HOME
    HOME = Path(tempfile.mkdtemp(prefix="bridge-explicit-")).resolve()
    with patch.dict(os.environ, HERMES_HOME=str(HOME)):
        bridge = importlib.import_module("hermes_mobile_bridge")
    # pid: (has key, extra .env text)
    for pid, key, extra in (("bacta-protocol", True, ""), ("captains-log", True, ""),
                            ("trading-desk", True, ""),            # protected name, never listed
                            ("vault-optout", True, bridge.OPT_OUT + "\n"),
                            ("wellness-nokey", False, ""), ("plain-bot", True, "")):
        d = HOME / "profiles" / pid
        d.mkdir(parents=True)
        (d / ".env").write_text(("API_SERVER_KEY=k-%s\n" % pid if key else "") + extra)
    (HOME / ".env").write_text("API_SERVER_KEY=k-default\n")


class ExplicitBots(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="explicit-"))).resolve()
        (self.tmp / "cat.json").write_text(json.dumps(CATALOG))
        self.enterContext(patch.object(bridge, "HERMES", HOME))
        self.enterContext(patch.dict(os.environ, {"HERMES_MOBILE_PROJECTS_CATALOG": str(self.tmp / "cat.json")}))
        for k in ("HERMES_MOBILE_WORKSPACES", "HERMES_MOBILE_WORKSPACE_BOTS", "HERMES_MOBILE_MANAGEABLE_BOTS",
                  "HERMES_MOBILE_PERSONA_HOSTS", "HERMES_MOBILE_OWNER_MANAGED"):
            os.environ.pop(k, None)

    def env(self, **kv):
        self.enterContext(patch.dict(os.environ, {k: json.dumps(v) for k, v in kv.items()}))

    def test_profile_protected_rule(self):
        p = bridge.profile_protected
        self.assertTrue(p("bacta-protocol"))
        self.assertTrue(p("captains-log"))
        self.assertFalse(p("bacta-protocol", explicit=True))
        self.assertFalse(p("captains-log", explicit=True))
        self.assertTrue(p("vault-optout", explicit=True))     # opt-out marker still wins
        self.assertTrue(p("wellness-nokey", explicit=True))   # no key still excluded
        self.assertTrue(p("ghost-health", explicit=True))     # no profile, no key
        self.assertFalse(p("plain-bot"))

    def test_manageable_bots(self):
        self.assertEqual(bridge.manageable_bots(), [])
        self.env(HERMES_MOBILE_MANAGEABLE_BOTS=NAMED + ["default"])
        self.assertEqual(bridge.manageable_bots(), ["bacta-protocol", "captains-log", "plain-bot"])
        self.env(HERMES_MOBILE_MANAGEABLE_BOTS=["plain-bot"])  # trading-desk unlisted: stays out
        self.assertEqual(bridge.manageable_bots(), ["plain-bot"])

    def test_persona_hosts(self):
        self.env(HERMES_MOBILE_PERSONA_HOSTS=NAMED)
        self.assertEqual(bridge.persona_hosts(), ["bacta-protocol", "captains-log", "plain-bot"])
        self.env(HERMES_MOBILE_PERSONA_HOSTS=["plain-bot"])
        self.assertEqual(bridge.persona_hosts(), ["plain-bot"])

    def test_workspace_bots_list(self):
        self.env(HERMES_MOBILE_WORKSPACE_BOTS=NAMED)
        self.assertEqual(bridge.workspace_base_eligible(), {"bacta-protocol", "captains-log", "plain-bot"})
        self.assertNotIn("trading-desk", bridge.workspace_base_eligible())

    def test_workspaces_union_counts_as_explicit(self):
        self.env(HERMES_MOBILE_WORKSPACES={"alpha": ["bacta-protocol", "vault-optout"]})
        self.assertEqual(bridge.workspace_base_eligible(), {"bacta-protocol"})

    def test_workspace_grants_from_workspaces(self):
        self.env(HERMES_MOBILE_WORKSPACES={"alpha": NAMED})
        self.assertEqual(bridge.workspace_grants(), {"alpha": {"bacta-protocol", "captains-log", "plain-bot"}})

    def test_unlisted_protected_bot_stays_out_everywhere(self):
        self.env(HERMES_MOBILE_WORKSPACES={"alpha": ["plain-bot"]}, HERMES_MOBILE_WORKSPACE_BOTS=["plain-bot"],
                 HERMES_MOBILE_MANAGEABLE_BOTS=["plain-bot"], HERMES_MOBILE_PERSONA_HOSTS=["plain-bot"])
        self.assertEqual(bridge.workspace_grants(), {"alpha": {"plain-bot"}})
        self.assertEqual(bridge.workspace_base_eligible(), {"plain-bot"})
        self.assertEqual(bridge.manageable_bots(), ["plain-bot"])
        self.assertEqual(bridge.persona_hosts(), ["plain-bot"])

    def test_owner_mode_eligibility_and_grants(self):
        self.env(HERMES_MOBILE_WORKSPACE_BOTS=NAMED)
        os.environ["HERMES_MOBILE_OWNER_MANAGED"] = "1"
        catalog = bridge.workspace_catalog()
        self.assertEqual(bridge.workspace_eligible("alpha", catalog), ["bacta-protocol", "captains-log", "plain-bot"])


if __name__ == "__main__":
    unittest.main()
