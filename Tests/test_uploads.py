"""Resumable uploads: announce, chunk, resume at the right offset, verify, and reference from a message."""
import base64
import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_uploads as up
import bridge_media as media


def ok_name(n):
    return media.valid_name(n)


def ok_mime(m):
    return media.valid_mime(m)


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "uploads"
        self.data = os.urandom(3 * 1024 * 1024 + 17)
        self.sha = hashlib.sha256(self.data).hexdigest()
        self.uid = "ab" * 16

    def tearDown(self):
        self.tmp.cleanup()
        media.UPLOADS = None

    def announce(self, **kw):
        args = dict(filename="screen.mov", mime="video/quicktime", size=len(self.data), sha256=self.sha)
        args.update(kw)
        return up.create(self.root, self.uid, args["filename"], args["mime"], args["size"], args["sha256"], ok_name, ok_mime)

    def test_chunked_upload_resumes_and_verifies(self):
        self.assertEqual(self.announce()["offset"], 0)
        self.assertEqual(self.announce()["offset"], 0, "announcing twice is harmless")
        first = up.append(self.root, self.uid, 0, self.data[:1024 * 1024])
        self.assertEqual(first["offset"], 1024 * 1024)
        # A lost acknowledgment: the phone retries the same chunk at the old offset and is told where to resume.
        with self.assertRaises(up.UploadError) as ctx:
            up.append(self.root, self.uid, 0, self.data[:1024 * 1024])
        self.assertEqual((ctx.exception.code, ctx.exception.offset), (409, 1024 * 1024))
        self.assertEqual(up.status(self.root, self.uid)["offset"], 1024 * 1024)
        done = up.append(self.root, self.uid, 1024 * 1024, self.data[1024 * 1024:])
        self.assertTrue(done["complete"])
        path, meta = up.resolve(self.root, self.uid)
        self.assertEqual(path.read_bytes(), self.data)
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")

    def test_damaged_file_restarts_from_zero(self):
        self.announce(sha256="0" * 64)
        with self.assertRaises(up.UploadError) as ctx:
            up.append(self.root, self.uid, 0, self.data)
        self.assertEqual((ctx.exception.code, ctx.exception.offset), (422, 0))
        self.assertEqual(up.status(self.root, self.uid)["offset"], 0)

    def test_same_id_different_file_is_refused(self):
        self.announce()
        with self.assertRaises(up.UploadError) as ctx:
            self.announce(filename="other.mov")
        self.assertEqual(ctx.exception.code, 409)

    def test_limits(self):
        with self.assertRaises(up.UploadError):
            self.announce(size=up.MAX_BYTES + 1)
        with self.assertRaises(up.UploadError):
            self.announce(filename="..")
        with self.assertRaises(up.UploadError):
            up.status(self.root, "not-an-id")

    def test_message_refers_to_a_finished_upload_and_stages_without_copying(self):
        self.announce()
        up.append(self.root, self.uid, 0, self.data)
        media.UPLOADS = self.root
        frames = media.decode([{"filename": "screen.mov", "mime": "video/quicktime", "upload_id": self.uid}])
        name, digest, raw, mime = frames[0]
        self.assertEqual((name, digest, mime), ("screen.mov", self.sha, "video/quicktime"))
        home = Path(self.tmp.name) / "home"
        home.mkdir()
        staged = media.stage(frames, home)
        self.assertEqual(Path(staged[0]["path"]).read_bytes(), self.data)
        self.assertEqual(staged[0]["size"], len(self.data))
        # Same fingerprint as if it had been sent inline: receipts don't care which path the bytes took.
        inline = media.decode([{"filename": "small.txt", "mime": "text/plain",
                                "base64": base64.b64encode(b"hi").decode()}])
        self.assertEqual(inline[0][1], hashlib.sha256(b"hi").hexdigest())

    def test_unfinished_or_mismatched_upload_is_refused(self):
        self.announce()
        media.UPLOADS = self.root
        with self.assertRaises(media.MediaError):
            media.decode([{"filename": "screen.mov", "mime": "video/quicktime", "upload_id": self.uid}])
        up.append(self.root, self.uid, 0, self.data)
        with self.assertRaises(media.MediaError):
            media.decode([{"filename": "renamed.mov", "mime": "video/quicktime", "upload_id": self.uid}])

    def test_prune_removes_stale_uploads(self):
        self.announce()
        self.assertEqual(up.prune(self.root, ttl=-1), 1)
        with self.assertRaises(up.UploadError):
            up.status(self.root, self.uid)


if __name__ == "__main__":
    unittest.main()
