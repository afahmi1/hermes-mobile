"""Managed overlay for owner management: managed projects, archive tombstones, app personas and persona chats.

Own SQLite file (STATE_DIR/manage/manage.db). The operator's catalog file and Hermes's profiles/ are never
written: archiving is a logical tombstone here, and deleting nothing means restore brings everything back.
"""
import os
import re
import secrets
import sqlite3
import threading
import time
import unicodedata
from contextlib import closing

MAX_MANAGED_PROJECTS = 64
MAX_PERSONAS = 64
TITLE_MAX, SUMMARY_MAX, NAME_MAX, PERSONA_MAX = 120, 1000, 60, 4096
PROJECT_ID_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
PERSONA_ID_RE = re.compile(r"persona-[0-9a-f]{8}")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT, created REAL NOT NULL);
CREATE TABLE IF NOT EXISTS archived_projects(id TEXT PRIMARY KEY, ts REAL NOT NULL);
CREATE TABLE IF NOT EXISTS personas(id TEXT PRIMARY KEY, name TEXT NOT NULL, persona TEXT NOT NULL,
    host TEXT NOT NULL, created REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS archived_bots(id TEXT PRIMARY KEY, ts REAL NOT NULL);
CREATE TABLE IF NOT EXISTS persona_chats(host TEXT NOT NULL, sid TEXT NOT NULL, persona TEXT NOT NULL,
    title TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY(host, sid));
"""


class ManageError(Exception):
    def __init__(self, message, status=400, code="bad_request"):
        super().__init__(message)
        self.status, self.code = status, code


def _text(value, limit, what, required=True, multiline=False):
    if value is None and not required:
        return None
    if not isinstance(value, str):
        raise ManageError("Bad %s." % what, 400, "bad_request")
    value = value.strip()
    if (required and not value) or len(value.encode("utf-8", "surrogatepass")) > limit:
        raise ManageError("Bad %s." % what, 400, "bad_request")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise ManageError("Bad %s." % what, 400, "bad_request") from None
    if any((unicodedata.category(c).startswith("C") and not (multiline and c in "\n\t")) for c in value):
        raise ManageError("Bad %s." % what, 400, "bad_request")
    return value


def slug(title):
    base = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:56].strip("-")
    return base if PROJECT_ID_RE.fullmatch(base or "x") and base else "project"


class Manage:
    def __init__(self, state_dir):
        self.dir = os.path.join(str(state_dir), "manage")
        os.makedirs(self.dir, 0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = os.path.join(self.dir, "manage.db")
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

    # ---- projects ----
    @staticmethod
    def _project(r):
        return {"id": r["id"], "title": r["title"], "summary": r["summary"], "bot_ids": [], "sources": [],
                "related_files": [], "managed": True}

    def managed_projects(self):
        with self._db() as db:
            return [self._project(r) for r in db.execute("SELECT * FROM projects ORDER BY created, id")]

    def archived_projects(self):
        with self._db() as db:
            return {r["id"] for r in db.execute("SELECT id FROM archived_projects")}

    def managed_ids(self):
        return {p["id"] for p in self.managed_projects()}

    def create_project(self, title, summary, pid, catalog_ids):
        title = _text(title, TITLE_MAX, "title")
        summary = _text(summary, SUMMARY_MAX, "summary", required=False) or None
        if pid is not None and (not isinstance(pid, str) or not PROJECT_ID_RE.fullmatch(pid)):
            raise ManageError("Bad id.", 400, "bad_request")
        with self.lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            taken = set(catalog_ids) | {r["id"] for r in db.execute("SELECT id FROM projects")} \
                | {r["id"] for r in db.execute("SELECT id FROM archived_projects")}
            if db.execute("SELECT COUNT(*) FROM projects").fetchone()[0] >= MAX_MANAGED_PROJECTS:
                raise ManageError("Too many managed projects.", 409, "limit")
            if pid is None:
                base = slug(title)
                pid, n = base, 1
                while pid in taken:
                    n += 1
                    pid = "%s-%d" % (base[:60], n)
                if not PROJECT_ID_RE.fullmatch(pid):
                    raise ManageError("Bad id.", 400, "bad_request")
            elif pid in taken:
                raise ManageError("That project id is taken.", 409, "id_taken")
            db.execute("INSERT INTO projects VALUES(?,?,?,?)", (pid, title, summary, time.time()))
            return {"id": pid, "title": title, "summary": summary, "bot_ids": [], "sources": [],
                    "related_files": [], "managed": True}

    def update_project(self, pid, body):
        with self.lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
            if row is None:
                raise ManageError("Not found.", 404, "not_found")
            title, summary = row["title"], row["summary"]
            if "title" in body:
                title = _text(body["title"], TITLE_MAX, "title")
            if "summary" in body:
                summary = _text(body["summary"], SUMMARY_MAX, "summary", required=False) or None
            db.execute("UPDATE projects SET title=?, summary=? WHERE id=?", (title, summary, pid))
            return {"id": pid, "title": title, "summary": summary, "bot_ids": [], "sources": [],
                    "related_files": [], "managed": True}

    def archive_project(self, pid):
        with self.lock, self._db() as db:
            db.execute("INSERT OR IGNORE INTO archived_projects VALUES(?,?)", (pid, time.time()))

    def restore_project(self, pid):
        with self.lock, self._db() as db:
            return db.execute("DELETE FROM archived_projects WHERE id=?", (pid,)).rowcount > 0

    # ---- live bots (tombstones only) ----
    def archived_bots(self):
        with self._db() as db:
            return {r["id"] for r in db.execute("SELECT id FROM archived_bots")}

    def archive_bot(self, pid):
        with self.lock, self._db() as db:
            db.execute("INSERT OR IGNORE INTO archived_bots VALUES(?,?)", (pid, time.time()))

    def restore_bot(self, pid):
        with self.lock, self._db() as db:
            return db.execute("DELETE FROM archived_bots WHERE id=?", (pid,)).rowcount > 0

    # ---- personas ----
    @staticmethod
    def _persona(r):
        return {"id": r["id"], "name": r["name"], "persona": r["persona"], "host": r["host"],
                "managed": True, "archived": bool(r["archived"])}

    def personas(self, archived=False):
        with self._db() as db:
            return [self._persona(r) for r in db.execute(
                "SELECT * FROM personas WHERE archived=? ORDER BY created, id", (1 if archived else 0,))]

    def persona(self, pid):
        with self._db() as db:
            r = db.execute("SELECT * FROM personas WHERE id=?", (pid,)).fetchone()
            return self._persona(r) if r else None

    def create_persona(self, name, persona, host):
        name = _text(name, NAME_MAX, "name")
        persona = _text(persona, PERSONA_MAX, "persona", multiline=True)
        with self.lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT COUNT(*) FROM personas").fetchone()[0] >= MAX_PERSONAS:
                raise ManageError("Too many bots.", 409, "limit")
            pid = "persona-" + secrets.token_hex(4)
            db.execute("INSERT INTO personas VALUES(?,?,?,?,?,0)", (pid, name, persona, host, time.time()))
            return {"id": pid, "name": name, "persona": persona, "host": host, "managed": True, "archived": False}

    def set_persona_archived(self, pid, archived):
        with self.lock, self._db() as db:
            return db.execute("UPDATE personas SET archived=? WHERE id=? AND archived=?",
                              (1 if archived else 0, pid, 0 if archived else 1)).rowcount > 0

    def link_chat(self, host, sid, persona, title):
        with self.lock, self._db() as db:
            db.execute("INSERT OR REPLACE INTO persona_chats VALUES(?,?,?,?,?)", (host, sid, persona, title, time.time()))

    def persona_for(self, host, sid):
        """The ACTIVE persona linked to (host, sid), else None. Archived personas stop applying."""
        with self._db() as db:
            r = db.execute("SELECT p.* FROM persona_chats c JOIN personas p ON p.id=c.persona "
                           "WHERE c.host=? AND c.sid=? AND p.archived=0", (host, sid)).fetchone()
            return self._persona(r) if r else None


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
