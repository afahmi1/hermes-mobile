"""Photos must be staged in the image cache of the gateway that serves the bot, not the bridge's own."""
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media


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
