import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sys
import types
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class _Shim:
    """Like hermes_state.SessionDB: unknown attributes raise AttributeError."""
    def __getattr__(self, name):
        raise AttributeError(name)


class _Native:
    def resolve_resume_session_id(self, sid):
        return "native-" + sid


def _fake_assembly(result=None, boom=False):
    seen = []

    class Lineage:
        def resolve_resume_target(self, sid):
            seen.append(sid)
            if boom:
                raise RuntimeError("store")
            return result

    @contextmanager
    def reader(target):
        seen.append(target)
        yield types.SimpleNamespace(lineage=Lineage())

    return types.SimpleNamespace(open_persistence_reader=reader), seen


class ResumeTargetTest(unittest.TestCase):
    def test_uses_the_method_when_the_object_has_it(self):
        self.assertEqual(bridge.resume_target(_Native(), "a", "/x/state.db"), "native-a")

    def test_falls_back_to_the_storage_interface_read_only(self):
        mod, seen = _fake_assembly("tip")
        with patch.dict(sys.modules, {"persistence_assembly": mod}):
            self.assertEqual(bridge.resume_target(_Shim(), "a", "/x/state.db"), "tip")
        self.assertEqual(seen, [Path("/x/state.db"), "a"])

    def test_returns_the_given_id_without_a_path(self):
        self.assertEqual(bridge.resume_target(_Shim(), "a"), "a")

    def test_returns_the_given_id_when_the_interface_is_missing(self):
        with patch.dict(sys.modules, {"persistence_assembly": None}):
            self.assertEqual(bridge.resume_target(_Shim(), "a", "/x/state.db"), "a")

    def test_returns_the_given_id_when_the_lookup_fails_or_is_empty(self):
        for mod in (_fake_assembly(boom=True)[0], _fake_assembly("")[0]):
            with patch.dict(sys.modules, {"persistence_assembly": mod}):
                self.assertEqual(bridge.resume_target(_Shim(), "a", "/x/state.db"), "a")


if __name__ == "__main__":
    unittest.main()
