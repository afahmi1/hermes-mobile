"""Resumable uploads: big files (screen recordings, videos, audio) travel separately from the message.

The phone announces a file (its own UUID, name, type, size and SHA-256), then sends it in chunks, each at the
offset the bridge says it has. A dropped connection, a Wi-Fi to cellular handoff or an app relaunch resumes
where it stopped: the phone asks for the offset and continues. When the last byte arrives the bridge checks the
SHA-256, and only then can a message refer to it by `upload_id`. The same id is the idempotency key, so a
retried announce or chunk never duplicates data.

Bounded: HERMES_MOBILE_UPLOAD_MAX_BYTES per file (default 2 GiB), enough free disk is required up front,
and anything untouched for 24 hours is removed.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import threading
import time
from pathlib import Path

ID = re.compile(r"^[0-9a-f]{32}$")
SHA = re.compile(r"^[0-9a-f]{64}$")
CHUNK_MAX = 16 * 1024 * 1024
TTL = 24 * 3600


def _max_bytes():
    try:
        configured = int(os.environ.get("HERMES_MOBILE_UPLOAD_MAX_BYTES", ""))
    except ValueError:
        configured = 0
    return configured if configured > 0 else 2 * 1024 ** 3


MAX_BYTES = _max_bytes()


class UploadError(ValueError):
    def __init__(self, message, code=400, offset=None):
        super().__init__(message)
        self.code, self.offset = code, offset


_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()


def _lock(uid):
    with _LOCKS_GUARD:
        return _LOCKS.setdefault(uid, threading.Lock())


def _dir(root: Path) -> Path:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        root.chmod(0o700)
    except OSError:
        pass
    return root


def _paths(root, uid):
    if not ID.match(uid or ""):
        raise UploadError("Invalid upload id.", 400)
    d = _dir(Path(root))
    return d / (uid + ".json"), d / (uid + ".part"), d / (uid + ".done")


def _meta(root, uid):
    meta_path, part, done = _paths(root, uid)
    try:
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError):
        return None
    meta["complete"] = done.is_file()
    f = done if meta["complete"] else part
    meta["offset"] = f.stat().st_size if f.is_file() else 0
    return meta


def _public(meta):
    return {"upload_id": meta["upload_id"], "offset": meta["offset"], "size": meta["size"],
            "complete": meta["complete"]}


def create(root, uid, filename, mime, size, sha256, valid_name, valid_mime):
    """Announce a file. Idempotent: the same announcement returns where the upload is now."""
    uid = (uid or "").replace("-", "").lower()
    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_BYTES:
        raise UploadError("Files can be up to %d MB." % (MAX_BYTES // (1024 * 1024)), 413)
    if not isinstance(sha256, str) or not SHA.match(sha256.lower()):
        raise UploadError("Invalid file checksum.", 400)
    if not valid_name(filename) or not valid_mime(mime):
        raise UploadError("Invalid file name or type.", 400)
    meta_path, part, _ = _paths(root, uid)
    with _lock(uid):
        existing = _meta(root, uid)
        if existing:
            if (existing["filename"], existing["mime"], existing["size"], existing["sha256"]) != (filename, mime, size, sha256.lower()):
                raise UploadError("That upload id belongs to a different file.", 409)
            return _public(existing)
        free = shutil.disk_usage(meta_path.parent).free
        if free < size + 512 * 1024 * 1024:
            raise UploadError("Your Mac is low on disk space for a file this big.", 507)
        meta = {"upload_id": uid, "filename": filename, "mime": mime, "size": size, "sha256": sha256.lower(),
                "created": time.time()}
        part.touch(mode=0o600)
        tmp = meta_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(meta))
        os.replace(tmp, meta_path)
        return _public(_meta(root, uid))


def status(root, uid):
    meta = _meta(root, (uid or "").replace("-", "").lower())
    if meta is None:
        raise UploadError("No such upload.", 404)
    return _public(meta)


def append(root, uid, offset, data: bytes):
    """Write one chunk at `offset`. A wrong offset answers 409 with the real one, so the phone just resumes."""
    uid = (uid or "").replace("-", "").lower()
    if len(data) > CHUNK_MAX:
        raise UploadError("Chunk too large.", 413)
    meta_path, part, done = _paths(root, uid)
    with _lock(uid):
        meta = _meta(root, uid)
        if meta is None:
            raise UploadError("No such upload.", 404)
        if meta["complete"]:
            return _public(meta)
        if offset != meta["offset"]:
            raise UploadError("Resume from %d." % meta["offset"], 409, meta["offset"])
        if not data or meta["offset"] + len(data) > meta["size"]:
            raise UploadError("That chunk doesn't fit the announced size.", 400)
        with open(part, "ab") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if meta["offset"] + len(data) == meta["size"]:
            digest = hashlib.sha256()
            with open(part, "rb") as f:
                for block in iter(lambda: f.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != meta["sha256"]:
                part.unlink(missing_ok=True)
                part.touch(mode=0o600)
                raise UploadError("The file arrived damaged. Sending it again from the start.", 422, 0)
            os.replace(part, done)
            done.chmod(0o600)
        return _public(_meta(root, uid))


def resolve(root, uid):
    """(path, meta) of a finished upload, or raises."""
    uid = (uid or "").replace("-", "").lower()
    meta = _meta(root, uid)
    if meta is None or not meta["complete"]:
        raise UploadError("That file hasn't finished uploading.", 409)
    _, _, done = _paths(root, uid)
    os.utime(done)  # in use: keep it past the sweep
    return done, meta


def prune(root, ttl=TTL):
    d = Path(root)
    if not d.is_dir():
        return 0
    cutoff, removed = time.time() - ttl, 0
    for meta_path in d.glob("*.json"):
        uid = meta_path.stem
        if not ID.match(uid):
            continue
        files = [meta_path, d / (uid + ".part"), d / (uid + ".done")]
        newest = max((f.stat().st_mtime for f in files if f.exists()), default=0)
        if newest < cutoff:
            for f in files:
                f.unlink(missing_ok=True)
            removed += 1
    return removed
