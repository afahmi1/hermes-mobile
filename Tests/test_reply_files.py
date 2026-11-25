"""Files a reply hands to the phone: wider roots for Hermes's own replies, secrets never served."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t


class ReplyFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.hermes = self.home / ".hermes"
        (self.hermes / "profiles" / "bot" / "cache").mkdir(parents=True)
        (self.home / "Desktop" / "proj").mkdir(parents=True)
        (self.home / ".ssh").mkdir()
        self.files = {}
        for rel in ("Desktop/proj/report.pdf", "Desktop/proj/model.3mf", "Desktop/proj/auth.json",
                    "Desktop/proj/.env", "Desktop/proj/server.pem", ".ssh/notes.txt", ".hermes/config.yaml",
                    ".hermes/profiles/bot/config.yaml", ".hermes/profiles/bot/cache/plot.png",
                    "Desktop/proj/session-notes.md", "Desktop/proj/tool.exe"):
            p = self.home / rel
            p.write_bytes(b"x")
            self.files[rel] = p
        self.env = patch.dict(os.environ, {"HERMES_HOME": str(self.hermes)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def allowed(self, rel, roots):
        return t.safe_file(str(self.files[rel]), roots) is not None

    def test_reply_roots_allow_work_files_but_never_secrets(self):
        roots = [self.hermes, self.home]
        for rel in ("Desktop/proj/report.pdf", "Desktop/proj/model.3mf", "Desktop/proj/session-notes.md",
                    ".hermes/profiles/bot/cache/plot.png"):
            self.assertTrue(self.allowed(rel, roots), rel)
        for rel in ("Desktop/proj/auth.json", "Desktop/proj/.env", "Desktop/proj/server.pem", ".ssh/notes.txt",
                    ".hermes/config.yaml", ".hermes/profiles/bot/config.yaml", "Desktop/proj/tool.exe"):
            self.assertFalse(self.allowed(rel, roots), rel)

    def test_only_hermes_replies_reach_outside_the_hermes_home(self):
        pdf = self.files["Desktop/proj/report.pdf"]
        digest = t._digest(pdf)
        said = "MEDIA:%s" % pdf
        self.assertIsNone(t.file_for_digest([("user", said)], digest, [self.hermes], [self.home]))
        self.assertIsNone(t.file_for_digest([said], digest, [self.hermes], [self.home]))
        self.assertEqual(t.file_for_digest([("assistant", said)], digest, [self.hermes], [self.home]), pdf)

    def test_timeline_cards_use_the_same_rule(self):
        pdf = self.files["Desktop/proj/report.pdf"]
        reply = t.project_timeline_message({"id": 1, "role": "assistant", "content": "Here it is\nMEDIA:%s" % pdf},
                                           [self.hermes], [self.home])
        self.assertEqual(reply["media"][0]["name"], "report.pdf")
        self.assertEqual(reply["media"][0]["kind"], "file")
        self.assertNotIn("MEDIA:", reply["content"])
        typed = t.project_timeline_message({"id": 2, "role": "user", "content": "MEDIA:%s" % pdf},
                                           [self.hermes], [self.home])
        self.assertNotIn("media", typed or {})


if __name__ == "__main__":
    unittest.main()
