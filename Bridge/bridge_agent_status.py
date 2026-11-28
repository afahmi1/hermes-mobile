"""Read-only chat identity and model metadata shared by the dashboard and phone bridge."""
from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path


_SOURCE_LABELS = {
    "local": "Desktop", "desktop": "Desktop", "gui": "Desktop",
    "tui": "CLI", "cli": "CLI", "oneshot": "CLI",
    "bluebubbles": "iMessage", "imessage": "iMessage", "api_server": "API",
    "hermes_browser": "Browser", "web": "Browser", "phone": "Phone",
    "cron": "Cron", "subagent": "Subagent",
}


def source_label(source):
    key = (source or "").removeprefix("gateway:")
    if not key or key == "gateway":
        return None
    return _SOURCE_LABELS.get(key, key.replace("_", " ").replace("-", " ").title())


def _text(value):
    return value.strip() if isinstance(value, str) and value.strip() else None


def _mapping(value):
    return value if isinstance(value, dict) else {}


def title_snippet(value, length=88):
    text = " ".join((value or "").split())
    return (text[:length - 1].rstrip() + "…" if len(text) > length else text) or None


class AgentSessions:
    """Resolve only the indexed sessions needed for the active rows; never open a writable DB."""

    def __init__(self, home: Path, default_model=None, default_provider=None):
        self.db = home / "state.db"
        self.defaults = (default_model, default_provider)
        self._by_id = {}

    def query(self, sql, params):
        if not self.db.is_file():
            return []
        try:
            with closing(sqlite3.connect(self.db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)) as con:
                con.row_factory = sqlite3.Row
                return [dict(row) for row in con.execute(sql, params)]
        except sqlite3.Error:
            # Optional tables/fields may not exist on older Hermes builds.
            return []

    def by_id(self, sid):
        if not sid:
            return {}
        if sid not in self._by_id:
            self._by_id[sid] = next(iter(self.query("SELECT * FROM sessions WHERE id=?", (sid,))), {})
        return self._by_id[sid]

    def _ancestry(self, row, skip_workers=False):
        """Skip nested workers to find their chat, then follow only compression (not forks or resets)."""
        chain, seen = [], set()
        while row and row["id"] not in seen:
            seen.add(row["id"])
            parent = self.by_id(row.get("parent_session_id"))
            if not skip_workers or row.get("source") != "subagent":
                chain.append(row)
                if parent.get("end_reason") != "compression" or parent.get("source") == "subagent":
                    break
            row = parent
        return chain

    def _resolve(self, sid, metadata):
        # Desktop leases can carry a logical route in session_id and a different live/storage ID.
        # Gateway leases carry the route key in both fields; chat_id is only used as an exact ID.
        keys = tuple(dict.fromkeys(k for k in (_text(metadata.get("live_session_id")), _text(sid)) if k))
        row = next((row for key in keys if (row := self.by_id(key))), {})
        if not row:
            for key in keys:
                row = next(iter(self.query("SELECT * FROM sessions WHERE session_key=? "
                                           "ORDER BY ended_at IS NOT NULL, started_at DESC LIMIT 1", (key,))), {})
                if row:
                    break
        if not row:
            row = self.by_id(_text(metadata.get("chat_id")))
        # A handle can still name the last segment while a turn runs in its compression successor.
        seen = set()
        while row.get("end_reason") == "compression" and row["id"] not in seen:
            seen.add(row["id"])
            children = self.query("SELECT * FROM sessions WHERE parent_session_id=? AND source IS ? "
                                  "ORDER BY ended_at IS NOT NULL, started_at DESC LIMIT 1",
                                  (row["id"], row.get("source")))
            if not children or children[0]["id"] in seen:
                break
            row = children[0]
        return row

    def first_user(self, sid):
        rows = self.query("SELECT substr(content, 1, 500) AS content FROM messages WHERE session_id=? "
                          "AND role='user' AND length(trim(content, ' ' || char(9,10,13))) > 0 "
                          "ORDER BY id LIMIT 1", (sid,))
        return title_snippet(rows[0]["content"], 300) if rows else None

    def _title(self, chain, label, *, root_first=False):
        for row in reversed(chain) if root_first else chain:
            if title := _text(row.get("title")):
                return title
        for row in reversed(chain):
            if text := self.first_user(row["id"]):
                return title_snippet(text)
        return f"{label} chat" if label and label != "CLI" else label or "Chat"

    def model_route(self, row, metadata, started_at):
        """Prefer the live override and real replies, not auxiliary title/compression model calls."""
        try:
            config = _mapping(json.loads(row.get("model_config") or "{}"))
        except (TypeError, ValueError):
            config = {}
        runtime = _mapping(config.get("gateway_runtime"))
        usage = {}
        if row and isinstance(started_at, (int, float)):
            usage = next(iter(self.query(
                "SELECT model, billing_provider FROM session_model_usage WHERE session_id=? "
                "AND coalesce(task, '')='' AND last_seen>=? ORDER BY last_seen DESC LIMIT 1",
                (row["id"], started_at))), {})
        routes = [(_text(d.get("model")), _text(d.get("provider")) or _text(d.get("billing_provider")))
                  for d in (metadata, usage, runtime, row)]
        default_model, default_provider = self.defaults
        routes.append((_text(default_model), _text(default_provider)))
        model = next((m for m, _ in routes if m), None)
        provider = next((p for m, p in routes if p and (m == model or m is None)), None)
        return {"model": model, "provider": provider}

    def chat(self, sid, *, metadata=None, surface=None, started_at=None):
        metadata = _mapping(metadata)
        row = self._resolve(sid, metadata)
        chain = self._ancestry(row)
        label = source_label(metadata.get("platform")) or source_label(surface) or source_label(row.get("source"))
        return {
            "session_id": row.get("id"), "title": self._title(chain, label),
            "source": row.get("source") or metadata.get("platform"), "source_label": label,
            **self.model_route(row, metadata, started_at),
        }

    def parent_title(self, subagent):
        chain = self._ancestry(subagent, skip_workers=True)
        if chain:
            return self._title(chain, source_label(chain[-1].get("source")), root_first=True)
        return None


def with_phone_turns(payload, turns, profile_home):
    """The bridge may be tracking a phone reply before/without a gateway registry lease."""
    agents = payload.setdefault("agents", [])
    bots = {b.get("id"): b for b in payload.get("bots", [])}
    for turn in turns:
        if turn["done"]:
            continue
        profile, sid = turn["profile"], turn["session_id"]
        bot = bots.get(profile, {})
        start = turn.get("started_at")
        sessions = AgentSessions(profile_home(profile), bot.get("model"), bot.get("provider"))
        info = sessions.chat(sid, surface="phone", started_at=start)
        chat_id = info["session_id"] or sid
        same = next((a for a in agents if a.get("kind") in ("chat", "phone") and a.get("profile") == profile
                     and a.get("session_id") in (sid, chat_id)), None)
        if same is not None:
            same.update(kind="phone", source_label="Phone")
        else:
            agents.append({**info, "kind": "phone", "profile": profile, "session_id": chat_id,
                           "started_at": datetime.fromtimestamp(start, timezone.utc).isoformat() if start else None,
                           "age_s": turn["age"]})
            if bot:
                bot["running"] = (bot.get("running") or 0) + 1
    return payload
