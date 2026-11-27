import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64


class InlineMedia(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        runs = self.root / "3D Printing" / "Runs"
        runs.mkdir(parents=True)
        self.a = runs / "Plate B front true-Z.png"
        self.b = runs / "01 All seven overall (IMG_2783).jpg"
        self.a.write_bytes(PNG)
        self.b.write_bytes(PNG)

    def row(self, text):
        return t.project_timeline_message({"role": "assistant", "content": text, "id": 1}, [self.root])

    def test_paths_with_spaces_become_images_in_place(self):
        text = ("**Nov 19: Klimt Tree Cat** [Rocket]\nMEDIA:%s\n\n**Nov 16, your photo**\nMEDIA:%s\n\nThat's all." % (self.a, self.b))
        row = self.row(text)
        self.assertEqual([m["name"] for m in row["media"]], [self.a.name, self.b.name])
        self.assertNotIn("MEDIA:", row["content"])
        self.assertNotIn("\ue000", row["content"])
        kinds = [("media" if "media" in p else "text") for p in row["content_parts"]]
        self.assertEqual(kinds, ["text", "media", "text", "media", "text"])
        self.assertEqual([p["media"] for p in row["content_parts"] if "media" in p], [0, 1])

    def test_emphasis_and_quotes(self):
        row = self.row('Here: **MEDIA:"%s"**' % self.a)
        self.assertEqual(len(row["media"]), 1)

    def test_plain_paths_show_under_their_line(self):
        text = ("Built from these:\n- `%s` (front)\n- %s, overall\n\n```\nls %s\n```\nDone." % (self.a, self.b, self.a))
        row = self.row(text)
        self.assertEqual([m["name"] for m in row["media"]], [self.a.name, self.b.name])
        self.assertIn(str(self.a), row["content"])  # the path text stays
        kinds = [("media" if "media" in p else "text") for p in row["content_parts"]]
        self.assertEqual(kinds, ["text", "media", "text", "media", "text"])
        # digest resolves back to the file for the image endpoint
        self.assertEqual(t.file_for_digest([("assistant", text)], row["media"][0]["digest"], [self.root]), self.a)

    def test_image_in_code_block_waits_for_the_fence(self):
        row = self.row("```\n%s\n```\nafter" % self.a)
        first = row["content_parts"][0]["text"]
        self.assertTrue(first.rstrip().endswith("```"))

    def test_user_paths_are_not_promoted(self):
        row = t.project_timeline_message({"role": "user", "content": "look at %s" % self.a, "id": 2}, [self.root])
        self.assertNotIn("media", row)

    def test_missing_file_keeps_the_text(self):
        row = self.row("MEDIA:%s/nope here.png" % self.root)
        self.assertIn("MEDIA:", row["content"])
        self.assertNotIn("content_parts", row)


if __name__ == "__main__":
    unittest.main()
