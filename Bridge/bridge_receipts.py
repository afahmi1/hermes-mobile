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
        fields.append([[name, digest] if mime in ("image/jpeg", "video/mp4") else [name, digest, mime]
                       for name, digest, _, mime in frames])
    request = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(request.encode()).hexdigest()


def annotate_origins(path, rows):
    if not rows or not path.is_file():
        return
    # One indexed lookup per displayed identity within one SQLite connection.
    # Presentation metadata must not compete with admission for a writer lock.
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.025)) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='mobile_origins'").fetchone():
            return
        for offset in range(0, len(rows), 200):
            page = rows[offset:offset + 200]
            ids = [(r["profile"], r["id"]) for r in page]
            values = ",".join(["(?,?)"] * len(ids))
            matches = set(map(tuple, db.execute(
                "WITH page(profile,sid) AS (VALUES " + values + ") "
                "SELECT p.profile,p.sid FROM page p JOIN mobile_origins m ON m.profile=p.profile AND m.sid=p.sid",
                [value for pair in ids for value in pair])))
            for row, key in zip(page, ids):
                if key in matches:
                    row["created_via"] = "mobile_bridge"


class Journal:
    def __init__(self, directory):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = directory / "send-receipts.sqlite3"
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        with closing(self.open()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("""CREATE TABLE IF NOT EXISTS receipts(
                id TEXT PRIMARY KEY, profile TEXT NOT NULL, sid TEXT NOT NULL, fingerprint TEXT NOT NULL,
                prompt TEXT, choice TEXT NOT NULL, workspace TEXT, started REAL NOT NULL,
                canonical TEXT, admission TEXT, generation INTEGER, terminal TEXT, steered INTEGER DEFAULT 0, media TEXT)""")
            if "media_types" not in {row[1] for row in db.execute("PRAGMA table_info(receipts)")}:
                db.execute("ALTER TABLE receipts ADD COLUMN media_types TEXT")
            if "runtime" not in {row[1] for row in db.execute("PRAGMA table_info(receipts)")}:
                # The admission's model_override as first submitted: a recovered send repeats it exactly.
                db.execute("ALTER TABLE receipts ADD COLUMN runtime TEXT")
            db.execute("CREATE TABLE IF NOT EXISTS mobile_origins(profile TEXT, sid TEXT, PRIMARY KEY(profile, sid)) WITHOUT ROWID")
            db.execute("CREATE INDEX IF NOT EXISTS pending_sends ON receipts(started) WHERE terminal IS NULL")

    def open(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA secure_delete=ON")
        return db

    def get(self, id):
        with closing(self.open()) as db:
            return db.execute("SELECT * FROM receipts WHERE id=?", (id,)).fetchone()

    def record_mobile_origin(self, profile, sid):
        with closing(self.open()) as db, db:
            db.execute("INSERT OR IGNORE INTO mobile_origins VALUES (?,?)", (profile, sid))

    def pending(self):
        with closing(self.open()) as db:
            return db.execute("SELECT * FROM receipts WHERE terminal IS NULL ORDER BY started").fetchall()

    def create(self, turn, digest, prompt):
        ws = turn.workspace
        metadata = ({k: ws.get(k) for k in ("project", "output_dir", "summary")} if ws else None)
        with closing(self.open()) as db, db:
            db.execute("""INSERT INTO receipts(id, profile, sid, fingerprint, prompt, choice, workspace, started, media, media_types)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", (turn.id, turn.profile, turn.sid, digest, prompt,
                       json.dumps(turn.choice), json.dumps(metadata, default=str), time.time(), json.dumps(turn.media),
                       json.dumps([item["mime"] for item in turn.media]) if turn.media else None))

    def prepared(self, turn):
        runtime = getattr(turn, "runtime", None)
        with closing(self.open()) as db, db:
            db.execute("UPDATE receipts SET canonical=?, runtime=? WHERE id=?",
                       (turn.canonical_sid, None if runtime is None else json.dumps(runtime), turn.id))

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
