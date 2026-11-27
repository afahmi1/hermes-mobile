"""Hermes's own Projects (the desktop app's Projects view), read-only for the phone.

Hermes keeps them per profile in `$HERMES_HOME/projects.db` (hermes_cli/projects_db.py): a named
project owns one or more folders, and a chat belongs to the project whose folder holds the chat's
working directory (the longest folder wins, so nested projects resolve to the innermost one).

This module only reads that file. Creating, renaming and archiving stay in the desktop app. Folder
paths never leave the Mac except as a folder's last component, for display.
"""
import os
import sqlite3
import urllib.parse

ID_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789-_")


def _slug_ok(slug):
    return (isinstance(slug, str) and 0 < len(slug) <= 64 and slug[0] not in "-_"
            and set(slug) <= ID_CHARS)


def _norm(path):
    p = os.path.abspath(os.path.expanduser(str(path).strip()))
    return p.rstrip("/") or p


def _clean(value, limit):
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def db_path(home):
    return os.path.join(str(home), "projects.db")


def available(home):
    """Hermes has a projects database for this profile (the feature exists, even with no projects)."""
    return os.path.isfile(db_path(home))


def _open(path):
    """Read-only connection. Hermes keeps projects.db in WAL mode, and a read-only open can't create the
    `-shm` file WAL needs, so a database nobody has written to since the last checkpoint (no -wal file:
    every page is already in the main file) is opened as immutable instead."""
    uri = "file:%s?mode=ro" % urllib.parse.quote(path)
    try:
        con = sqlite3.connect(uri, uri=True, timeout=2)
        con.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        return con
    except sqlite3.Error:
        pass
    if os.path.exists(path + "-wal"):
        return None  # live writes pending: never read around them
    try:
        con = sqlite3.connect(uri + "&immutable=1", uri=True, timeout=2)
        con.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        return con
    except sqlite3.Error:
        return None


def load(home):
    """Non-archived projects, oldest first: [{slug, name, description, primary, folders}]. [] when the
    database is missing, unreadable or from a schema this reader doesn't know."""
    path = db_path(home)
    if not os.path.isfile(path):
        return []
    con = _open(path)
    if con is None:
        return []
    try:
        con.row_factory = sqlite3.Row
        cols = {r[1] for r in con.execute("PRAGMA table_info(projects)")}
        if not {"id", "slug", "name"} <= cols:
            return []
        where = " WHERE archived = 0" if "archived" in cols else ""
        order = " ORDER BY created_at ASC" if "created_at" in cols else ""
        extra = "".join(", " + c for c in ("description", "primary_path") if c in cols)
        rows = con.execute("SELECT id, slug, name%s FROM projects%s%s" % (extra, where, order)).fetchall()
        folders = {}
        try:
            for r in con.execute("SELECT project_id, path, is_primary FROM project_folders "
                                 "ORDER BY is_primary DESC, added_at ASC"):
                folders.setdefault(r["project_id"], []).append(_norm(r["path"]))
        except sqlite3.Error:
            pass
    except sqlite3.Error:
        return []
    finally:
        con.close()
    out, seen = [], set()
    for r in rows:
        slug = r["slug"]
        if not _slug_ok(slug) or slug in seen:
            continue
        seen.add(slug)
        keys = r.keys()
        own = folders.get(r["id"], [])
        primary = _norm(r["primary_path"]) if "primary_path" in keys and r["primary_path"] else (own[0] if own else None)
        if primary and primary not in own:
            own = [primary] + own
        out.append({"slug": slug, "name": _clean(r["name"], 120) or slug,
                    "description": _clean(r["description"], 1000) if "description" in keys else None,
                    "primary": primary, "folders": own})
    return out


def owns(folder, path):
    stem = folder.rstrip("/")
    return path == folder or path.startswith(stem + "/")


def owner(projects, cwd):
    """The slug of the project owning `cwd`, or None. Same rule as Hermes's project_for_path."""
    if not isinstance(cwd, str) or not cwd.strip():
        return None
    target = _norm(cwd)
    best = None
    for p in projects:
        for folder in p["folders"]:
            if owns(folder, target) and (best is None or len(folder) > len(best[0])):
                best = (folder, p["slug"])
    return best[1] if best else None


def find(projects, slug):
    return next((p for p in projects if p["slug"] == slug), None)


def start_folder(project):
    """Where a new chat in this project starts: its main folder, or None when it no longer exists."""
    for folder in ([project.get("primary")] if project.get("primary") else []) + project.get("folders", []):
        if folder and os.path.isabs(folder) and os.path.isdir(folder):
            return folder
    return None


def catalog_entry(project, chats=None):
    """The phone's Project shape (bridge_projects schema V1) plus a `hermes` block. Read-only."""
    folder = project.get("primary")
    info = {"folder": os.path.basename(folder) if folder else None, "folders": len(project["folders"])}
    if chats is not None:
        info["chats"] = chats
    return {"id": project["slug"], "title": project["name"], "summary": project.get("description"),
            "bot_ids": [], "sources": [], "related_files": [], "managed": False, "hermes": info}


def session_ids(con, projects, slug, limit=200):
    """Ids of the chats (newest first) whose working directory belongs to `slug`. Chats are matched by
    folder prefix in SQL first, then confirmed with the longest-folder rule so a nested project keeps
    its own chats."""
    project = find(projects, slug)
    if project is None or not project["folders"]:
        return []
    cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
    if "cwd" not in cols:
        return []
    clauses, args = [], []
    for folder in project["folders"]:
        stem = folder.rstrip("/")
        clauses.append("(cwd = ? OR cwd = ? OR substr(cwd, 1, ?) = ?)")
        args += [folder, stem + "/", len(stem) + 1, stem + "/"]
    sql = ("SELECT id, cwd FROM sessions WHERE (%s) AND coalesce(hidden,0)=0 AND archived=0 "
           "AND coalesce(source,'') NOT IN ('subagent','tool','cron','oneshot') "
           "ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT %d") % (" OR ".join(clauses), int(limit) * 2)
    out = []
    for r in con.execute(sql, args):
        if owner(projects, r[1]) == slug:
            out.append(r[0])
            if len(out) >= limit:
                break
    return out


def chat_counts(con, projects):
    """{slug: number of chats} over every chat with a working directory."""
    counts = {p["slug"]: 0 for p in projects}
    if not projects:
        return counts
    cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
    if "cwd" not in cols:
        return counts
    for (cwd,) in con.execute("SELECT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd != '' "
                              "AND coalesce(hidden,0)=0 AND archived=0 "
                              "AND coalesce(source,'') NOT IN ('subagent','tool','cron','oneshot')"):
        slug = owner(projects, cwd)
        if slug:
            counts[slug] += 1
    return counts
