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
            # WAL: checking a phone's grant (every request) never waits behind a write (push token, presence,
            # pairing). Under the old rollback journal a write held past the lock timeout made a valid
            # phone's request fail, and the bridge answered that with "Sign in again".
            try:
                db.execute("PRAGMA journal_mode=WAL")
            except sqlite3.Error:
                pass
            db.executescript("""
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, issued INTEGER NOT NULL,
                    expires INTEGER NOT NULL, method TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS pairing (digest BLOB PRIMARY KEY, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS push_tokens (
                    device_id TEXT PRIMARY KEY, token TEXT NOT NULL, env TEXT NOT NULL,
                    account TEXT NOT NULL, updated INTEGER NOT NULL, topic TEXT);
            """)
            # Registries from before the app reported its bundle ID (the APNs topic) gain the column in place.
            if "topic" not in {row[1] for row in db.execute("PRAGMA table_info(push_tokens)")}:
                db.execute("ALTER TABLE push_tokens ADD COLUMN topic TEXT")
                db.commit()
        if os.name == "posix":
            self.path.chmod(0o600)

    def connect(self):
        # A long wait is cheap; a timeout is not (see RegistryBusy in hermes_mobile_bridge).
        return sqlite3.connect(self.path, timeout=15)

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
            db.execute("DELETE FROM push_tokens WHERE device_id NOT IN (SELECT id FROM devices)")
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

    def permitted(self, keys):
        """Fresh registry snapshot, including revocations made by other processes."""
        ids = tuple(set(keys))
        permitted = set()
        with closing(self.connect()) as db, db:
            for start in range(0, len(ids), 500):
                chunk = ids[start:start + 500]
                slots = ",".join("?" for _ in chunk)
                permitted.update(row[0] for row in db.execute(
                    f"SELECT id FROM devices WHERE revoked=0 AND expires>? AND id IN ({slots})",
                    (time.time(), *chunk)))
        return permitted

    def active(self):
        with closing(self.connect()) as db:
            db.row_factory = sqlite3.Row
            return [dict(row) for row in db.execute(
                "SELECT id,name,issued,expires,method FROM devices WHERE revoked=0 AND expires>? ORDER BY issued DESC,id",
                (time.time(),))]

    def revoke(self, key):
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM push_tokens WHERE device_id=?", (key,))
            return db.execute("UPDATE devices SET revoked=1 WHERE id=? AND revoked=0", (key,)).rowcount == 1

    def set_push_token(self, key, token, env, account, topic=None):
        """One APNs token per device grant. A token that moved to another grant leaves the old one. `topic` is the
        app's own bundle ID as the phone reports it (None from builds that predate it: the bridge's setting applies)."""
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM push_tokens WHERE token=? AND device_id!=?", (token, key))
            db.execute("INSERT OR REPLACE INTO push_tokens(device_id,token,env,account,updated,topic) VALUES(?,?,?,?,?,?)",
                       (key, token, env, account, int(time.time()), topic))

    def set_push_env(self, token, env):
        """APNs accepted this token only in the other environment: remember the one that works."""
        with closing(self.connect()) as db, db:
            db.execute("UPDATE push_tokens SET env=? WHERE token=?", (env, token))

    def clear_push_token(self, key):
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM push_tokens WHERE device_id=?", (key,))

    def drop_push_token(self, token):
        with closing(self.connect()) as db, db:
            db.execute("DELETE FROM push_tokens WHERE token=?", (token,))

    def push_targets(self, key=None):
        """Tokens of live grants only; one device, or every device when the turn's origin is unknown."""
        with closing(self.connect()) as db:
            db.row_factory = sqlite3.Row
            db.execute("DELETE FROM push_tokens WHERE device_id NOT IN "
                       "(SELECT id FROM devices WHERE revoked=0 AND expires>?)", (time.time(),))
            db.commit()
            sql = "SELECT device_id,token,env,account,topic FROM push_tokens"
            rows = db.execute(sql + (" WHERE device_id=?" if key else ""), (key,) if key else ())
            return [dict(row) for row in rows]

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


def push_summary(directory: Path):
    """Read-only count of the phones registered for push on live grants: {"phones", "envs", "own_topic"}, or None
    when there is no registry. It never writes (no migration, no pruning), so `--doctor` leaves live state alone."""
    path = Path(directory) / "devices.sqlite3"
    if not path.is_file():
        return None
    try:
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(push_tokens)")}
            if not columns:
                return {"phones": 0, "envs": {}, "own_topic": 0}
            topic = "topic" if "topic" in columns else "NULL"
            rows = db.execute("SELECT p.env, %s FROM push_tokens p JOIN devices d ON d.id = p.device_id "
                              "WHERE d.revoked = 0 AND d.expires > ?" % topic, (time.time(),)).fetchall()
    except sqlite3.Error:
        return None
    envs = {}
    for env, _ in rows:
        envs[env] = envs.get(env, 0) + 1
    return {"phones": len(rows), "envs": envs, "own_topic": sum(1 for _, t in rows if t)}


class Streams:
    """Close live streams, including idle upstream reads, on token revocation or expiry."""
    def __init__(self, permitted):
        self.permitted = permitted
        self.lock = threading.Lock()
        self.live = {}
        self.running = False

    @contextmanager
    def watch(self, claims, valid, *sockets):
        handle = object()
        with self.lock:
            self.live[handle] = claims["did"], claims["exp"], sockets
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
            self._check(entries)

    def _check(self, entries):
        # Signatures were checked at entry. Continue enforcing the individual token
        # deadline and read current grants every tick, even for a completely idle socket.
        try:
            allowed = self.permitted(key for _, (key, _, _) in entries)
        except (sqlite3.Error, OSError):
            # The registry is busy or unreadable for a moment. That is not a revocation: keep every stream
            # (revoke() still closes a revoked device's streams at once) and enforce only the token deadline.
            allowed = None
        now = time.time()
        for handle, (key, expiry, _) in entries:
            if expiry <= now or (allowed is not None and key not in allowed):
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
