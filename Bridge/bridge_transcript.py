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
# Files a reply can hand to the phone. The phone opens them in Quick Look (documents, code, audio, video,
# 3D models) and can share or save them from there.
FILE_EXT = IMAGE_EXT | {
    ".pdf", ".txt", ".md", ".json", ".csv", ".tsv", ".log", ".rtf", ".html", ".htm", ".xml", ".svg",
    ".yaml", ".yml", ".toml", ".ini", ".py", ".js", ".ts", ".tsx", ".swift", ".sh", ".rb", ".go", ".rs",
    ".c", ".h", ".cpp", ".java", ".kt", ".sql", ".ipynb",
    ".docx", ".xlsx", ".pptx", ".pages", ".numbers", ".keynote", ".epub", ".zip",
    ".mp3", ".m4a", ".wav", ".aac", ".mp4", ".mov", ".m4v",
    ".stl", ".3mf", ".obj", ".usdz", ".step", ".stp",
}
MAX_MEDIA = 32 * 1024 * 1024
# Never hand these to a phone, whatever a message says: credentials, keys and private config.
_SECRET_DIRS = {".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure", ".gcloud", "keychains", ".password-store",
                ".netrc", ".config"}
_SECRET_NAMES = re.compile(r"(?i)(^|[._-])(auth|credential|credentials|secret|secrets|token|tokens|password|passwd|"
                           r"id_rsa|id_ed25519|id_ecdsa|cookies?|keystore)([._-]|$)|\.(pem|p12|pfx|key|env|db|sqlite3?)$")
_CREATE = re.compile(r"^[a-z0-9][a-z0-9-]{1,40}$")
_SKIP_COMMANDS = {"approve", "deny"}
_ARG_KEYS = ("command", "code", "query", "search_term", "path", "file", "filepath",
             "name", "skill", "goal", "url", "prompt")
_TASK = re.compile(r"^---\s*([✓✗⚠])\s*TASK\s+\d+/\d+:?\s*(.*?)\s*\(status=([a-z_]+)", re.M)
_IMAGE_AT = re.compile(r"\[Image attached at:\s*([^\]\n]+?)\s*\]")
# Hermes's own MEDIA tag grammar when it's importable (paths with spaces, `**MEDIA:/x.png**`, quotes, Windows
# drives); otherwise a close copy. The old one-token pattern dropped every path with a space ("3D Printing/…").
_MEDIA_FALLBACK = re.compile(
    r"""[`"'*_]{0,3}MEDIA:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/|[A-Za-z]:[/\\])[^\n]*?\."""
    r"""(?:png|jpe?g|gif|webp|heic|pdf|mp4|mov|m4a|mp3|wav|txt|md|csv|json|3mf|stl|zip|html?))(?=[\s`"'*_,;:)\]]|MEDIA:|$)[`"'*_]{0,3}""",
    re.IGNORECASE)
try:
    from gateway.platforms.base import MEDIA_TAG_CLEANUP_RE as _HERMES_MEDIA
except Exception:  # an older Hermes, or the bridge's tests without Hermes on the path
    _HERMES_MEDIA = None
_MEDIA = _HERMES_MEDIA or _MEDIA_FALLBACK


def _media_path(m):
    raw = m.groupdict().get("path") if m.re.groupindex else None
    raw = raw if raw is not None else m.group(1)
    return (raw or "").strip().strip("`\"'").strip()


# Where an image sat in a reply. Private-use, never typed; replaced by `content_parts` before the row leaves.
_ANCHOR, _ANCHOR_END = "\ue000", "\ue001"
_ANCHOR_RE = re.compile("\ue000(\\d+)\ue001")
_MD_IMAGE = re.compile(r"!\[[^\]]*\]\((?:file://)?(/[^)\s]+)\)")
# The bridge's own hand-off notes (bridge_turns._media_notes): files, clips, audio, and images sent with a steer.
# One line each, ending in a JSON-quoted path. The person never typed them, so the whole note goes.
# Images a message can show: the phone sends up to 20 (ChatMedia.maxAttachments).
MAX_REFS = 20
_BRIDGE_NOTE = re.compile(r"(?m)^[ \t]*The user (?:attached|sent) (?:an image|a file|a video clip|an audio file)\b"
                          r"(?: named (\"(?:[^\"\\\n]|\\.)*\"))?[^\n]*?"
                          r"Local file path: (\"(?:[^\"\\\n]|\\.)*\")[ \t]*$")
# The note for a photo sent as its original file (HEIC, PNG, a JPEG over the size cap): one line, the original's path
# after "It is saved at", then where its JPEG copy is. The original is what the phone shows (iOS decodes HEIC).
_PHOTO_NOTE = re.compile(r"(?m)^[ \t]*The user attached a photo named (\"(?:[^\"\\\n]|\\.)*\") \([^\n]*?\)\. "
                         r"It is saved at (\"(?:[^\"\\\n]|\\.)*\")\.[^\n]*$")
# Older desktop builds stored the model's image part after the text: a base64 data URL nobody should read.
_INLINE_DATA_PART = re.compile(r'\{"type":\s*"image_url",\s*"image_url":\s*\{"url":\s*"data:[^"]*"\s*(?:,[^{}]*)?\}\s*\}')
# Hermes's voice-note format: the transcript stays as the person's words, the recording becomes playable.
_AUDIO_NOTE = re.compile(r"\[User sent audio: ([^\]\n]+)\]")
# The CLI and desktop collapse a long paste into a file. The marker stays (it becomes a "Pasted N lines" note);
# the file is offered so the paste can actually be read on the phone.
_PASTE_NOTE = re.compile(r"\[Pasted text #\d+: \d+ lines? → ([^\]\n]+)\]")
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
    skills = _skill_ops(data)
    if skills:
        return skills
    for key in _ARG_KEYS:
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            return _clip(val, 160)
    return ""


_SKILL_VERBS = {"create": "created", "patch": "updated", "write_file": "wrote", "remove_file": "removed",
                "delete": "deleted", "edit": "updated"}


def _skill_ops(data):
    """What a skill_manage call did, readable: "created hermes-mobile-app; updated hermes-mobile-app/references/x.md".
    Hermes takes a list of operations (or one action on older builds), so the plain-key preview found nothing."""
    ops = data.get("operations")
    if not isinstance(ops, list):
        ops = [data] if isinstance(data.get("action"), str) and isinstance(data.get("name"), str) else []
    parts = []
    for op in ops[:3]:
        if not isinstance(op, dict) or not isinstance(op.get("action"), str) or not isinstance(op.get("name"), str):
            continue
        verb = _SKILL_VERBS.get(op["action"], op["action"].replace("_", " "))
        target = op["name"] + ("/" + op["file_path"] if isinstance(op.get("file_path"), str) and op["file_path"] else "")
        parts.append("%s %s" % (verb, target))
    if not parts:
        return ""
    text = "; ".join(parts)
    if len(ops) > 3:
        text += " · %d changes" % len(ops)
    return _clip(text, 180)


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


_PROC = re.compile(r"\[IMPORTANT: Background process (\S+) ([^\n(]*?)\s*"
                   r"\(exit code (-?\d+|None)[^)]*\)\.?\]?[^\n]*\n(?:(?!Command: )[^\n]*\n)*?Command: (.*?)(?:\nOutput:\n(.*?))?"
                   r"(?=\n\[IMPORTANT: Background process |\Z)", re.S)
_TASK_BLOCK = re.compile(r"^---\s*([✓✗⚠])\s*TASK\s+(\d+)/(\d+):?\s*(.*?)\s*\(status=([a-z_]+)"
                         r"(?:,\s*api_calls=(\d+))?(?:,\s*([\d.]+)s)?\)\s*-*\s*$\n?(.*?)(?=^---\s*[✓✗⚠]\s*TASK|\Z)", re.M | re.S)
_MODEL = re.compile(r"Model:\s*(\S+)")
# Older batch form: "- proc_x: exit_code=-15, reason=exited" followed by its output.
_PROC_LINE = re.compile(r"^- (proc_\w+): exit_code=(-?\d+), reason=(\w+)\n(.*?)(?=^- proc_\w+: exit_code=|\Z)", re.M | re.S)
# Early warning for one failed subagent while its siblings still run.
_TASK_EARLY = re.compile(r"^\[ASYNC DELEGATION TASK (FAILED|COMPLETE)[^\]]*task (\d+)/(\d+)\]", re.M)
_TASK_FIELD = re.compile(r"^(Task|Status|Duration|Error):\s*(.*)$", re.M)
# The delegation a wall reports on. Hermes keeps each subagent's tokens under this id (async_delegations).
_DELEGATION = re.compile(r"\b(deleg_[0-9a-f]{6,64})\b")
_INTERPRETERS = {"python", "python3", "bash", "sh", "zsh", "node", "bun", "deno", "ruby", "perl", "uv", "uvx", "npx",
                 "pnpm", "npm", "yarn", "swift", "go", "cargo", "make", "xcodebuild", "git", "gh", "hermes", "docker"}
_SKIP_PROGRAMS = {"cd", "mkdir", "export", "source", ".", "set", "sleep", "true", "echo", "cp", "mv", "rm", "env"}


def _seconds(text):
    try:
        s = float(text)
    except (TypeError, ValueError):
        return None
    if s < 60:
        return "%ds" % round(s)
    if s < 3600:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def command_label(command):
    """("build.py --mesh", "plate B") for a long shell line: the program that mattered and the folder it ran in."""
    import shlex
    cwd = ""
    label = ""
    for segment in re.split(r"\s*(?:&&|\|\||;|\n)\s*", command or ""):
        segment = segment.strip()
        if not segment:
            continue
        try:
            words = shlex.split(segment, posix=True)
        except ValueError:
            words = segment.split()
        while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] == "env"):
            if words[0] == "env":
                words.pop(0)
                while words and words[0].startswith("-"):
                    flag = words.pop(0)
                    if flag in ("-u", "-C", "-S") and words:
                        words.pop(0)
            else:
                words.pop(0)
        if not words:
            continue
        # Wrappers that only change how a command runs: name what they wrap.
        while words and os.path.basename(words[0]) in ("timeout", "gtimeout", "nohup", "time", "caffeinate", "exec", "sudo", "nice"):
            words.pop(0)
            while words and (words[0].startswith("-") or re.fullmatch(r"[\d.]+[smhd]?", words[0])):
                words.pop(0)
        if not words:
            continue
        program = os.path.basename(words[0])
        if program == "cd" and len(words) > 1:
            cwd = os.path.basename(words[1].rstrip("/")) or words[1]
            continue
        if program in _SKIP_PROGRAMS or program.startswith("for") or program in ("do", "done", "if", "then", "fi"):
            continue
        rest = []
        for w in words[1:]:
            if w in ("|", ">", ">>", "<", "2>", "&>") or re.match(r"^(\d?>|&>|<|\|)", w):
                break  # redirections and pipes end the part worth naming
            if len(w) > 24 and re.fullmatch(r"[0-9A-Fa-f-]+", w):
                continue  # device and run ids
            rest.append(w)
        base = re.sub(r"\d+(\.\d+)*$", "", program)
        if base in _INTERPRETERS and rest:
            script = next((w for w in rest if not w.startswith("-")), "")
            if script and ("/" in script or "." in script) and base not in ("git", "gh", "npm", "pnpm", "yarn", "cargo", "make", "docker", "hermes"):
                tail = rest[rest.index(script) + 1:]
                label = " ".join([os.path.basename(script)] + tail[:2])
            else:
                label = " ".join([program] + [w for w in rest[:3] if len(w) < 40])
        else:
            label = " ".join([program] + [w for w in rest[:2] if len(w) < 40 and not w.startswith("/")])
        break
    return _clip(label or _one_line(command) or "command", 64), _clip(cwd, 48)


def activity_details(body):
    """Structured cards for background work: one entry per command or subagent task, or None."""
    body = body or ""
    items = []
    for proc, how, code, command, output in _PROC.findall(body):
        code = int(code) if code != "None" else None
        label, cwd = command_label(command)
        out = (output or "").strip()
        stopped = code is None or code in (-15, -9, 137, 143)
        items.append({"type": "process", "id": proc, "exit_code": code,
                      "status": "ok" if code == 0 else ("stopped" if stopped else "failed"),
                      "label": label, "cwd": cwd, "command": command.strip()[:1500],
                      "output": out[-1500:] if len(out) > 1500 else out})
    if not items:
        for proc, code, reason, output in _PROC_LINE.findall(body):
            code = int(code)
            out = output.strip()
            killed = code in (-15, -9, 137, 143)
            items.append({"type": "process", "id": proc, "status": "ok" if code == 0 else ("stopped" if killed else "failed"),
                          "exit_code": code, "label": "Stopped by signal" if killed else "Background command",
                          "cwd": "", "command": "", "output": out[-1500:]})
    early = _TASK_EARLY.search(body)
    if early and not _TASK_BLOCK.search(body):
        fields = {}
        for key, value in _TASK_FIELD.findall(body):
            fields.setdefault(key, value.strip())
        status_word = (fields.get("Status") or "").split()[0] if fields.get("Status") else ""
        secs = re.search(r"Duration:\s*([\d.]+)s", body)
        failed = early.group(1) == "FAILED"
        items.append({"type": "task", "status": "failed" if failed else "ok", "state": status_word or None,
                      "label": _clip(fields.get("Task") or "Subagent task %s of %s" % (early.group(2), early.group(3)), 160),
                      "duration": _seconds(secs.group(1)) if secs else None, "api_calls": None, "model": None,
                      "output": _clip(fields.get("Error") or "", 600), "index": int(early.group(2)) - 1})
    model = _MODEL.search(body)
    for icon, index, total, goal, status, calls, secs, result in _TASK_BLOCK.findall(body):
        failed = icon == "✗" or status in _FAILED
        items.append({"type": "task", "status": "failed" if failed else ("ok" if icon == "✓" else "warning"),
                      "state": status, "label": _clip(goal, 160) or "Background task",
                      "duration": _seconds(secs), "api_calls": int(calls) if calls else None,
                      "model": model.group(1) if model else None,
                      "output": "\n".join(line for line in result.strip().splitlines() if line.strip())[:1200],
                      "index": int(index) - 1})
    if not items:
        return None
    delegation = _DELEGATION.search(body.split("\n", 1)[0]) or _DELEGATION.search(body[:2000])
    for item in items:
        if item["type"] == "task" and delegation:
            item["delegation"] = delegation.group(1)
    failed = sum(1 for item in items if item["status"] == "failed")
    stopped = sum(1 for item in items if item["status"] == "stopped")
    procs = [i for i in items if i["type"] == "process"]
    tasks = [i for i in items if i["type"] == "task"]
    if len(items) == 1:
        one = items[0]
        if one["type"] == "process":
            title = ("%s failed (exit %s)" % (one["label"], one["exit_code"]) if failed
                     else "%s was stopped" % one["label"] if stopped else "%s finished" % one["label"])
        else:
            title = ("Subagent failed: " if failed else "Subagent done: ") + _clip(one["label"], 90)
    else:
        parts = []
        if procs:
            parts.append("%d command%s" % (len(procs), "" if len(procs) == 1 else "s"))
        if tasks:
            parts.append("%d subagent task%s" % (len(tasks), "" if len(tasks) == 1 else "s"))
        title = (" and ".join(parts) + " finished" + (" · %d failed" % failed if failed else "")
                 + (" · %d stopped" % stopped if stopped else ""))
    return {"title": _clip(title, 180), "failed": bool(failed), "items": items[:12]}


def _activity(kind, body):
    """A desktop notice title, plus the task lines worth opening. The model wall stays off the phone."""
    rich = activity_details(body)
    if rich and any(item["type"] == "process" for item in rich["items"]):
        lines = ["%s · %s" % ("Failed" if i["status"] == "failed" else "Done", i["label"]) for i in rich["items"]]
        return rich["title"], "\n".join(lines)[:800], rich["failed"]
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


# Text the harness writes into user-role rows. The phone shows the person's own words as their bubble and
# everything else as a small system notice, never as something they said.
_OOB_HEAD = re.compile(r"^\s*\[OUT-OF-BAND USER MESSAGE[^\]\n]*\]\s*\n?")
_OOB_TAIL = re.compile(r"\n?\s*\[/OUT-OF-BAND USER MESSAGE\]\s*$")
_TRAILING_SYSTEM = re.compile(r"(?:\n\s*\[(?:System|SYSTEM|System note|Note)\s*:[^\]]*\]\s*)+$")
_SKILL_INVOKED = re.compile(r'^\s*\[(?:SYSTEM|IMPORTANT|System): The user has invoked the "([^"]+)" skill')
_MODEL_SWITCH = re.compile(r"^\s*\[Note: model was just switched from \S+ to (\S+?)(?: via ([^.\]]+))?\.[^\]]*\]\s*")
_REPLYING = re.compile(r'^\s*\[Replying to: "(.*?)"\]\s*', re.S)
_PASTED = re.compile(r"^\s*\[Pasted text #\d+: (\d+) lines? → [^\]]+\]\s*")
_SPEAKER = re.compile(r"^\s*\[(?!System|SYSTEM|Note|IMPORTANT)[A-Z][\w .'-]{0,30}\] ")
_NOTICES = (
    (re.compile(r"^\s*You've reached the maximum number of tool-calling iterations"), "Hermes hit its tool-call limit for this turn and wrapped up"),
    (re.compile(r"^\s*\[CONTEXT COMPACTION"), "Earlier turns were compacted into a summary"),
    (re.compile(r"^\s*\[Your active task list was preserved"), "Task list carried over after compaction"),
    (re.compile(r"^\s*\[System note: Your previous turn was interrupted"), "Resumed after an interruption"),
    (re.compile(r"^\s*\[System: Your previous response was truncated"), "Hermes continued a reply that ran long"),
    (re.compile(r"^\s*\[System: Your previous response contained only internal reasoning"), "Hermes was asked to answer instead of thinking"),
    (re.compile(r"^\s*\[IMPORTANT: MCP servers have been reloaded"), "Tool servers reloaded"),
    (re.compile(r"^\s*\[(?:System|SYSTEM|System note)\s*:"), "System note for Hermes"),
)


def classify_user_text(text, kind=""):
    """("user", words, note) for something the person wrote, or ("notice", title, "") for harness text."""
    body = text or ""
    skill = _SKILL_INVOKED.match(body)
    if skill:
        return "notice", "Loaded the %s skill" % skill.group(1), ""
    if re.match(r"^\s*\[STILL IN PROGRESS", body):
        return "notice", "Your earlier request carried over after compaction", ""
    for pattern, title in _NOTICES:
        if pattern.match(body):
            return "notice", title, ""
    notes = []
    if _OOB_HEAD.match(body) or kind == "steer":
        body = _OOB_TAIL.sub("", _OOB_HEAD.sub("", body, count=1))
        notes.append("Sent while Hermes was working")
    if "[Recent channel messages]" in body and "[New message]" in body:
        body = body.split("[New message]", 1)[1]
    m = _MODEL_SWITCH.match(body)
    if m:
        notes.append("Model switched to %s" % m.group(1).rstrip("/").rsplit("/", 1)[-1])
        body = body[m.end():]
    m = _REPLYING.match(body)
    if m:
        notes.append("Replying to “%s”" % _clip(m.group(1), 60))
        body = body[m.end():]
    m = _PASTED.match(body)
    if m:
        notes.append("Pasted %s lines" % m.group(1))
        body = body[m.end():]
    if body.lstrip().startswith("[The user sent an image"):
        cut = body.find("\n\n")
        notes.append("Sent an image")
        body = body[cut + 2:] if cut >= 0 else ""
    body = _SPEAKER.sub("", body, count=1)
    body = _TRAILING_SYSTEM.sub("", body).strip()
    if notes and body != (text or "").strip():
        # A model-switch or reply note can sit in front of harness text: classify what is left.
        verdict, inner, _ = classify_user_text(body)
        if verdict == "notice" or _is_wall(body):
            return "notice", inner if verdict == "notice" else "Background work finished", ""
    return "user", body, " · ".join(notes)


def _is_wall(text):
    opened = text.lstrip()
    return (opened.startswith(("[ASYNC DELEGATION", "[BACKGROUND PROCESS", "[PROCESS COMPLETE", "[SUBAGENT"))
            or re.match(r"\[IMPORTANT: (\d+ )?background (process|subagent)", opened, re.I) is not None)


def _sensitive(path, base):
    """True for credentials and private config anywhere under a root (a dotted folder other than .hermes)."""
    if _SECRET_NAMES.search(path.name):
        return True
    try:
        parts = path.relative_to(base).parts[:-1]
    except ValueError:
        return True
    # A Hermes home (or a profile inside it) keeps config.yaml, .env and auth at its top level: never served.
    try:
        home = hermes_home().resolve()
    except OSError:
        home = None
    if home is not None and (path.parent == home or path.parent.parent == home / "profiles"):
        return True
    for part in parts:
        low = part.lower()
        if low in _SECRET_DIRS or (low.startswith(".") and low not in (".hermes", ".t3")):
            return True
    return False


def safe_file(raw, roots):
    """A regular file the session already named, still inside an allowed root, not a secret, and small enough."""
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
        if (real == base or base in real.parents) and not _sensitive(real, base):
            return real
    return None


def desktop_attachment_roots():
    """Where the Hermes desktop app keeps what you attach in its composer, on each OS. Your own messages may
    show files from here on the phone (images you dropped in, long pastes), like the Hermes home."""
    home = Path.home()
    bases = [home / "Library" / "Application Support" / "Hermes", home / ".config" / "Hermes"]
    appdata = os.environ.get("APPDATA")
    if appdata:
        bases.append(Path(appdata) / "Hermes")
    return [base / name for base in bases for name in ("composer-images", "composer-pastes")]


def _digest(path):
    return hashlib.sha256(str(path).encode()).hexdigest()


def _json_path(raw):
    try:
        value = json.loads(raw)
    except ValueError:
        return None
    return value if isinstance(value, str) else None


def _marker_paths(text):
    """Every path an attachment marker in this text names (what _refs would offer), in order."""
    text = text or ""
    paths = _IMAGE_AT.findall(text) + [_media_path(m) for m in _MEDIA.finditer(text)] + _MD_IMAGE.findall(text)
    paths += [p for p in (_json_path(raw) for _, raw in _BRIDGE_NOTE.findall(text)) if p]
    paths += [p for p in (_json_path(raw) for _, raw in _PHOTO_NOTE.findall(text)) if p]
    paths += mentioned_images(text)
    return paths + _AUDIO_NOTE.findall(text) + _PASTE_NOTE.findall(text)


def _refs(text, roots, bare=False):
    """Attachment markers in transcript text. Only a file that resolves inside the roots is removed.

    `bare` (Hermes's own replies): an image named by a plain path ("~/Runs/plate.png", backticked or not) also
    shows, right under the line that names it; the path text stays. Inside a code block or a table the image
    waits until the block ends, so neither breaks."""
    found = []
    seen = set()

    def take(raw, keep=None, gone="", label=None, anchor=False):
        # `keep` is the text a marker leaves when its file can't be offered; `gone` what it leaves when it can.
        # `anchor`: Hermes put this file at a spot in its reply; remember the spot so the phone shows it there.
        path = safe_file(raw, roots) if raw else None
        if path is None:
            return raw if keep is None else keep
        if path in seen:
            return gone
        seen.add(path)
        if len(found) < MAX_REFS:
            if anchor:
                gone = "\n%s%d%s\n" % (_ANCHOR, len(found), _ANCHOR_END)
            shown = label.strip() if isinstance(label, str) and label.strip() and "/" not in label and "\\" not in label else path.name
            if Path(shown).suffix.lower() != path.suffix.lower():
                # The phone opens it by this name, so the extension must be the file's (a HEIC staged as JPEG).
                shown = (Path(shown).stem or path.stem) + path.suffix
            found.append({"name": shown.strip()[:120], "digest": _digest(path),
                          "kind": "image" if path.suffix.lower() in IMAGE_EXT else "file"})
        return gone

    def gone_note(m):
        name = _json_path(m.group(1)) if m.group(1) else None
        return "📎 " + name if name else ""

    cleaned = _INLINE_DATA_PART.sub("", text or "")
    cleaned = _IMAGE_AT.sub(lambda m: take(m.group(1)), cleaned)
    cleaned = _MEDIA.sub(lambda m: take(_media_path(m), keep=m.group(0), anchor=True), cleaned)
    cleaned = _MD_IMAGE.sub(lambda m: take(m.group(1), keep=m.group(0), anchor=True), cleaned)
    # A hand-off note is never the person's words: it goes whether or not the file is still there.
    cleaned = _BRIDGE_NOTE.sub(lambda m: take(_json_path(m.group(2)), keep=gone_note(m),
                                              label=_json_path(m.group(1)) if m.group(1) else None), cleaned)
    cleaned = _PHOTO_NOTE.sub(lambda m: take(_json_path(m.group(2)), keep=gone_note(m),
                                             label=_json_path(m.group(1))), cleaned)
    cleaned = _AUDIO_NOTE.sub(lambda m: take(m.group(1).strip(), keep=""), cleaned)
    cleaned = _PASTE_NOTE.sub(lambda m: take(m.group(1).strip(), keep=m.group(0), gone=m.group(0)), cleaned)
    if bare:
        out, waiting, fenced = [], [], False
        for line in cleaned.split("\n"):
            out.append(line)
            if line.lstrip().startswith("```"):
                fenced = not fenced
            for p in mentioned_images(line):
                if Path(p).suffix.lower() in IMAGE_EXT:
                    before = len(found)
                    mark = take(p, keep="", anchor=True)
                    if len(found) > before:
                        waiting.append(mark.strip("\n"))
            if waiting and not fenced and not line.lstrip().startswith("|"):
                out += waiting
                waiting = []
        cleaned = "\n".join(out + waiting)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned, found


def content_parts(shown):
    """Split a reply at its image anchors: [{"text"}, {"media": 0}, {"text"}, …], and the text without anchors.
    Newer phones draw each image where Hermes put it; older ones read `content` and show images below."""
    if _ANCHOR not in shown:
        return None, shown
    parts, last = [], 0
    for m in _ANCHOR_RE.finditer(shown):
        piece = shown[last:m.start()].strip("\n")
        if piece.strip():
            parts.append({"text": piece})
        parts.append({"media": int(m.group(1))})
        last = m.end()
    tail = shown[last:].strip("\n")
    if tail.strip():
        parts.append({"text": tail})
    return parts, re.sub(r"\n{3,}", "\n\n", _ANCHOR_RE.sub("", shown)).strip()


def file_for_digest(texts, digest, roots, assistant_roots=()):
    """The file a timeline digest pointed at, re-derived from this session's own messages.

    `texts` holds message bodies, or (role, body) pairs. Only Hermes's own replies may point outside the
    Hermes home (into `assistant_roots`); what a phone typed is confined to `roots`.
    """
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        return None
    for entry in texts:
        role, text = entry if isinstance(entry, tuple) else ("user", entry)
        allowed = list(roots) + (list(assistant_roots) if role == "assistant" else [])
        for match in _marker_paths(text):
            path = safe_file(match, allowed)
            if path is not None and _digest(path) == digest:
                return path
    return None


_BARE_PATH = re.compile(r"(?<![\w.~/])((?:~|/(?:Users|tmp|private|var|opt|Volumes|home))/[^\s`'\"<>()\[\]{}|]+)")


_BARE_IMAGE = re.compile(r"(?<![\w.~/])((?:~|/(?:Users|tmp|private|var|opt|Volumes|home|mnt))/[^\n`'\"<>|*]*?"
                         r"\.(?:png|jpe?g|gif|webp|heic|heif|bmp|tiff?))(?![\w])", re.I)


def mentioned_images(text):
    """Image paths written in a reply, spaces allowed ("~/3D Printing/Runs/Plate B.png"), ~ expanded."""
    out = []
    for m in _BARE_IMAGE.finditer(text or ""):
        p = m.group(1)
        out.append(str(Path.home()) + p[1:] if p.startswith("~") else p)
    return out


def mentioned_paths(text):
    """Absolute or ~ paths written in a reply, with trailing punctuation trimmed."""
    out = []
    for m in _BARE_PATH.finditer(text or ""):
        p = m.group(1).rstrip(".,:;!?")
        if p.startswith("~"):
            p = str(Path.home()) + p[1:]
        out.append(p)
    return out


def file_for_path(texts, raw, roots, assistant_roots=()):
    """A file a reply in this chat named by path. Only Hermes's own replies count, and the file must still pass
    safe_file (inside an allowed root, a known file type, not a credential or dot-folder, under the size cap)."""
    want = (raw or "").strip()
    if want.startswith("~"):
        want = str(Path.home()) + want[1:]
    if not want.startswith("/") or "\x00" in want or len(want) > 1024:
        return None
    allowed = list(roots) + list(assistant_roots)
    for entry in texts:
        role, text = entry if isinstance(entry, tuple) else ("user", entry)
        if role != "assistant" or want not in mentioned_paths(text):
            continue
        return safe_file(want, allowed)
    return None


def project_timeline_message(message, roots=None, assistant_roots=()):
    """One mobile timeline row. Hidden diagnostics disappear. Delegation walls become activity cards."""
    if not isinstance(message, dict):
        return None
    kind = message.get("display_kind") or ""
    if kind == "hidden":
        return None
    roots = list(roots) if roots is not None else [hermes_home()]
    role = message.get("role") or "assistant"
    if role == "assistant":
        roots += list(assistant_roots)
    body = content_text(message.get("content"))
    shown, media = _refs(body, roots, bare=role == "assistant")
    parts, shown = content_parts(shown)
    row = {k: message[k] for k in ("id", "timestamp") if k in message}
    if media:
        row["media"] = media
        if parts and role == "assistant":
            row["content_parts"] = parts
    wall = kind in ("async_delegation_complete", "process_complete") or _is_wall(shown)
    if wall:
        title, detail, failed = _activity(kind, body)
        row.update(role="system", display_kind=kind or "async_delegation_complete",
                   notice=title, content=detail, ok=not failed)
        rich = activity_details(body)
        if rich:
            row["activity"] = rich["items"]
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
        verdict, shown, note = classify_user_text(shown, kind)
        if verdict == "notice":
            row.update(role="system", display_kind="system_note", notice=shown, content="", ok=True)
            return row
        if not shown and not media:
            return None
        row["role"] = "user"
        if shown:
            row["content"] = shown
        if note:
            row["note"] = note
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


def _skill_roots(home):
    """Every place Hermes finds skills: this profile, the shared home, then Hermes's own configured
    roots (create_dir and skills.external_dirs). A fixed two-folder scan missed most of them."""
    roots = [Path(home) / "skills", hermes_home() / "skills"]
    try:
        from agent.skill_utils import get_all_skills_dirs
        roots += [Path(d) for d in get_all_skills_dirs()]
    except Exception:
        pass
    out, seen = [], set()
    for root in roots:
        try:
            key = root.expanduser().resolve()
        except OSError:
            continue
        if key not in seen and key.is_dir():
            seen.add(key)
            out.append(key)
    return out


_SKILL_CACHE = {}
_SKILL_TTL = 60.0
_DESC = re.compile(r"(?m)^description:\s*(.+?)\s*$")


def _skill_description(skill_md):
    """The frontmatter one-liner, read from the first few KB only."""
    try:
        with open(skill_md, "r", encoding="utf-8", errors="replace") as f:
            head = f.read(4096)
    except OSError:
        return ""
    if not head.startswith("---"):
        return ""
    end = head.find("\n---", 3)
    m = _DESC.search(head[:end if end > 0 else len(head)])
    if not m:
        return ""
    text = m.group(1).strip().strip("'\"")
    if text in (">", "|", ">-", "|-"):
        return ""
    return _clip(text, 160)


def skill_catalog(home, limit=2000, depth=4):
    """Every skill Hermes can load: name, category folder and description. Cached for a minute, so a
    chat open does not walk 600 skill folders, and a new skill shows up within the minute."""
    import time
    key = (str(home), limit, depth)
    hit = _SKILL_CACHE.get(key)
    if hit and time.monotonic() - hit[0] < _SKILL_TTL:
        return [dict(x) for x in hit[1]]
    rows = _walk_skills(home, limit, depth)
    _SKILL_CACHE[key] = (time.monotonic(), rows)
    return [dict(x) for x in rows]


def skill_names(home, limit=2000, depth=4):
    return [row["name"] for row in skill_catalog(home, limit, depth)]


def _walk_skills(home, limit, depth):
    """Category folders nest (skills/<category>/<name>), so the walk goes a few levels deep and stops
    descending once it finds a SKILL.md. The first root that has a name wins, like Hermes's own lookup."""
    found, seen = [], set()
    for root in _skill_roots(home):
        stack = [(root, 0, "")]
        while stack:
            folder, level, category = stack.pop()
            try:
                children = sorted((c for c in folder.iterdir() if c.is_dir() and not c.name.startswith(".")),
                                  key=lambda p: p.name, reverse=True)
            except OSError:
                continue
            for child in children:
                skill_md = child / "SKILL.md"
                if skill_md.is_file():
                    if _skill_name_ok(child.name) and child.name not in seen:
                        seen.add(child.name)
                        found.append({"name": child.name, "category": category,
                                      "description": _skill_description(skill_md)})
                        if len(found) >= limit:
                            return sorted(found, key=lambda r: r["name"])
                elif level + 1 < depth:
                    stack.append((child, level + 1, category or child.name))
    return sorted(found, key=lambda r: r["name"])


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
