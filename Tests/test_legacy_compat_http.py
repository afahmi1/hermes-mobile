"""Deployment compatibility: the current send-once/media protocol and older clients on one bridge.

Older app builds use plain `/send`, chunked `/m/upload` + `/m/media`, `/m/turns` and hm1 bearer
tokens with no device id. These must keep working next to media-capabilities and send-once.
Synthetic HERMES_HOME, token and gateway only.
"""
import base64
import hashlib
import hmac
import io
import json
import sys
import threading
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_chat_media_http as base

Image = base.Image


def setUpModule():
    base.setUpModule()


class LegacyCompat(base.Harness):
    def legacy_token(self, **extra):
        """A pre-device-registry hm1 token, exactly as the older bridge signed it."""
        claims = {"exp": int(time.time()) + 3600, "dev": "older-phone", "n": "ab12cd34", **extra}
        payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        return "hm1." + payload + "." + hmac.new(base.bridge.SECRET, payload.encode(), hashlib.sha256).hexdigest()

    def put(self, path, raw, token=True):
        c = base.http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        c.request("PUT", path, body=raw, headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/octet-stream"})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, json.loads(body)

    def upload(self, name, raw, mime=""):
        status, start = self.req("POST", "/m/upload/bot-a", {"name": name, "size": len(raw), "mime": mime})
        self.assertEqual(status, 201, start)
        status, done = self.put("/m/upload/%s?offset=0" % start["upload_id"], raw)
        self.assertEqual((status, done["done"]), (200, True), done)
        return done

    def wait_idle(self):
        for _ in range(200):
            if not any(not t.done for t in base.turns.TURNS.values()):
                return
            threading.Event().wait(0.02)

    def test_legacy_hm1_token_still_signs_in_and_is_registered_additively(self):
        self.token = self.legacy_token()
        status, caps = self.req("GET", "/m/capabilities")
        self.assertEqual(status, 200)
        self.assertIn("file_attachments_v1", caps["features"])  # the protocol whose absence was the 404
        self.assertEqual(self.req("GET", "/m/chat/bot-a/media-capabilities")[0], 200)
        # Same token still lists turns, and the registry file is new, additive state.
        self.assertEqual(self.req("GET", "/m/turns")[0], 200)
        self.assertTrue((Path(base.bridge.STATE_DIR) / "devices" / "devices.sqlite3").is_file())
        self.token = "hm1.e30.bad"
        self.assertEqual(self.req("GET", "/m/capabilities")[0], 401)

    def test_plain_legacy_text_send_has_no_media_and_no_submission_id(self):
        status, turn = self.req("POST", "/m/chat/bot-a/stored1/send", {"text": "plain legacy"})
        self.assertEqual(status, 202, turn)
        params = self.wait_submitted()
        self.assertEqual(params["text"], "plain legacy")
        self.assertNotIn("attachments", params)

    @unittest.skipIf(Image is None, "Pillow is required to make the PNG")
    def test_legacy_chunked_png_and_pdf_reach_the_gateway(self):
        png = io.BytesIO()
        Image.new("RGB", (24, 24), (200, 40, 40)).save(png, "PNG")
        image = self.upload("shot.png", png.getvalue(), "image/png")
        self.assertEqual(image["kind"], "image")
        pdf = self.upload("brief.pdf", base.PDF, "application/pdf")
        self.assertEqual(pdf["kind"], "file")
        status, turn = self.req("POST", "/m/chat/bot-a/stored1/send",
                                {"text": "legacy refs", "attachments": [image["ref"], pdf["ref"]]})
        self.assertEqual(status, 202, turn)
        params = self.wait_submitted()
        [native] = params["attachments"]
        self.assertEqual(native["mime"], "image/png")
        self.assertEqual(self.gw.contents[native["path"]], png.getvalue())
        self.assertIn("brief.pdf", params["text"])
        staged = Path(json.loads(params["text"].rsplit("Local file path: ", 1)[1]))
        self.assertEqual(self.gw.contents[str(staged)], base.PDF)
        self.wait_idle()
        self.assertTrue(staged.is_file(), "a legacy upload is kept by its own sweep, not deleted by the turn")
        # The image comes back for the history thumbnail route, only for an authenticated caller.
        path = Path(native["path"])
        status, _ = self.req("GET", "/m/media/bot-a?path=%s" % path)
        self.assertEqual(status, 200)

    def test_legacy_refs_are_bot_scoped_signed_and_authenticated(self):
        done = self.upload("notes.txt", b"hello\n", "text/plain")
        self.assertEqual(self.req("POST", "/m/upload/bot-a", {"name": "x", "size": 1}, token=False)[0], 401)
        self.assertEqual(self.req("GET", "/m/media/bot-a?path=/etc/hosts", token=False)[0], 401)
        self.assertEqual(self.req("GET", "/m/media/bot-a?path=/etc/hosts")[0], 404)
        forged = done["ref"][:-4] + "0000"
        status, body = self.req("POST", "/m/chat/bot-a/stored1/send", {"text": "x", "attachments": [forged]})
        self.assertEqual(status, 400, body)
        status, body = self.req("POST", "/m/chat/default/stored1/send", {"text": "x", "attachments": [done["ref"]]})
        self.assertIn(status, (400, 404), body)  # a ref issued for bot-a is not accepted for another bot
        self.assertEqual(self.gw.submitted, [])

    def test_both_wire_paths_coexist(self):
        item = self.item("notes.txt", "text/plain", b"x")
        self.assertEqual(self.send([item])[0], 202)
        self.wait_idle()
        done = self.upload("notes.txt", b"y", "text/plain")
        self.assertEqual(self.req("POST", "/m/chat/bot-a/stored1/send", {"text": "z", "attachments": [done["ref"]]})[0], 202)
        self.wait_idle()
        self.assertEqual(len(self.gw.submitted), 2)

    def send_refs(self, *done):
        status, turn = self.req("POST", "/m/chat/bot-a/stored1/send", {"text": "see file", "attachments": [d["ref"] for d in done]})
        self.assertEqual(status, 202, turn)
        params = self.wait_submitted()
        self.wait_idle()
        return params

    def test_legacy_file_labelled_video_mp4_is_ordinary_file_context(self):
        done = self.upload("clip.mp4", b"just benign text, not a video\n", "video/mp4")
        self.assertEqual(done["kind"], "file")
        params = self.send_refs(done)
        self.assertNotIn("video_analyze", params["text"])
        self.assertNotIn("consented", params["text"])
        self.assertNotIn("attachments", params)
        self.assertIn("The user attached a file named", params["text"])
        self.assertIn("video/mp4", params["text"])

    def test_legacy_non_image_labelled_jpeg_is_never_a_native_attachment(self):
        done = self.upload("pic.jpg", b"plain text pretending to be a picture\n", "image/jpeg")
        self.assertEqual((done["kind"], done["mime"]), ("file", "image/jpeg"))
        params = self.send_refs(done)
        self.assertNotIn("attachments", params)
        self.assertIn("The user attached a file named", params["text"])
        self.assertIn("Local file path", params["text"])

    @unittest.skipIf(Image is None, "Pillow is required to make the PNG")
    def test_real_legacy_image_stays_native_next_to_a_mislabelled_file(self):
        png = io.BytesIO()
        Image.new("RGB", (16, 16), (1, 2, 3)).save(png, "PNG")
        image = self.upload("a.png", png.getvalue(), "application/octet-stream")  # label is irrelevant; bytes decide
        fake = self.upload("b.jpg", b"not an image\n", "image/jpeg")
        params = self.send_refs(image, fake)
        [native] = params["attachments"]
        self.assertEqual(native["mime"], "image/png")
        self.assertEqual(self.gw.contents[native["path"]], png.getvalue())
        self.assertEqual(params["text"].count("The user attached a file named"), 1)

    def test_legacy_true_file_uses_the_gateway_file_attach_ref(self):
        self.gw.ref_text = "@file:notes.txt"
        done = self.upload("notes.txt", b"hello\n", "text/plain")
        params = self.send_refs(done)
        [call] = self.gw.attached
        self.assertEqual((call["session_id"], call["name"]), ("stored1", "notes.txt"))
        self.assertIn("@file:notes.txt", params["text"])
        self.assertNotIn("Local file path", params["text"])
        self.gw.ref_text = None  # gateway without a ref: the bridge falls back to the path text
        before = len(self.gw.submitted)
        done = self.upload("more.txt", b"x\n", "text/plain")
        status, _ = self.req("POST", "/m/chat/bot-a/stored1/send", {"text": "again", "attachments": [done["ref"]]})
        self.assertEqual(status, 202)
        self.wait_submitted(before + 1)
        self.assertIn("Local file path", self.gw.submitted[-1]["text"])
        self.wait_idle()

    def test_new_protocol_validated_jpeg_and_files_unchanged(self):
        self.test_both_wire_paths_coexist()

    def test_timeline_helper_error_from_a_newer_hermes_falls_back_to_the_gateway(self):
        """Installed Hermes may drop SessionDB.resolve_resume_session_id; the proxy must then use the gateway."""
        from unittest.mock import patch

        class Request:
            headers = {"X-Hermes-Transcript": "timeline-v1"}

        with patch.object(base.bridge, "native_timeline_page", side_effect=AttributeError("resolve_resume_session_id")):
            self.assertIsNone(base.bridge.H._native_timeline(Request(), "bot-a", "/api/sessions/s1/messages", ""))


if __name__ == "__main__":
    unittest.main()
