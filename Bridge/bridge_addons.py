"""Add-ons from the phone: the Skills Hub, the curated plugin catalog and the MCP catalog.

Owner only (the bridge checks that before calling in here). Everything Hermes-specific runs in a CHILD process
(`python bridge_addons.py --worker`) with `HERMES_HOME` set to the chosen bot's home, calling the same Hermes
functions the dashboard routers call (hermes_cli/web_routers/skills.py, dashboard_ui.py, mcp.py). A child, not
this process, because Hermes binds profile paths at import time and its profile scopes switch process-wide state,
while this process also hosts every phone turn.

Slow work (skill installs, plugin clones, MCP clones and probes) runs as a detached background action with its
own log under `<home>/mobile/addons/`; the request returns at once with an action id the phone polls.

Safety rules (mirroring the dashboard):
  - skills install only after a fresh scan of the same id for the same bot (the scan replaces the CLI's prompt),
    and never when the scan's policy is block;
  - plugin capability consent and force flags are only ever passed when the request carries consent: true;
  - MCP credentials are a closed schema (undeclared keys are refused), secrets go to the bot's .env, and no value
    is ever echoed back or written to a log.
"""
from __future__ import annotations

import json
import os
import re
import secrets as _secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

KINDS = ("skills", "plugins", "mcp")
RESTARTS = ("none", "next_session", "restart_hermes")
SCAN_TTL = 15 * 60
CATALOG_TTL = 60
README_CAP = 60_000
ID_RE = re.compile(r"^[A-Za-z0-9@][A-Za-z0-9@._:/+-]{0,199}$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
OWNER_ONLY = "Only the phone that owns this Mac can change add-ons."


class AddonError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# ── bridge side ────────────────────────────────────────────────────────────────────────────────────

_LOCK = threading.Lock()
SCANS: dict = {}     # scan_id -> {"kind", "id", "profile", "policy", "at"}
ACTIONS: dict = {}   # action -> {"proc", "log", "result", "state", "message", "restart", ...}
_CATALOG_CACHE: dict = {}


def hermes_root(home=None):
    try:
        import hermes_cli
        return Path(hermes_cli.__file__).resolve().parents[1]
    except Exception:
        return Path(home or Path.home() / ".hermes") / "hermes-agent"


def _child_env(home):
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONHOME",)}
    env["HERMES_HOME"] = str(home)
    env["PYTHONUNBUFFERED"] = "1"
    env.setdefault("NO_COLOR", "1")
    return env


def run_worker(op, home, profile, args, timeout=90):
    """Run one worker op in a child with the bot's HERMES_HOME. Returns the op's result or raises AddonError."""
    payload = json.dumps({"op": op, "profile": profile, "args": args})
    try:
        done = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--worker"], input=payload,
                              capture_output=True, text=True, timeout=timeout, env=_child_env(home),
                              cwd=str(hermes_root(home)))
    except subprocess.TimeoutExpired:
        raise AddonError(502, "Hermes took too long to answer. Try again.")
    except OSError as exc:
        raise AddonError(502, "Couldn't start Hermes on the Mac (%s)." % type(exc).__name__)
    lines = [ln for ln in (done.stdout or "").splitlines() if ln.strip()]
    try:
        out = json.loads(lines[-1])
    except Exception:
        tail = (done.stderr or "").strip().splitlines()[-1:] or ["no answer"]
        raise AddonError(502, "Hermes failed: %s" % tail[0][:200])
    if not out.get("ok"):
        raise AddonError(int(out.get("code") or 502), str(out.get("error") or "Hermes failed."))
    return out.get("result")


def _cli_command(profile, argv):
    return [sys.executable, "-m", "hermes_cli.main", "-p", profile, *argv]


def _actions_dir(home):
    d = Path(home) / "mobile" / "addons"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def start_action(home, profile, *, kind, ident, verb, cli=None, worker=None, verify=None, done_message="",
                 restart="next_session"):
    """Start a detached background action. Exactly one of `cli` (hermes argv) or `worker` ((op, args)).
    `verify(result_dict, exit_code) -> (ok, message)` decides the outcome when the process exits."""
    action = "%s-%s-%s" % (verb, re.sub(r"[^a-z0-9]+", "-", ident.lower()).strip("-")[:40] or kind,
                           _secrets.token_hex(4))
    adir = _actions_dir(home)
    log_path, result_path = adir / (action + ".log"), adir / (action + ".json")
    log = open(log_path, "ab", buffering=0)
    log.write(("=== %s %s %s started %s ===\n" % (verb, kind, ident, time.strftime("%Y-%m-%d %H:%M:%S"))).encode())
    stdin_data = None
    if cli is not None:
        cmd = _cli_command(profile, cli)
    else:
        op, args = worker
        cmd = [sys.executable, str(Path(__file__).resolve()), "--worker", "--result", str(result_path)]
        stdin_data = json.dumps({"op": op, "profile": profile, "args": args}).encode()
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, env=_child_env(home),
                                cwd=str(hermes_root(home)), start_new_session=True)
    except OSError as exc:
        log.close()
        raise AddonError(502, "Couldn't start Hermes on the Mac (%s)." % type(exc).__name__)
    if stdin_data is not None:
        try:
            proc.stdin.write(stdin_data)
            proc.stdin.close()
        except OSError:
            pass
    rec = {"proc": proc, "log": log_path, "result": result_path, "state": "running", "kind": kind, "id": ident,
           "profile": profile, "verb": verb, "message": "Working on it.", "restart": "none", "started": time.time()}
    with _LOCK:
        ACTIONS[action] = rec

    def watch():
        code = proc.wait()
        try:
            log.close()
        except OSError:
            pass
        result = {}
        try:
            result = json.loads(result_path.read_text())
        except Exception:
            pass
        try:
            ok, message = verify(result, code) if verify else (code == 0, "")
        except Exception as exc:  # never leave an action "running" forever
            ok, message = False, "Couldn't check the result (%s)." % type(exc).__name__
        with _LOCK:
            rec["state"] = "done" if ok else "failed"
            rec["message"] = message or (done_message if ok else "It didn't finish. See the log.")
            rec["restart"] = (result.get("restart") if result.get("restart") in RESTARTS else restart) if ok else "none"
            if kind == "skills":
                _UPDATES.pop(profile, None)
        invalidate_catalog()

    threading.Thread(target=watch, daemon=True, name="addon-" + action).start()
    return action


def _tail(path, lines=40):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 64_000))
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    return "\n".join(text.splitlines()[-lines:])


def action_status(action):
    with _LOCK:
        rec = ACTIONS.get(action)
        if rec is None:
            raise AddonError(404, "That add-on job isn't known here. It may have finished before the Mac restarted.")
        state, message, restart = rec["state"], rec["message"], rec["restart"]
        log = rec["log"]
    return {"state": state, "log_tail": _tail(log), "message": message, "restart": restart}


def wait_action(action, seconds):
    """Wait up to `seconds` for a quick action to settle (plugin re-pins answer consent in a second or two)."""
    end = time.time() + seconds
    while time.time() < end:
        with _LOCK:
            rec = ACTIONS.get(action)
            if rec is None or rec["state"] != "running":
                return rec
        time.sleep(0.1)
    return None


def invalidate_catalog():
    with _LOCK:
        _CATALOG_CACHE.clear()


def _lock_entries(home):
    """Hub-installed skills from <home>/skills/.hub/lock.json: name -> entry (stdlib read)."""
    try:
        data = json.loads((Path(home) / "skills" / ".hub" / "lock.json").read_text())
        return dict(data.get("installed") or {})
    except Exception:
        return {}


def _skill_lock_name(home, ident):
    for name, entry in _lock_entries(home).items():
        if ident in (entry.get("identifier"), name):
            return name
        if ident.startswith("clawhub/") and entry.get("source") == "clawhub" and \
                str(entry.get("identifier", "")).split("/")[-1] == ident.split("/", 1)[1]:
            return name
    return None


def _check(kind, ident=None):
    if kind not in KINDS:
        raise AddonError(400, "kind must be skills, plugins or mcp.")
    if ident is not None and (not isinstance(ident, str) or not ID_RE.match(ident) or ".." in ident):
        raise AddonError(400, "That add-on id isn't valid.")


UPDATES_TTL = 10 * 60
_UPDATES: dict = {}  # profile -> {"at": time, "ids": set | None, "running": bool}


def skill_updates(home, profile):
    """Hub skills with an upstream update (ids), or None while the first check runs. The check fetches every
    installed hub skill's source, so it runs in the background and is cached for ten minutes."""
    with _LOCK:
        rec = _UPDATES.setdefault(profile, {"at": 0.0, "ids": None, "running": False})
        stale = time.time() - rec["at"] > UPDATES_TTL
        if stale and not rec["running"]:
            rec["running"] = True
            start = True
        else:
            start = False
        ids = rec["ids"]
    if start:
        def run():
            try:
                found = set(run_worker("skill_updates", home, profile, {}, timeout=600) or [])
            except Exception:
                found = None
            with _LOCK:
                rec["running"] = False
                if found is not None:
                    rec["ids"], rec["at"] = found, time.time()
                    _CATALOG_CACHE.pop((profile, "skills", ""), None)
                else:
                    rec["at"] = time.time() - UPDATES_TTL + 60  # retry in a minute
        threading.Thread(target=run, daemon=True, name="addon-skill-updates").start()
    return ids


def catalog(home, profile, kind, q=""):
    _check(kind)
    q = (q or "").strip()[:120]
    key = (profile, kind, q.lower())
    with _LOCK:
        hit = _CATALOG_CACHE.get(key)
        fresh = hit and time.time() - hit[0] < CATALOG_TTL
    if fresh:
        out = hit[1]
    else:
        out = run_worker("catalog", home, profile, {"kind": kind, "q": q}, timeout=90)
        with _LOCK:
            _CATALOG_CACHE[key] = (time.time(), out)
    out = _browse_page(out, q)
    if kind != "skills":
        return out
    ids = skill_updates(home, profile)
    out = dict(out, items=[dict(it, update_available=it["installed"] and it["id"] in ids) if ids is not None
                           else it for it in out["items"]])
    if ids is None and not q:
        out["note"] = out.get("note") or "Checking installed skills for updates."
    return out


BROWSE_LIMIT = 150


def _browse_page(out, q):
    """Browsing (no search) sends what's installed, what's featured and the first BROWSE_LIMIT others: the full
    plugin catalog is thousands of rows (1.4 MB), too much to send a phone every time Add-ons opens."""
    items = out.get("items") or []
    if q or len(items) <= BROWSE_LIMIT:
        return out
    featured = set(out.get("featured") or [])
    keep = [it for it in items if it.get("installed") or it.get("id") in featured]
    rest = [it for it in items if not (it.get("installed") or it.get("id") in featured)][:BROWSE_LIMIT]
    note = f"Showing {len(keep) + len(rest)} of {len(items):,}. Search to find the rest."
    return dict(out, items=keep + rest, note=" ".join(x for x in (out.get("note"), note) if x))


def detail(home, profile, kind, ident):
    _check(kind, ident)
    return run_worker("detail", home, profile, {"kind": kind, "id": ident}, timeout=60)


def scan(home, profile, kind, ident):
    _check(kind, ident)
    if kind == "skills":
        out = run_worker("scan", home, profile, {"id": ident}, timeout=120)
    else:
        out = run_worker("trust", home, profile, {"kind": kind, "id": ident}, timeout=60)
    scan_id = _secrets.token_urlsafe(12)
    now = time.time()
    with _LOCK:
        for sid in [s for s, v in SCANS.items() if now - v["at"] > SCAN_TTL]:
            SCANS.pop(sid, None)
        SCANS[scan_id] = {"kind": kind, "id": ident, "profile": profile, "policy": out.get("policy"), "at": now}
    return {**out, "scan_id": scan_id}


def _require_scan(profile, kind, ident, scan_id):
    with _LOCK:
        rec = SCANS.get(scan_id) if isinstance(scan_id, str) else None
    if (rec is None or rec["kind"] != kind or rec["id"] != ident or rec["profile"] != profile
            or time.time() - rec["at"] > SCAN_TTL):
        raise AddonError(409, "Scan it first.")
    if rec["policy"] == "block":
        raise AddonError(403, "Hermes's security scan blocked this add-on, so it can't be installed.")
    return rec


def _clean_env(env):
    if env is None:
        return {}
    if not isinstance(env, dict):
        raise AddonError(400, "env must be an object of names to values.")
    out = {}
    for k, v in env.items():
        if not isinstance(k, str) or not ENV_NAME_RE.match(k):
            raise AddonError(400, "That setting name isn't valid.")
        if not isinstance(v, str):
            raise AddonError(400, "Setting values must be text.")
        if len(v) > 8192:
            raise AddonError(400, "A setting value is too long.")
        if v:
            out[k] = v
    return out


def install(home, profile, kind, ident, *, env=None, scan_id=None, consent=False):
    _check(kind, ident)
    consent = consent is True
    if kind == "skills":
        _require_scan(profile, kind, ident, scan_id)
        lock_path_name = ident

        def verify(_result, code):
            name = _skill_lock_name(home, lock_path_name)
            if name:
                return True, "Installed %s. It loads in your next chat." % name
            return False, "Hermes didn't install it. The log says why."

        action = start_action(home, profile, kind=kind, ident=ident, verb="install",
                              cli=["skills", "install", ident, "--yes"], verify=verify, restart="next_session")
        invalidate_catalog()
        return {"status": "running", "action": action, "message": "Installing. This can take a minute.",
                "restart": "next_session", "capabilities": []}
    if kind == "plugins":
        if env:
            raise AddonError(400, "Plugins don't take settings here.")
        info = run_worker("trust", home, profile, {"kind": kind, "id": ident}, timeout=60)
        caps = list(info.get("capabilities") or [])
        if not consent:
            return {"status": "consent_required", "action": None,
                    "message": "Allow this plugin to add what it lists below?", "restart": "none",
                    "capabilities": caps}
        action = start_action(home, profile, kind=kind, ident=ident, verb="install",
                              worker=("plugin_install", {"id": ident}), verify=_worker_verify,
                              restart="next_session")
        return _settle(action, caps, "Installing the plugin.")
    # mcp
    prep = run_worker("mcp_prepare", home, profile, {"id": ident, "env": _clean_env(env)}, timeout=60)
    if prep.get("git"):
        action = start_action(home, profile, kind=kind, ident=ident, verb="install",
                              cli=["mcp", "install", ident], verify=_mcp_verify(home, profile, ident),
                              restart="next_session")
    else:
        action = start_action(home, profile, kind=kind, ident=ident, verb="install",
                              worker=("mcp_install", {"id": ident, "env": prep.get("non_secret") or {}}),
                              verify=_worker_verify, restart="next_session")
    return {"status": "running", "action": action, "message": "Adding it. This can take a minute.",
            "restart": "next_session", "capabilities": list(prep.get("capabilities") or [])}


def _worker_verify(result, code):
    if result.get("ok"):
        return True, str(result.get("message") or "Done.")
    return False, str(result.get("error") or "It didn't finish. See the log.")


def _mcp_verify(home, profile, ident):
    def verify(_result, code):
        try:
            state = run_worker("mcp_state", home, profile, {"id": ident}, timeout=30)
        except AddonError:
            state = {}
        if state.get("installed"):
            return True, "Added %s. Its tools load in your next chat." % ident
        return False, "Hermes didn't add it. The log says why."
    return verify


def _settle(action, caps, running_message):
    rec = wait_action(action, 25)
    if rec is None:
        return {"status": "running", "action": action, "message": running_message, "restart": "none",
                "capabilities": caps}
    try:
        result = json.loads(Path(rec["result"]).read_text())
    except Exception:
        result = {}
    if result.get("consent_required"):
        return {"status": "consent_required", "action": action, "message": rec["message"], "restart": "none",
                "capabilities": list(result.get("capabilities") or caps)}
    if result.get("blocked"):
        return {"status": "blocked", "action": action, "message": rec["message"], "restart": "none",
                "capabilities": caps}
    if rec["state"] == "failed":
        raise AddonError(502, rec["message"])
    return {"status": "done", "action": action, "message": rec["message"], "restart": rec["restart"],
            "capabilities": caps}


def uninstall(home, profile, kind, ident):
    _check(kind, ident)
    if kind == "skills":
        name = _skill_lock_name(home, ident)
        if not name:
            raise AddonError(404, "That skill wasn't installed from the hub, so there's nothing to remove here.")

        def verify(_result, code):
            if name not in _lock_entries(home):
                return True, "Removed %s." % name
            return False, "Hermes didn't remove it. The log says why."

        action = start_action(home, profile, kind=kind, ident=ident, verb="uninstall",
                              cli=["skills", "uninstall", name, "--yes"], verify=verify, restart="next_session")
        return {"status": "running", "action": action, "message": "Removing it.", "restart": "next_session"}
    out = run_worker("uninstall", home, profile, {"kind": kind, "id": ident}, timeout=90)
    invalidate_catalog()
    return {"status": "done", "action": None, "message": out.get("message") or "Removed.",
            "restart": out.get("restart") if out.get("restart") in RESTARTS else "next_session"}


def enable(home, profile, kind, ident, enabled):
    _check(kind, ident)
    if kind not in ("plugins", "mcp"):
        raise AddonError(400, "Only plugins and MCP servers can be switched on or off here.")
    if not isinstance(enabled, bool):
        raise AddonError(400, "enabled must be true or false.")
    out = run_worker("enable", home, profile, {"kind": kind, "id": ident, "enabled": enabled}, timeout=90)
    invalidate_catalog()
    return {"status": "done", "message": out.get("message") or ("Switched on." if enabled else "Switched off."),
            "restart": out.get("restart") if out.get("restart") in RESTARTS else "next_session"}


def update(home, profile, kind, ident, *, consent=False):
    _check(kind, ident)
    consent = consent is True
    if kind == "skills":
        name = _skill_lock_name(home, ident)
        if not name:
            raise AddonError(404, "That skill wasn't installed from the hub, so it has no updates here.")
        before = (_lock_entries(home).get(name) or {}).get("content_hash")

        def verify(_result, code):
            entry = _lock_entries(home).get(name) or {}
            if code == 0 and entry:
                changed = entry.get("content_hash") != before
                return True, ("Updated %s." % name) if changed else ("%s is already up to date." % name)
            return False, "Hermes didn't update it. The log says why."

        action = start_action(home, profile, kind=kind, ident=ident, verb="update",
                              cli=["skills", "update", name], verify=verify, restart="next_session")
        return {"status": "running", "action": action, "message": "Updating.", "restart": "next_session",
                "capabilities": []}
    if kind == "plugins":
        action = start_action(home, profile, kind=kind, ident=ident, verb="update",
                              worker=("plugin_update", {"id": ident, "consent": consent}), verify=_worker_verify,
                              restart="next_session")
        return _settle(action, [], "Updating the plugin.")
    # mcp: a catalog MCP updates by reinstalling from the manifest (keeps tool selection; secrets stay in .env)
    return install(home, profile, kind, ident, env={}, consent=consent)


# ── worker side (runs in the child, HERMES_HOME = the bot's home) ──────────────────────────────────

def _one_line(text, cap=240):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= cap else text[:cap - 1].rstrip() + "…"


def item(*, id, name, description="", source="", trust="community", repo=None, tags=(), installed=False,
         enabled=None, update_available=False, needs_setup=False, version=None):
    return {"id": str(id), "name": str(name or id), "description": _one_line(description), "source": str(source or ""),
            "trust": trust if trust in ("builtin", "trusted", "community", "curated") else "community",
            "repo": repo or None, "tags": [str(t) for t in (tags or [])][:12], "installed": bool(installed),
            "enabled": enabled if enabled is None else bool(enabled), "update_available": bool(update_available),
            "needs_setup": bool(needs_setup), "version": str(version) if version else None}


def _matches(it, q):
    if not q:
        return True
    q = q.lower()
    hay = " ".join([it["id"], it["name"], it["description"], " ".join(it["tags"])]).lower()
    return all(word in hay for word in q.split())


def _order(items, featured):
    rank = {fid: i for i, fid in enumerate(featured)}
    return sorted(items, key=lambda it: (not it["installed"], it["id"] not in rank, rank.get(it["id"], 0),
                                         it["name"].lower()))


def _with_budget(fn, seconds, default):
    box = {"v": default, "done": False}

    def run():
        try:
            box["v"] = fn()
        except Exception:
            box["v"] = default
        box["done"] = True

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(seconds)
    return box["v"], box["done"]


def _skill_meta_item(m, installed_ids, disabled=frozenset()):
    ident = getattr(m, "identifier", "") or getattr(m, "name", "")
    inst = installed_ids.get(ident)
    return item(id=ident, name=getattr(m, "name", ident), description=getattr(m, "description", ""),
                source=getattr(m, "source", ""), trust=getattr(m, "trust_level", "community"),
                repo=getattr(m, "repo", None), tags=list(getattr(m, "tags", None) or []), installed=inst is not None,
                enabled=(None if inst is None else (inst.get("name") or getattr(m, "name", "")) not in disabled))


def _skills_state():
    from tools.skills_hub import HubLockFile
    try:
        installed_ids = HubLockFile().by_identifier()
    except Exception:
        installed_ids = {}
    try:
        from hermes_cli.config import load_config
        from hermes_cli.skills_config import get_disabled_skills
        disabled = set(get_disabled_skills(load_config()))
    except Exception:
        disabled = set()
    return installed_ids, disabled


def w_catalog_skills(q):
    installed_ids, disabled = _skills_state()
    timed_out, note = [], None
    if q:
        from tools.skills_hub_search import create_source_router, parallel_search_sources
        sources = create_source_router()
        results, _counts, timed_out = parallel_search_sources(sources, query=q, source_filter="all",
                                                              overall_timeout=30)
        rank, seen = {"builtin": 2, "trusted": 1, "community": 0}, {}
        for r in results:
            prev = seen.get(r.identifier)
            if prev is None or rank.get(r.trust_level, 0) > rank.get(prev.trust_level, 0):
                seen[r.identifier] = r
        items = [_skill_meta_item(m, installed_ids, disabled) for m in list(seen.values())[:50]]
        return {"kind": "skills", "items": items, "featured": [], "timed_out": list(timed_out or []), "note": None}
    from tools.skills_hub_official import OptionalSkillSource
    by_id = {}
    featured_ids = []

    def featured():
        from tools.skills_hub_search import create_source_router
        for src in create_source_router():
            if src.source_id() == "hermes-index" and getattr(src, "is_available", False):
                return list(src.search("", limit=12))
        return []

    metas, ok = _with_budget(featured, 15, [])
    if not ok:
        timed_out.append("hermes-index")
    for m in metas:
        it = _skill_meta_item(m, installed_ids, disabled)
        by_id.setdefault(it["id"], it)
        featured_ids.append(it["id"])
    for m in OptionalSkillSource().list_local():
        it = _skill_meta_item(m, installed_ids, disabled)
        by_id.setdefault(it["id"], it)
    for ident, entry in installed_ids.items():
        if ident in by_id or (ident.startswith("clawhub/") and entry.get("identifier") in by_id):
            continue
        by_id[ident] = item(id=ident, name=entry.get("name") or ident, description="Installed from %s" % (
            entry.get("source") or "the hub"), source=entry.get("source") or "", trust=entry.get("trust_level"),
            installed=True, enabled=(entry.get("name") or ident) not in disabled)

    return {"kind": "skills", "items": _order(list(by_id.values()), featured_ids), "featured": featured_ids,
            "timed_out": timed_out, "note": note}


_PLUGIN_TRUST = {"official": "trusted", "verified": "trusted", "community": "community"}


def _plugin_locals():
    """(installed alias -> {dir, runtime_status}, discovered rows) as the dashboard catalog route builds them."""
    from hermes_cli.plugins_cmd import _discover_all_plugins, _get_disabled_set, _get_enabled_set
    try:
        from hermes_cli.web_server_dashboard import _plugin_runtime_status
    except Exception:
        from hermes_cli.plugins_cmd import _plugin_status

        def _plugin_runtime_status(aliases, enabled, disabled):
            name = sorted(aliases)[0]
            return _plugin_status(name, enabled, disabled, key=name)
    enabled, disabled = _get_enabled_set(), _get_disabled_set()
    installed, rows = {}, _discover_all_plugins()
    for name, _v, _d, _s, dir_str, key in rows:
        aliases = {name, key} - {""}
        info = {"dir": dir_str, "runtime_status": _plugin_runtime_status(aliases, enabled, disabled)}
        installed.update({alias: info for alias in aliases})
    return installed, rows


def _caps_list(entry):
    caps = getattr(entry, "capabilities", None)
    out = []
    for label, attr in (("Adds tools", "provides_tools"), ("Adds hooks", "provides_hooks"),
                        ("Adds middleware", "provides_middleware"), ("Needs settings", "requires_env")):
        vals = list(getattr(caps, attr, None) or [])
        if vals:
            out.append("%s: %s" % (label, ", ".join(vals)))
    if not out:
        out.append("Declares no tools, hooks, middleware or settings.")
    plats = list(getattr(entry, "platforms", None) or [])
    if plats:
        out.append("Platforms: %s" % ", ".join(plats))
    if getattr(entry, "requires_hermes", ""):
        out.append("Requires Hermes %s" % entry.requires_hermes)
    for issue in list(getattr(entry, "known_issues", None) or [])[:3]:
        out.append("Known issue: %s" % _one_line(issue, 160))
    return out


def w_catalog_plugins(q):
    from hermes_cli.plugins_cmd_catalog import installed_catalog_state
    installed, rows = _plugin_locals()
    state = installed_catalog_state(installed)
    items, featured, seen_dirs = [], [], set()
    for e in state.get("entries") or []:
        inst = bool(e.get("installed"))
        if inst:
            local = installed.get(e.get("name"))
            if local:
                seen_dirs.add(local["dir"])
        it = item(id=e["name"], name=e.get("title") or e["name"], description=e.get("description"), source="curated",
                  trust=_PLUGIN_TRUST.get(e.get("tier"), "community"), repo=e.get("repo"),
                  tags=[t for t in (e.get("category"), e.get("tier")) if t], installed=inst,
                  enabled=(e.get("runtime_status") == "enabled") if inst else None,
                  update_available=e.get("update_available"),
                  needs_setup=bool((e.get("capabilities") or {}).get("requires_env")), version=e.get("version"))
        items.append(it)
        if e.get("tier") in ("official", "verified") or e.get("default"):
            featured.append(it["id"])
    from hermes_cli.plugins_cmd_catalog import catalog_install_record
    for name, version, desc, source, dir_path, key in rows:
        if source in ("bundled", "entrypoint") or str(dir_path) in seen_dirs:
            continue
        if catalog_install_record(dir_path):
            continue
        info = installed.get(key) or installed.get(name) or {}
        items.append(item(id=key or name, name=name, description=desc, source="github" if source == "git" else "local",
                          trust="community", installed=True, enabled=info.get("runtime_status") == "enabled",
                          version=version))
    items = [it for it in items if _matches(it, q)]
    featured = [f for f in featured if any(it["id"] == f for it in items)]
    return {"kind": "plugins", "items": _order(items, featured), "featured": featured, "timed_out": [], "note": None}


def _env_present(name):
    try:
        from hermes_cli.config import get_env_value
        return bool(get_env_value(name))
    except Exception:
        return bool(os.environ.get(name))


def _mcp_item(entry, installed, enabled):
    specs = list(getattr(entry.auth, "env", None) or [])
    missing = [s for s in specs if s.required and s.secret and not _env_present(s.name)]
    needs = (not installed and (bool(specs) or entry.install is not None or entry.auth.type == "oauth")) or \
        (installed and bool(missing))
    tags = [t for t in (entry.transport.type, entry.auth.type if entry.auth.type != "none" else None) if t]
    return item(id=entry.name, name=entry.name, description=entry.description, source="curated", trust="curated",
                repo=(entry.install.url if entry.install else None) or entry.source or None, tags=tags,
                installed=installed, enabled=enabled if installed else None, needs_setup=needs,
                version=(entry.install.ref if entry.install else None))


def w_catalog_mcp(q):
    from hermes_cli import mcp_catalog
    items, featured = [], []
    for e in mcp_catalog.list_catalog():
        inst = mcp_catalog.is_installed(e.name)
        it = _mcp_item(e, inst, mcp_catalog.is_enabled(e.name) if inst else False)
        if _matches(it, q):
            items.append(it)
            if e.suggest and (e.suggest.examples or e.suggest.keywords) and e.install is None:
                featured.append(it["id"])
    featured = featured[:12]
    return {"kind": "mcp", "items": _order(items, featured), "featured": featured, "timed_out": [], "note": None}


def _resolve_skill(ident):
    from hermes_cli.skills_hub import _resolve_source_meta_and_bundle
    from tools.skills_hub_search import create_source_router
    return _resolve_source_meta_and_bundle(ident, create_source_router())


def w_detail_skills(ident):
    installed_ids, disabled = _skills_state()
    meta, bundle, _src = _resolve_skill(ident)
    if not meta and not bundle:
        local = installed_ids.get(ident)
        if not local:
            raise AddonError(404, "No skill called %s was found." % ident)
        meta = None
    files, readme = [], None
    if bundle:
        for rel, content in (bundle.files or {}).items():
            files.append(rel)
            if rel == "SKILL.md":
                readme = content.decode("utf-8", "replace") if isinstance(content, bytes) else str(content)
    m = meta or bundle
    if m is not None:
        it = _skill_meta_item(m, installed_ids, disabled)
        it["id"] = ident
        it["installed"] = it["installed"] or ident in installed_ids
    else:
        entry = installed_ids[ident]
        it = item(id=ident, name=entry.get("name") or ident, source=entry.get("source"),
                  trust=entry.get("trust_level"), installed=True)
    if readme is None and it["installed"]:
        readme = _installed_skill_md(installed_ids.get(ident) or {})
    return {"item": it, "readme": readme[:README_CAP] if readme else None, "files": sorted(files),
            "env": _skill_env(readme), "capabilities": [], "suggest": []}


def _installed_skill_md(entry):
    try:
        from hermes_constants import get_hermes_home
        p = Path(get_hermes_home()) / "skills" / entry.get("install_path", "") / "SKILL.md"
        return p.read_text(encoding="utf-8-sig")
    except Exception:
        return None


def _skill_env(skill_md):
    """required_environment_variables from SKILL.md frontmatter (names + prompts only)."""
    if not skill_md or not skill_md.startswith("---"):
        return []
    try:
        import yaml
        front = yaml.safe_load(skill_md.split("---", 2)[1]) or {}
    except Exception:
        return []
    out = []
    for raw in front.get("required_environment_variables") or []:
        if isinstance(raw, str):
            raw = {"name": raw}
        if isinstance(raw, dict) and raw.get("name"):
            out.append({"name": str(raw["name"]), "description": raw.get("prompt") or raw.get("help") or None,
                        "secret": True, "required": not raw.get("optional", False)})
    return out


def _find_plugin_entry(ident):
    from hermes_cli.plugin_catalog import load_catalog_live
    return next((e for e in load_catalog_live() if e.name == ident), None)


def _installed_plugin_dir(ident):
    """The on-disk dir for a catalog name (sidecar match first) or an installed plugin key/name."""
    from hermes_cli.plugins_cmd_catalog import catalog_install_record
    installed, rows = _plugin_locals()
    for _n, _v, _d, source, dir_path, _k in rows:
        rec = catalog_install_record(dir_path) if source not in ("bundled", "entrypoint") else None
        if rec and str(rec.get("catalog_name")) == ident:
            return Path(dir_path)
    local = installed.get(ident)
    return Path(local["dir"]) if local and local.get("dir") else None


def _plugin_name(ident):
    d = _installed_plugin_dir(ident)
    if d is None:
        raise AddonError(404, "That plugin isn't installed on this bot.")
    from hermes_cli.plugins_cmd import _discover_all_plugins
    for name, _v, _d, _s, dir_path, key in _discover_all_plugins():
        if Path(dir_path) == d:
            return key or name, d
    return d.name, d


def _fetch_readme(entry):
    if not entry or not entry.repo or not entry.sha:
        return None
    m = re.match(r"https?://github\.com/([^/]+)/([^/#?]+?)(?:\.git)?/?$", entry.repo)
    if not m:
        return None
    sub = (entry.subdir.strip("/") + "/") if entry.subdir else ""
    import urllib.request
    for fname in ("README.md", "readme.md", "README.MD"):
        url = "https://raw.githubusercontent.com/%s/%s/%s/%s%s" % (m.group(1), m.group(2), entry.sha, sub, fname)
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                return r.read(README_CAP + 1).decode("utf-8", "replace")
        except Exception:
            continue
    return None


def w_detail_plugins(ident):
    entry = _find_plugin_entry(ident)
    local_dir = _installed_plugin_dir(ident)
    if entry is None and local_dir is None:
        raise AddonError(404, "No plugin called %s was found." % ident)
    cat = w_catalog_plugins("")
    it = next((i for i in cat["items"] if i["id"] == ident), None) or item(id=ident, name=ident, installed=True)
    readme, files = None, []
    if local_dir is not None:
        for fname in ("README.md", "readme.md"):
            p = local_dir / fname
            if p.is_file():
                readme = p.read_text(encoding="utf-8", errors="replace")
                break
        try:
            files = sorted(str(p.relative_to(local_dir)) for p in local_dir.rglob("*")
                           if p.is_file() and ".git" not in p.parts)[:300]
        except OSError:
            files = []
    if readme is None:
        readme = _fetch_readme(entry)
    if readme is None and entry is not None:
        readme = entry.description or None
    env = [{"name": n, "description": None, "secret": True, "required": True}
           for n in (list(entry.capabilities.requires_env) if entry else [])]
    return {"item": it, "readme": readme[:README_CAP] if readme else None, "files": files, "env": env,
            "capabilities": _caps_list(entry) if entry else [], "suggest": []}


def _mcp_caps(entry):
    t, out = entry.transport, []
    if t.url:
        out.append("Connects to %s" % t.url)
    if t.command:
        out.append("Runs %s" % " ".join([t.command, *list(t.args or [])])[:300])
    if entry.install:
        out.append("Downloads %s%s" % (entry.install.url, (" at " + entry.install.ref) if entry.install.ref else ""))
        for cmd in list(entry.install.bootstrap or [])[:6]:
            out.append("Then runs: %s" % cmd[:200])
    if entry.auth.type == "oauth":
        out.append("Signs in with %s" % (entry.auth.provider or "OAuth in a browser"))
    if entry.tools.default_enabled is not None:
        out.append("Tools on by default: %s" % (", ".join(entry.tools.default_enabled) or "none"))
    return out


def w_detail_mcp(ident):
    from hermes_cli import mcp_catalog
    entry = mcp_catalog.get_entry(ident)
    if entry is None:
        raise AddonError(404, "No MCP server called %s is in the catalog." % ident)
    inst = mcp_catalog.is_installed(ident)
    it = _mcp_item(entry, inst, mcp_catalog.is_enabled(ident) if inst else False)
    parts = [entry.description or ""]
    if entry.source:
        parts.append("Source: %s" % entry.source)
    if entry.post_install:
        parts.append(entry.post_install.strip())
    env = [{"name": s.name, "description": s.prompt or None, "secret": bool(s.secret), "required": bool(s.required)}
           for s in (entry.auth.env or [])]
    examples = list(getattr(entry.suggest, "examples", None) or []) if entry.suggest else []
    return {"item": it, "readme": "\n\n".join(p for p in parts if p)[:README_CAP] or None, "files": [], "env": env,
            "capabilities": _mcp_caps(entry), "suggest": examples}


def w_scan(ident):
    from tools.skills_hub_install import discard_quarantine, quarantine_bundle
    from tools.skills_guard import scan_skill, should_allow_install
    from hermes_cli.skills_hub import _scan_source_for_install
    meta, bundle, matched = _resolve_skill(ident)
    if not bundle:
        raise AddonError(404, "No skill called %s was found." % ident)
    scan_source, scan_trust = _scan_source_for_install(bundle, meta, ident, matched)
    q_path = quarantine_bundle(bundle)
    try:
        result = scan_skill(q_path, source=scan_source, trust_level=scan_trust)
    finally:
        discard_quarantine(q_path)
    allowed, reason = should_allow_install(result, force=False)
    counts = {sev: 0 for sev in ("critical", "high", "medium", "low")}
    for f in result.findings:
        counts[f.severity] = counts.get(f.severity, 0) + 1
    findings = [{"severity": f.severity, "title": _one_line(f.description or f.category, 200),
                 "file": ("%s:%s" % (f.file, f.line) if getattr(f, "line", None) else f.file) or None}
                for f in result.findings][:200]
    return {"verdict": result.verdict, "policy": "allow" if allowed is True else "ask" if allowed is None else "block",
            "reason": reason or None, "severity_counts": counts, "findings": findings}


def w_trust(kind, ident):
    """Plugins and MCP aren't scanned before install: policy from the catalog's trust, plus what it can do."""
    if kind == "plugins":
        entry = _find_plugin_entry(ident)
        if entry is None and _installed_plugin_dir(ident) is None:
            raise AddonError(404, "No plugin called %s was found." % ident)
        tier = entry.tier if entry else "community"
        policy = "allow" if tier in ("official", "verified") else "ask"
        reason = None if policy == "allow" else "Community plugin: read what it adds before you allow it."
        return {"verdict": "not_scanned", "policy": policy, "reason": reason, "severity_counts": {}, "findings": [],
                "capabilities": _caps_list(entry) if entry else []}
    from hermes_cli import mcp_catalog
    entry = mcp_catalog.get_entry(ident)
    if entry is None:
        raise AddonError(404, "No MCP server called %s is in the catalog." % ident)
    policy = "ask" if (entry.install is not None or entry.transport.command) else "allow"
    reason = "It runs a program on your Mac." if policy == "ask" else None
    return {"verdict": "not_scanned", "policy": policy, "reason": reason, "severity_counts": {}, "findings": [],
            "capabilities": _mcp_caps(entry)}


def w_mcp_prepare(ident, env):
    """Validate the env map against the entry's declared schema, save secrets to .env, return non-secrets."""
    from hermes_cli import mcp_catalog
    from hermes_cli.config import save_env_value, validate_env_var_name_for_write
    entry = mcp_catalog.get_entry(ident)
    if entry is None:
        raise AddonError(404, "No MCP server called %s is in the catalog." % ident)
    plugin = _mcp_plugin_owner(ident)
    if plugin:
        raise AddonError(409, "%s comes with the plugin %s. Manage it from that plugin." % (ident, plugin))
    specs = list(entry.auth.env or [])
    declared = {s.name for s in specs}
    extra = sorted(set(env) - declared)
    if extra:
        raise AddonError(400, "%s doesn't use the setting(s): %s." % (ident, ", ".join(extra)))
    try:
        for k in env:
            validate_env_var_name_for_write(k)
    except ValueError as exc:
        raise AddonError(400, str(exc))
    missing = [s.name for s in specs if s.required and not env.get(s.name)
               and not (s.secret and _env_present(s.name)) and not s.default]
    if missing:
        raise AddonError(400, "%s needs: %s." % (ident, ", ".join(missing)))
    non_secret = {}
    for s in specs:
        v = env.get(s.name)
        if v and s.secret:
            save_env_value(s.name, v)
        elif v:
            non_secret[s.name] = v
    return {"git": entry.install is not None, "non_secret": non_secret, "capabilities": _mcp_caps(entry)}


def _mcp_plugin_owner(name):
    from hermes_cli.mcp_config import _get_mcp_servers
    from tui_gateway.mcp_rpc_helpers import server_configs_with_sources
    _servers, plugins = server_configs_with_sources(_get_mcp_servers())
    return plugins.get(name)


def w_mcp_install(ident, env):
    from hermes_cli import mcp_catalog
    entry = mcp_catalog.get_entry(ident)
    if entry is None:
        return {"ok": False, "error": "No MCP server called %s is in the catalog." % ident}
    mcp_catalog.install_entry(entry, enable=True, preloaded_env=env or None)
    msg = "Added %s. Its tools load in your next chat." % ident
    if entry.auth.type == "oauth":
        msg += " It signs in through a browser the first time Hermes connects to it."
    return {"ok": True, "message": msg, "restart": "next_session"}


def w_plugin_install(ident):
    from hermes_cli.plugins_cmd import dashboard_install_plugin
    res = dashboard_install_plugin("", force=False, enable=True, catalog_name=ident)
    if not res.get("ok"):
        return {"ok": False, "error": res.get("error") or "Install failed.",
                "blocked": bool(res.get("scan_blocked"))}
    return {"ok": True, "message": _plugin_message("Installed %s." % (res.get("plugin_name") or ident), res),
            "restart": _plugin_restart(res)}


def _plugin_restart(res):
    if res.get("restart_required"):
        return "restart_hermes"
    act = res.get("activation") or {}
    if act.get("deferred") or not res.get("gateway_reloaded", True):
        return "next_session"
    return "none"


def _plugin_message(first, res):
    bits = [first]
    if res.get("missing_env"):
        bits.append("It still needs: %s." % ", ".join(res["missing_env"]))
    if res.get("restart_required"):
        bits.append("Restart Hermes to finish loading it.")
    return " ".join(bits)


def w_plugin_update(ident, consent):
    from hermes_cli.plugins_cmd_update import dashboard_update_user_plugin
    name, _d = _plugin_name(ident)
    res = dashboard_update_user_plugin(name, accept_capabilities=bool(consent), force=False)
    if res.get("consent_required"):
        return {"ok": False, "consent_required": True, "capabilities": list(res.get("delta_lines") or []),
                "error": "This update asks for more than before. Look it over, then allow it."}
    if res.get("scan_blocked"):
        return {"ok": False, "blocked": True,
                "error": "Hermes's security scan stopped this update: %s" % _one_line(res.get("error"), 200)}
    if not res.get("ok"):
        return {"ok": False, "error": res.get("error") or "Update failed."}
    first = ("%s is already up to date." % name) if res.get("unchanged") else ("Updated %s." % name)
    return {"ok": True, "message": _plugin_message(first, res), "restart": _plugin_restart(res)}


def w_uninstall(kind, ident):
    if kind == "plugins":
        from hermes_cli.plugins_cmd_remove import dashboard_remove_user_plugin
        name, _d = _plugin_name(ident)
        res = dashboard_remove_user_plugin(name)
        if not res.get("ok"):
            raise AddonError(409 if "Bundled" in str(res.get("error")) else 502, res.get("error") or "Remove failed.")
        return {"message": "Removed %s." % name, "restart": "restart_hermes" if res.get("restart_required")
                else "next_session"}
    from hermes_cli import mcp_catalog
    plugin = _mcp_plugin_owner(ident)
    if plugin:
        raise AddonError(409, "%s comes with the plugin %s. Remove that plugin instead." % (ident, plugin))
    if not mcp_catalog.uninstall_entry(ident):
        raise AddonError(404, "%s isn't set up on this bot." % ident)
    return {"message": "Removed %s." % ident, "restart": "next_session"}


def w_enable(kind, ident, enabled):
    if kind == "plugins":
        from hermes_cli.plugins_cmd import dashboard_set_agent_plugin_enabled
        name, _d = _plugin_name(ident)
        res = dashboard_set_agent_plugin_enabled(name, enabled=enabled)
        if not res.get("ok"):
            raise AddonError(409, res.get("error") or "Couldn't change it.")
        verb = "Switched on" if enabled else "Switched off"
        return {"message": "%s %s." % (verb, name),
                "restart": "restart_hermes" if res.get("restart_required") else
                ("none" if enabled and res.get("gateway_reloaded") else "next_session")}
    from hermes_cli.config import load_config, save_config
    from tools.mcp_tool_common import write_mcp_server_enabled
    plugin = _mcp_plugin_owner(ident)
    if plugin:
        raise AddonError(409, "%s comes with the plugin %s. Switch that plugin instead." % (ident, plugin))
    cfg = load_config()
    servers = cfg.get("mcp_servers")
    if not isinstance(servers, dict) or not isinstance(servers.get(ident), dict):
        raise AddonError(404, "%s isn't set up on this bot." % ident)
    write_mcp_server_enabled(servers[ident], enabled)
    save_config(cfg)
    return {"message": "%s %s." % ("Switched on" if enabled else "Switched off", ident), "restart": "next_session"}


def w_skill_updates():
    from tools.skills_hub_install import check_for_skill_updates
    return [r.get("identifier") for r in check_for_skill_updates() if r.get("status") == "update_available"]


def w_mcp_state(ident):
    from hermes_cli import mcp_catalog
    return {"installed": mcp_catalog.is_installed(ident)}


def dispatch(op, args):
    kind = args.get("kind")
    if op == "catalog":
        return {"skills": w_catalog_skills, "plugins": w_catalog_plugins, "mcp": w_catalog_mcp}[kind](args.get("q") or "")
    if op == "detail":
        return {"skills": w_detail_skills, "plugins": w_detail_plugins, "mcp": w_detail_mcp}[kind](args["id"])
    if op == "scan":
        return w_scan(args["id"])
    if op == "trust":
        return w_trust(kind, args["id"])
    if op == "mcp_prepare":
        return w_mcp_prepare(args["id"], args.get("env") or {})
    if op == "mcp_install":
        return w_mcp_install(args["id"], args.get("env") or {})
    if op == "skill_updates":
        return w_skill_updates()
    if op == "mcp_state":
        return w_mcp_state(args["id"])
    if op == "plugin_install":
        return w_plugin_install(args["id"])
    if op == "plugin_update":
        return w_plugin_update(args["id"], args.get("consent") is True)
    if op == "uninstall":
        return w_uninstall(kind, args["id"])
    if op == "enable":
        return w_enable(kind, args["id"], args.get("enabled") is True)
    raise AddonError(400, "Unknown add-on operation.")


def _load_profile_env():
    try:
        from hermes_cli.config import load_env
        for k, v in (load_env() or {}).items():
            os.environ.setdefault(k, v)
    except Exception:
        pass


def worker_main(argv):
    result_path = argv[argv.index("--result") + 1] if "--result" in argv else None
    real_out = os.dup(1)
    os.dup2(2, 1)  # anything Hermes prints goes to stderr (or the action log), never into the answer
    sys.stdout = sys.stderr
    sys.path.insert(0, os.getcwd())
    try:
        req = json.loads(sys.stdin.read() or "{}")
        _load_profile_env()
        result = dispatch(req.get("op"), req.get("args") or {})
        out = {"ok": True, "result": result}
    except AddonError as exc:
        out = {"ok": False, "code": exc.code, "error": exc.message}
    except Exception as exc:
        import traceback
        traceback.print_exc()
        out = {"ok": False, "code": 502, "error": "Hermes failed: %s" % _one_line("%s: %s" % (type(exc).__name__, exc), 200)}
    if result_path:
        # Background action: the op's own dict ({"ok", "message"/"error", ...}) is the outcome.
        final = out["result"] if out.get("ok") and isinstance(out.get("result"), dict) else \
            {"ok": False, "error": out.get("error")}
        Path(result_path).write_text(json.dumps(final))
        print(final.get("message") or final.get("error") or "", file=sys.stderr)
        sys.stderr.flush()
        os._exit(0 if final.get("ok") else 1)
    os.write(real_out, (json.dumps(out) + "\n").encode())
    sys.stderr.flush()
    os._exit(0)


if __name__ == "__main__" and "--worker" in sys.argv:
    worker_main(sys.argv)
