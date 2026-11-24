"""Chat attachments over the real bridge HTTP surface with a stub gateway.

Covers what the phone does: read media-capabilities, then POST send-once with the exact bodies the
app builds (a PNG is re-encoded to JPEG on the phone; text and PDF files keep their bytes). Asserts
the bridge accepts each upload and that the gateway's prompt.submit carries it (image path in
`attachments`, file path in the prompt text). Synthetic HERMES_HOME, token and gateway only.
"""
import asyncio
import base64
import contextlib
import http.client
import importlib
import io
import json
import os
import sys
import tempfile
import threading
import types
import unittest
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))

try:
    from PIL import Image
except ImportError:  # the bridge needs Pillow for image attachments
    Image = None

PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"


def setUpModule():
    global bridge, turns, HOME
    if "HOME" in globals():  # shared with the legacy-compat tests in the same process
        return
    HOME = Path(tempfile.mkdtemp(prefix="bridge-media-http-")).resolve()
    with patch.dict(os.environ, HERMES_HOME=str(HOME)):
        bridge = importlib.import_module("hermes_mobile_bridge")
    turns = bridge.turns
    (HOME / "profiles" / "bot-a").mkdir(parents=True)
    (HOME / "profiles" / "bot-a" / ".env").write_text("API_SERVER_KEY=k-bot-a\n")
    (HOME / ".env").write_text("API_SERVER_KEY=k-default\n")


class FakeClient:
    def __init__(self):
        self.events = asyncio.Queue()


class FakeGateway:
    def __init__(self):
        self.submitted = []
        self.contents = {}  # path -> bytes as the gateway saw them; the bridge deletes staged media after admission

    @contextlib.asynccontextmanager
    async def connect(self, home):
        yield FakeClient()

    async def rpc(self, c, method, **params):
        if method == "session.resume":
            sid = params["session_id"]
            return {"session_id": sid, "stored_session_id": sid, "revision": 1, "execution_generation": 1, "pending": []}
        if method == "file.attach":
            self.attached = getattr(self, "attached", []) + [dict(params)]
            ref = getattr(self, "ref_text", None)
            return {"ref_text": ref} if ref else {}
        if method == "prompt.submit":
            paths = [a["path"] for a in params.get("attachments", [])]
            if "Local file path: " in params["text"]:
                paths.append(json.loads(params["text"].rsplit("Local file path: ", 1)[1]))
            for path in paths:
                self.contents[path] = Path(path).read_bytes()
            self.submitted.append(dict(params))  # visible to the test only once contents are captured
            c.events.put_nowait({"method": "event", "params": {"type": "message.complete", "admission_id": "adm-1",
                                 "payload": {"admission_id": "adm-1", "status": "complete", "content": "ok"}}})
            return {"admission_id": "adm-1", "status": "started", "execution_generation": 1}
        return {}


class Harness(unittest.TestCase):
    """Real bridge handler over HTTP, stub gateway, private temp state."""

    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="media-http-"))).resolve()
        self.images = self.tmp / "images"
        self.images.mkdir()
        state = self.tmp / "mobile"
        state.mkdir(mode=0o700)
        self.enterContext(patch.object(bridge, "HERMES", HOME))
        self.enterContext(patch.object(bridge, "STATE_DIR", state))
        self.enterContext(patch.dict(os.environ, {"HERMES_MOBILE_ADMISSIONS_DIR": str(self.tmp / "adm")}))
        self.enterContext(patch.object(sys, "stderr", io.StringIO()))
        # Stand in for the installed Hermes image cache; the bridge stages JPEGs there.
        base = types.ModuleType("gateway.platforms.base")
        base.get_image_cache_dir = lambda: self.images
        self.enterContext(patch.dict(sys.modules, {"gateway": types.ModuleType("gateway"),
                                                  "gateway.platforms": types.ModuleType("gateway.platforms"),
                                                  "gateway.platforms.base": base}))
        self.enterContext(patch.object(turns.bridge_media, "supported", lambda: Image is not None))
        self.gw = FakeGateway()
        self.enterContext(patch.object(turns, "connect", self.gw.connect))
        self.enterContext(patch.object(turns, "_rpc", self.gw.rpc))
        turns.TURNS.clear()
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), bridge.H)
        self.srv.daemon_threads = True
        threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True).start()
        self.addCleanup(lambda: (self.srv.shutdown(), self.srv.server_close()))
        self.token = bridge.make_token("media-test")

    def req(self, method, path, body=None, token=True):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        headers = {"Authorization": "Bearer " + self.token} if token else {}
        c.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=headers)
        r = c.getresponse()
        raw = r.read()
        c.close()
        try:
            return r.status, json.loads(raw) if raw else None
        except ValueError:  # a binary body, such as an image
            return r.status, raw

    def send(self, attachments, text="look", action="send-once"):
        body = {"text": text, "submission_id": str(uuid.uuid4()), "attachments": attachments}
        return self.req("POST", "/m/chat/bot-a/stored1/" + action, body)

    @staticmethod
    def item(name, mime, raw):
        return {"filename": name, "mime": mime, "base64": base64.b64encode(raw).decode()}

    def wait_submitted(self, count=1):
        for _ in range(200):
            if len(self.gw.submitted) >= count:
                return self.gw.submitted[-1]
            threading.Event().wait(0.02)
        self.fail("the gateway never received prompt.submit")


class ChatMediaHTTP(Harness):
    def test_capabilities_require_a_token_and_advertise_files(self):
        self.assertEqual(self.req("GET", "/m/chat/bot-a/media-capabilities", token=False)[0], 401)
        status, caps = self.req("GET", "/m/chat/bot-a/media-capabilities")
        self.assertEqual(status, 200)
        self.assertTrue(caps["files"])
        self.assertEqual(caps["images"], Image is not None)
        self.assertGreaterEqual(caps["max_file_bytes"], 256 * 1024)
        self.assertEqual(self.req("GET", "/m/chat/nope/media-capabilities")[0], 404)

    @unittest.skipIf(Image is None, "Pillow is required for image attachments")
    def test_png_reencoded_as_jpeg_is_accepted_and_reaches_the_gateway(self):
        png = io.BytesIO()
        Image.new("RGB", (48, 48), (20, 120, 220)).save(png, "PNG")
        jpeg = io.BytesIO()
        Image.open(io.BytesIO(png.getvalue())).convert("RGB").save(jpeg, "JPEG")  # what ChatMedia.image does
        status, turn = self.send([self.item("Photo-abc123.png", "image/jpeg", jpeg.getvalue())])
        self.assertEqual(status, 202, turn)
        params = self.wait_submitted()
        [attachment] = params["attachments"]
        self.assertEqual(attachment["mime"], "image/jpeg")
        path = Path(attachment["path"])
        self.assertEqual(path.resolve().parent, self.images.resolve())
        self.assertEqual(self.gw.contents[str(path)], jpeg.getvalue())

    @unittest.skipIf(Image is None, "Pillow is required for image attachments")
    def test_a_raw_png_is_refused_with_a_clear_error(self):
        png = io.BytesIO()
        Image.new("RGB", (8, 8)).save(png, "PNG")
        status, body = self.send([self.item("shot.png", "image/png", png.getvalue())])
        self.assertEqual(status, 400)
        self.assertIn("JPEG", body["error"])
        self.assertEqual(self.gw.submitted, [])

    def test_text_and_pdf_files_are_staged_privately_and_named_in_the_prompt(self):
        for name, mime, raw in (("notes.txt", "text/plain", b"hello synthetic notes\n"), ("brief.pdf", "application/pdf", PDF)):
            before = len(self.gw.submitted)
            status, turn = self.send([self.item(name, mime, raw)])
            self.assertEqual(status, 202, turn)
            params = self.wait_submitted(before + 1)
            self.assertNotIn("attachments", params)
            self.assertIn(json.dumps(name), params["text"])
            self.assertIn(mime, params["text"])
            staged = Path(json.loads(params["text"].rsplit("Local file path: ", 1)[1]))
            self.assertEqual(staged.parent.name, "mobile-file-inputs")
            self.assertEqual(staged.suffix, Path(name).suffix)
            self.assertEqual(self.gw.contents[str(staged)], raw)
            for _ in range(100):  # the turn must finish before the next send starts
                if not any(not t.done for t in turns.TURNS.values()):
                    break
                threading.Event().wait(0.02)

    def test_media_needs_a_durable_send_and_a_token(self):
        item = self.item("notes.txt", "text/plain", b"x")
        self.assertEqual(self.send([item], action="send")[0], 400)
        self.assertEqual(self.req("POST", "/m/chat/bot-a/stored1/send-once", {"text": "x", "attachments": [item]}, token=False)[0], 401)
        self.assertEqual(self.gw.submitted, [])


if __name__ == "__main__":
    unittest.main()
