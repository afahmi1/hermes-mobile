"""The doctor names Hermes's real version, even where ``hermes_cli.__version__`` falls back to 0.0.0."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_doctor as d


def fake_hermes(dunder, info=None, info_raises=False):
    pkg = types.ModuleType("hermes_cli")
    pkg.__version__ = dunder
    vi = types.ModuleType("hermes_cli.version_info")
    if info_raises:
        def get_version_info():
            raise RuntimeError("no git")
    else:
        def get_version_info():
            return types.SimpleNamespace(base_version=info)
    vi.get_version_info = get_version_info
    pkg.version_info = vi
    return {"hermes_cli": pkg, "hermes_cli.version_info": vi}


class HermesVersionTest(unittest.TestCase):
    def test_prefers_version_info_over_stampless_dunder(self):
        with patch.dict(sys.modules, fake_hermes("0.0.0", "0.23.4")):
            self.assertEqual(d.hermes_version(), "0.23.4")

    def test_falls_back_to_dunder_when_version_info_fails(self):
        with patch.dict(sys.modules, fake_hermes("0.23.1", info_raises=True)):
            self.assertEqual(d.hermes_version(), "0.23.1")

    def test_falls_back_when_version_info_is_placeholder(self):
        with patch.dict(sys.modules, fake_hermes("0.22.9", "0.0.0")):
            self.assertEqual(d.hermes_version(), "0.22.9")

    def test_older_hermes_without_version_info(self):
        pkg = types.ModuleType("hermes_cli")
        pkg.__version__ = "0.21.0"
        with patch.dict(sys.modules, {"hermes_cli": pkg, "hermes_cli.version_info": None}):
            self.assertEqual(d.hermes_version(), "0.21.0")


if __name__ == "__main__":
    unittest.main()
