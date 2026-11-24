"""What the phone is allowed to see of a Hermes transcript, plus skill notes and slash metadata.

The desktop app reads tool arguments, display titles and file paths straight out of the session.
The phone gets a bounded projection of the same facts: a command, a skill name, a delegate's goal,
whether it failed, and an image that already lives under the Hermes home. It does not get reasoning,
raw argument blobs, or a path the session did not already name.
"""
import hashlib
import json
import os
import re
from pathlib import Path

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"}
FILE_EXT = IMAGE_EXT | {".pdf", ".txt", ".md", ".json", ".csv"}
MAX_MEDIA = 8 * 1024 * 1024
_CREATE = re.compile(r"^[a-z0-9][a-z0-9-]{1,40}$")
_SKIP_COMMANDS = {"approve", "deny"}
_ARG_KEYS = ("command", "code", "query", "search_term", "path", "file", "filepath",
             "name", "skill", "goal", "url", "prompt")
_TASK = re.compile(r"^---\s*([✓✗⚠])\s*TASK\s+\d+/\d+:?\s*(.*?)\s*\(status=([a-z_]+)", re.M)
_IMAGE_AT = re.compile(r"\[Image attached at:\s*([^\]\n]+?)\s*\]")
_MEDIA = re.compile(r"(?m)^[ \t]*MEDIA:\s*(\"[^\"]+\"|\S+)\s*$")
_MD_IMAGE = re.compile(r"!\[[^\]]*\]\((?:file://)?(/[^)\s]+)\)")
_FAILED = ("failed", "error", "cancelled", "canceled", "interrupted", "timeout", "stalled", "rejected")
_FALLBACK = [
    {"name": "learn", "description": "Learn a reusable skill from what you describe, a URL, or this chat",
     "hint": "<what to learn from>", "category": "Tools & Skills"},
    {"name": "reload-skills", "description": "Rescan skill folders", "hint": "", "category": "Tools & Skills"},
    {"name": "memory", "description": "Review what Hermes remembers", "hint": "", "category": "Tools & Skills"},
    {"name": "bundles", "description": "List skill bundles", "hint": "", "category": "Tools & Skills"},
    {"name": "status", "description": "Session and gateway status", "hint": "", "category": "Status"},
    {"name": "agents", "description": "Background tasks for this chat", "hint": "", "category": "Status"},
    {"name": "usage", "description": "Token use for this chat", "hint": "", "category": "Status"},
    {"name": "context", "description": "How full this chat is", "hint": "", "category": "Session"},
    {"name": "compress", "description": "Summarize earlier turns to free context", "hint": "", "category": "Session"},
    {"name": "goal", "description": "Set or show the goal for this chat", "hint": "<goal>", "category": "Session"},
    {"name": "plan", "description": "Plan before changing anything", "hint": "", "category": "Session"},
    {"name": "review", "description": "Review the current work", "hint": "", "category": "Session"},
    {"name": "btw", "description": "A side question that does not steer the chat", "hint": "<question>", "category": "Session"},
    {"name": "title", "description": "Rename this chat", "hint": "<title>", "category": "Session"},
    {"name": "model", "description": "Show or change the model", "hint": "", "category": "Session"},
    {"name": "reasoning", "description": "Show or change reasoning effort", "hint": "", "category": "Session"},
    {"name": "help", "description": "Commands Hermes can run from this chat", "hint": "", "category": "Help"},
]


def hermes_home():
    return Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))


def content_text(body):
    if isinstance(body, list):
        body = "\n".join(p["text"] for p in body if isinstance(p, dict) and isinstance(p.get("text"), str))
    return body if isinstance(body, str) else ""


def _clip(text, limit):
    text = " ".join((text or "").split())
    return text[:limit]


def _one_line(text):
    line = (text or "").strip().splitlines()
    return line[0].strip() if line else ""


def _failed_result(text):
    line = text.lstrip().lower()
    if line.startswith(("error", "traceback", "exception", "failed")):
        return True
    return '"is_error": true' in line or '"status": "error"' in line


def _arg_preview(raw):
    if not isinstance(raw, str) or len(raw) > 20000 or not raw.strip().startswith("{"):
        return ""
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return ""
    if not isinstance(data, dict):
        return ""
    tasks = data.get("tasks")
    if isinstance(tasks, list):
        goals = [_clip(task.get("goal"), 80) for task in tasks[:4]
                 if isinstance(task, dict) and isinstance(task.get("goal"), str) and task.get("goal").strip()]
        if goals:
            text = "; ".join(goals[:3])
            if len(tasks) > 3:
                text += " · %d tasks" % len(tasks)
            return text[:180]
    for key in _ARG_KEYS:
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            return _clip(val, 160)
    return ""


def _tool_calls(calls):
    rows = []
    if not isinstance(calls, list):
        return rows
    for call in calls:
        if not isinstance(call, dict):
            continue
        fn = call.get("function")
        if not isinstance(fn, dict) or not isinstance(fn.get("name"), str):
            continue
        row = {"function": {"name": fn["name"]}}
        preview = _arg_preview(fn.get("arguments"))
        if preview:
            row["preview"] = preview
        rows.append(row)
    return rows


def _activity(kind, body):
    """A desktop notice title, plus the task lines worth opening. The model wall stays off the phone."""
    tasks = _TASK.findall(body or "")
    if tasks:
        titles, labels = [], []
        for icon, goal, status in tasks:
            failed = icon == "✗" or status in _FAILED
            labels.append("Failed" if failed else "Completed")
            titles.append(_clip(goal, 80) or "Background task")
        if len(tasks) == 1:
            title = "Subagent task %s: %s" % (labels[0].lower(), titles[0])
        else:
            outcome = labels[0].lower() if len(set(labels)) == 1 else "finished with issues"
            title = "Subagent tasks %s: %s (%d tasks)" % (outcome, _clip("; ".join(titles), 100), len(tasks))
        lines = []
        for icon, goal, status in tasks:
            failed = icon == "✗" or status in _FAILED
            lines.append("%s · %s" % ("Failed" if failed else "Done", _clip(goal, 120) or status))
        return _clip(title, 180), "\n".join(lines)[:800], any(label == "Failed" for label in labels)
    header = _one_line(body) or "Background work finished"
    if header.startswith("["):
        header = "Background work finished"
    detail = "\n".join((body or "").splitlines()[:8])[:800]
    return _clip(header, 180), detail, any(word in (body or "").lower() for word in ("status=failed", "✗"))


def _is_wall(text):
    opened = text.lstrip()
    return opened.startswith(("[ASYNC DELEGATION", "[BACKGROUND PROCESS", "[PROCESS COMPLETE", "[SUBAGENT"))


def safe_file(raw, roots):
    """A regular file the session already named, still inside a Hermes home, and small enough to preview."""
    text = (raw or "").strip().strip("\"'").strip()
    if text.startswith("file://"):
        text = text[7:]
    if not text.startswith("/") or "\x00" in text:
        return None
    try:
        real = Path(text).resolve()
        size = real.stat().st_size
    except OSError:
        return None
    if not real.is_file() or real.suffix.lower() not in FILE_EXT or size <= 0 or size > MAX_MEDIA:
        return None
    for root in roots:
        try:
            base = Path(root).resolve()
        except OSError:
            continue
        if real == base or base in real.parents:
            return real
    return None


def _digest(path):
    return hashlib.sha256(str(path).encode()).hexdigest()


def _refs(text, roots):
    """Attachment markers in transcript text. Only a file that resolves inside the roots is removed."""
    found = []
    seen = set()

    def take(raw):
        path = safe_file(raw, roots)
        if path is None or path in seen:
            return raw if path is None else ""
        seen.add(path)
        if len(found) < 6:
            found.append({"name": path.name, "digest": _digest(path),
                          "kind": "image" if path.suffix.lower() in IMAGE_EXT else "file"})
        return ""

    cleaned = _IMAGE_AT.sub(lambda m: take(m.group(1)), text or "")
    cleaned = _MEDIA.sub(lambda m: take(m.group(1)), cleaned)
    cleaned = _MD_IMAGE.sub(lambda m: take(m.group(1)), cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned, found


def file_for_digest(texts, digest, roots):
    """The file a timeline digest pointed at, re-derived from this session's own messages."""
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        return None
    for text in texts:
        for match in _IMAGE_AT.findall(text or "") + _MEDIA.findall(text or "") + _MD_IMAGE.findall(text or ""):
            path = safe_file(match, roots)
            if path is not None and _digest(path) == digest:
                return path
    return None


def project_timeline_message(message, roots=None):
    """One mobile timeline row. Hidden diagnostics disappear. Delegation walls become activity cards."""
    if not isinstance(message, dict):
        return None
    kind = message.get("display_kind") or ""
    if kind == "hidden":
        return None
    roots = list(roots) if roots is not None else [hermes_home()]
    role = message.get("role") or "assistant"
    body = content_text(message.get("content"))
    shown, media = _refs(body, roots)
    row = {k: message[k] for k in ("id", "timestamp") if k in message}
    if media:
        row["media"] = media
    wall = kind in ("async_delegation_complete", "process_complete") or _is_wall(shown)
    if wall:
        title, detail, failed = _activity(kind, body)
        row.update(role="system", display_kind=kind or "async_delegation_complete",
                   notice=title, content=detail, ok=not failed)
        return row
    if role == "assistant":
        calls = _tool_calls(message.get("tool_calls"))
        if calls:
            row["tool_calls"] = calls
        if shown:
            row["content"] = shown
        elif not calls and not media:
            return None
        row["role"] = "assistant"
        return row
    if role == "tool":
        preview = _clip(_one_line(shown), 120)
        row["role"] = "tool"
        if message.get("tool_name"):
            row["tool_name"] = str(message["tool_name"])[:80]
        if preview:
            row["preview"] = preview
        row["ok"] = not _failed_result(shown)
        return row
    if role == "user":
        if not shown and not media:
            return None
        row["role"] = "user"
        if shown:
            row["content"] = shown
        return row
    return None


def phone_commands():
    """Gateway commands worth a composer menu. CLI-only and approval buttons stay out."""
    try:
        from hermes_cli.commands import COMMAND_REGISTRY
    except Exception:
        return list(_FALLBACK)
    rows, seen = [], set()
    for cmd in COMMAND_REGISTRY:
        name = getattr(cmd, "name", "") or ""
        if not name or name in seen or "_" in name or name in _SKIP_COMMANDS or getattr(cmd, "cli_only", False):
            continue
        seen.add(name)
        rows.append({"name": name, "description": str(getattr(cmd, "description", "") or "")[:180],
                     "hint": str(getattr(cmd, "args_hint", "") or "")[:80],
                     "category": str(getattr(cmd, "category", "") or "General")[:40]})
    return rows or list(_FALLBACK)


def _skill_name_ok(name):
    return (isinstance(name, str) and bool(name) and name not in (".", "..") and len(name) <= 60
            and "/" not in name and "\\" not in name and "\x00" not in name and not name.startswith("."))


def skill_names(home, limit=24):
    """Skill directory names under this profile, then the shared Hermes home. One or two levels deep."""
    found, seen = [], set()
    roots = [Path(home) / "skills"]
    shared = hermes_home() / "skills"
    if shared not in roots:
        roots.append(shared)

    def add(name):
        if _skill_name_ok(name) and name not in seen and len(found) < limit:
            seen.add(name)
            found.append(name)

    for root in roots:
        if not root.is_dir():
            continue
        try:
            children = sorted(root.iterdir(), key=lambda p: p.name)
        except OSError:
            continue
        for child in children:
            if not child.is_dir() or child.name.startswith("."):
                continue
            if (child / "SKILL.md").is_file():
                add(child.name)
            else:
                try:
                    nested = sorted(child.iterdir(), key=lambda p: p.name)
                except OSError:
                    continue
                for item in nested:
                    if item.is_dir() and not item.name.startswith(".") and (item / "SKILL.md").is_file():
                        add(item.name)
            if len(found) >= limit:
                return found
    return found


def _inside(root, path):
    try:
        base, real = Path(root).resolve(), Path(path).resolve()
    except OSError:
        return False
    return real == base or base in real.parents


def _find_skill(home, name):
    if not _skill_name_ok(name):
        raise ValueError("That skill name is not allowed.")
    roots = [Path(home) / "skills", hermes_home() / "skills"]
    for root in roots:
        if not root.is_dir():
            continue
        direct = root / name / "SKILL.md"
        candidates = [direct] if direct.is_file() else []
        try:
            for category in sorted(root.iterdir(), key=lambda p: p.name):
                nested = category / name / "SKILL.md"
                if category.is_dir() and nested.is_file():
                    candidates.append(nested)
        except OSError:
            continue
        for path in candidates:
            if _inside(root, path):
                return path.resolve()
    raise ValueError("That skill is not on this bot.")


def _guard(directory):
    """Hermes's own skill scanner. A dangerous verdict deletes nothing by itself; the caller reverts."""
    try:
        from tools.skills_guard import scan_skill
    except Exception:
        return ""
    try:
        result = scan_skill(directory, source="local")
    except Exception:
        return ""
    if getattr(result, "verdict", "") == "dangerous":
        return getattr(result, "summary", "") or "Hermes blocked this skill."
    return ""


def _frontmatter(name, description, body):
    description = _clip(description or body, 200).replace("---", "—")
    quoted = '"' + description.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return "---\nname: %s\ndescription: %s\n---\n\n%s\n" % (name, quoted, body.strip())


def create_skill(home, name, description, body):
    if not _CREATE.fullmatch(name or ""):
        raise ValueError("Use a short lowercase name, like print-plates.")
    text = (body or "").strip()
    if len(text) < 8 or len(text) > 20000:
        raise ValueError("Write the skill in a few sentences.")
    root = Path(home) / "skills"
    root.mkdir(parents=True, exist_ok=True)
    dest = root / name
    if not _inside(root, dest):
        raise ValueError("That skill name is not allowed.")
    try:
        dest.mkdir(mode=0o700)
    except FileExistsError:
        raise ValueError("That skill already exists. Append a note instead.")
    path = dest / "SKILL.md"
    path.write_text(_frontmatter(name, description, text), encoding="utf-8")
    os.chmod(path, 0o600)
    blocked = _guard(dest)
    if blocked:
        path.unlink(missing_ok=True)
        dest.rmdir()
        raise ValueError(blocked)
    return {"name": name, "action": "created"}


def append_skill(home, name, note):
    text = (note or "").strip()
    if len(text) < 2 or len(text) > 8000:
        raise ValueError("Write the note you want to add.")
    path = _find_skill(home, name)
    previous = path.read_text(encoding="utf-8")
    addition = "\n\n## Added from iPhone\n\n%s\n" % text
    path.write_text(previous + addition, encoding="utf-8")
    blocked = _guard(path.parent)
    if blocked:
        path.write_text(previous, encoding="utf-8")
        raise ValueError(blocked)
    return {"name": name, "action": "appended"}


def public_slash(result):
    """The fields a composer can show. Worker output is capped; nothing else is forwarded."""
    if not isinstance(result, dict):
        return {"output": ""}
    out = {}
    for key in ("output", "warning", "type", "message", "display", "notice", "status", "name"):
        val = result.get(key)
        if isinstance(val, str) and val.strip():
            out[key] = val[:8000]
    return out
