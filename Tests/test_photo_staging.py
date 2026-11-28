"""Photos must be staged in the image cache of the gateway that serves the bot, not the bridge's own."""
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media
from types import ModuleType
from unittest.mock import patch

_OWN = Path(tempfile.mkdtemp(prefix="hm-own-")).resolve()
_PLATFORM = ModuleType("gateway.platforms.base")
_PLATFORM.get_image_cache_dir = lambda: _OWN
_HOME = ModuleType("hermes_constants")
_HOME.get_hermes_home = lambda: _OWN


def _get_hermes_dir(new, old, home=None):
    old_path = home / old
    return old_path if old_path.is_dir() and any(old_path.iterdir()) else home / new


_HOME.get_hermes_dir = _get_hermes_dir
_MODULES = {"gateway.platforms.base": _PLATFORM, "hermes_constants": _HOME}


def setUpModule():
    global _patch
    _patch = patch.dict(sys.modules, _MODULES)
    _patch.start()


def tearDownModule():
    _patch.stop()


class PhotoStagingTests(unittest.TestCase):
    def test_bot_photo_stages_in_that_profiles_image_cache(self):
        from hermes_constants import get_hermes_home
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve() / "profiles" / "3d-printing"
            home.mkdir(parents=True)
            self.assertNotEqual(home, Path(get_hermes_home()).resolve())
            staged = bridge_media.stage([("p.jpg", 0, b"\xff\xd8jpeg", bridge_media.JPEG)], home)
            try:
                path = Path(staged[0]["path"]).resolve()
                self.assertEqual(path.parent, (home / "cache" / "images").resolve())
                self.assertEqual(path.suffix, ".jpg")
            finally:
                bridge_media.discard(staged)

    def test_every_profile_stages_in_its_own_cache_including_health_and_journal_bots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name in ("bacta-protocol", "captains-log", "3d-printing", "research"):
                home = root / name
                home.mkdir()
                staged = bridge_media.stage([("p.jpg", 0, b"\xff\xd8jpeg", bridge_media.JPEG)], home)
                self.assertEqual(Path(staged[0]["path"]).resolve().parent, (home / "cache" / "images").resolve())

    def test_legacy_populated_image_cache_is_honoured_like_the_gateway(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve() / "captains-log"
            (home / "image_cache").mkdir(parents=True)
            (home / "image_cache" / "old.jpg").write_bytes(b"x")
            staged = bridge_media.stage([("p.jpg", 0, b"\xff\xd8jpeg", bridge_media.JPEG)], home)
            self.assertEqual(Path(staged[0]["path"]).resolve().parent, (home / "image_cache").resolve())

    def test_uploaded_photo_is_a_private_copy_hermes_will_admit(self):
        """Hermes refuses a native attachment with a second name (st_nlink != 1) as a bare invalid_params.
        An uploaded photo used to be hard-linked from the upload store, so every uploaded batch failed."""
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve() / "bot"
            home.mkdir()
            upload = Path(tmp) / "abc.done"
            upload.write_bytes(b"\xff\xd8jpeg-from-upload")
            staged = bridge_media.stage([("p.jpg", 0, upload, bridge_media.JPEG)], home)
            path = Path(staged[0]["path"])
            self.assertEqual(path.lstat().st_nlink, 1)
            self.assertEqual(upload.lstat().st_nlink, 1)
            self.assertFalse(path.samefile(upload))
            self.assertEqual(path.read_bytes(), upload.read_bytes())
            self.assertEqual(staged[0]["size"], upload.stat().st_size)
            bridge_media.discard(staged)
            self.assertTrue(upload.exists(), "discarding the staged photo must not touch the upload")

    def test_uploaded_file_sent_by_path_may_still_be_linked(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve() / "bot"
            home.mkdir()
            upload = Path(tmp) / "doc.done"
            upload.write_bytes(b"%PDF-1.7 big")
            staged = bridge_media.stage([("doc.pdf", 0, upload, "application/pdf")], home)
            self.assertEqual(Path(staged[0]["path"]).read_bytes(), b"%PDF-1.7 big")
            bridge_media.discard(staged)
            self.assertTrue(upload.exists())

    def test_own_home_uses_the_gateway_image_cache(self):
        from gateway.platforms.base import get_image_cache_dir
        from hermes_constants import get_hermes_home
        staged = bridge_media.stage([("p.jpg", 0, b"\xff\xd8jpeg", bridge_media.JPEG)], get_hermes_home())
        try:
            self.assertEqual(Path(staged[0]["path"]).resolve().parent, get_image_cache_dir().resolve())
        finally:
            bridge_media.discard(staged)


if __name__ == "__main__":
    unittest.main()
