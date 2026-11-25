"""Pinned messages: a per-chat stack of important messages, like Telegram pins.

Own SQLite file (STATE_DIR/pins/pins.db). Hermes's state.db is only read, never written. Each pin keeps a
snapshot of the message text taken from state.db when it was pinned, so the pin still reads correctly after
compression trims or rewrites the live transcript. The client sends only ids; the text never comes from it.

A chat with pins is protected: archiving it is refused until the caller confirms it knows about the pins
(see hermes_mobile_bridge.session_flags). Archiving never deletes pins, and unarchiving brings them back.
"""
import json
import os
import sqlite3
import threading
import time

MAX_PINS_PER_CHAT = 100
EXCERPT_MAX = 4000
LINEAGE_MAX = 64
PINNABLE_ROLES = ("user", "assistant")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS pins(
    profile TEXT NOT NULL, sid TEXT NOT NULL, mid INTEGER NOT NULL,
    role TEXT NOT NULL, excerpt TEXT NOT NULL, msg_ts REAL, pinned_at REAL NOT NULL,
    PRIMARY KEY(profile, sid, mid));
CREATE INDEX IF NOT EXISTS pins_by_chat ON pins(profile, sid, pinned_at);
"""


class PinError(Exception):
    def __init__(self, message, status=400, code="bad_request"):
        super().__init__(message)
        self.status, self.code = status, code


def flatten(content):
    """Message content is a string or a JSON list of OpenAI-style parts; pins keep only the text."""
    if content is None:
        return ""
    text = content
    if isinstance(content, str):
        stripped = content.lstrip()
        if stripped.startswith("["):
            try:
                parts = json.loads(stripped)
            except ValueError:
                parts = None
            if isinstance(parts, list):
                text = "\n".join(p.get("text") or "" for p in parts if isinstance(p, dict))
    elif isinstance(content, list):
        text = "\n".join(p.get("text") or "" for p in content if isinstance(p, dict))
    text = str(text).strip()
    return text[:EXCERPT_MAX]


def _lineage(con, sid):
    """sid plus its ancestors: the transcript a phone shows includes messages from parent sessions."""
    chain, current = [sid], sid
    try:
        for _ in range(LINEAGE_MAX):
            row = con.execute("SELECT parent_session_id FROM sessions WHERE id=?", (current,)).fetchone()
            parent = row[0] if row else None
            if not parent or parent in chain:
                break
            chain.append(parent)
            current = parent
    except sqlite3.OperationalError:
        pass  # an older state.db without lineage columns: the session itself is the whole chat
    return chain


def read_message(con, sid, mid):
    """(role, excerpt, timestamp) for message `mid` if it belongs to chat `sid`, else raise PinError."""
    row = con.execute("SELECT session_id, role, content, timestamp FROM messages WHERE id=?", (mid,)).fetchone()
    if row is None or row[0] not in _lineage(con, sid):
        raise PinError("That message is not in this chat.", 404, "not_found")
    if row[1] not in PINNABLE_ROLES:
        raise PinError("Only your messages and Hermes's replies can be pinned.", 400, "not_pinnable")
    excerpt = flatten(row[2])
    if not excerpt:
        raise PinError("That message has no text to pin.", 400, "empty")
    return row[1], excerpt, row[3]


class Pins:
    def __init__(self, state_dir):
        self.dir = os.path.join(str(state_dir), "pins")
        os.makedirs(self.dir, 0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = os.path.join(self.dir, "pins.db")
        self.lock = threading.Lock()
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        os.chmod(self.path, 0o600)
        with self._db() as db:
            db.executescript(_SCHEMA)

    def _db(self):
        c = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        c.row_factory = sqlite3.Row
        return _Conn(c)

    @staticmethod
    def _row(r):
        return {"message_id": r["mid"], "role": r["role"], "text": r["excerpt"],
                "message_at": r["msg_ts"], "pinned_at": r["pinned_at"]}

    def list(self, profile, sid):
        """Newest pin first, the order Telegram's pinned bar cycles through."""
        with self._db() as db:
            return [self._row(r) for r in db.execute(
                "SELECT * FROM pins WHERE profile=? AND sid=? ORDER BY pinned_at DESC, mid DESC", (profile, sid))]

    def add(self, profile, sid, mid, role, excerpt, msg_ts):
        """Pin a message. Re-pinning an already pinned message is a no-op that keeps its original time."""
        with self.lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute("SELECT * FROM pins WHERE profile=? AND sid=? AND mid=?",
                                  (profile, sid, mid)).fetchone()
            if existing:
                return self._row(existing), False
            count = db.execute("SELECT COUNT(*) FROM pins WHERE profile=? AND sid=?", (profile, sid)).fetchone()[0]
            if count >= MAX_PINS_PER_CHAT:
                raise PinError("This chat already has %d pins. Unpin one first." % MAX_PINS_PER_CHAT, 409, "limit")
            now = time.time()
            db.execute("INSERT INTO pins VALUES(?,?,?,?,?,?,?)", (profile, sid, mid, role, excerpt, msg_ts, now))
            return {"message_id": mid, "role": role, "text": excerpt, "message_at": msg_ts, "pinned_at": now}, True

    def remove(self, profile, sid, mid):
        with self.lock, self._db() as db:
            return db.execute("DELETE FROM pins WHERE profile=? AND sid=? AND mid=?", (profile, sid, mid)).rowcount > 0

    def clear(self, profile, sid):
        with self.lock, self._db() as db:
            return db.execute("DELETE FROM pins WHERE profile=? AND sid=?", (profile, sid)).rowcount

    def counts(self, profile, sids):
        """{sid: pin count} for the given chats of one profile; chats without pins are omitted."""
        sids = [s for s in dict.fromkeys(sids) if isinstance(s, str)]
        out = {}
        with self._db() as db:
            for start in range(0, len(sids), 400):
                chunk = sids[start:start + 400]
                marks = ",".join("?" * len(chunk))
                for r in db.execute("SELECT sid, COUNT(*) AS n FROM pins WHERE profile=? AND sid IN (%s) GROUP BY sid"
                                    % marks, (profile, *chunk)):
                    out[r["sid"]] = r["n"]
        return out

    def counts_for_rows(self, rows):
        """{(profile, sid): n} for session rows from many profiles, one query per profile."""
        by_profile = {}
        for row in rows:
            if isinstance(row, dict) and isinstance(row.get("profile"), str) and isinstance(row.get("id"), str):
                by_profile.setdefault(row["profile"], []).append(row["id"])
        out = {}
        for profile, sids in by_profile.items():
            for sid, n in self.counts(profile, sids).items():
                out[(profile, sid)] = n
        return out


def with_pin_counts(page, store):
    """A copy of a session page whose rows carry `pin_count` when they have pins.

    Page bodies are cached and shared between requests, so rows are copied, never mutated in place.
    """
    if not isinstance(page, dict) or not isinstance(page.get("data"), list) or store is None:
        return page
    try:
        counts = store.counts_for_rows(page["data"])
    except sqlite3.Error:
        return page
    if not counts:
        return page
    rows = []
    for row in page["data"]:
        n = counts.get((row.get("profile"), row.get("id"))) if isinstance(row, dict) else None
        rows.append(dict(row, pin_count=n) if n else row)
    return dict(page, data=rows)


class _Conn:
    def __init__(self, c):
        self.c = c

    def __enter__(self):
        return self.c

    def __exit__(self, et, ev, tb):
        try:
            if self.c.in_transaction:
                self.c.execute("ROLLBACK" if et else "COMMIT")
        finally:
            self.c.close()
        return False
