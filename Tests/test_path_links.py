import sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t


class PathLinkTests(unittest.TestCase):
    def test_mentioned_paths(self):
        got = t.mentioned_paths("Saved to /Users/z/out/report.pdf. Also `~/notes.md`, and (/tmp/x.txt)!")
        self.assertIn("/Users/z/out/report.pdf", got)
        self.assertIn(str(Path.home()) + "/notes.md", got)
        self.assertIn("/tmp/x.txt", got)

    def test_only_assistant_named_files_inside_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            good = root / "report.md"; good.write_text("hi")
            secret = root / ".env"; secret.write_text("KEY=1")
            outside = Path(tempfile.mkdtemp()).resolve() / "x.md"; outside.write_text("no")
            texts = [("assistant", "Wrote %s and %s and %s" % (good, secret, outside)), ("user", "look at %s" % good)]
            self.assertEqual(t.file_for_path(texts, str(good), [root]), good)
            self.assertIsNone(t.file_for_path(texts, str(secret), [root]))
            self.assertIsNone(t.file_for_path(texts, str(outside), [root]))
            self.assertIsNone(t.file_for_path([("user", str(good))], str(good), [root]))


if __name__ == "__main__":
    unittest.main()
