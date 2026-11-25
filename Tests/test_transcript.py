import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as transcript


class TranscriptProjectionTest(unittest.TestCase):
    def test_tool_preview_keeps_the_command_and_drops_the_blob(self):
        secret = "Z" * 500
        row = transcript.project_timeline_message({
            "role": "assistant", "id": 1, "content": "Done",
            "reasoning": "private chain of thought",
            "tool_calls": [{"function": {"name": "terminal", "arguments": json.dumps({
                "command": "git status", "blob": secret})}}],
        })
        encoded = json.dumps(row)
        self.assertEqual(row["tool_calls"], [{"function": {"name": "terminal"}, "preview": "git status"}])
        self.assertNotIn(secret, encoded)
        self.assertNotIn("private chain of thought", encoded)

    def test_long_tool_result_is_capped(self):
        tail = "TAIL-SECRET-" * 40
        row = transcript.project_timeline_message({"role": "tool", "id": 2, "tool_name": "terminal",
                                                   "content": "ok\n" + tail})
        self.assertEqual(row["preview"], "ok")
        self.assertTrue(row["ok"])
        self.assertNotIn("TAIL-SECRET", json.dumps(row))

    def test_failed_delegate_is_an_activity_card(self):
        wall = "\n".join([
            "[ASYNC DELEGATION BATCH COMPLETE — deleg_test]",
            "--- ✗ TASK 1/1: Check the printer  (status=failed, duration=4s) ---",
            "a long private log " + ("x" * 500),
        ])
        row = transcript.project_timeline_message({"role": "user", "id": 3, "content": wall,
                                                   "display_kind": "async_delegation_complete"})
        self.assertEqual(row["role"], "system")
        self.assertIn("failed", row["notice"].lower())
        self.assertIn("Check the printer", row["notice"])
        self.assertNotIn("deleg_test", json.dumps(row))
        self.assertFalse(row["ok"])

    def test_hidden_diagnostics_are_omitted(self):
        self.assertIsNone(transcript.project_timeline_message(
            {"role": "user", "content": "heartbeat", "display_kind": "hidden"}))

    def test_image_marker_becomes_a_digest_inside_the_hermes_home_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shot = root / "shot.png"
            shot.write_bytes(b"\x89PNG\r\n" + b"pixels")
            outside = Path(tempfile.mkdtemp()) / "secret.png"
            outside.write_bytes(b"\x89PNG\r\nsecret")
            text = "See [Image attached at: %s] and [Image attached at: %s]" % (shot, outside)
            row = transcript.project_timeline_message({"role": "assistant", "id": 4, "content": text}, [root])
            self.assertEqual(len(row["media"]), 1)
            self.assertEqual(row["media"][0]["name"], "shot.png")
            self.assertEqual(row["media"][0]["kind"], "image")
            self.assertNotIn(str(shot), row["content"])
            self.assertIn(str(outside), row["content"])
            self.assertEqual(transcript.file_for_digest([text], row["media"][0]["digest"], [root]), shot.resolve())
            self.assertIsNone(transcript.file_for_digest([text], "a" * 64, [root]))
            outside.unlink()
            outside.parent.rmdir()


class SkillFileTest(unittest.TestCase):
    def test_create_and_append_stay_inside_the_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            created = transcript.create_skill(home, "print-plates", "How plates are named",
                                             "Name a plate after the part it holds.")
            self.assertEqual(created["action"], "created")
            path = home / "skills" / "print-plates" / "SKILL.md"
            self.assertIn("print-plates", path.read_text())
            transcript.append_skill(home, "print-plates", "Also record the color.")
            self.assertIn("Also record the color.", path.read_text())
            with self.assertRaises(ValueError):
                transcript.create_skill(home, "../escape", "no", "not allowed here")
            with self.assertRaises(ValueError):
                transcript.append_skill(home, "..", "no")

    def test_phone_commands_include_learn_and_skip_cli_only(self):
        names = [row["name"] for row in transcript.phone_commands()]
        self.assertIn("learn", names)
        self.assertNotIn("skills", names)  # the hub browser is cli-only
        self.assertTrue(all("_" not in name for name in names))


if __name__ == "__main__":
    unittest.main()
