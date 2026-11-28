"""Every kind of file the phone sends reaches the model the way Hermes's own adapters hand it over, and survives."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import base64
import io
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media as media
import bridge_turns as turns
from PIL import Image


def jpeg(size=(64, 64), color="red"):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "JPEG", quality=95)
    return buf.getvalue()


def item(name, mime, raw):
    return {"filename": name, "mime": mime, "base64": base64.b64encode(raw).decode()}


class AttachmentHandlingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve() / "profiles" / "bot"
        self.home.mkdir(parents=True)
        self.attachments = (self.home / "attachments" / "mobile").resolve()

    def notes(self, staged):
        return turns._media_notes(staged)

    def test_names_are_cleaned_not_refused(self):
        self.assertEqual(media.clean_name("Screenshot 2026-11-27 at 7.40.12 PM.png"),
                         "Screenshot 2026-11-27 at 7.40.12 PM.png")
        nfd = "가.pdf"  # decomposed Hangul from iOS
        self.assertEqual(media.clean_name(nfd), "가.pdf")
        long = "x" * 300 + ".pptx"
        cleaned = media.clean_name(long)
        self.assertLessEqual(len(cleaned), 140)
        self.assertTrue(cleaned.endswith(".pptx"), "a shortened name keeps its extension")
        self.assertEqual(media.clean_name("a\x00b​c.txt"), "abc.txt")
        self.assertIsNone(media.clean_name(""))

    def test_photos_past_hermes_limits_go_by_path_and_outlive_the_image_cache_sweep(self):
        frames = media.decode([item("p%d.jpg" % i, "image/jpeg", jpeg(color=(i * 20, 0, 0))) for i in range(12)])
        staged = media.stage(frames, self.home)
        native = [s for s in staged if s["native"]]
        by_path = [s for s in staged if not s["native"]]
        self.assertEqual(len(native), media.native_image_limit())
        self.assertEqual(len(by_path), 12 - media.native_image_limit())
        for s in by_path:
            self.assertEqual(Path(s["path"]).parent, self.attachments, "not in cache/images, which Hermes sweeps daily")
            self.assertTrue(Path(s["path"]).is_file())
        note = self.notes(staged)
        for s in by_path:
            self.assertIn(s["path"], note)
        self.assertEqual(note.count("vision_analyze"), len(by_path))

    def test_native_photos_stop_at_hermes_byte_cap(self):
        frames = media.decode([item("p%d.jpg" % i, "image/jpeg", jpeg(color=(0, i * 40, 0))) for i in range(4)])
        one = len(frames[0][2])
        with patch.object(media, "message_limit", return_value=int(one * 2.5 / 0.95)):
            staged = media.stage(frames, self.home)
        self.assertEqual([s["native"] for s in staged], [True, True, False, False])
        self.assertLessEqual(sum(s["size"] for s in staged if s["native"]), one * 2.5)

    def test_heic_like_original_is_kept_and_viewed_through_a_copy(self):
        buf = io.BytesIO()
        Image.new("RGB", (80, 60), "green").save(buf, "PNG")
        staged = media.stage(media.decode([item("IMG_0001.png", "image/png", buf.getvalue())]), self.home)
        original, copy = staged
        self.assertEqual(Path(original["path"]).parent, self.attachments)
        self.assertTrue(original["path"].endswith("_IMG_0001.png"))
        self.assertEqual(copy["copy_of"], original["path"])
        self.assertIn("the original file, untouched", self.notes(staged))

    def test_small_text_files_are_inlined_like_telegram(self):
        staged = media.stage(media.decode([item("notes.md", "text/markdown", b"# Plan\n- ship it\n")]), self.home)
        note = self.notes(staged)
        self.assertIn("Its content has been included below", note)
        self.assertIn("[Content of notes.md]:\n# Plan\n- ship it", note)

    def test_big_text_files_are_referenced_not_inlined(self):
        big = b"a,b\n" * (media_limit := turns._TEXT_INLINE_BYTES // 4 + 10)
        staged = media.stage(media.decode([item("data.csv", "text/csv", big)]), self.home)
        note = self.notes(staged)
        self.assertIn("Its content is not inlined here", note)
        self.assertNotIn("a,b\na,b", note)

    def test_office_and_pdf_point_at_read_file(self):
        for name, mime in (("Q3 deck.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
                           ("report.pdf", "application/pdf"), ("budget.xlsx", "application/vnd.ms-excel"),
                           ("letter.docx", "application/msword")):
            staged = media.stage(media.decode([item(name, mime, b"PK\x03\x04binary")]), self.home)
            note = self.notes(staged)
            self.assertIn("read_file extracts its text", note, name)
            self.assertIn("'%s'" % name, note)
            self.assertIn("Do not execute it", note)

    def test_iwork_bundle_gets_its_preview_pdf_extracted(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("Index/Document.iwa", b"\x00\x01")
            z.writestr("QuickLook/Preview.pdf", b"%PDF-1.7 preview")
        staged = media.stage(media.decode([item("Talk.key", "application/x-iwork-keynote-sffkey", buf.getvalue())]),
                             self.home)
        preview = Path(staged[0]["preview"])
        self.assertEqual(preview.read_bytes(), b"%PDF-1.7 preview")
        self.assertIn(str(preview), self.notes(staged))
        media.discard(staged)
        self.assertFalse(preview.exists())

    def test_archives_and_videos_get_specific_guidance(self):
        staged = media.stage(media.decode([item("site.zip", "application/zip", b"PK\x05\x06" + b"\0" * 18)]), self.home)
        self.assertIn("list its contents first", self.notes(staged))
        staged = media.stage(media.decode([item("clip.mov", "video/quicktime", b"\0\0\0\x14ftypqt  ")]), self.home)
        self.assertIn("video_analyze", self.notes(staged))

    def test_extensionless_file_takes_its_extension_from_the_type(self):
        staged = media.stage(media.decode([item("Report", "application/pdf", b"%PDF-1.7")]), self.home)
        self.assertTrue(staged[0]["path"].endswith("_Report.pdf"))


if __name__ == "__main__":
    unittest.main()
