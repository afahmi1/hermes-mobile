"""Guard: tests must never read or write the live ~/.hermes/mobile."""
import _isolation  # noqa: F401
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class StateIsolationTests(unittest.TestCase):
    def test_env_points_outside_live_state(self):
        self.assertFalse(_isolation.inside_real_state(os.environ["HERMES_MOBILE_STATE_DIR"]))

    def test_bridge_state_dir_is_isolated(self):
        self.assertFalse(_isolation.inside_real_state(bridge.STATE_DIR), bridge.STATE_DIR)

    def test_secret_comes_from_isolated_dir(self):
        # Compare bytes without printing them.
        self.assertTrue((bridge.STATE_DIR / "secret").exists())
        self.assertEqual(bridge.SECRET, (bridge.STATE_DIR / "secret").read_bytes().strip())

    def test_default_without_env_is_hermes_home_mobile(self):
        self.assertEqual(bridge.HERMES / "mobile", Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / "mobile")


if __name__ == "__main__":
    unittest.main()
