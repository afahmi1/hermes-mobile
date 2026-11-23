import hashlib
import json
import sqlite3
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class TimelineTest(unittest.TestCase):
    def test_mobile_view_preserves_public_text_tools_and_offset(self):
        rows = [{"role": "user", "id": 1, "timestamp": 12, "content": [{"text": "hello"}, {"image": "opaque"}, {"text": "world"}]},
                {"role": "tool", "id": 2, "content": "a large private tool result"},
                {"role": "assistant", "id": 3, "content": "OK", "reasoning": "hidden", "tool_calls": [
                    {"function": {"name": "lookup", "arguments": "large arguments"}}]}]
        actual = json.loads(bridge.timeline_page(json.dumps({"data": rows})))["data"]
        self.assertEqual(actual, [{"role": "user", "id": 1, "timestamp": 12, "content": "hello\nworld"},
                                  {"role": "tool", "id": 2},
                                  {"role": "assistant", "id": 3, "content": "OK", "tool_calls": [{"function": {"name": "lookup"}}]}])

    def test_conditional_proxy_revalidates_even_if_number_of_rows_stays_constant(self):
        handler = MagicMock()
        handler.command = "GET"
        handler.headers = {"X-Hermes-Transcript": "timeline-v1"}
        with patch.object(bridge, "key_for", return_value="fixture"), patch.object(bridge.http.client, "HTTPConnection") as conn:
            upstream = conn.return_value.getresponse.return_value
            upstream.status = 200
            def read(text):
                upstream.read.return_value = json.dumps({"data": [{"role": "assistant", "content": text}]}).encode()
                bridge.H.proxy(handler, "/m/p/default/api/sessions/fixture/messages", "")
                return handler.send.call_args
            first = read("A")
            tag = first.kwargs["validator"]
            self.assertEqual(tag, '"' + hashlib.sha256(first.args[1]).hexdigest() + '"')
            handler.headers["If-None-Match"] = tag
            self.assertEqual(read("A").args, (304,))
            changed = read("B")
            self.assertEqual(changed.args[0], 200)
            self.assertNotEqual(changed.kwargs["validator"], tag)
            handler.headers.clear()
            raw = read("B")
            self.assertEqual(raw.args[1], upstream.read.return_value)

    def test_unknown_query_options_and_duplicate_order_use_gateway(self):
        handler = MagicMock()
        for query in ("order=latest&order=oldest", "after_id=1", "include_compacted=true"):
            with patch.object(bridge, "native_timeline_page") as native:
                self.assertIsNone(bridge.H._native_timeline(handler, "default", "/api/sessions/x/messages", query))
                native.assert_not_called()

    def test_compact_reader_returns_canonical_gateway_display(self):
        try:
            from hermes_state import SessionDB
            from gateway.platforms.api_server import APIServerAdapter
        except ImportError:
            self.skipTest("installed Hermes required")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            from contextlib import closing
            with closing(SessionDB(home / "state.db")) as db:
                db.create_session("chat", source="cli")
                db.append_message("chat", "user", "hello")
                db.append_message("chat", "assistant", "diagnostic text", display_kind="hidden",
                                  display_metadata={"notification_category": "diagnostic"})
                rows = db.get_messages("chat", include_ancestors=True, latest=True, limit=100)
                expected = bridge.timeline_bytes(APIServerAdapter._message_response(row) for row in rows)
                self.assertNotIn(b"diagnostic text", expected)
            with patch.object(bridge, "profile_home", return_value=home):
                self.assertEqual(bridge.native_timeline_page("default", "chat", 100, 0, True), expected)
                self.assertIsNone(bridge.native_timeline_page("default", "missing", 100, 0, True))


if __name__ == "__main__":
    unittest.main()
