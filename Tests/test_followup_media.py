import asyncio
"""Follow-ups (Send next / Guide this reply) can carry the files staged in the composer."""
import base64
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_media
import bridge_turns as engine


def _jpeg(shade=0):
    from io import BytesIO
    from PIL import Image
    out = BytesIO()
    Image.new("RGB", (4, 4), (shade, shade, shade)).save(out, "JPEG")
    return out.getvalue()


def item(name, mime, raw=None):
    if raw is None:
        raw = _jpeg() if mime == "image/jpeg" else b"data"
    elif mime == "image/jpeg":
        raw = _jpeg(len(raw) * 40 % 255)
    return {"filename": name, "mime": mime, "base64": base64.b64encode(raw).decode()}


def fake_stage(frames, home):
    return [{"path": "/tmp/hm_send_%d_%s" % (i, name), "mime": mime, "name": name, "size": len(raw)}
            for i, (name, _, raw, mime) in enumerate(frames)]


class FollowUpMediaTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.stage = patch.object(bridge_media, "stage", side_effect=fake_stage)
        self.discard = patch.object(bridge_media, "discard")
        self.supported = patch.object(bridge_media, "supported", return_value=True)
        self.supported.start()
        self.stage.start()
        self.discarded = self.discard.start()

    def tearDown(self):
        self.stage.stop()
        self.discard.stop()
        self.supported.stop()

    def turn(self):
        turn = engine.Turn("default", Path("."), "chat", "first", {})
        turn.client, turn.generation = object(), 4
        return turn

    async def test_queue_sends_images_natively_and_files_by_path(self):
        turn = self.turn()
        frames = engine._follow_up_frames([item("photo.jpg", "image/jpeg"), item("notes.pdf", "application/pdf")])
        request = uuid4().hex
        with patch.dict(engine.TURNS, {turn.id: turn}, clear=True), patch.object(engine, "_drive", AsyncMock()), \
                patch.object(engine, "_rpc", AsyncMock(return_value={"status": "queued", "admission_id": "a1"})) as rpc:
            receipt = await engine._follow_up(turn, "queue", "look at these", request, {}, frames)
            kwargs = rpc.await_args.kwargs
            self.assertEqual(kwargs["attachments"], [{"path": "/tmp/hm_send_0_photo.jpg", "mime": "image/jpeg"}])
            self.assertTrue(kwargs["text"].startswith("look at these"))
            self.assertIn("notes.pdf", kwargs["text"])
            self.assertNotIn("photo.jpg", kwargs["text"])
            queued = engine.TURNS[receipt["turn_id"]]
            self.assertEqual([m["mime"] for m in queued.media], ["image/jpeg", "application/pdf"])
            # Images are copied by the gateway at admission, like a first send; the PDF stays for the agent.
            self.discarded.assert_called_once_with([queued.media[0]])
            # An exact retry returns the same receipt; the same id with different files is refused.
            self.assertEqual(await engine._follow_up(turn, "queue", "look at these", request, {}, frames), receipt)
            other = engine._follow_up_frames([item("other.jpg", "image/jpeg", b"x")])
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "queue", "look at these", request, {}, other)
            self.assertEqual(rpc.await_count, 1)

    async def test_a_cancelled_admission_under_the_same_id_is_not_success(self):
        # Hermes hands back the earlier, cancelled admission for a reused submission id: nothing is queued now.
        turn = self.turn()
        with patch.dict(engine.TURNS, {turn.id: turn}, clear=True), patch.object(engine, "_drive", AsyncMock()), \
                patch.object(engine, "_rpc", AsyncMock(return_value={"status": "terminal", "outcome": "cancelled",
                                                                     "admission_id": "a9"})):
            with self.assertRaises(engine.TurnError) as e:
                await engine._follow_up(turn, "queue", "again", uuid4().hex, {}, [])
        self.assertEqual(e.exception.code, 409)
        self.assertIn("submission_reused", str(e.exception))
        # A transferred (steered) or completed admission is a real delivery and still answers as queued.
        for outcome in ("completed", "steered"):
            with patch.dict(engine.TURNS, {turn.id: turn}, clear=True), patch.object(engine, "_drive", AsyncMock()), \
                    patch.object(engine, "_rpc", AsyncMock(return_value={"status": "terminal", "outcome": outcome,
                                                                         "admission_id": "b" + outcome})):
                self.assertEqual((await engine._follow_up(turn, "queue", "ok", uuid4().hex, {}, []))["status"], "queued")

    async def test_a_finished_follower_does_not_answer_a_retry_itself(self):
        turn = self.turn()
        request = uuid4().hex
        old = engine.Turn("default", Path("."), "chat", "again", {})
        old.submission, old.admission, old.done = request, "dead", True
        with patch.dict(engine.TURNS, {turn.id: turn, old.id: old}, clear=True), \
                patch.object(engine, "_drive", AsyncMock()), \
                patch.object(engine, "_rpc", AsyncMock(return_value={"status": "terminal", "outcome": "cancelled",
                                                                     "admission_id": "dead"})) as rpc:
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "queue", "again", request, {}, [])
        self.assertEqual(rpc.await_count, 1, "Hermes's ledger was asked instead of the bridge's memory")

    async def test_a_reconnecting_turn_is_not_called_finished(self):
        # While the bridge reconnects to the gateway the turn is alive: 503 (retry), never 409 (ended).
        turn = self.turn()
        turn.client = None
        with self.assertRaises(engine.TurnError) as e:
            await engine._follow_up(turn, "steer", "turn left", uuid4().hex, None, [])
        self.assertEqual(e.exception.code, 503)
        turn.done = True
        with self.assertRaises(engine.TurnError) as e:
            await engine._follow_up(turn, "steer", "turn left", uuid4().hex, None, [])
        self.assertEqual(e.exception.code, 409)

    async def test_a_failed_guide_can_be_retried_under_the_same_id(self):
        turn = self.turn()
        steer = uuid4().hex
        with patch.object(engine, "_rpc", AsyncMock(side_effect=[engine.TurnError("gateway hiccup", 502),
                                                                  {"status": "queued"}])) as rpc:
            with self.assertRaises(engine.TurnError):
                await engine._follow_up(turn, "steer", "turn left", steer, None, [])
            await asyncio.sleep(0)
            result = await engine._follow_up(turn, "steer", "turn left", steer, None, [])
        self.assertEqual(result["status"], "steer_accepted")
        self.assertEqual(rpc.await_count, 2)

    async def test_attachment_only_queue_needs_no_text(self):
        turn = self.turn()
        with patch.dict(engine.TURNS, {turn.id: turn}, clear=True), patch.object(engine, "_drive", AsyncMock()), \
                patch.object(engine, "_rpc", AsyncMock(return_value={"status": "queued", "admission_id": "a2"})), \
                patch.object(engine, "run", side_effect=lambda coro: coro):
            coro = engine.follow_up(turn, "queue", "  ", uuid4().hex, {}, [item("a.jpg", "image/jpeg")])
            self.assertEqual((await coro)["status"], "queued")
        with self.assertRaises(engine.TurnError):
            engine.follow_up(turn, "queue", "  ", uuid4().hex, {}, [])

    async def test_steer_hands_every_file_over_by_path(self):
        turn = self.turn()
        frames = engine._follow_up_frames([item("shot.jpg", "image/jpeg"), item("log.txt", "text/plain")])
        with patch.object(engine, "_rpc", AsyncMock(return_value={"status": "queued"})) as rpc:
            result = await engine._follow_up(turn, "steer", "use this", uuid4().hex, None, frames)
        self.assertEqual(result["attachments"], 2)
        text = rpc.await_args.kwargs["text"]
        self.assertIn("vision_analyze", text)
        self.assertIn("/tmp/hm_send_0_shot.jpg", text)
        self.assertIn("log.txt", text)
        self.assertNotIn("attachments", rpc.await_args.kwargs)
        self.discarded.assert_not_called()

    async def test_declined_steer_discards_its_files(self):
        turn = self.turn()
        frames = engine._follow_up_frames([item("shot.jpg", "image/jpeg")])
        with patch.object(engine, "_rpc", AsyncMock(return_value={"status": "rejected"})), \
                self.assertRaises(engine.TurnError):
            await engine._follow_up(turn, "steer", "use this", None, None, frames)
        self.discarded.assert_called_once()

    def test_clips_must_be_a_new_message(self):
        with self.assertRaises(engine.TurnError):
            engine._follow_up_frames([item("clip.mp4", "video/mp4")])


if __name__ == "__main__":
    unittest.main()


class FramesDigestTests(unittest.TestCase):
    """A follow-up's attachment key must work for uploaded files, whose frames hold a path instead of bytes."""

    def test_uploaded_frame_holding_a_path_gets_a_key(self):
        import hashlib
        raw = b"uploaded file body"
        digest = hashlib.sha256(raw).hexdigest()
        uploaded = [("clip.txt", digest, Path("/tmp/hm-upload-does-not-matter"), "text/plain")]
        inline = [("clip.txt", digest, raw, "text/plain")]
        key = engine._frames_digest(uploaded)
        self.assertEqual(len(key), 64)
        # Same file, delivered inline or uploaded ahead: same key, so a retry of either is recognized.
        self.assertEqual(key, engine._frames_digest(inline))

    def test_key_is_unchanged_for_inline_frames(self):
        import hashlib
        frames = bridge_media.decode([item("a.txt", "text/plain", b"one"), item("b.txt", "text/plain", b"two")])
        legacy = hashlib.sha256(b"".join(hashlib.sha256(raw).digest() + mime.encode()
                                         for _, _, raw, mime in frames)).hexdigest()
        self.assertEqual(engine._frames_digest(frames), legacy)
        self.assertEqual(engine._frames_digest([]), "")
