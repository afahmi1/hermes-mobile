"""Uploads from the phone: photos, scans, PDFs and any other file, staged where Hermes itself reads them.

Flow (the desktop app's own, done by the bridge for the phone):
  1. ``start`` reserves an upload; the phone sends the bytes in chunks (``append``), resumable after a
     dropped connection (tus-style offset: ask ``status`` for the offset, send the rest).
  2. When the last byte lands the file is finalized by its magic bytes, never its claimed type:
     - PNG / JPEG / GIF / WebP go to the profile's image staging dir (``cache/images``), the only place
       ``prompt.submit`` accepts ``attachments: [{path, mime}]`` from (``gateway/session_ingress_media``).
     - anything else goes to ``<profile home>/uploads/``; the turn hands it to the gateway's
       ``file.attach``, which copies it into the session workspace and returns an ``@file:`` ref.
  3. The phone gets back an opaque signed ``ref``. A send names refs only, so the phone never picks
     a path on the Mac, and refs survive a bridge restart (nothing to look up: the signature is the proof).

Stdlib only. Partial uploads live in ``~/.hermes/mobile/partial`` and expire after a day.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from pathlib import Path

CHUNK = 4 * 1024 * 1024            # what the phone sends per request (fits the bridge's 12 MB body cap)
MAX_IMAGE = 25 * 1024 * 1024       # Hermes's own chat image cap (hermes_cli/web_upload_limit.py)
MAX_FILE = 120 * 1024 * 1024       # under gateway.max_inbound_media_bytes (128 MB)
MAX_PER_TURN = 10                  # gateway/session_ingress_media._ATTACHMENT_LIMIT (images); files share it
REF_TTL = 7 * 86400
PARTIAL_TTL = 86400
UPLOAD_KEEP = 30 * 86400           # staged copies under uploads/ (file.attach may reference them in place)
IMAGE_MIMES = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp"}
ID_RE = re.compile(r"^up_[0-9a-f]{32}$")

_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


class UploadError(Exception):
    def __init__(self, message, code=400):
        super().__init__(message)
        self.code = code


def _lock(uid):
    with _locks_guard:
        return _locks.setdefault(uid, threading.Lock())


def _sniff(head: bytes) -> str | None:
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def _safe_name(name: str) -> str:
    base = Path(str(name or "")).name.replace("\x00", "").strip()
    base = re.sub(r"[^A-Za-z0-9._ -]+", "_", base).strip(" ._") or "attachment"
    stem, dot, ext = base.rpartition(".")
    if dot and len(ext) <= 12:
        return (stem[:80] or "attachment") + "." + ext
    return base[:96]


def _private_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def image_dir(home: Path) -> Path:
    """``hermes_constants.get_hermes_dir("cache/images", "image_cache", home=home)``: a populated legacy
    ``image_cache/`` wins, otherwise ``cache/images``. Admission requires the file's parent to be exactly this."""
    legacy = home / "image_cache"
    try:
        if legacy.is_dir() and any(legacy.iterdir()):
            return legacy
    except OSError:
        pass
    return home / "cache" / "images"


def upload_dir(home: Path) -> Path:
    return home / "uploads"


class Uploads:
    def __init__(self, state_dir: Path, secret: bytes, profile_home, log=lambda m: None):
        self.partial = _private_dir(state_dir / "partial")
        self.thumbs = _private_dir(state_dir / "thumbs")
        self.secret = secret
        self.profile_home = profile_home
        self.log = log

    # ---- signed refs ----
    def _sign(self, d: dict) -> str:
        payload = base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).decode().rstrip("=")
        sig = hmac.new(self.secret, b"upload:" + payload.encode(), hashlib.sha256).hexdigest()
        return "hu1.%s.%s" % (payload, sig)

    def resolve(self, ref: str, pid: str) -> dict:
        """A ref the phone sent with a message -> {kind, path, mime, name, size}. Refuses anything not
        signed here, for another bot, expired, moved, or outside that bot's staging dirs."""
        try:
            ver, payload, sig = str(ref).split(".")
            good = hmac.new(self.secret, b"upload:" + payload.encode(), hashlib.sha256).hexdigest()
            if ver != "hu1" or not hmac.compare_digest(sig, good):
                raise ValueError
            d = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        except Exception:
            raise UploadError("An attachment wasn't recognised. Attach it again.")
        if d.get("pid") != pid:
            raise UploadError("An attachment was uploaded for a different bot. Attach it again.")
        if int(d.get("exp", 0)) < time.time():
            raise UploadError("An attachment expired. Attach it again.")
        path = Path(d["path"])
        home = self.profile_home(pid)
        root = image_dir(home) if d["kind"] == "image" else upload_dir(home)
        try:
            if path.resolve().parent != root.resolve() or not path.is_file() or path.is_symlink():
                raise FileNotFoundError
        except OSError:
            raise UploadError("%s is no longer on your Mac. Attach it again." % d.get("name", "An attachment"), 410)
        return {k: d[k] for k in ("kind", "path", "mime", "name", "size")}

    # ---- resumable upload ----
    def _meta_path(self, uid):
        return self.partial / (uid + ".json")

    def _part_path(self, uid):
        return self.partial / (uid + ".part")

    def _meta(self, uid):
        if not ID_RE.match(uid or ""):
            raise UploadError("Unknown upload.", 404)
        try:
            return json.loads(self._meta_path(uid).read_text())
        except (OSError, ValueError):
            raise UploadError("That upload is gone. Attach the file again.", 404)

    def _save_meta(self, uid, meta):
        tmp = self.partial / (".%s.%s" % (uid, secrets.token_hex(3)))
        tmp.write_text(json.dumps(meta))
        os.chmod(tmp, 0o600)
        os.replace(tmp, self._meta_path(uid))

    def start(self, pid: str, name: str, size, mime: str = "") -> dict:
        try:
            size = int(size)
        except (TypeError, ValueError):
            raise UploadError("Missing the file size.")
        if size <= 0:
            raise UploadError("That file is empty.")
        if size > MAX_FILE:
            raise UploadError("That file is %d MB; the limit is %d MB." % (size >> 20, MAX_FILE >> 20), 413)
        self.sweep()
        uid = "up_" + secrets.token_hex(16)
        meta = {"pid": pid, "name": _safe_name(name), "size": size, "mime": str(mime or "")[:100],
                "created": time.time()}
        fd = os.open(self._part_path(uid), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        self._save_meta(uid, meta)
        return {"upload_id": uid, "offset": 0, "size": size, "chunk_size": CHUNK, "done": False}

    def status(self, uid: str) -> dict:
        meta = self._meta(uid)
        if meta.get("ref"):
            return self._done_reply(uid, meta)
        try:
            off = self._part_path(uid).stat().st_size
        except OSError:
            raise UploadError("That upload is gone. Attach the file again.", 404)
        return {"upload_id": uid, "offset": off, "size": meta["size"], "chunk_size": CHUNK, "done": False}

    def append(self, uid: str, offset, data: bytes) -> dict:
        with _lock(uid):
            meta = self._meta(uid)
            if meta.get("ref"):
                return self._done_reply(uid, meta)  # a retried last chunk: already finished
            part = self._part_path(uid)
            have = part.stat().st_size
            try:
                offset = int(offset)
            except (TypeError, ValueError):
                raise UploadError("Missing the chunk offset.")
            if offset != have:
                # Out of step (a chunk got lost or was sent twice): tell the phone where to resume.
                raise UploadError("offset_mismatch:%d" % have, 409)
            if not data or have + len(data) > meta["size"]:
                raise UploadError("That chunk doesn't fit the file.")
            with open(part, "ab") as f:
                f.write(data)
            have += len(data)
            if have < meta["size"]:
                return {"upload_id": uid, "offset": have, "size": meta["size"], "chunk_size": CHUNK, "done": False}
            meta.update(self._finalize(uid, meta))
            self._save_meta(uid, meta)
            return self._done_reply(uid, meta)

    def _done_reply(self, uid, meta):
        return {"upload_id": uid, "offset": meta["size"], "size": meta["size"], "done": True, "ref": meta["ref"],
                "kind": meta["kind"], "mime": meta["final_mime"], "name": meta["name"]}

    def _finalize(self, uid, meta) -> dict:
        part = self._part_path(uid)
        with open(part, "rb") as f:
            head = f.read(16)
        mime = _sniff(head)
        home = self.profile_home(meta["pid"])
        if mime:
            if meta["size"] > MAX_IMAGE:
                part.unlink(missing_ok=True)
                raise UploadError("That image is over %d MB. Send a smaller one." % (MAX_IMAGE >> 20), 413)
            h = hashlib.sha256()
            with open(part, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
            root = _private_dir(image_dir(home))
            # Content-addressed like Hermes's own hosted staging: a resend of the same photo is the same file.
            target = root / (h.hexdigest() + IMAGE_MIMES[mime])
            if target.exists() and not target.is_symlink():
                part.unlink(missing_ok=True)
            else:
                os.replace(part, target)
                os.chmod(target, 0o600)
            kind = "image"
        else:
            root = _private_dir(upload_dir(home))
            target = root / ("mobile-%s-%s" % (secrets.token_hex(4), meta["name"]))
            os.replace(part, target)
            os.chmod(target, 0o600)
            kind = "file"
            mime = meta.get("mime") or "application/octet-stream"
        ref = self._sign({"pid": meta["pid"], "kind": kind, "path": str(target), "mime": mime,
                          "name": meta["name"], "size": meta["size"], "exp": int(time.time()) + REF_TTL})
        self.log("upload %s: %s %s (%d bytes) for %s" % (uid, kind, meta["name"], meta["size"], meta["pid"]))
        return {"ref": ref, "kind": kind, "final_mime": mime, "path": str(target)}

    def cancel(self, uid: str):
        with _lock(uid):
            meta = self._meta(uid)
            if not meta.get("ref"):
                self._part_path(uid).unlink(missing_ok=True)
            self._meta_path(uid).unlink(missing_ok=True)

    def sweep(self):
        """Forget partial uploads older than a day and staged phone files older than a month."""
        now = time.time()
        try:
            for p in self.partial.iterdir():
                if now - p.stat().st_mtime > PARTIAL_TTL:
                    p.unlink(missing_ok=True)
        except OSError:
            pass

    def sweep_staged(self, homes):
        now = time.time()
        for home in homes:
            d = upload_dir(home)
            try:
                for p in d.glob("mobile-*"):
                    if p.is_file() and now - p.stat().st_mtime > UPLOAD_KEEP:
                        p.unlink(missing_ok=True)
            except OSError:
                continue
        try:
            for p in self.thumbs.iterdir():
                if now - p.stat().st_atime > 30 * 86400:
                    p.unlink(missing_ok=True)
        except OSError:
            pass

    # ---- reading media back (history thumbnails) ----
    def media_roots(self, home: Path):
        return [image_dir(home), home / "cache" / "documents", home / "document_cache", upload_dir(home)]

    def media(self, pid: str, raw_path: str, thumb: bool) -> tuple[bytes, str]:
        """An image Hermes recorded in this bot's transcript (``[Image attached at: …]``), for the phone
        to show. Only files inside the bot's own media dirs, only images."""
        home = self.profile_home(pid)
        try:
            path = Path(raw_path).resolve(strict=True)
        except (OSError, RuntimeError):
            raise UploadError("not found", 404)
        roots = [r.resolve() for r in self.media_roots(home) if r.exists()]
        if not any(path.is_relative_to(r) for r in roots) or not path.is_file():
            raise UploadError("not found", 404)
        with open(path, "rb") as f:
            head = f.read(16)
        mime = _sniff(head)
        if not mime:
            raise UploadError("not an image", 415)
        if not thumb:
            if path.stat().st_size > MAX_IMAGE:
                raise UploadError("too large", 413)
            return path.read_bytes(), mime
        st = path.stat()
        key = hashlib.sha256(("%s|%d|%d" % (path, st.st_size, int(st.st_mtime))).encode()).hexdigest()[:32]
        out = self.thumbs / (key + ".jpg")
        if not out.exists():
            tmp = self.thumbs / (".%s.%s.jpg" % (key, secrets.token_hex(3)))
            try:
                # macOS's own image tool: no third-party imaging library in the bridge.
                subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "640",
                                str(path), "--out", str(tmp)], check=True, capture_output=True, timeout=20)
                os.replace(tmp, out)
            except Exception:
                tmp.unlink(missing_ok=True)
                return path.read_bytes(), mime  # fall back to the original
        os.utime(out)
        return out.read_bytes(), "image/jpeg"
