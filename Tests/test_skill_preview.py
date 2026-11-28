import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as bt  # noqa: E402


class SkillPreview(unittest.TestCase):
    """A skill edit says what it did in the tool card, instead of a bare "skill manage"."""

    def test_operations_list(self):
        raw = json.dumps({"operations": [
            {"action": "create", "name": "hermes-mobile-app", "content": "---"},
            {"action": "write_file", "name": "hermes-mobile-app", "file_path": "references/media-limits.md",
             "file_content": "x"}]})
        self.assertEqual(bt._arg_preview(raw),
                         "created hermes-mobile-app; wrote hermes-mobile-app/references/media-limits.md")

    def test_single_action_and_many(self):
        self.assertEqual(bt._arg_preview(json.dumps({"action": "patch", "name": "cad"})), "updated cad")
        many = {"operations": [{"action": "patch", "name": "s%d" % i} for i in range(5)]}
        self.assertEqual(bt._arg_preview(json.dumps(many)), "updated s0; updated s1; updated s2 · 5 changes")

    def test_other_tools_unchanged(self):
        self.assertEqual(bt._arg_preview(json.dumps({"command": "ls -la"})), "ls -la")
        self.assertEqual(bt._arg_preview(json.dumps({"name": "cad"})), "cad")


if __name__ == "__main__":
    unittest.main()
