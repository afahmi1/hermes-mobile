import asyncio
import contextlib
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as engine  # noqa: E402


class Branch(unittest.TestCase):
    """Branch from a message: Hermes's own session.mutate "branch" through that message, refusals in plain words."""

    def setUp(self):
        self.calls = []
        self.home = Path(self.enterContext(TemporaryDirectory()))

    @contextlib.asynccontextmanager
    async def connect(self, home):
        yield object()

    def run_branch(self, mutate, **kw):
        async def fake(c, sid, operation, payload, ask=False):
            self.calls.append((sid, operation, payload))
            return await mutate(payload)
        with patch.object(engine, "connect", self.connect), patch.object(engine, "_mutate", fake):
            return asyncio.run(engine._branch(self.home, "local-abc", kw.get("message_id", 42), kw.get("title")))

    def test_branches_through_the_message_with_title(self):
        async def ok(payload):
            return {"branched_session_id": "local-child", "copied_messages": 17, "title": "Plan #2"}
        out = self.run_branch(ok, title="Plan #2")
        self.assertEqual(self.calls, [("local-abc", "branch", {"through_message_id": 42, "title": "Plan #2"})])
        self.assertEqual(out, {"session_id": "local-child", "parent_session_id": "local-abc",
                               "copied_messages": 17, "title": "Plan #2", "compressed": False})

    def test_refusals_are_plain(self):
        async def unknown(payload):
            raise engine.TurnError("invalid_params: through_message_id", 400)
        with self.assertRaises(engine.TurnError) as e:
            self.run_branch(unknown)
        self.assertIn("isn't saved", str(e.exception))

        async def busy(payload):
            raise engine.TurnError("session_busy", 409)
        with self.assertRaises(engine.TurnError) as e:
            self.run_branch(busy)
        self.assertIn("Branch once the reply finishes", str(e.exception))

    def test_compressed_message_branches_from_its_summary(self):
        import sqlite3
        con = sqlite3.connect(self.home / "state.db")
        con.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, active INTEGER)")
        con.executemany("INSERT INTO messages VALUES (?,?,?)",
                        [(10, "local-abc", 0), (11, "local-abc", 0), (20, "local-abc", 1), (21, "local-abc", 1),
                         (15, "other", 1)])
        con.commit()
        con.close()
        self.assertEqual(engine._live_boundary(self.home, "local-abc", 10), (20, True))
        self.assertEqual(engine._live_boundary(self.home, "local-abc", 21), (21, False))
        self.assertEqual(engine._live_boundary(self.home, "local-abc", 99), (99, False), "unknown: Hermes decides")

    def test_bad_ids_never_reach_hermes(self):
        for bad in (None, "42", 0, -1, 2 ** 63, 4.0, True):
            with self.assertRaises(engine.TurnError):
                engine.branch(self.home, "local-abc", bad)


if __name__ == "__main__":
    unittest.main()
