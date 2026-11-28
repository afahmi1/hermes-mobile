"""Gateway refusals reach the phone as sentences, not bare codes, and keep the code for logs and callers."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_turns as t


class RefusalTextTest(unittest.TestCase):
    def test_photo_submit_refusal_names_the_photos(self):
        text = t.refusal_text("prompt.submit", "invalid_params", {"attachments": [{"path": "/x.jpg", "mime": "image/jpeg"}]})
        self.assertIn("refused the attached photos", text)
        self.assertTrue(text.endswith("(prompt.submit: invalid_params)"))

    def test_plain_invalid_params_is_a_sentence_with_the_code(self):
        text = t.refusal_text("prompt.submit", "invalid_params", {"text": "hi"})
        self.assertTrue(text.startswith("Hermes rejected this request as malformed."))
        self.assertIn("invalid_params", text)

    def test_gateway_detail_is_kept(self):
        text = t.refusal_text("session.config", "invalid_params", {}, {"field": "all", "detail": "must be a boolean"})
        self.assertIn("field: all", text)
        self.assertIn("detail: must be a boolean", text)

    def test_unknown_code_still_says_which_action(self):
        text = t.refusal_text("prompt.steer", "brand_new_reason")
        self.assertIn("Hermes refused this request.", text)
        self.assertIn("prompt.steer: brand_new_reason", text)

    def test_codes_callers_match_on_survive(self):
        # _queue_error and the revision_conflict retry match the reason inside the message text.
        for reason in ("revision_conflict", "unsupported_control", "admission_started", "session_busy"):
            self.assertIn(reason, t.refusal_text("prompt.queue.edit", reason))


if __name__ == "__main__":
    unittest.main()
