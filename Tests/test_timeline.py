import hashlib
import json
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
