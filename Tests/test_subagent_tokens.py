"""A finished subagent's card shows the tokens Hermes recorded for it (async_delegations), never a made-up cost."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t
import hermes_mobile_bridge as b

# The real wall shape from 2026-11-27 (two tasks, one delegation).
WALL = """[ASYNC DELEGATION BATCH COMPLETE — deleg_2a8492a8]
A background fan-out unit you dispatched earlier — 2 subagent(s) — has finished.

Dispatched: 2026-11-27 03:04:46 (37m3s ago)
Role: leaf   Model: claude-opus-5-5[1m]   Total duration: 2228.22s

--- ✓ TASK 1/2: Rebuild plate G  (status=completed, api_calls=34, 2223.2s) ---
Plate G is rebuilt.

--- ✓ TASK 2/2: Render the preview  (status=completed, api_calls=9, 300.0s) ---
Rendered.
"""

RESULT = {"results": [
    {"task_index": 0, "status": "completed", "model": "claude-opus-5-5[1m]", "tokens": {"input": 3696385, "output": 25144},
     "cost_usd": 1.977743, "cost_status": "estimated"},
    {"task_index": 1, "status": "completed", "tokens": {"input": 812, "output": "lots"}},
]}


class SubagentTokensTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "state.db"
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE async_delegations(delegation_id TEXT PRIMARY KEY, result_json TEXT)")
        con.execute("INSERT INTO async_delegations VALUES(?,?)", ("deleg_2a8492a8", json.dumps(RESULT)))
        con.execute("INSERT INTO async_delegations VALUES(?,?)", ("deleg_badbadbad", "{not json"))
        con.commit()
        con.close()

        def ro(pid):
            c = sqlite3.connect(self.db)
            c.row_factory = sqlite3.Row
            return c
        self.ro = ro

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self, body, pid="default"):
        with patch.object(b, "_ro", self.ro):
            doc = json.loads(b.timeline_bytes([{"role": "user", "content": body, "id": 1}], pid=pid))
        return doc["data"]

    def test_each_task_shows_its_own_tokens(self):
        items = self.rows(WALL)[0]["activity"]
        self.assertEqual((items[0]["tokens_in"], items[0]["tokens_out"]), (3696385, 25144))
        self.assertEqual(items[1]["tokens_in"], 812)
        self.assertNotIn("tokens_out", items[1])  # not a number: left off

    def test_no_cost_and_no_plumbing_reaches_the_phone(self):
        text = json.dumps(self.rows(WALL))
        for leaked in ('"cost', "1.977", '"delegation"', 'deleg_', '"index"'):
            self.assertNotIn(leaked, text)

    def test_unknown_or_broken_records_leave_the_card_as_it_was(self):
        for body in (WALL.replace("deleg_2a8492a8", "deleg_0000000000"), WALL.replace("deleg_2a8492a8", "deleg_badbadbad")):
            items = self.rows(body)[0]["activity"]
            self.assertNotIn("tokens_in", items[0])
            self.assertEqual(items[0]["api_calls"], 34)

    def test_without_a_profile_nothing_is_looked_up(self):
        self.assertNotIn("tokens_in", self.rows(WALL, pid=None)[0]["activity"][0])

    def test_the_transcript_marks_which_task_is_which(self):
        items = t.activity_details(WALL)["items"]
        self.assertEqual([(i["delegation"], i["index"]) for i in items], [("deleg_2a8492a8", 0), ("deleg_2a8492a8", 1)])


if __name__ == "__main__":
    unittest.main()
