"""Messages that send later: "Try again when limits reset".

A failed turn (usage limit, provider outage) can be retried at a set time. The row lives on the Mac in its own SQLite
file (``STATE_DIR/schedule/schedule.db``, 0700 dir, 0600 file), so it fires even when the phone is closed and survives
bridge restarts. Each row is sent once through the bridge's durable send (the same admissions journal as a phone
send), keyed by the row's own id, so a crash between "submitted" and "marked sent" can't double-send.

Stdlib only.
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time
import uuid

MAX_TEXT = 64 * 1024
MAX_WAITING = 20            # per chat
MAX_AHEAD = 8 * 24 * 3600   # a week and a bit: usage windows reset within 5 h to 7 days
RETRY_AFTER = 120           # a due row that couldn't start (chat busy, gateway down) tries again this much later
GIVE_UP_AFTER = 6 * 3600    # ...until this long past its time, then it's marked failed

_SCHEMA = """
CREATE TABLE IF NOT EXISTS scheduled(
  id TEXT PRIMARY KEY, profile TEXT NOT NULL, session TEXT NOT NULL, text TEXT NOT NULL,
  due REAL NOT NULL, next_try REAL NOT NULL, created REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'waiting', reason TEXT, error TEXT, sent_at REAL);
CREATE INDEX IF NOT EXISTS scheduled_due ON scheduled(status, next_try);
CREATE INDEX IF NOT EXISTS scheduled_chat ON scheduled(profile, session);
"""


class ScheduleError(Exception):
    def __init__(self, message, code=400):
        super().__init__(message)
        self.code = code


class Schedule:
    def __init__(self, state_dir):
        self.dir = os.path.join(str(state_dir), "schedule")
        os.makedirs(self.dir, 0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = os.path.join(self.dir, "schedule.db")
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        os.chmod(self.path, 0o600)
        self.lock = threading.Lock()
        db = sqlite3.connect(self.path, timeout=5)
        try:
            db.executescript(_SCHEMA)  # runs its own commit, so not inside _Tx
        finally:
            db.close()

    def _db(self):
        db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        return _Tx(db)

    @staticmethod
    def _public(r):
        return {k: r[k] for k in ("id", "text", "due", "status", "reason", "error", "sent_at", "created")}

    def add(self, profile, session, text, due, reason=None, now=None):
        now = time.time() if now is None else now
        text = (text or "").strip()
        if not text or len(text.encode("utf-8", "replace")) > MAX_TEXT:
            raise ScheduleError("Nothing to send.")
        try:
            due = float(due)
        except (TypeError, ValueError):
            raise ScheduleError("Bad time.") from None
        if due > now + MAX_AHEAD:
            raise ScheduleError("That's too far ahead.")
        due = max(due, now)
        with self.lock, self._db() as db:
            waiting = db.execute("SELECT count(*) FROM scheduled WHERE profile=? AND session=? AND status='waiting'",
                                 (profile, session)).fetchone()[0]
            if waiting >= MAX_WAITING:
                raise ScheduleError("This chat already has %d messages waiting to send." % MAX_WAITING, 409)
            sid = str(uuid.uuid4())
            db.execute("INSERT INTO scheduled(id, profile, session, text, due, next_try, created, reason) "
                       "VALUES(?,?,?,?,?,?,?,?)", (sid, profile, session, text, due, due, now, (reason or "")[:80] or None))
            return self._public(db.execute("SELECT * FROM scheduled WHERE id=?", (sid,)).fetchone())

    def list(self, profile, session, include_done=False):
        q = "SELECT * FROM scheduled WHERE profile=? AND session=?"
        if not include_done:
            q += " AND status='waiting'"
        with self._db() as db:
            return [self._public(r) for r in db.execute(q + " ORDER BY due", (profile, session))]

    def cancel(self, profile, session, sched_id):
        with self.lock, self._db() as db:
            cur = db.execute("UPDATE scheduled SET status='cancelled' WHERE id=? AND profile=? AND session=? "
                             "AND status='waiting'", (sched_id, profile, session))
            return cur.rowcount > 0

    def due(self, now=None):
        now = time.time() if now is None else now
        with self._db() as db:
            return [dict(r) for r in db.execute(
                "SELECT * FROM scheduled WHERE status='waiting' AND next_try<=? ORDER BY due LIMIT 20", (now,))]

    def mark_sent(self, sched_id, now=None):
        with self.lock, self._db() as db:
            db.execute("UPDATE scheduled SET status='sent', sent_at=?, error=NULL WHERE id=?",
                       (time.time() if now is None else now, sched_id))

    def postpone(self, row, error, now=None):
        """A due row that couldn't start: try again in a bit, or give up once it's long past its time."""
        now = time.time() if now is None else now
        with self.lock, self._db() as db:
            if now - row["due"] > GIVE_UP_AFTER:
                db.execute("UPDATE scheduled SET status='failed', error=? WHERE id=?", (str(error)[:300], row["id"]))
            else:
                db.execute("UPDATE scheduled SET next_try=?, error=? WHERE id=?",
                           (now + RETRY_AFTER, str(error)[:300], row["id"]))

    def tick(self, send, busy=lambda profile, session: False, now=None):
        """Send everything due. `send(row)` starts the turn (raises on failure); `busy` defers a chat mid-reply."""
        done = 0
        for row in self.due(now):
            if busy(row["profile"], row["session"]):
                self.postpone(row, "Hermes was still replying in this chat.", now)
                continue
            try:
                send(row)
            except Exception as exc:  # noqa: BLE001  (any failure retries; the reason is kept for the phone)
                self.postpone(row, "%s: %s" % (type(exc).__name__, exc), now)
                continue
            self.mark_sent(row["id"], now)
            done += 1
        return done


class _Tx:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        self.db.execute("BEGIN IMMEDIATE")
        return self.db

    def __exit__(self, kind, *_):
        try:
            self.db.execute("ROLLBACK" if kind else "COMMIT")
        finally:
            self.db.close()
