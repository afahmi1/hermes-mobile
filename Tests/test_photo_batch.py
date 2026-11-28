"""A big batch of full-resolution photos: fifteen real 24 MP JPEGs uploaded in 1 MiB chunks (with a dropped
acknowledgment mid-way), referenced from ONE message, verified and staged byte-for-byte. Also the pixel limit:
an iPhone's 12 MP and 48 MP photos are accepted, anything past 50 MP is refused with a clear reason."""
import hashlib
import io
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media as media  # noqa: E402
import bridge_uploads as up  # noqa: E402

try:
    from PIL import Image
except ImportError:  # the bridge runs in Hermes's environment, which always has Pillow
    Image = None

CHUNK = 1024 * 1024
COUNT = 15


def jpeg(size, noisy=False, quality=92):
    image = Image.effect_noise(size, 90).convert("RGB") if noisy else Image.new("RGB", size, (40, 60, 90))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=quality)
    return out.getvalue()


def variant(data, i):
    # A JPEG comment right after the start marker: still a valid photo, but a different file (and hash).
    note = b"photo %d" % i
    return data[:2] + b"\xff\xfe" + struct.pack(">H", len(note) + 2) + note + data[2:]


@unittest.skipIf(Image is None, "needs Pillow")
class PhotoBatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.photo = jpeg((6048, 4032), noisy=True)  # a 24 MP iPhone photo, full detail

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "uploads"
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        media.UPLOADS = self.root
        self._supported = media.supported
        media.supported = lambda: True  # Hermes's image intake is present on a real install

    def tearDown(self):
        media.supported = self._supported
        media.UPLOADS = None
        self.tmp.cleanup()

    def send_photo(self, i, data, drop_ack_at=None):
        uid = hashlib.sha256(b"photo-%d" % i).hexdigest()[:32]
        sha = hashlib.sha256(data).hexdigest()
        name = "Photo-%02d.jpg" % i
        self.assertEqual(up.create(self.root, uid, name, "image/jpeg", len(data), sha,
                                   media.valid_name, media.valid_mime)["offset"], 0)
        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + CHUNK]
            if drop_ack_at is not None and offset == drop_ack_at:
                up.append(self.root, uid, offset, chunk)  # arrives, but the phone never hears back
                with self.assertRaises(up.UploadError) as ctx:  # so it retries the same chunk
                    up.append(self.root, uid, offset, chunk)
                self.assertEqual(ctx.exception.code, 409)
                offset = ctx.exception.offset  # and is told exactly where to resume
                drop_ack_at = None
                continue
            offset = up.append(self.root, uid, offset, chunk)["offset"]
        self.assertTrue(up.status(self.root, uid)["complete"])
        return {"filename": name, "mime": "image/jpeg", "upload_id": uid}, sha

    def test_fifteen_full_size_photos_in_one_message(self):
        photos = [variant(self.photo, i) for i in range(COUNT)]
        self.assertGreater(len(photos[0]), 4 * CHUNK, "the fixture is a real full-size photo")
        items, digests = [], []
        for i, data in enumerate(photos):
            item, sha = self.send_photo(i, data, drop_ack_at=2 * CHUNK if i == 7 else None)
            items.append(item)
            digests.append(sha)

        frames = media.decode(items)  # uploads sit outside the inline budget: no size error for the batch
        self.assertEqual(len(frames), COUNT)
        self.assertEqual([f[1] for f in frames], digests, "every photo verified by its SHA-256")
        staged = media.stage(frames, self.home)
        self.assertEqual(len(staged), COUNT)
        for data, s in zip(photos, staged):
            got = Path(s["path"]).read_bytes()
            self.assertEqual(got, data, "every byte arrives as sent, nothing shrunk")
            with Image.open(s["path"]) as im:
                self.assertEqual(im.size, (6048, 4032), "full resolution on the Mac")

    def test_iphone_photo_sizes_are_accepted_and_giants_arrive_with_a_viewing_copy(self):
        for i, size in enumerate([(4032, 3024), (8064, 6048)]):  # 12.19 MP (the old cap refused it) and 48.8 MP
            item, _ = self.send_photo(i, jpeg(size))
            self.assertEqual([f[3] for f in media.decode([item])], [media.JPEG], "%dx%d must be accepted" % size)
        giant = jpeg((9000, 6000))  # 54 MP: a panorama. Never refused: the original is kept, the model gets a copy.
        item, _ = self.send_photo(9, giant)
        frames = media.decode([item])
        staged = media.stage(frames, self.home)
        original, copy = staged
        self.assertEqual(Path(original["path"]).read_bytes(), giant)
        self.assertIs(original["native"], False)
        self.assertEqual(copy["copy_of"], original["path"])
        self.assertTrue(copy["native"])
        with Image.open(copy["path"]) as im:
            self.assertLessEqual(im.width * im.height, media.MAX_PIXELS)

    def test_a_damaged_photo_still_arrives_as_a_file(self):
        broken = self.photo[: len(self.photo) // 3]  # cut off mid-scan
        item, _ = self.send_photo(0, broken)
        frames = media.decode([item])
        self.assertEqual(frames[0][3], "application/octet-stream", "kept, but never attached as a picture")

    def test_a_mislabelled_photo_is_relabelled_not_refused(self):
        from io import BytesIO
        buf = BytesIO()
        Image.new("RGB", (64, 64), "blue").save(buf, "PNG")
        item, _ = self.send_photo(0, buf.getvalue())  # the phone said image/jpeg
        frames = media.decode([item])
        self.assertEqual(frames[0][3], "image/png")
        staged = media.stage(frames, self.home)
        self.assertEqual([s["mime"] for s in staged], ["image/png", media.JPEG])

    def test_batch_over_the_item_limit_is_refused_with_a_clear_message(self):
        small = jpeg((64, 64))
        items = [self.send_photo(i, variant(small, i))[0] for i in range(media.MAX_ITEMS + 1)]
        with self.assertRaises(media.MediaError) as ctx:
            media.decode(items)
        self.assertIn(str(media.MAX_ITEMS), str(ctx.exception))

    def test_message_limit_is_reported(self):
        self.assertGreater(media.message_limit(), 0)

    def test_fifteen_photos_never_exceed_hermes_native_limit(self):
        """Hermes refuses a whole message with more than 10 native images ("invalid params"). Fifteen photos:
        ten ride natively, five are named by path, all fifteen arrive."""
        import bridge_turns
        small = jpeg((800, 600))
        items = [self.send_photo(i, variant(small, i))[0] for i in range(15)]
        staged = media.stage(media.decode(items), self.home)
        native = [m for m in staged if m.get("native")]
        self.assertEqual(len(native), media.native_image_limit())
        self.assertEqual(len(staged), 15, "every photo staged")
        notes = bridge_turns._media_notes(staged)
        for m in staged:
            if not m.get("native"):
                self.assertIn(m["path"], notes, "a photo past the limit is handed over by path")
            else:
                self.assertNotIn(m["path"], notes, "a native photo isn't described twice")
        try:  # the contract with Hermes itself, when it's importable
            from gateway.session_ingress_media import _ATTACHMENT_LIMIT, _ATTACHMENT_MIMES
        except Exception:
            return
        self.assertLessEqual(len(native), _ATTACHMENT_LIMIT)
        self.assertTrue(all(m["mime"] in _ATTACHMENT_MIMES for m in native))

    def test_heic_original_arrives_untouched_with_a_jpeg_copy(self):
        try:
            import pillow_heif
            pillow_heif.register_heif_opener()
        except Exception:
            self.skipTest("needs pillow-heif")
        out = io.BytesIO()
        Image.effect_noise((4032, 3024), 60).convert("RGB").save(out, "HEIF", quality=90)
        heic = out.getvalue()
        sha = hashlib.sha256(heic).hexdigest()
        uid = "c" * 32
        up.create(self.root, uid, "IMG_2783.HEIC", "image/heic", len(heic), sha, media.valid_name, media.valid_mime)
        up.append(self.root, uid, 0, heic)
        staged = media.stage(media.decode([{"filename": "IMG_2783.HEIC", "mime": "image/heic", "upload_id": uid}]), self.home)
        original = next(m for m in staged if m["mime"] == "image/heic")
        copy = next(m for m in staged if m.get("copy_of"))
        self.assertEqual(Path(original["path"]).read_bytes(), heic, "the HEIC itself, byte for byte")
        self.assertTrue(original["path"].lower().endswith(".heic"))
        with Image.open(copy["path"]) as im:
            self.assertEqual((im.format, im.size), ("JPEG", (4032, 3024)), "a full-resolution JPEG to look at")
        self.assertTrue(copy["native"])
        import bridge_turns
        notes = bridge_turns._media_notes(staged)
        self.assertIn(original["path"], notes)
        self.assertIn("untouched", notes)

    def test_any_file_type_is_accepted(self):
        for mime in ("image/heic", "image/png", "image/x-adobe-dng", "application/pdf", "model/stl", "audio/mp4"):
            self.assertTrue(media.valid_mime(mime), mime)


if __name__ == "__main__":
    unittest.main()
