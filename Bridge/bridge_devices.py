"""Persistent device grants and single-use pair codes for one Hermes Mobile bridge."""
from contextlib import closing, contextmanager
import hashlib
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import threading
import time


class Devices:
    def __init__(self, directory: Path):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = directory / "devices.sqlite3"
        with closing(self.connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, issued INTEGER NOT NULL,
                    expires INTEGER NOT NULL, method TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS pairing (digest BLOB PRIMARY KEY, expires INTEGER NOT NULL);
            """)
        if os.name == "posix":
            self.path.chmod(0o600)

    def connect(self):
        return sqlite3.connect(self.path, timeout=3)

    def issue(self, claims, code=None):
        with closing(self.connect()) as db, db:
            if claims["method"] == "pair":
                if not isinstance(code, str) or len(code) != 24:
                    return False
                used = db.execute("DELETE FROM pairing WHERE digest=? AND expires>?",
                                  (self.digest(code), time.time())).rowcount
                if not used:
                    return False
            db.execute("DELETE FROM devices WHERE expires<=?", (time.time(),))
            db.execute("INSERT INTO devices(id,name,issued,expires,method) VALUES(?,?,?,?,?)",
                       (claims["did"], claims["dev"], claims["issued"], claims["exp"], claims["method"]))
            return True

    def accepts(self, claims, token):
        # Older signed tokens acquire a stable, revocable id on first presentation.
        key = claims.get("did") or hashlib.sha256(token.encode()).hexdigest()[:32]
        with closing(self.connect()) as db, db:
            row = db.execute("SELECT revoked FROM devices WHERE id=?", (key,)).fetchone()
            if row is None and "did" not in claims:
                db.execute("INSERT OR IGNORE INTO devices(id,name,issued,expires,method) VALUES(?,?,?,?,?)",
                           (key, str(claims.get("dev") or "Older device")[:60], 0, claims["exp"], "legacy"))
                row = db.execute("SELECT revoked FROM devices WHERE id=?", (key,)).fetchone()
            if row is None or row[0]:
                return False
        claims["did"] = key
        return True

    def active(self):
        with closing(self.connect()) as db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute(
                "SELECT id,name,issued,expires,method FROM devices WHERE revoked=0 AND expires>? ORDER BY issued DESC,id",
                (time.time(),))]

    def revoke(self, key):
        with closing(self.connect()) as db, db:
            return db.execute("UPDATE devices SET revoked=1 WHERE id=? AND revoked=0", (key,)).rowcount == 1

    def offer(self):
        code = secrets.token_urlsafe(18)
        now = int(time.time())
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM pairing WHERE expires<=?", (now,))
            db.execute("INSERT INTO pairing VALUES(?,?)", (self.digest(code), now + 300))
        return {"code": code, "expires": now + 300}

    @staticmethod
    def digest(code):
        return hashlib.sha256(code.encode()).digest()


class Streams:
    """Close live streams, including idle upstream reads, on token revocation or expiry."""
    def __init__(self):
        self.lock = threading.Lock()
        self.live = {}
        self.running = False

    @contextmanager
    def watch(self, key, valid, *sockets):
        handle = object()
        with self.lock:
            self.live[handle] = key, valid, sockets
            if not self.running:
                self.running = True
                threading.Thread(target=self._monitor, daemon=True, name="device-stream-auth").start()
        try:
            yield valid()
        finally:
            with self.lock:
                self.live.pop(handle, None)

    def _monitor(self):
        while True:
            time.sleep(1)
            with self.lock:
                entries = list(self.live.items())
                if not entries:
                    self.running = False
                    return
            for handle, (_, valid, _) in entries:
                if valid():
                    continue
                self._disconnect(handle)

    def revoked(self, key):
        with self.lock:
            handles = [handle for handle, (device, _, _) in self.live.items() if key == device]
        for handle in handles:
            self._disconnect(handle)

    def _disconnect(self, handle):
        with self.lock:
            entry = self.live.pop(handle, None)
            if entry:
                for connection in entry[2]:
                    if connection is not None:
                        try:
                            connection.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
