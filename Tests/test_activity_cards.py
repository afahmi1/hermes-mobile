"""Background work (commands, subagents) becomes readable, structured activity cards."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t

ONE = """[IMPORTANT: Background process proc_92a676dbf0da completed normally (exit code 0).
Command: cd ~/Desktop/Projects/hermes-mobile-pins; bash Tests/run-swift.sh EE236E6D-0D24-4D2D-8396-615525A5466C 2>&1 | grep -v x | tail -25
Output:
All Swift suites passed"""

BATCH = """[IMPORTANT: 2 background process results arrived while this session was busy. Treat them as one batch.]

[IMPORTANT: Background process proc_e8ba1252bfd6 completed normally (exit code 0).
Command: cd ~/Desktop/3D\\ Printing/Runs/plate\\ B && env -u PYTHONPATH ~/.venvs/cad/bin/python build.py --mesh > ../build.log 2>&1
Output:
ok

[IMPORTANT: Background process proc_af856977c5cf exited (exit code 2).
Command: cd /tmp/x && timeout 500 python3 -u oracle4.py host.example > o4.txt
Output:
Traceback (most recent call last):
SystemExit: 2"""

TASKS = """[ASYNC DELEGATION BATCH COMPLETE — deleg_4ddc47e0]
A background fan-out unit you dispatched earlier has finished.

Dispatched: 2026-11-24 00:09:26 (7m25s ago)
Role: leaf   Model: gpt-6.2-astra   Total duration: 446.24s

--- ✓ TASK 1/2: Build and render the reprints (keep every Z)  (status=completed, api_calls=14, 445.01s) ---
Verification passed for all 25 meshes.

--- ✗ TASK 2/2: Prepare the dispatcher  (status=interrupted, api_calls=3, 61.2s) ---
Stopped early."""

EARLY = """[ASYNC DELEGATION TASK FAILED — deleg_fa97515d, task 2/4]
One subagent failed while its siblings are still running.
Task: Read 7 arXiv papers and write review records.
Status: failed   Duration: 522.02s
Error: HTTP 429: rate limit"""


class ActivityCardTests(unittest.TestCase):
    def test_single_command_reads_like_a_sentence(self):
        card = t.activity_details(ONE)
        self.assertEqual(card["title"], "run-swift.sh finished")
        item = card["items"][0]
        self.assertEqual((item["status"], item["exit_code"], item["cwd"]), ("ok", 0, "hermes-mobile-pins"))
        self.assertIn("run-swift.sh", item["command"])
        self.assertEqual(item["output"], "All Swift suites passed")

    def test_batch_keeps_each_command_and_its_failure(self):
        card = t.activity_details(BATCH)
        self.assertEqual(card["title"], "2 commands finished · 1 failed")
        first, second = card["items"]
        self.assertEqual((first["label"], first["cwd"]), ("build.py --mesh", "plate B"))
        self.assertEqual((second["label"], second["status"], second["exit_code"]), ("oracle4.py host.example", "failed", 2))

    def test_subagent_tasks_carry_status_duration_and_model(self):
        card = t.activity_details(TASKS)
        self.assertEqual(card["title"], "2 subagent tasks finished · 1 failed")
        done, failed = card["items"]
        self.assertEqual((done["status"], done["duration"], done["api_calls"], done["model"]), ("ok", "7m25s", 14, "gpt-6.2-astra"))
        self.assertIn("25 meshes", done["output"])
        self.assertEqual((failed["status"], failed["state"]), ("failed", "interrupted"))

    def test_early_failure_warning(self):
        card = t.activity_details(EARLY)
        self.assertTrue(card["title"].startswith("Subagent failed: Read 7 arXiv papers"))
        self.assertEqual(card["items"][0]["duration"], "8m42s")
        self.assertIn("429", card["items"][0]["output"])

    def test_timeline_row_carries_structured_items_and_a_legacy_notice(self):
        row = t.project_timeline_message({"id": 9, "role": "user", "display_kind": "process_complete", "content": BATCH}, [])
        self.assertEqual(row["role"], "system")
        self.assertEqual(row["notice"], "2 commands finished · 1 failed")
        self.assertFalse(row["ok"])
        self.assertEqual(len(row["activity"]), 2)

    def test_signals_read_as_stopped_not_failed(self):
        card = t.activity_details(ONE.replace("completed normally (exit code 0)", "exited (exit code -15, SIGTERM)"))
        self.assertEqual(card["items"][0]["status"], "stopped")
        self.assertEqual(card["title"], "run-swift.sh was stopped")

    def test_labels_name_the_program_not_the_plumbing(self):
        self.assertEqual(t.command_label("cd ~/a/b && npm run build"), ("npm run build", "b"))
        self.assertEqual(t.command_label("FOO=1 nohup ./brute_serial 0.40 > out.txt"), ("brute_serial 0.40", ""))
        self.assertEqual(t.command_label("git -C repo status")[0], "git -C repo status")


if __name__ == "__main__":
    unittest.main()
