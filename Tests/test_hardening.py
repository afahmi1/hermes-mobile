"""Regressions for faults that lost chats, stopped the bridge at startup or dropped a connection."""
import io
import json
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_receipts
import bridge_turns
import hermes_mobile_bridge as bridge


def gateway(rows, pins_outside=True):
    """Mirror the gateway listing: a LIMIT/OFFSET window over every row, then pins the window missed."""
    def gw(method, pid, path, body=None, timeout=20):
        query = dict(part.split("=") for part in path.split("?")[1].split("&"))
        limit, offset = int(query["limit"]), int(query["offset"])
        window = rows[offset:offset + limit]
        seen = {r["id"] for r in window}
        backfill = [r for r in rows if r.get("pinned") and r["id"] not in seen] if pins_outside else []
        return 200, {"data": [dict(r) for r in window + backfill]}
    return gw


def page_all(rows, limit):
    seen, cursor, rounds = [], None, 0
    with patch.object(bridge, "profile_ids", return_value=["default"]), \
            patch.object(bridge, "key_for", return_value="key"), \
            patch.object(bridge, "gw", side_effect=gateway(rows)), \
            patch.object(bridge, "with_mobile_origins", side_effect=lambda r: r), \
            patch.object(bridge, "NATIVE_INBOX", False):
        while rounds < 50:
            rounds += 1
            page = bridge.all_sessions(limit, cursor)
            seen += [r["id"] for r in page["data"]]
            cursor = page["next"]
            if not cursor:
                break
    return seen, rounds


class PaginationTests(unittest.TestCase):
    def rows(self, count, pinned=()):
        return [{"id": "s%03d" % i, "source": "gui", "last_active": 10_000 - i, "pinned": i in pinned}
                for i in range(count)]

    def test_pin_on_the_last_row_of_a_full_window_does_not_end_the_inbox(self):
        seen, _ = page_all(self.rows(100, pinned={39}), 40)
        self.assertEqual(set(seen), {"s%03d" % i for i in range(100)})

    def test_every_chat_is_listed_once_with_pins_anywhere(self):
        for pinned in ({0}, {39, 40}, {38, 39}, {79}, {99}, {5, 39, 79, 80}):
            seen, _ = page_all(self.rows(100, pinned=pinned), 40)
            self.assertEqual(sorted(set(seen)), ["s%03d" % i for i in range(100)], pinned)
            self.assertEqual(len(seen), len(set(seen)), pinned)

    def test_paging_ends_when_only_pins_remain(self):
        seen, rounds = page_all(self.rows(45, pinned=set(range(45))), 40)
        self.assertLess(rounds, 5)
        self.assertEqual(len(set(seen)), 45)


class RecoveryTests(unittest.TestCase):
    def test_one_unrecoverable_send_does_not_stop_startup(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            journal = bridge_receipts.Journal(directory)
            with sqlite3.connect(journal.path) as db:
                for name in ("turn-a", "turn-b"):
                    db.execute("INSERT INTO receipts(id, profile, sid, fingerprint, prompt, choice, started) "
                               "VALUES (?,?,?,?,?,?,?)", (name, "default", name, "f", "hi", "{}", time.time()))
            calls = []

            def restored(row, home, journal, restore):
                calls.append(row["id"])
                raise RuntimeError("workspace storage offline")

            with patch.object(bridge_turns, "restored_turn", side_effect=restored), \
                    patch.object(bridge_turns, "get_turn", return_value=None):
                bridge_turns.recover_primary(directory, lambda profile: directory, None)
            self.assertEqual(calls, ["turn-a", "turn-b"])
            self.assertEqual(journal.pending(), [])
            self.assertEqual(json.loads(journal.get("turn-a")["terminal"])["event"], "run.failed")

    def test_finished_receipts_expire_and_pending_ones_stay(self):
        with tempfile.TemporaryDirectory() as tmp:
            journal = bridge_receipts.Journal(Path(tmp))
            old = time.time() - 40 * 86400
            with sqlite3.connect(journal.path) as db:
                for name, started, terminal in (("old-done", old, "{}"), ("old-pending", old, None),
                                                ("new-done", time.time(), "{}")):
                    db.execute("INSERT INTO receipts(id, profile, sid, fingerprint, choice, started, terminal) "
                               "VALUES (?,?,?,?,?,?,?)", (name, "default", name, "f", "{}", started, terminal))
            self.assertEqual(journal.prune(30 * 86400), 1)
            self.assertIsNone(journal.get("old-done"))
            self.assertIsNotNone(journal.get("old-pending"))
            self.assertIsNotNone(journal.get("new-done"))


class Request(bridge.H):
    def __init__(self, path):
        self.command, self.path, self.request_version = "GET", path, "HTTP/1.1"
        self.requestline, self.client_address = "GET %s HTTP/1.1" % path, ("127.0.0.1", 0)
        self.headers, self.wfile, self._headers_buffer = {}, io.BytesIO(), []
        self.close_connection = False

    def log_message(self, *args):
        pass

    def status(self):
        return int(self.wfile.getvalue().split(b" ", 2)[1])


class RequestTests(unittest.TestCase):
    def test_a_handler_fault_still_answers(self):
        request = Request("/m/sessions")
        with patch.object(bridge.H, "route", side_effect=RuntimeError("boom")), patch.object(bridge, "log"):
            request._guarded()
        self.assertEqual(request.status(), 500)
        self.assertTrue(request.close_connection)
        self.assertNotIn(b"boom", request.wfile.getvalue())

    def test_a_fault_after_the_reply_started_writes_nothing_more(self):
        request = Request("/m/sessions")

        def route(self):
            self.send(200, {"ok": True})
            raise RuntimeError("late")

        with patch.object(bridge.H, "route", route), patch.object(bridge, "log"):
            request._guarded()
        self.assertEqual(request.wfile.getvalue().count(b"HTTP/1.1"), 1)
        self.assertEqual(request.status(), 200)

    def test_limit_is_bounded_and_tolerates_garbage(self):
        self.assertEqual(bridge._bounded_int("abc", 40, 1, 100), 40)
        self.assertEqual(bridge._bounded_int(None, 40, 1, 100), 40)
        self.assertEqual(bridge._bounded_int("0", 40, 1, 100), 1)
        self.assertEqual(bridge._bounded_int("999", 40, 1, 100), 100)

    def test_login_without_a_readable_config_has_no_credentials(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(bridge, "HERMES", Path(tmp)):
            self.assertFalse(any(bridge.basic_auth()))


if __name__ == "__main__":
    unittest.main()
