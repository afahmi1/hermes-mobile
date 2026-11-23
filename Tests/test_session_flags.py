"""Batch archive/pin fanout keeps per-session outcomes and invalidates the inbox once."""
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class SessionFlagTests(unittest.TestCase):
    def test_partial_failure_is_reported_per_session(self):
        def fake_gw(method, pid, path, body=None, timeout=20):
            sid = path.rsplit("/", 1)[-1]
            if sid == "s1":
                return 200, {"ok": True}
            if sid == "s2":
                return 404, {"error": "gone"}
            raise OSError("gateway down")

        with patch.object(bridge, "profile_ids", return_value=["default", "bot"]), \
                patch.object(bridge, "key_for", return_value="key"), \
                patch.object(bridge, "gw", side_effect=fake_gw), \
                patch.object(bridge, "invalidate_pages") as invalidated:
            updated, errors = bridge.set_session_flags("bot", ["s1", "s2", "s3"], {"archived": True})
        self.assertEqual(updated, ["s1"])
        self.assertEqual(errors["s2"], "gone")
        self.assertEqual(errors["s3"], "OSError")
        invalidated.assert_called_once()

    def test_all_failures_do_not_invalidate_the_page_cache(self):
        with patch.object(bridge, "gw", return_value=(503, {"error": "busy"})), \
                patch.object(bridge, "invalidate_pages") as invalidated:
            updated, errors = bridge.set_session_flags("bot", ["s1"], {"pinned": True})
        self.assertEqual(updated, [])
        self.assertEqual(errors, {"s1": "busy"})
        invalidated.assert_not_called()

    def test_empty_selection_is_a_noop(self):
        with patch.object(bridge, "invalidate_pages") as invalidated:
            self.assertEqual(bridge.set_session_flags("bot", [], {"archived": True}), ([], {}))
        invalidated.assert_not_called()

    def call_route(self, body):
        handler = MagicMock()
        handler.command = "POST"
        handler.json_body.return_value = body
        with patch.object(bridge, "profile_ids", return_value=["default", "bot"]), \
                patch.object(bridge, "key_for", return_value="key"), \
                patch.object(bridge, "set_session_flags", return_value=(["s1"], {})), \
                patch.object(bridge, "invalidate_pages"):
            bridge.H.session_flags(handler)
        return handler.send.call_args

    def test_route_rejects_unknown_fields_and_bad_ids(self):
        self.assertEqual(self.call_route({"profile": "bot", "ids": ["s1"], "fields": {"title": "x"}}).args[0], 400)
        self.assertEqual(self.call_route({"profile": "bot", "ids": ["../s1"], "fields": {"archived": True}}).args[0], 400)
        self.assertEqual(self.call_route({"profile": "bot", "ids": [], "fields": {"archived": True}}).args[0], 400)
        self.assertEqual(self.call_route({"profile": "nope", "ids": ["s1"], "fields": {"archived": True}}).args[0], 404)

    def test_route_returns_per_session_outcomes(self):
        status, body = self.call_route({"profile": "bot", "ids": ["s1", "s1"], "fields": {"archived": True}}).args
        self.assertEqual(status, 200)
        self.assertEqual(body, {"updated": ["s1"], "errors": {}})


if __name__ == "__main__":
    unittest.main()
