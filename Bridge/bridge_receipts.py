"""Bridge admission journal. The original prompt is retained only until Hermes confirms its receipt."""
import hashlib
import json
import os
import sqlite3
import time
from contextlib import closing


def fingerprint(profile, session, text, choice, project, frames=()):
    fields = [profile, session, text, choice, project]
    if frames:
        fields.append([[name, digest] for name, digest, _, _ in frames])
    request = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(request.encode()).hexdigest()


class Journal:
    def __init__(self, directory):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = directory / "send-receipts.sqlite3"
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        with closing(self.open()) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS receipts(
                id TEXT PRIMARY KEY, profile TEXT NOT NULL, sid TEXT NOT NULL, fingerprint TEXT NOT NULL,
                prompt TEXT, choice TEXT NOT NULL, workspace TEXT, started REAL NOT NULL,
                canonical TEXT, admission TEXT, generation INTEGER, terminal TEXT, steered INTEGER DEFAULT 0, media TEXT)""")
            db.execute("CREATE INDEX IF NOT EXISTS pending_sends ON receipts(started) WHERE terminal IS NULL")

    def open(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA secure_delete=ON")
        return db

    def get(self, id):
        with closing(self.open()) as db:
            return db.execute("SELECT * FROM receipts WHERE id=?", (id,)).fetchone()

    def pending(self):
        with closing(self.open()) as db:
            return db.execute("SELECT * FROM receipts WHERE terminal IS NULL ORDER BY started").fetchall()

    def create(self, turn, digest, prompt):
        ws = turn.workspace
        metadata = ({k: ws.get(k) for k in ("project", "output_dir", "summary")} if ws else None)
        with closing(self.open()) as db, db:
            db.execute("""INSERT INTO receipts(id, profile, sid, fingerprint, prompt, choice, workspace, started, media)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""", (turn.id, turn.profile, turn.sid, digest, prompt,
                       json.dumps(turn.choice), json.dumps(metadata, default=str), time.time(), json.dumps(turn.media)))

    def prepared(self, turn):
        with closing(self.open()) as db, db:
            db.execute("UPDATE receipts SET canonical=? WHERE id=?", (turn.canonical_sid, turn.id))

    def admitted(self, turn):
        with closing(self.open()) as db, db:
            db.execute("UPDATE receipts SET admission=?, generation=?, prompt=NULL WHERE id=?",
                       (turn.admission, turn.generation, turn.id))

    def suppress_capture(self, turn):
        with closing(self.open()) as db, db:
            db.execute("UPDATE receipts SET steered=1 WHERE id=?", (turn.id,))

    def terminal(self, turn, event):
        # Completed text and usage remain in the canonical Hermes transcript.
        marker = {"event": event["event"]}
        if marker["event"] == "run.failed":
            marker["error"] = "Hermes could not finish this reply. Check the saved chat."
        with closing(self.open()) as db, db:
            db.execute("UPDATE receipts SET terminal=?, prompt=NULL, workspace=NULL, media=NULL WHERE id=?",
                       (json.dumps(marker), turn.id))
