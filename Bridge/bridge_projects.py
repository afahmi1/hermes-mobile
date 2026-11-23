"""Opt-in, read-only project catalog for the Hermes Mobile bridge.

The only input is one operator-supplied filename (HERMES_MOBILE_PROJECTS_CATALOG). The file is
display metadata only: nothing named inside it is ever opened, mapped or fetched. Every failure
collapses to one generic error so no path or content leaks to the phone.
"""
import json
import os
import re
import stat
import unicodedata

SETTING = "HERMES_MOBILE_PROJECTS_CATALOG"
MAX_BYTES = 256 * 1024
UNCONFIGURED = {"schema_version": 1, "configured": False, "roots": [], "projects": []}
UNAVAILABLE = {"error": "Project catalog unavailable."}

ID_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
BOT_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,40}")
MAX_ROOTS, MAX_PROJECTS, MAX_BOTS, MAX_SOURCES, MAX_FILES = 64, 300, 32, 32, 64
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


class CatalogError(Exception):
    pass


def supported():
    need = ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK", "O_CLOEXEC")
    return (os.name == "posix" and all(hasattr(os, n) for n in need)
            and os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd)


def bad():
    raise CatalogError


def text(value, limit):
    if not isinstance(value, str) or not value or value != value.strip():
        bad()
    try:
        if len(value.encode("utf-8")) > limit:
            bad()
    except UnicodeEncodeError:
        bad()
    if any(category.startswith("C") or category in ("Zl", "Zp") for category in map(unicodedata.category, value)):
        bad()
    return value


def keys(obj, required, optional=()):
    if not isinstance(obj, dict) or not set(required) <= set(obj) or set(obj) - set(required) - set(optional):
        bad()


def array(value, cap):
    if not isinstance(value, list) or len(value) > cap:
        bad()
    return value


def rel_path(value):
    text(value, 512)
    if value.startswith("~") or any(c in value for c in ":\\%#?"):
        bad()
    if any(seg in ("", ".", "..") for seg in value.split("/")):
        bad()
    return value


def no_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            bad()
        out[k] = v
    return out


def normalize(doc):
    keys(doc, ("schema_version", "roots", "projects"))
    if type(doc["schema_version"]) is not int or doc["schema_version"] != 1:
        bad()
    roots, seen = [], set()
    for r in array(doc["roots"], MAX_ROOTS):
        keys(r, ("id", "label", "kind"))
        if not isinstance(r["id"], str) or not ID_RE.fullmatch(r["id"]) or r["id"] in seen:
            bad()
        if r["kind"] not in ("repo", "vault"):
            bad()
        seen.add(r["id"])
        roots.append({"id": r["id"], "label": text(r["label"], 120), "kind": r["kind"]})
    projects, ids = [], set()
    for p in array(doc["projects"], MAX_PROJECTS):
        keys(p, ("id", "title"), ("summary", "bot_ids", "sources", "related_files"))
        if not isinstance(p["id"], str) or not ID_RE.fullmatch(p["id"]) or p["id"] in ids:
            bad()
        ids.add(p["id"])
        out = {"id": p["id"], "title": text(p["title"], 120)}
        if "summary" in p:
            out["summary"] = None if p["summary"] is None else text(p["summary"], 1000)
        bots = array(p.get("bot_ids", []), MAX_BOTS)
        if any(not isinstance(b, str) or not BOT_RE.fullmatch(b) for b in bots) or len(set(bots)) != len(bots):
            bad()
        out["bot_ids"] = list(bots)
        sources = []
        for s in array(p.get("sources", []), MAX_SOURCES):
            keys(s, ("provider", "source"))
            sources.append({"provider": text(s["provider"], 120), "source": text(s["source"], 120)})
        if len({(s["provider"], s["source"]) for s in sources}) != len(sources):
            bad()
        out["sources"] = sources
        files = []
        for f in array(p.get("related_files", []), MAX_FILES):
            keys(f, ("root", "path"))
            if not isinstance(f["root"], str) or f["root"] not in seen:
                bad()
            files.append({"root": f["root"], "path": rel_path(f["path"])})
        if len({(f["root"], f["path"]) for f in files}) != len(files):
            bad()
        out["related_files"] = files
        projects.append(out)
    return {"schema_version": 1, "configured": True, "roots": roots, "projects": projects}


def read_catalog_bytes(filename):
    """Open `filename` with descriptor-based no-follow traversal and return at most MAX_BYTES."""
    if not supported() or not isinstance(filename, str) or "\0" in filename or not os.path.isabs(filename):
        bad()
    parts = filename.split("/")[1:]
    if not parts or any(p in ("", ".", "..") for p in parts):
        bad()
    repo = os.stat(REPO_ROOT)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    fd = os.open("/", flags | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            nxt = os.open(part, flags | os.O_DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = nxt
            if os.path.samestat(os.fstat(fd), repo):
                bad()
        # Avoid even opening a non-regular file. Recheck the opened inode in case of concurrent replacement.
        approved = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        if not valid_file(approved):
            bad()
        nxt = os.open(parts[-1], flags, dir_fd=fd)
        os.close(fd)
        fd = nxt
        opened = os.fstat(fd)
        if not valid_file(opened) or not os.path.samestat(opened, approved):
            bad()
        chunks, total = [], 0
        while total <= MAX_BYTES:
            chunk = os.read(fd, MAX_BYTES + 1 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > MAX_BYTES:
            bad()
        return b"".join(chunks)
    finally:
        os.close(fd)


def valid_file(st):
    return stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_size <= MAX_BYTES


def catalog_response():
    """Return (status, body_bytes). Reads the file only when the setting is present."""
    if SETTING not in os.environ:
        return 200, json.dumps(UNCONFIGURED, separators=(",", ":")).encode()
    try:
        raw = read_catalog_bytes(os.environ[SETTING])
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=no_dupes,
                         parse_constant=lambda _c: bad())
        body = json.dumps(normalize(doc), separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(body) > MAX_BYTES:
            bad()
        return 200, body
    except (CatalogError, OSError, ValueError, TypeError, RecursionError, MemoryError, KeyError):
        return 503, json.dumps(UNAVAILABLE).encode()
