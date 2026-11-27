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

    def test_missing_file_keeps_the_text(self):
        row = self.row("MEDIA:%s/nope here.png" % self.root)
        self.assertIn("MEDIA:", row["content"])
        self.assertNotIn("content_parts", row)


if __name__ == "__main__":
    unittest.main()
