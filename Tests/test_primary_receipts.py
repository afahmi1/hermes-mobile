import asyncio
import threading
import hashlib
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch
import uuid
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as engine


class PrimaryReceipts(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(TemporaryDirectory()))
        self.enterContext(patch.dict(engine.TURNS, clear=True))
        self.schedule = self.enterContext(patch.object(engine.asyncio, "run_coroutine_threadsafe",
                                                      side_effect=lambda coro, loop: coro.close()))
        self.native = {}
        self.attempts = []
        self.store = Mock()
        self.journal = engine.primary_journal(self.directory)
        self.submission = uuid.uuid4().hex
        self.prepare = Mock(return_value={"store": self.store, "project": "alpha", "suffix": "original context",
                                         "output_dir": self.directory / "one", "summary": {"project": "alpha"}})
        self.fail_ack = True

    def start(self, text="hello", project="alpha", attachments=None, video_consent=False):
        return engine.start_primary("default", self.directory, "sid", text, {}, self.submission, project,
                                    self.directory, self.prepare, lambda ws, p, s: dict(ws, store=self.store), attachments, video_consent)

    @asynccontextmanager
    async def connect(self, _home):
        yield object()

    async def rpc(self, client, method, **p):
        if method == "session.resume":
            return {"session_id": "sid", "stored_session_id": "sid", "pending": []}
        if method == "prompt.submit":
            self.attempts.append(dict(p))
            prior = self.native.setdefault(p["submission_id"], p["text"])
            self.assertEqual(prior, p["text"])
            if self.fail_ack:
                self.fail_ack = False
                raise ConnectionError("socket lost after admission")
            return {"admission_id": "admission", "status": "terminal", "execution_generation": 2}
        self.assertEqual(method, "prompt.receipt")
        return {"admission_id": "admission", "status": "terminal", "outcome": "completed",
                "result": {"final_response": "done"}}

    def test_concurrent_requests_and_conflicting_intents(self):
        with ThreadPoolExecutor(max_workers=8) as workers:
            turns = list(workers.map(lambda _: self.start(), range(20)))
        self.assertTrue(all(t is turns[0] for t in turns))
        self.assertEqual(self.prepare.call_count, 1)
        self.assertEqual(self.schedule.call_count, 1)
        for params in [{"text": "other"}, {"project": "other"}]:
            with self.assertRaises(engine.TurnError) as error:
                self.start(**params)
            self.assertEqual(error.exception.code, 409)

    def test_slow_stage_keeps_other_chat_and_control_available(self):
        waiting, release = threading.Event(), threading.Event()
        def hold(frames, home):
            waiting.set()
            if not release.wait(4):
                raise AssertionError("unrelated chat was blocked by staging")
            return []
        with ThreadPoolExecutor(max_workers=4) as pool, patch.object(engine.bridge_media, "stage", side_effect=hold):
            first = pool.submit(self.start)
            try:
                self.assertTrue(waiting.wait(1))
                other = pool.submit(engine.start_turn, "default", self.directory, "other", "hi", {})
                live = other.result(timeout=2)
                self.assertIs(pool.submit(engine.get_turn, live.id).result(timeout=1), live)
                duplicate = pool.submit(self.start)
                legacy = pool.submit(engine.start_turn, "default", self.directory, "sid", "hi", {})
            finally:
                release.set()
            self.assertIs(first.result(), duplicate.result())
            with self.assertRaises(engine.TurnError):
                legacy.result()

    def test_receipt_proves_exact_send_without_restaging(self):
        data = b"private bytes"
        attachment = dict(filename="a.mp3", mime="audio/mpeg", base64=base64.b64encode(data).decode())
        request = dict(submission_id=self.submission, project_context="alpha", manifest=[
            dict(filename="a.mp3", mime="audio/mpeg", sha256=hashlib.sha256(data).hexdigest())])
        def lookup(sid="sid", text="hello"):
            return engine.match_receipt("default", sid, text, request, self.directory)
        with self.assertRaises(engine.TurnError) as missing:
            lookup()
        self.assertEqual(missing.exception.code, 404)
        accepted = self.start(attachments=[attachment])
        with patch.object(engine.bridge_media, "stage", side_effect=AssertionError):
            self.assertEqual(lookup(), {"turn_id": accepted.id})
            for args in [("other", "hello"), ("sid", "different")]:
                with self.assertRaises(engine.TurnError) as mismatch:
                    lookup(*args)
                self.assertEqual(mismatch.exception.code, 409)
            request["manifest"][0]["mime"] = "application/pdf"
            with self.assertRaises(engine.TurnError) as changed:
                lookup()
            self.assertEqual(changed.exception.code, 409)

    def test_older_media_journal_migrates_and_reuses_original_upload(self):
        from contextlib import closing
        data = b"old send"
        attachment = dict(filename="test.txt", mime="text/plain", base64=base64.b64encode(data).decode())
        turn = self.start(attachments=[attachment])
        with closing(self.journal.open()) as db, db:
            db.execute("ALTER TABLE receipts DROP COLUMN media_types")
        engine.primary_journal.cache_clear()
        request = dict(submission_id=self.submission, project_context="alpha", manifest=[
            dict(filename="test.txt", mime="text/plain", sha256=hashlib.sha256(data).hexdigest())])
        with self.assertRaises(engine.TurnError) as legacy:
            engine.match_receipt("default", "sid", "hello", request, self.directory)
        self.assertEqual(legacy.exception.code, 404)
        with patch.object(engine.bridge_media, "stage", side_effect=AssertionError):
            self.assertIs(turn, self.start(attachments=[attachment]))
        self.assertEqual(self.schedule.call_count, 1)

    def test_lost_ack_restart_reuses_native_admission_and_workspace(self):
        first = self.start()
        with patch.object(engine, "connect", self.connect), patch.object(engine, "_rpc", self.rpc):
            with self.assertRaises(ConnectionError):
                asyncio.run(engine._drive_connection(first))
            engine.TURNS.clear()  # process restart before recording upstream's admission
            self.prepare.side_effect = AssertionError("project context was regenerated")
            recovered = self.start()
            self.assertEqual(first.id, recovered.id)
            asyncio.run(engine._drive(recovered))
            self.assertTrue(recovered.done)
            self.assertEqual(recovered._terminal["event"], "run.completed")
            self.assertEqual(self.attempts[0], self.attempts[1])
            self.assertEqual(len(self.native), 1)
            self.assertIn("original context", self.attempts[0]["text"])
            self.store.capture.assert_called_once()
            self.store.discard_output.assert_called_once()
            self.assertIsNone(self.journal.get(first.id)["prompt"])
            engine.TURNS.clear()
            restored = engine.completed_primary(first.id, self.directory, lambda _: self.directory)
            self.assertTrue(restored.done)
            self.assertEqual(restored._terminal["event"], "run.completed")
            self.assertTrue(self.start().done)
            self.assertEqual(len(self.attempts), 2)

    def test_confirmed_admission_recovery_only_queries_receipt(self):
        turn = self.start()
        turn.admission, turn.generation = "admission", 2
        self.journal.prepared(turn)
        self.journal.admitted(turn)
        self.journal.suppress_capture(turn)
        engine.TURNS.clear()
        with patch.object(engine, "connect", self.connect), patch.object(engine, "_rpc", self.rpc):
            recovered = self.start()
            asyncio.run(engine._drive(recovered))
        self.assertFalse(self.attempts)
        self.store.capture.assert_not_called()
        self.assertEqual(recovered._terminal["event"], "run.completed")

    def test_native_media_staging_survives_lost_ack_and_is_purged(self):
        import base64
        import io
        from types import ModuleType
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Optional image support requires Pillow")
        import bridge_media

        def attachment(color):
            image = io.BytesIO()
            Image.new("RGB", (12, 12), color).save(image, "JPEG")
            return dict(filename="frame-1.jpg", mime="image/jpeg", base64=base64.b64encode(image.getvalue()).decode())

        row = attachment("red")
        platform = ModuleType("gateway.platforms.base")
        platform.get_image_cache_dir = lambda: self.directory
        with patch.dict(sys.modules, {"gateway.platforms.base": platform}), patch.object(bridge_media, "supported", return_value=True):
            t = self.start(attachments=[row])
            path = Path(t.media[0]["path"])
            self.assertEqual(path.parent, self.directory.resolve())
            self.assertNotEqual(path.name, row["filename"])
            with self.assertRaises(engine.TurnError):
                self.start(attachments=[attachment("blue")])
            with patch.object(engine, "connect", self.connect), patch.object(engine, "_rpc", self.rpc):
                with self.assertRaises(ConnectionError):
                    asyncio.run(engine._drive_connection(t))
                self.assertTrue(path.is_file())
                engine.TURNS.clear()
                restored = self.start(attachments=[row])
                asyncio.run(engine._drive(restored))
                self.assertEqual(self.attempts[0]["attachments"], self.attempts[1]["attachments"])
                self.assertFalse(path.exists())
                self.assertEqual(len(self.native), 1)
            for bad in [dict(row, filename="../unsafe.jpg"), dict(row, mime="video/mp4"),
                        dict(row, base64="AAAA"), dict(row, base64="A" * 5592412),
                        dict(row, path="/tmp/a")]:
                with self.assertRaises(bridge_media.MediaError):
                    bridge_media.decode([bad])
            with self.assertRaises(bridge_media.MediaError):
                bridge_media.decode([row] * 5)
        with patch.object(bridge_media, "supported", return_value=False), self.assertRaises(bridge_media.MediaError):
            bridge_media.decode([row])

    def test_file_retry_recovers_original_bytes_and_one_admission(self):
        import base64
        raw = b"ID3" + bytes(range(127))
        attachment = {"filename": "sample.mp3", "mime": "audio/mpeg",
                      "base64": base64.b64encode(raw).decode()}
        first = self.start(attachments=[attachment])
        path = Path(first.media[0]["path"])
        with patch.object(engine, "connect", self.connect), patch.object(engine, "_rpc", self.rpc):
            with self.assertRaises(ConnectionError):
                asyncio.run(engine._drive_connection(first))
            with self.assertRaises(engine.TurnError):
                self.start(attachments=[dict(attachment, mime="application/octet-stream")])
            engine.TURNS.clear()
            restored = self.start(attachments=[attachment])
            self.assertEqual(Path(restored.media[0]["path"]).read_bytes(), raw)
            asyncio.run(engine._drive(restored))
            self.assertEqual(self.attempts[0], self.attempts[1])
            self.assertEqual(len(self.native), 1)
            self.assertFalse(path.exists())
            self.assertEqual(restored._terminal["event"], "run.completed")

    def test_video_consent_capability_private_file_and_recovery(self):
        import base64
        import json
        import os
        import bridge_media

        def box(name, payload):
            return (8 + len(payload)).to_bytes(4, "big") + name + payload

        def clip(track=b"vide", ref=b"\0\0\0\1"):
            dref = box(b"dref", b"\0" * 7 + b"\1" + box(b"url ", ref))
            mdia = box(b"hdlr", b"\0" * 8 + track + b"\0" * 12) + box(b"minf", box(b"dinf", dref))
            return (box(b"ftyp", b"isom\0\0\0\1mp42") + box(b"moov", box(b"trak", box(b"mdia", mdia)))
                    + box(b"mdat", b"synthetic sample"))

        def item(raw):
            return {"filename": "my original filename.mp4", "mime": "video/mp4", "base64": base64.b64encode(raw).decode()}
        attachment = item(clip())
        for wrong in [item(clip(track=b"soun")), item(clip(ref=b"\0\0\0\0https://invalid")), item(clip()[:-2])]:
            with self.assertRaises(bridge_media.MediaError):
                bridge_media.decode([wrong])
        with self.assertRaises(bridge_media.MediaError):
            bridge_media.decode([attachment, attachment])
        with self.assertRaises(engine.TurnError):
            self.start(attachments=[attachment])
        with patch.object(bridge_media, "video_supported", return_value=False), self.assertRaises(engine.TurnError):
            self.start(attachments=[attachment], video_consent=True)
        with patch.object(bridge_media, "video_supported", return_value=True):
            first = self.start(attachments=[attachment], video_consent=True)
        path = Path(first.media[0]["path"])
        self.assertEqual(path.read_bytes(), clip())
        self.assertNotIn(attachment["filename"], str(path))
        self.assertEqual(path.parent, self.directory.resolve() / "mobile-video-inputs")
        if os.name != "nt":
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(str(path), json.dumps(first.summary()))
        self.assertEqual(first.summary()["attachments"][0]["status"], "staged")
        with patch.object(engine, "connect", self.connect), patch.object(engine, "_rpc", self.rpc):
            with self.assertRaises(ConnectionError):
                asyncio.run(engine._drive_connection(first))
            self.assertTrue(path.is_file())
            engine.TURNS.clear()
            with patch.object(bridge_media, "video_supported", return_value=False):
                recovered = self.start(attachments=[attachment], video_consent=True)
            asyncio.run(engine._drive(recovered))
        self.assertEqual(self.attempts[0], self.attempts[1])
        self.assertNotIn("attachments", self.attempts[0])
        self.assertIn("video_analyze", self.attempts[0]["text"])
        self.assertIn(json.dumps(str(path)), self.attempts[0]["text"])
        self.assertIsNone(self.journal.get(first.id)["media"])
        self.assertFalse(path.exists())
