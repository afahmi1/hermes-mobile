import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sqlite3
import tempfile
import time
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as turns


def make_db(home):
    db = sqlite3.connect(home / "state.db")
    db.execute("CREATE TABLE sessions (id TEXT, parent_session_id TEXT, started_at REAL)")
    db.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, timestamp REAL, display_kind TEXT)")
    db.commit()
    return db


class SteerPickup(unittest.TestCase):
    def setUp(self):
        self.home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.db = make_db(self.home)
        self.turn = turns.Turn("default", self.home, "s1", "x", {})
        self.turn.canonical_sid = "s1"
        self.pushed = []
        self.turn.push = lambda kind, **kw: self.pushed.append((kind, kw))

    def test_picked_up_once_hermes_writes_the_steer_row(self):
        now = time.time()
        self.turn.unread_steers["a" * 32] = (turns.steer_key("Use the  Obsidian vault"), now)
        turns.check_steers(self.turn, force=True)
        self.assertEqual(self.pushed, [])
        self.db.execute("INSERT INTO messages VALUES ('s1','user',?,?, 'steer')",
                        ("[OUT-OF-BAND USER MESSAGE]\nuse the obsidian vault\n[/OUT-OF-BAND]", now + 3))
        self.db.commit()
        turns.check_steers(self.turn, force=True)
        self.assertEqual(self.pushed[0][0], "steer.picked_up")
        self.assertEqual(self.pushed[0][1]["submission_id"], "a" * 32)
        self.assertEqual(self.turn.unread_steers, {})

    def test_found_in_a_compressed_continuation(self):
        now = time.time()
        self.turn.unread_steers["b" * 32] = (turns.steer_key("ship it"), now)
        self.db.execute("INSERT INTO sessions VALUES ('s2','s1',?)", (now + 1,))
        self.db.execute("INSERT INTO messages VALUES ('s2','user','ship it',?, 'steer')", (now + 2,))
        self.db.commit()
        turns.check_steers(self.turn, force=True)
        self.assertEqual([k for k, _ in self.pushed], ["steer.picked_up"])

    def test_rate_limited_and_idle_when_nothing_is_unread(self):
        turns.check_steers(self.turn)  # nothing unread: no query at all
        self.assertEqual(self.turn.steer_checked, 0.0)
        self.turn.unread_steers["c" * 32] = ("x", time.time())
        turns.check_steers(self.turn)
        first = self.turn.steer_checked
        turns.check_steers(self.turn)
        self.assertEqual(self.turn.steer_checked, first)


class TurnSummary(unittest.TestCase):
    def test_waiting_and_times_for_the_chat_list(self):
        t = turns.Turn("default", Path("/tmp"), "s1", "x", {})
        self.assertIsNone(t.summary()["waiting"])
        t.clarify["q"] = 1
        self.assertEqual(t.summary()["waiting"], "question")
        t.finish()
        s = t.summary()
        self.assertIsNone(s["waiting"])
        self.assertGreaterEqual(s["ended_at"], s["started_at"])


if __name__ == "__main__":
    unittest.main()
