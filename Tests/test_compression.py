"""Large JSON replies are gzipped for clients that ask; small, binary and 304 replies are not."""
import gzip
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class Reply(bridge.H):
    """A handler with no socket: `send` writes the response into a buffer."""

    def __init__(self, accept, command="GET", path="/m/sessions"):
        self.command, self.path, self.request_version = command, path, "HTTP/1.1"
        self.requestline, self.client_address = "%s %s HTTP/1.1" % (command, path), ("127.0.0.1", 0)
        self.headers = {"Accept-Encoding": accept} if accept is not None else {}
        self.wfile = io.BytesIO()
        self._headers_buffer = []
        self.close_connection = False

    def log_message(self, *args):
        pass

    def parts(self):
        head, _, body = self.wfile.getvalue().partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")[1:]
        return {k.lower(): v for k, v in (line.split(": ", 1) for line in lines)}, body


BIG = {"data": [{"id": "session-%d" % i, "title": "Demo chat %d" % i, "profile": "default"} for i in range(200)]}


class CompressionTests(unittest.TestCase):
    def send(self, accept, code=200, body=BIG, **kw):
        reply = Reply(accept)
        with patch.object(bridge, "invalidate_pages"):
            reply.send(code, body, **kw)
        return reply.parts()

    def test_large_json_round_trips_and_is_smaller(self):
        headers, body = self.send("gzip, deflate, br")
        plain = json.dumps(BIG).encode()
        self.assertEqual(headers["content-encoding"], "gzip")
        self.assertEqual(int(headers["content-length"]), len(body))
        self.assertLess(len(body), len(plain) // 3)
        self.assertEqual(gzip.decompress(body), plain)
        self.assertIn("Accept-Encoding", headers["vary"])

    def test_identical_bodies_compress_to_identical_bytes(self):
        self.assertEqual(self.send("gzip")[1], self.send("gzip")[1])

    def test_client_without_gzip_gets_plain_bytes(self):
        for accept in (None, "", "identity", "br", "gzip;q=0", "gzip; q=0.0"):
            headers, body = self.send(accept)
            self.assertNotIn("content-encoding", headers, accept)
            self.assertEqual(body, json.dumps(BIG).encode(), accept)
            # A cache between the phone and the bridge must still key on the request header.
            self.assertIn("Accept-Encoding", headers["vary"], accept)

    def test_specific_encoding_wins_over_a_wildcard_in_either_order(self):
        for header in ("*;q=1, gzip;q=0", "gzip;q=0, *;q=1", "gzip;q=garbage"):
            self.assertNotIn("content-encoding", self.send(header)[0])
        for header in ("*;q=0, gzip;q=0.25", "gzip;q=1, *;q=0", "*;q=0.001"):
            self.assertEqual(self.send(header)[0]["content-encoding"], "gzip")

    def test_small_reply_is_left_alone(self):
        headers, body = self.send("gzip", body={"ok": True})
        self.assertNotIn("content-encoding", headers)
        self.assertEqual(body, b'{"ok": true}')

    def test_binary_media_is_not_recompressed(self):
        jpeg = bytes(range(256)) * 64
        headers, body = self.send("gzip", body=jpeg, ctype="image/jpeg")
        self.assertNotIn("content-encoding", headers)
        self.assertNotIn("vary", headers)
        self.assertEqual(body, jpeg)

    def test_not_modified_carries_the_validator_and_no_body(self):
        headers, body = self.send("gzip", code=304, body=b"", validator='"abc"')
        self.assertEqual(headers["etag"], '"abc"')
        self.assertNotIn("content-encoding", headers)
        self.assertNotIn("content-length", headers)
        self.assertEqual(body, b"")

    def test_validated_reply_varies_on_every_input(self):
        headers, body = self.send("gzip", validator='"abc"')
        self.assertEqual(headers["vary"], "X-Hermes-Transcript, Authorization, Accept-Encoding")
        self.assertEqual(headers["etag"], '"abc"')
        self.assertEqual(gzip.decompress(body), json.dumps(BIG).encode())


if __name__ == "__main__":
    unittest.main()
