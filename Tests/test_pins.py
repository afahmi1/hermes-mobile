"""Pinned messages: the store, the state.db snapshot, the HTTP routes and the archive guard."""
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_pins
import hermes_mobile_bridge as bridge


def make_state_db(path):
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE sessions(id TEXT PRIMARY KEY, parent_session_id TEXT);
        CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
        INSERT INTO sessions VALUES ('root', NULL), ('child', 'root'), ('other', NULL);
        INSERT INTO messages VALUES (1, 'root', 'user', 'remember the SF lease deadline', 100.0);
        INSERT INTO messages VALUES (2, 'child', 'assistant', '[{"type":"text","text":"Lease due Dec 1"}]', 200.0);
        INSERT INTO messages VALUES (3, 'child', 'tool', 'tool output', 210.0);
        INSERT INTO messages VALUES (4, 'other', 'user', 'unrelated chat', 300.0);
        INSERT INTO messages VALUES (5, 'child', 'assistant', '   ', 220.0);
    """)
    con.commit()
    return con


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = bridge_pins.Pins(self.tmp.name)
        self.con = make_state_db(Path(self.tmp.name) / "state.db")

    def tearDown(self):
        self.con.close()
        self.tmp.cleanup()

    def test_snapshot_comes_from_state_db_including_ancestor_sessions(self):
        role, text, ts = bridge_pins.read_message(self.con, "child", 1)
        self.assertEqual((role, text, ts), ("user", "remember the SF lease deadline", 100.0))
        role, text, _ = bridge_pins.read_message(self.con, "child", 2)
        self.assertEqual((role, text), ("assistant", "Lease due Dec 1"))

    def test_foreign_tool_and_empty_messages_are_refused(self):
        for mid, code in ((4, "not_found"), (999, "not_found"), (3, "not_pinnable"), (5, "empty")):
            with self.assertRaises(bridge_pins.PinError) as caught:
                bridge_pins.read_message(self.con, "child", mid)
            self.assertEqual(caught.exception.code, code, mid)

    def test_add_is_idempotent_and_lists_newest_first(self):
        first, created = self.store.add("default", "child", 1, "user", "a", 100.0)
        self.assertTrue(created)
        again, created = self.store.add("default", "child", 1, "user", "a", 100.0)
        self.assertFalse(created)
        self.assertEqual(again["pinned_at"], first["pinned_at"])
        self.store.add("default", "child", 2, "assistant", "b", 200.0)
        self.assertEqual([p["message_id"] for p in self.store.list("default", "child")], [2, 1])

    def test_pins_are_scoped_per_bot_and_chat(self):
        self.store.add("default", "child", 1, "user", "a", 1.0)
        self.store.add("hooke", "child", 1, "user", "a", 1.0)
        self.assertEqual(self.store.counts("default", ["child", "other"]), {"child": 1})
        self.assertEqual(self.store.list("default", "other"), [])
        self.assertTrue(self.store.remove("default", "child", 1))
        self.assertFalse(self.store.remove("default", "child", 1))
        self.assertEqual(self.store.counts("hooke", ["child"]), {"child": 1})

    def test_limit_and_clear(self):
        with patch.object(bridge_pins, "MAX_PINS_PER_CHAT", 2):
            self.store.add("default", "c", 1, "user", "a", 1.0)
            self.store.add("default", "c", 2, "user", "b", 2.0)
            with self.assertRaises(bridge_pins.PinError) as caught:
                self.store.add("default", "c", 3, "user", "c", 3.0)
            self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.store.clear("default", "c"), 2)
        self.assertEqual(self.store.list("default", "c"), [])

    def test_page_rows_get_counts_without_mutating_the_cached_page(self):
        self.store.add("default", "child", 1, "user", "a", 1.0)
        page = {"data": [{"id": "child", "profile": "default"}, {"id": "other", "profile": "default"}], "next": None}
        out = bridge_pins.with_pin_counts(page, self.store)
        self.assertEqual(out["data"][0]["pin_count"], 1)
        self.assertNotIn("pin_count", out["data"][1])
        self.assertNotIn("pin_count", page["data"][0])
        self.assertIs(bridge_pins.with_pin_counts(page, None), page)


class FakeHandler:
    """Drives Handler.pins_route/session_flags without a socket."""
    def __init__(self, command, path, body=None):
        self.command, self.path = command, path
        self._body = json.dumps(body or {}).encode()
        self.sent = None

    def json_body(self):
        return json.loads(self._body)

    def send(self, code, body=b"", **_):
        self.sent = (code, body)
        return code


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        make_state_db(self.home / "state.db").close()
        self.patches = [patch.object(bridge, "STATE_DIR", Path(self.tmp.name) / "mobile"),
                        patch.object(bridge, "profile_ids", return_value=["default"]),
                        patch.object(bridge, "profile_home", return_value=self.home),
                        patch.object(bridge, "key_for", return_value="key")]
        for p in self.patches:
            p.start()
        bridge._PINS.clear()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        bridge._PINS.clear()
        self.tmp.cleanup()

    def call(self, command, path, body=None, route="pins_route"):
        h = FakeHandler(command, path, body)
        if route == "pins_route":
            bridge.H.pins_route(h, path)
        else:
            bridge.H.session_flags(h)
        return h.sent

    def test_pin_list_unpin_roundtrip(self):
        code, body = self.call("POST", "/m/pins/default/child", {"message_id": 2})
        self.assertEqual(code, 201)
        self.assertEqual(body["pin"]["text"], "Lease due Dec 1")
        code, _ = self.call("POST", "/m/pins/default/child", {"message_id": 2})
        self.assertEqual(code, 200)
        code, body = self.call("GET", "/m/pins/default/child")
        self.assertEqual((code, len(body["pins"])), (200, 1))
        code, body = self.call("DELETE", "/m/pins/default/child/2")
        self.assertEqual((code, body["removed"], body["pins"]), (200, 1, []))

    def test_bad_requests(self):
        self.assertEqual(self.call("POST", "/m/pins/default/child", {"message_id": "2"})[0], 400)
        self.assertEqual(self.call("POST", "/m/pins/default/child", {"message_id": True})[0], 400)
        self.assertEqual(self.call("POST", "/m/pins/default/child", {"message_id": 4})[0], 404)
        self.assertEqual(self.call("GET", "/m/pins/nobody/child")[0], 404)
        self.assertEqual(self.call("GET", "/m/pins/default/bad%20id")[0], 400)
        self.assertEqual(self.call("PUT", "/m/pins/default/child")[0], 405)

    def test_archive_is_refused_for_chats_with_pins_until_confirmed(self):
        self.call("POST", "/m/pins/default/child", {"message_id": 1})
        with patch.object(bridge, "set_session_flags", return_value=(["other"], {})) as flags:
            code, body = self.call("POST", "/m/sessions/flags",
                                   {"profile": "default", "ids": ["child", "other"], "fields": {"archived": True}},
                                   route="flags")
        self.assertEqual(code, 200)
        flags.assert_called_once_with("default", ["other"], {"archived": True})
        self.assertEqual(body["pins"], {"child": 1})
        self.assertIn("pinned", body["errors"]["child"])

        with patch.object(bridge, "set_session_flags") as flags:
            code, body = self.call("POST", "/m/sessions/flags",
                                   {"profile": "default", "ids": ["child"], "fields": {"archived": True}}, route="flags")
        self.assertEqual((code, body["code"]), (409, "has_pins"))
        flags.assert_not_called()

        with patch.object(bridge, "set_session_flags", return_value=(["child"], {})) as flags:
            code, body = self.call("POST", "/m/sessions/flags",
                                   {"profile": "default", "ids": ["child"], "fields": {"archived": True},
                                    "confirm_pins": True}, route="flags")
        self.assertEqual((code, body["updated"]), (200, ["child"]))
        # Archiving keeps the pins; unarchiving brings the chat back with them.
        self.assertEqual(len(self.call("GET", "/m/pins/default/child")[1]["pins"]), 1)

    def test_pin_and_unarchive_are_never_blocked(self):
        self.call("POST", "/m/pins/default/child", {"message_id": 1})
        for fields in ({"archived": False}, {"pinned": True}):
            with patch.object(bridge, "set_session_flags", return_value=(["child"], {})) as flags:
                code, _ = self.call("POST", "/m/sessions/flags",
                                    {"profile": "default", "ids": ["child"], "fields": fields}, route="flags")
            self.assertEqual(code, 200)
            flags.assert_called_once()


if __name__ == "__main__":
    unittest.main()
