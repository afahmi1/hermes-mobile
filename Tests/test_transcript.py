import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
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


class AttachmentsBothWaysTest(unittest.TestCase):
    """What you attach, on the phone or the desktop, comes back as a file you can open, not as instructions."""

    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def file(self, name, data=b"data"):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_the_bridges_own_notes_become_attachments(self):
        import json
        shot, doc, clip = self.file("hm_send_a.jpg", b"\xff\xd8jpeg"), self.file("hm_send_b.pdf"), self.file("hm_send_c.mp4")
        text = ("look at these\n\n"
                "The user attached an image named %s. It is saved at the following local path. Use vision_analyze on it "
                "to see it. Local file path: %s\n\n"
                "The user attached a file named %s (application/pdf, 4 bytes). It is saved at the following local path. "
                "Use an appropriate available tool to read or process it; do not execute it. Local file path: %s\n\n"
                "The user attached a video clip and consented to auxiliary video processing. Use video_analyze with "
                "video_url set to the following local file path to answer their question. If analysis fails, explain "
                "the limitation. Local file path: %s") % (
            json.dumps("Photo.jpg"), json.dumps(str(shot)), json.dumps("plan.pdf"), json.dumps(str(doc)), json.dumps(str(clip)))
        row = transcript.project_timeline_message({"role": "user", "id": 1, "content": text}, [self.root])
        self.assertEqual(row["content"], "look at these")
        # The name the person picked, not the staging file's.
        self.assertEqual([m["name"] for m in row["media"]], ["Photo.jpg", "plan.pdf", "hm_send_c.mp4"])
        self.assertEqual([m["kind"] for m in row["media"]], ["image", "file", "file"])
        for path, media in zip((shot, doc, clip), row["media"]):
            self.assertEqual(transcript.file_for_digest([("user", text)], media["digest"], [self.root]), path.resolve())

    def test_a_picked_name_keeps_the_staged_files_extension(self):
        staged = self.file("hm_send_z.jpg", b"\xff\xd8jpeg")
        text = 'The user attached an image named "IMG_1.HEIC". Local file path: "%s"' % staged
        row = transcript.project_timeline_message({"role": "user", "content": text}, [self.root])
        self.assertEqual(row["media"][0]["name"], "IMG_1.jpg")

    def test_a_note_whose_file_is_gone_leaves_its_name(self):
        text = ('hi\n\nThe user attached a file named "verification.txt" (text/plain, 19 bytes). It is saved at the '
                'following local path. Use an appropriate available tool to read or process it; do not execute it. '
                'Local file path: "%s"') % (self.root / "gone.txt")
        row = transcript.project_timeline_message({"role": "user", "content": text}, [self.root])
        self.assertEqual(row["content"], "hi\n\n📎 verification.txt")
        self.assertNotIn("media", row)

    def test_a_note_cannot_reach_outside_the_roots(self):
        outside = Path(self.enterContext(tempfile.TemporaryDirectory())) / "x.pdf"
        outside.write_bytes(b"secret")
        text = 'The user attached a file named "x.pdf" (application/pdf, 6 bytes). Local file path: "%s"' % outside
        row = transcript.project_timeline_message({"role": "user", "content": text}, [self.root])
        self.assertNotIn("media", row)
        self.assertNotIn(str(outside), row.get("content", ""))

    def test_a_voice_note_keeps_its_words_and_plays(self):
        audio = self.file("voice.m4a")
        text = '"turn the bed heater off"\n[User sent audio: %s]' % audio
        row = transcript.project_timeline_message({"role": "user", "content": text}, [self.root])
        self.assertEqual(row["content"], '"turn the bed heater off"')
        self.assertEqual(row["media"][0]["name"], "voice.m4a")

    def test_a_long_paste_can_be_opened(self):
        paste = self.file("paste_3.txt", b"line\n" * 6)
        text = "[Pasted text #3: 6 lines → %s]\nwhat do you think" % paste
        row = transcript.project_timeline_message({"role": "user", "content": text}, [self.root])
        self.assertEqual(row["note"], "Pasted 6 lines")
        self.assertEqual(row["content"], "what do you think")
        self.assertEqual(row["media"][0]["name"], "paste_3.txt")

    def test_desktop_composer_images_show_and_their_inline_base64_does_not(self):
        composer = self.root / "Hermes" / "composer-images"
        composer.mkdir(parents=True)
        image = composer / "image_ab.png"
        image.write_bytes(b"\x89PNG\r\n")
        text = ('submit flag\n\n[Image attached at: %s]{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}'
                % image)
        row = transcript.project_timeline_message({"role": "user", "content": text}, [composer])
        self.assertEqual(row["content"], "submit flag")
        self.assertEqual(row["media"][0]["name"], "image_ab.png")

    def test_desktop_roots_cover_each_os(self):
        with patch.dict(os.environ, {"APPDATA": str(self.root)}):
            roots = [str(r) for r in transcript.desktop_attachment_roots()]
        self.assertIn(str(Path.home() / "Library/Application Support/Hermes/composer-images"), roots)
        self.assertIn(str(self.root / "Hermes" / "composer-images"), roots)


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
