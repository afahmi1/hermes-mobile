"""Suggest a chat title from what the chat is about now, with Hermes's own title generator.

Hermes titles a chat once, from the opening message, on its cheap auxiliary model (auxiliary.title_generation).
A chat that wandered keeps a stale name. This feeds the same generator a short digest of the whole chat (how it
started, what was asked lately, the last answer's opening) so the suggestion fits, and it stays one small call on
the bot's own auxiliary model, in a child process with that bot's config and keys.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

_SUGGEST = r"""
import json, os, sys
try:
    from hermes_cli.config import load_env
    for k, v in (load_env() or {}).items():
        os.environ.setdefault(k, v)
except Exception:
    pass
from agent.title_generator import generate_title
digest = sys.stdin.read()
try:
    title = generate_title(digest, timeout=25)
except Exception as e:
    title = None
print(json.dumps({"title": title or ""}))
"""


def digest(bodies, limit=1400):
    """The chat in a few lines: first ask, the latest asks, and the start of the latest answer."""
    users = [t.strip() for role, t in bodies if role == "user" and t and t.strip()]
    answers = [t.strip() for role, t in bodies if role == "assistant" and t and t.strip()]
    parts = []
    if users:
        parts.append("Started with: " + users[0][:300])
    for u in users[-3:]:
        if u != users[0]:
            parts.append("Then: " + u[:250])
    if answers:
        parts.append("Latest answer: " + answers[-1][:300])
    return "\n".join(parts)[:limit]


def suggest(home: Path, bodies, timeout=40):
    text = digest(bodies)
    if not text:
        return ""
    import hermes_cli
    env = {**os.environ, "HERMES_HOME": str(home)}
    try:
        done = subprocess.run([sys.executable, "-c", _SUGGEST], input=text, capture_output=True, text=True,
                              timeout=timeout, env=env, cwd=str(Path(hermes_cli.__file__).resolve().parents[1]))
        out = json.loads((done.stdout.strip().splitlines() or ["{}"])[-1])
    except Exception:
        return ""
    title = " ".join(str(out.get("title") or "").split())[:80]
    # The auxiliary model sometimes answers instead of titling ('$ df -h /'): never offer that.
    return title if title and title[0].isalnum() else ""
