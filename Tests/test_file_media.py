"""Generic Files attachments: pass-through bytes, private staging and agent-readable prompt."""
import base64
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media
import bridge_turns as turns


class FileAttachmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def item(name="song.mp3", mime="audio/mpeg", raw=b"ID3\x04\x00\x00" + b"x" * 64):
        return {"filename": name, "mime": mime, "base64": base64.b64encode(raw).decode()}

    def test_original_bytes_stage_privately_and_reach_the_agent_prompt(self):
        item = self.item()
        frames = bridge_media.decode([item])
        self.assertEqual(frames[0][0], "song.mp3")
        self.assertEqual(frames[0][3], "audio/mpeg")
        staged = bridge_media.stage(frames, self.home)
        path = Path(staged[0]["path"])
        self.assertEqual(path.parent.resolve(), (self.home / "attachments" / "mobile").resolve())
        self.assertTrue(path.name.endswith("_song.mp3"), "kept under its real name")
        self.assertEqual(path.read_bytes(), base64.b64decode(item["base64"]))
        self.assertEqual(staged[0]["name"], "song.mp3")
        self.assertEqual(staged[0]["size"], len(base64.b64decode(item["base64"])))
        if os.name != "nt":
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

        turn = turns.Turn("default", self.home, "session", "Please summarize this.", {})
        turn.media = staged
        prompt = turns._turn_text(turn)
        self.assertIn("song.mp3", prompt)
        self.assertIn("audio/mpeg", prompt)
        self.assertIn(str(path), prompt)
        self.assertIn("do not execute", prompt)
        self.assertNotIn(str(path), str(turn.summary()))

    def test_pdf_text_and_zip_are_files_not_images(self):
        for name, mime in (("notes.pdf", "application/pdf"), ("readme.txt", "text/plain"),
                           ("bundle.zip", "application/zip")):
            self.assertEqual(bridge_media.decode([self.item(name, mime)])[0][3], mime)

    def test_invalid_types_names_and_oversized_files_are_refused(self):
        # Any real image type is accepted now (an iPhone photo is HEIC); it's staged as itself.
        self.assertEqual(len(bridge_media.decode([self.item("pic.webp", mime="image/webp")])), 1)
        with self.assertRaises(bridge_media.MediaError):
            bridge_media.decode([self.item(mime="not a mime")])
        # Names are cleaned, never trusted as paths: a slash can't climb out of the attachments folder.
        self.assertEqual(bridge_media.decode([self.item(name="../song.mp3")])[0][0], ".._song.mp3")
        self.assertEqual(bridge_media.decode([self.item(name="song/name.mp3")])[0][0], "song_name.mp3")
        staged = bridge_media.stage(bridge_media.decode([self.item(name="../../$(rm -rf ~)`x`;.mp3")]), self.home)
        path = Path(staged[0]["path"])
        self.assertEqual(path.parent.resolve(), (self.home / "attachments" / "mobile").resolve())
        self.assertRegex(path.name, r"^[0-9a-f]{12}_[\w.\-]+\.mp3$")
        for name in ("", "..", "\u200b\u200b"):
            with self.assertRaises(bridge_media.MediaError):
                bridge_media.decode([self.item(name=name)])
        oversized = {"filename": "big.mp3", "mime": "audio/mpeg",
                     "base64": base64.b64encode(b"x" * (bridge_media.MAX_BYTES + 1)).decode()}
        with self.assertRaises(bridge_media.MediaError):
            bridge_media.decode([oversized])

    def test_mixed_files_are_bounded_to_the_total_and_age_pruned(self):
        frames = bridge_media.decode([self.item("one.mp3"), self.item("two.pdf", "application/pdf"),
                                      self.item("three.txt", "text/plain")])
        staged = bridge_media.stage(frames, self.home)
        self.assertEqual(len(staged), 3)
        # Kept through a long conversation (the old 4-hour sweep lost files mid-chat), dropped after 30 days.
        day = os.path.getmtime(staged[0]["path"]) - 86400
        os.utime(staged[1]["path"], (day, day))
        old = os.path.getmtime(staged[0]["path"]) - 31 * 86400
        os.utime(staged[0]["path"], (old, old))
        bridge_media._PRUNED.clear()
        bridge_media.prune(self.home)
        self.assertFalse(Path(staged[0]["path"]).exists())
        self.assertTrue(Path(staged[1]["path"]).exists())

    def test_image_mime_still_uses_the_native_image_path(self):
        # A JPEG body is validated for the inline adapter, not staged as a generic file.
        from io import BytesIO
        from PIL import Image
        buf = BytesIO()
        Image.new("RGB", (32, 32), "red").save(buf, "JPEG")
        with patch.object(bridge_media, "supported", return_value=False), \
                self.assertRaises(bridge_media.MediaError):
            bridge_media.decode([self.item("photo.jpg", "image/jpeg", buf.getvalue())])


if __name__ == "__main__":
    unittest.main()
