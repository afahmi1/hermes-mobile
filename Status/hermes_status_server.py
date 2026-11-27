#!/usr/bin/env python3
"""Hermes status dashboard — read-only local server.

Serves dashboard.html and /api/status, assembled from ~/.hermes state files,
cron databases (root + every profile), and `hermes usage/auth` for providers.
Nothing here writes to Hermes. API keys never leave this process except to
their own provider's balance endpoint.

    python3 hermes_status_server.py [--port 9230]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import sqlite3
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from contextlib import closing
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Bridge"))
from bridge_process import pid_alive
HERMES_BIN = os.environ.get("HERMES_BIN", str(Path.home() / ".local/bin/hermes"))
PROVIDER_TTL = 60  # seconds between `hermes auth list` refreshes
USAGE_TTL = {"openrouter": 300, "anthropic": 600, "openai-codex": 300}  # per-provider poll interval (default 120s)
FORCE_FLOOR = {"openrouter": 60, "anthropic": 300, "openai-codex": 60}  # min gap even on manual refresh (default 15s)
USAGE_PROVIDERS = {"anthropic", "openai-codex"}  # supported by `hermes usage`
# Change tracking ("What's new"): the dashboard's own memory of which bots and cron jobs it has seen.
STATE_FILE = Path(os.environ.get("HERMES_STATUS_STATE",
                                 Path.home() / "Library/Application Support/hermes-status/seen.json"))
NEW_WINDOW_S = 24 * 3600   # how long a newly created bot or job carries its "new" badge
GONE_AFTER_S = 90          # an item must be missing this long before it counts as removed


# ---------------------------------------------------------------- helpers
def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def first_float(path: Path):
    try:
        return float(path.read_text().split()[0])
    except Exception:
        return None


def iso_from_epoch(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else None


def ro_query(db: Path, sql: str, params=()):
    if not db.exists():
        return []
    try:
        con = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
        con.row_factory = sqlite3.Row
        try:
            return [dict(r) for r in con.execute(sql, params)]
        finally:
            con.close()
    except Exception:
        return []


# Hermes's own rule (hermes_constants.named_profile_is_live): a folder under profiles/ is a bot when it
# carries an identity marker and has no deletion tombstone. A brand-new bot has no config.yaml yet.
_PROFILE_MARKERS = ("config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db")


_PROFILE_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")


def is_live_profile(home):
    return (home.is_dir() and home.name != "default" and _PROFILE_ID.fullmatch(home.name) is not None
            and any((home / m).is_file() or (home / m).is_symlink() for m in _PROFILE_MARKERS)
            and not (home.parent / ".deleted" / home.name).exists())

def profile_homes():
    homes = [("default", HOME)]
    pdir = HOME / "profiles"
    if pdir.is_dir():
        homes += [(p.name, p) for p in sorted(pdir.iterdir()) if is_live_profile(p)]
    return homes


# ---------------------------------------------------------------- gateway
def prior_platform_observation(platform, lifecycle, pid):
    # Hermes preserves old adapter rows across runs, including platforms since disabled.
    # Require this process's lifecycle record and leave a minute for startup ordering.
    if not pid or lifecycle.get("pid") != pid or lifecycle.get("phase") != "running":
        return False
    try:
        observed = datetime.fromisoformat(platform["updated_at"])
        started = datetime.fromisoformat(lifecycle["started_at"])
        return (started - observed).total_seconds() > 60
    except (KeyError, TypeError, ValueError):
        return False


def gateway_status():
    st = read_json(HOME / "gateway_state.json", {}) or {}
    hb = read_json(HOME / "state" / "gateway.heartbeat", {}) or {}
    life = read_json(HOME / "state" / "gateway.lifecycle.json", {}) or {}
    hb_at = hb.get("updated_at")
    hb_age = None
    if hb_at:
        try:
            hb_age = (datetime.now(timezone.utc) - datetime.fromisoformat(hb_at)).total_seconds()
        except Exception:
            pass

    # During a restart Hermes may update the heartbeat before its state file.
    fresh_heartbeat = hb_age is not None and -5 <= hb_age < 120
    candidates = [st.get("pid"), life.get("pid") if life.get("phase") == "running" else None]
    if fresh_heartbeat:
        candidates.insert(0, hb.get("pid"))
    pid = next((candidate for candidate in candidates if candidate and pid_alive(candidate)), None)
    alive = pid is not None
    if not alive:
        pid = next((candidate for candidate in candidates if candidate), hb.get("pid"))

    platforms = []
    for name, p in (st.get("platforms") or {}).items():
        if prior_platform_observation(p, life, pid):
            continue
        platforms.append({
            "name": name,
            "state": p.get("state"),
            "error": p.get("error_message") or p.get("error_code"),
            "needs_attention": p.get("needs_attention"),
            "retrying_since": p.get("retrying_since"),
            "updated_at": p.get("updated_at"),
            "metrics": p.get("metrics"),
            "listener": p.get("listener_base"),
        })

    estops = [str(h / "ESTOP") for _, h in profile_homes() if (h / "ESTOP").exists()]

    ticker = []
    for name, h in profile_homes():
        beat = first_float(h / "cron" / "ticker_heartbeat")
        ok = first_float(h / "cron" / "ticker_last_success")
        if beat or ok:
            ticker.append({"profile": name, "heartbeat": iso_from_epoch(beat),
                           "last_success": iso_from_epoch(ok)})

    reasons = []
    try:
        free_mib = shutil.disk_usage(HOME).free // (1024 * 1024)
        if free_mib < 512:
            reasons.append("Hermes storage has %d MiB free. Saving chat history may fail." % free_mib)
    except OSError:
        pass
    if not alive:
        reasons.append("Recorded gateway process %s has exited" % pid if pid else "Gateway process has no recorded PID")
    if st.get("gateway_state") != "running":
        reasons.append("Gateway state: " + str(st.get("gateway_state") or "unknown"))
    if estops:
        reasons.append("Emergency stop is active")
    for platform in platforms:
        if platform["needs_attention"] or platform["state"] not in ("connected", "running"):
            reasons.append("%s: %s" % (platform["name"], platform["error"] or platform["state"] or "needs attention"))
    if hb_age is not None and hb_age > 120:
        reasons.append("Last heartbeat was %d seconds ago" % hb_age)

    return {
        "health": "down" if not alive else "degraded" if reasons else "healthy",
        "reasons": reasons,
        "pid": pid,
        "alive": alive,
        "state": st.get("gateway_state"),
        "exit_reason": st.get("exit_reason"),
        "restart_requested": st.get("restart_requested"),
        "active_agents": st.get("active_agents"),
        "active_work": st.get("active_work"),
        "version": st.get("code_version"),
        "sha": (st.get("code_sha") or "")[:12],
        "started_at": life.get("started_at"),
        "heartbeat_at": hb_at,
        "heartbeat_age_s": hb_age,
        "session_store": (st.get("session_store") or {}).get("status"),
        "served_profiles": st.get("served_profiles") or [],
        "parked_profiles": st.get("parked_profiles") or {},
        "platforms": platforms,
        "estop": estops,
        "ticker": ticker,
    }


# ---------------------------------------------------------------- jobs
def jobs_status():
    jobs, live, recent, incidents = [], [], [], []
    tokens_24h = {}
    read_ok = []  # profiles whose jobs.json parsed (or doesn't exist): safe to infer removals from
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)

    for prof, h in profile_homes():
        cron = h / "cron"
        data = read_json(cron / "jobs.json", None)
        if data is not None or not (cron / "jobs.json").exists():
            read_ok.append(prof)
        data = data or {}
        names = {}
        for j in data.get("jobs", []):
            names[j["id"]] = j.get("name")
            paused = j.get("state") == "paused" or not j.get("enabled", True)
            jobs.append({
                "profile": prof,
                "id": j["id"],
                "name": j.get("name"),
                "schedule": j.get("schedule_display") or (j.get("schedule") or {}).get("display"),
                "state": j.get("state"),
                "enabled": j.get("enabled"),
                "paused": paused,
                "paused_at": j.get("paused_at"),
                "paused_reason": j.get("paused_reason"),
                "next_run_at": j.get("next_run_at"),
                "last_run_at": j.get("last_run_at"),
                "last_status": j.get("last_status"),
                "last_error": j.get("last_error") or j.get("last_delivery_error"),
                "failure_streak": j.get("failure_streak") or 0,
                "completed": (j.get("repeat") or {}).get("completed"),
                "model": j.get("model"),
                "script_only": j.get("no_agent"),
                "deliver": j.get("deliver"),
                "claimed": j.get("fire_claim") is not None,
            })

        db = cron / "executions.db"
        for r in ro_query(db, "SELECT * FROM executions WHERE status IN ('claimed','running') "
                              "AND finished_at IS NULL ORDER BY claimed_at DESC LIMIT 50"):
            r.update(profile=prof, name=names.get(r["job_id"], r["job_id"]),
                     pid_alive=pid_alive(r.get("pid")))
            live.append(r)
        for r in ro_query(db, "SELECT job_id,status,claimed_at,started_at,finished_at,error,"
                              "delivery_outcome FROM executions ORDER BY claimed_at DESC LIMIT 25"):
            r.update(profile=prof, name=names.get(r["job_id"], r["job_id"]))
            recent.append(r)
        for r in ro_query(db, "SELECT job_id,state,failure_type,first_seen_at,last_seen_at,error "
                              "FROM cron_incidents WHERE closed_at IS NULL AND acked_at IS NULL"):
            r.update(profile=prof, name=names.get(r["job_id"], r["job_id"]))
            incidents.append(r)

        audit = cron / "usage_audit.jsonl"
        if audit.exists():
            try:
                for line in audit.read_text().splitlines()[-500:]:
                    e = json.loads(line)
                    ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
                    if ts < cutoff:
                        continue
                    m = e.get("model") or "unknown"
                    t = tokens_24h.setdefault(m, {"model": m, "runs": 0, "prompt": 0,
                                                  "completion": 0, "errors": 0})
                    t["runs"] += 1
                    t["prompt"] += e.get("prompt_tokens") or 0
                    t["completion"] += e.get("completion_tokens") or 0
                    t["errors"] += 1 if e.get("error") else 0
            except Exception:
                pass

    # Fire claims on jobs.json with no matching execution row still count as live.
    live_ids = {(r["profile"], r["job_id"]) for r in live}
    for j in jobs:
        if j["claimed"] and (j["profile"], j["id"]) not in live_ids:
            live.append({"profile": j["profile"], "job_id": j["id"], "name": j["name"],
                         "status": "claimed", "claimed_at": None, "started_at": None,
                         "pid_alive": None, "progress_at": None})

    recent.sort(key=lambda r: r.get("claimed_at") or "", reverse=True)
    sessions = (read_json(HOME / "runtime" / "active_sessions.json", {}) or {}).get("entries", [])
    return {
        "jobs": jobs,
        "live": live,
        "recent": recent[:30],
        "incidents": incidents,
        "tokens_24h": sorted(tokens_24h.values(), key=lambda t: -(t["prompt"] + t["completion"])),
        "active_sessions": sessions,
        "read_ok": read_ok,
    }


# ---------------------------------------------------------------- bots
def _model_default(cfg: Path):
    try:
        text = cfg.read_text()
    except Exception:
        return "", ""
    try:
        import yaml
        config = yaml.safe_load(text)
        model = config.get("model") if isinstance(config, dict) else None
        if isinstance(model, dict):
            return str(model.get("default") or model.get("model") or ""), str(model.get("provider") or "")
    except (ImportError, ValueError):
        pass
    except Exception:
        return "", ""
    # Stdlib-only installations: match direct children of the root model map.
    match = re.search(r"^model:[ \t]*(?:#[^\n]*)?\n((?:[ \t]+[^\n]*\n?|\n)*)", text, re.M)
    values = {}
    indent = None
    for line in (match.group(1).splitlines() if match else []):
        field = re.match(r"^( +)([\w-]+):[ \t]*([^#]*)", line)
        if field:
            indent = len(field[1]) if indent is None else indent
            if len(field[1]) == indent:
                values[field[2]] = field[3].strip().strip("\"'")
    return values.get("default") or values.get("model", ""), values.get("provider", "")


def _fleet_meta():
    """Display names and one-line roles from the fleet list in the main SOUL.md, if it has one."""
    meta, front = {}, "Hermes"
    try:
        text = (HOME / "SOUL.md").read_text()
    except Exception:
        return meta, front
    for m in re.finditer(r"^- `([a-z0-9_-]+)`(?: \(([^)]+)\))?:\s*(.+(?:\n  \S.*)*)", text, re.M):
        blurb = re.sub(r"\s+", " ", m.group(3)).replace("`", "").strip()
        meta[m.group(1)] = (m.group(2) or "", (blurb[:1].upper() + blurb[1:])[:140])
    me = re.search(r"^I'm ([^\s—-]+(?: [A-Z][^\s—-]+)?)\s*[—-]", text, re.M)
    return meta, (me.group(1) if me else front)


def _has_env_key(h: Path, key: str) -> bool:
    try:
        return any(line.startswith(key + "=") and line.split("=", 1)[1].strip().strip("'\"")
                   for line in (h / ".env").read_text().splitlines())
    except Exception:
        return False


def bots_status(gw, jobs):
    """Every profile on disk, found fresh on each call: a bot created a second ago shows up."""
    served = set(gw.get("served_profiles") or [])
    parked = set((gw.get("parked_profiles") or {}).keys())
    meta, front = _fleet_meta()
    gmodel, gprov = _model_default(HOME / "config.yaml")
    out = []
    for name, h in profile_homes():
        model, prov = _model_default(h / "config.yaml")
        row = (ro_query(h / "state.db", "SELECT COUNT(*) AS n, MAX(coalesce(last_activity_at, started_at)) AS last "
                                       "FROM sessions WHERE archived=0 AND coalesce(hidden,0)=0 "
                                       "AND source NOT IN ('subagent','tool')") or [{}])[0]
        mine = [j for j in jobs if j["profile"] == name]
        nm, blurb = meta.get(name, ("", ""))
        if name == "default":
            nm, blurb = front, blurb or "The front door. Does the work or hands it to the right bot."
        out.append({
            "id": name,
            "name": nm or name.replace("-", " ").replace("_", " ").title(),
            "blurb": blurb,
            "model": model or gmodel,
            "provider": prov or gprov,
            "served": name in served,
            "parked": name in parked,
            "api_key": _has_env_key(h, "API_SERVER_KEY"),
            "sessions": row.get("n") or 0,
            "last_active": iso_from_epoch(row.get("last")),
            "jobs": len(mine),
            "jobs_paused": sum(1 for j in mine if j["paused"]),
            "jobs_failing": sum(1 for j in mine if j["failure_streak"] or j["last_status"] in ("failed", "error")),
            "created_at": iso_from_epoch(_created_at(h)),
        })
    return out


def _created_at(h: Path):
    try:
        st = h.stat()
        return getattr(st, "st_birthtime", None) or st.st_ctime
    except Exception:
        return None


# ---------------------------------------------------------------- agents
def agents_status(jobs_payload):
    """What is running right now, across every profile: live chats (the gateway's session leases),
    subagents that are still working, and cron runs in flight."""
    now = time.time()
    agents = []
    for prof, h in profile_homes():
        db = h / "state.db"
        for e in (read_json(h / "runtime" / "active_sessions.json", {}) or {}).get("entries", []):
            md = e.get("metadata") or {}
            if e.get("pid") and not pid_alive(e.get("pid")):
                continue  # a lease left behind by a process that died; Hermes prunes it on its next write
            # Gateway leases carry the session key (agent:<profile>:<platform>:...); CLI, TUI and desktop
            # leases carry the state.db id itself.
            key = e.get("session_id") or md.get("live_session_id") or ""
            row = {}
            if key:
                row = (ro_query(db, "SELECT id, title, model, source FROM sessions WHERE session_key=? "
                                    "ORDER BY started_at DESC LIMIT 1", (key,))
                       or ro_query(db, "SELECT id, title, model, source FROM sessions WHERE id=?", (key,))
                       or ro_query(db, "SELECT id, title, model, source FROM sessions WHERE id=?",
                                   (md.get("chat_id") or "",)) or [{}])[0]
            agents.append({
                "kind": "chat", "profile": prof, "session_id": row.get("id"),
                "title": row.get("title") or "Untitled chat", "model": row.get("model"),
                "source": row.get("source") or md.get("platform"), "surface": e.get("surface"),
                "started_at": iso_from_epoch(e.get("started_at")), "pid": e.get("pid"),
                "pid_alive": pid_alive(e.get("pid")) if e.get("pid") else None,
            })
        for r in ro_query(db, "SELECT id, title, model, billing_provider, message_count, parent_session_id, started_at, "
                              "(SELECT substr(content, 1, 400) FROM messages m WHERE m.session_id = sessions.id "
                              " AND m.role = 'user' ORDER BY m.id LIMIT 1) AS goal, "
                              "coalesce(last_activity_at, started_at) AS last FROM sessions "
                              "WHERE source='subagent' AND ended_at IS NULL "
                              "AND coalesce(last_activity_at, started_at) > ? ORDER BY last DESC LIMIT 20",
                          (now - 900,)):
            agents.append({
                "kind": "subagent", "profile": prof, "session_id": r["id"],
                "title": (r.get("title") or "Subagent").removeprefix("Subagent: "), "model": r.get("model"),
                "parent_session_id": r.get("parent_session_id"), "provider": r.get("billing_provider"),
                "steps": r.get("message_count"), "goal": " ".join(str(r.get("goal") or "").split())[:300] or None,
                "started_at": iso_from_epoch(r.get("started_at")), "last_active": iso_from_epoch(r.get("last")),
            })
    for r in jobs_payload.get("live") or []:
        agents.append({
            "kind": "cron", "profile": r.get("profile"), "job_id": r.get("job_id"),
            "title": r.get("name"), "status": r.get("status"),
            "started_at": r.get("started_at") or r.get("claimed_at"), "pid": r.get("pid"),
            "pid_alive": r.get("pid_alive"),
        })
    return agents


# ---------------------------------------------------------------- what's new
_seen_lock = threading.Lock()


def _write_state(state):
    try:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_name(f".{STATE_FILE.name}.{uuid.uuid4().hex}")
        tmp.write_text(json.dumps(state))
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        print(f"could not save {STATE_FILE}: {e}", flush=True)


def track_changes(bots, jobs, read_ok):
    """Compare what exists now with what the dashboard has seen before. New bots and cron jobs get a
    first_seen time (and a "new" badge for a day); ones that disappear are logged as removed.
    The very first run only records a baseline, so existing things are never flagged as new."""
    now = time.time()
    current = {f"bot:{b['id']}": {"kind": "bot", "name": b["name"], "profile": b["id"]} for b in bots}
    for j in jobs:  # keyed by job id alone, so a bot rename moves its jobs instead of re-creating them
        current[f"job:{j['id']}"] = {"kind": "cron job", "name": j["name"] or j["id"], "profile": j["profile"]}
    homes = dict(profile_homes())
    existing = {name for name, _ in profile_homes()}
    # A job's removal can be trusted when its bot's jobs.json read cleanly, or the bot itself is gone.
    unreadable = existing - set(read_ok)
    with _seen_lock:
        state = read_json(STATE_FILE, None)
        baseline = state is None
        state = state or {"items": {}, "events": []}
        items, events, changed = state["items"], state["events"], baseline
        if state.get("version") != 2:  # earlier keys were job:<profile>:<id>
            for k in [k for k in items if k.startswith("job:") and k.count(":") == 2]:
                items[f"job:{k.split(':', 2)[2]}"] = items.pop(k)
            state["version"], changed = 2, True
        for k, v in current.items():
            if k not in items and k.startswith("bot:"):
                old = next((o for o in _previous_names(homes.get(v["profile"]))
                            if f"bot:{o}" in items and f"bot:{o}" not in current), None)
                if old:
                    items[k] = {**items.pop(f"bot:{old}"), **v}
                    items[k].pop("missing_since", None)
                    events.append({"type": "renamed", **v, "old_name": old, "at": now})
                    changed = True
            if k not in items:
                items[k] = {**v, "first_seen": None if baseline else now}
                if not baseline:
                    events.append({"type": "added", **v, "at": now})
                changed = True
            elif items[k].pop("missing_since", None) is not None:
                changed = True
            elif items[k].get("name") != v["name"] or items[k].get("profile") != v["profile"]:
                items[k].update(name=v["name"], profile=v["profile"])
                changed = True
        for k in list(items):
            if k in current:
                continue
            it = items[k]
            # A cron job only counts as gone when its profile's jobs.json was readable this time.
            if k.startswith("job:") and it.get("profile") in unreadable:
                continue
            gone = it.setdefault("missing_since", now)
            changed = True
            if now - gone >= GONE_AFTER_S:
                events.append({"type": "removed", "kind": it.get("kind"), "name": it.get("name"),
                               "profile": it.get("profile"), "at": now})
                del items[k]
        state["events"] = events[-100:]
        if changed:
            _write_state(state)
        first_seen = {k: v.get("first_seen") for k, v in items.items()}
        recent = [dict(e, at=iso_from_epoch(e["at"])) for e in reversed(state["events"][-30:])]
    for b in bots:
        fs = first_seen.get(f"bot:{b['id']}")
        b["first_seen"] = iso_from_epoch(fs)
        b["new"] = bool(fs and now - fs < NEW_WINDOW_S)
    for j in jobs:
        fs = first_seen.get(f"job:{j['id']}")
        j["first_seen"] = iso_from_epoch(fs)
        j["new"] = bool(fs and now - fs < NEW_WINDOW_S)
    return {"events": recent, "baseline_only": baseline}


def _previous_names(home):
    """Old names Hermes recorded in profile.yaml when this bot was renamed (`hermes profile rename`)."""
    if not home:
        return []
    try:
        text = (home / "profile.yaml").read_text()
    except Exception:
        return []
    m = re.search(r"^previous_names:\s*\[(.*?)\]", text, re.M)
    if m:
        return [x.strip().strip("'\"") for x in m.group(1).split(",") if x.strip()]
    m = re.search(r"^previous_names:\s*\n((?:[ \t]*-[ \t]*.+\n?)+)", text, re.M)
    return [re.sub(r"^[ \t]*-[ \t]*", "", ln).strip().strip("'\"") for ln in m.group(1).splitlines()] if m else []


def full_status(force=False):
    """Everything the Mac dashboard and the phone show, assembled fresh on each call."""
    payload = {"generated_at": datetime.now(timezone.utc).isoformat(), "hermes_home": str(HOME)}
    for k, fn in (("gateway", gateway_status), ("jobs", jobs_status)):
        try:
            payload[k] = fn()
        except Exception as e:
            payload[k] = {"error": f"{type(e).__name__}: {e}"}
    gw, J = payload.get("gateway") or {}, payload.get("jobs") or {}
    jobs = J.get("jobs") or []
    try:
        payload["bots"] = bots_status(gw, jobs)
    except Exception as e:
        payload["bots"] = []
        payload["bots_error"] = f"{type(e).__name__}: {e}"
    try:
        payload["agents"] = agents_status(J)
    except Exception as e:
        payload["agents"] = []
        payload["agents_error"] = f"{type(e).__name__}: {e}"
    try:
        payload["changes"] = track_changes(payload["bots"], jobs, J.get("read_ok") or [])
    except Exception as e:
        payload["changes"] = {"events": [], "error": f"{type(e).__name__}: {e}"}
    for b in payload["bots"]:
        b["running"] = sum(1 for a in payload["agents"]
                           if a.get("profile") == b["id"] and a.get("pid_alive") is not False)
    try:
        payload["providers"] = providers_status(force)
    except Exception as e:
        payload["providers"] = {"error": f"{type(e).__name__}: {e}", "providers": []}
    return payload


# ---------------------------------------------------------------- providers
_prov_lock = threading.Lock()
_prov_cache = {"at": 0.0, "data": None}


def run(cmd, timeout=25):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           cwd=str(Path.home()))
        return p.returncode, p.stdout
    except Exception as e:
        return 1, str(e)


def parse_auth_list(text):
    providers, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^(\S+) \((\d+) credentials?\):", line)
        if m:
            cur = providers.setdefault(m.group(1), {"provider": m.group(1), "credentials": []})
            continue
        m = re.match(r"^\s+#(\d+)\s+(.+?)\s+(\S+)\s+id=(\S+)\s+priority=(\d+)\s*(.*)$", line)
        if m and cur:
            rest = m.group(6)
            cur["credentials"].append({
                "index": int(m.group(1)), "label": m.group(2), "type": m.group(3),
                "priority": int(m.group(5)), "active": "←" in rest,
                "note": rest.replace("←", "").strip(),
            })
    return providers


def env_value(key):
    try:
        for line in (HOME / ".env").read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return os.environ.get(key)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Usage requests carry a provider credential.


def http_json(url, key, timeout=10):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}",
                                               "User-Agent": "hermes-status-dashboard"})
    with urllib.request.build_opener(_NoRedirect()).open(req, timeout=timeout) as r:
        return json.load(r)


def openrouter_usage():
    env_key = env_value("OPENROUTER_API_KEY")
    pool = (read_json(HOME / "auth.json", {}) or {}).get("credential_pool", {}).get("openrouter", [])
    keys = dict.fromkeys(row.get("access_token") for row in pool if isinstance(row, dict)
                         and row.get("base_url") in (None, "", "https://openrouter.ai/api/v1",
                                                     "https://openrouter.ai/api/v1/"))
    if env_key:
        keys[env_key] = None
    keys.pop(None, None)
    keys.pop("", None)
    if not keys:
        return {"unavailable_reason": "No native OpenRouter credentials found"}

    def check(key):
        try:
            key_data = http_json("https://openrouter.ai/api/v1/key", key, timeout=5)["data"]
            return {field: key_data[field] for field in ("usage_daily", "usage_monthly", "usage")
                    if isinstance(key_data.get(field), (int, float))}
        except (OSError, ValueError, KeyError, TypeError):
            return {}

    with cf.ThreadPoolExecutor(max_workers=3) as ex:
        readings = list(ex.map(check, keys))
    out = {"source": "OpenRouter", "scope": "Spend across distinct keys in the default profile",
           "key_count": len(keys), "keys_reporting": sum(bool(r) for r in readings),
           "spend": {}, "windows": [], "details": []}
    for field in ("usage_daily", "usage_monthly", "usage"):
        amounts = [row[field] for row in readings if field in row]
        if amounts:
            out["spend"][field] = {"usd": sum(amounts), "reporting": len(amounts)}
    if not out["keys_reporting"]:
        out["unavailable_reason"] = "OpenRouter returned no key usage readings"
    if env_key:
        try:
            account = http_json("https://openrouter.ai/api/v1/credits", env_key, timeout=5)["data"]
            total, used = float(account["total_credits"]), float(account["total_usage"])
            out["balance"] = {"remaining": round(total - used, 4), "total": total, "used": used,
                              "currency": "USD", "label": "Environment key’s billing account"}
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return out


def deepseek_usage():
    key = env_value("DEEPSEEK_API_KEY")
    if not key:
        return {"unavailable_reason": "DEEPSEEK_API_KEY not set"}
    try:
        d = http_json("https://api.deepseek.com/user/balance", key)
        infos = d.get("balance_infos") or []
        out = {"source": "deepseek /user/balance", "windows": [], "details": []}
        if infos:
            b = infos[0]
            out["balance"] = {"remaining": float(b.get("total_balance") or 0),
                              "currency": b.get("currency", "USD")}
            out["details"].append(f"Granted {b.get('granted_balance')} · topped-up {b.get('topped_up_balance')}")
        if not d.get("is_available", True):
            out["details"].append("Account reports insufficient balance")
        return out
    except Exception as e:
        return {"unavailable_reason": f"balance fetch failed: {type(e).__name__}"}


def hermes_usage(provider):
    code, out = run([HERMES_BIN, "usage", "--provider", provider, "--json"])
    if code == 0:
        try:
            return json.loads(out)
        except Exception:
            pass
    return {"unavailable_reason": (out.strip().splitlines() or ["usage fetch failed"])[-1][:200]}


_usage_cache = {}
_usage_lock = threading.Lock()


def _usable(d):
    return bool(d and (d.get("windows") or d.get("balance") or d.get("spend")))


def cached_usage(name, force=False):
    """Per-provider cache. Anthropic's usage endpoint rate-limits aggressively, so it is
    polled rarely, and a failed check falls back to the last good reading (marked stale)."""
    now = time.time()
    ttl = (FORCE_FLOOR if force else USAGE_TTL).get(name, 15 if force else 120)
    with _usage_lock:
        c = _usage_cache.get(name)
        if not (c and now - c["at"] < ttl):
            c = None
    if c is None:
        d = provider_usage(name)
        with _usage_lock:
            prev = _usage_cache.get(name) or {}
            c = {"at": now, "data": d, "good": prev.get("good"), "good_at": prev.get("good_at")}
            if _usable(d):
                c.update(good=d, good_at=now)
            _usage_cache[name] = c
    d = c["data"]
    if _usable(d) or not c.get("good"):
        return dict(d, checked_at=iso_from_epoch(c["at"]))
    return dict(c["good"], stale=True, checked_at=iso_from_epoch(c["at"]),
                stale_since=iso_from_epoch(c["good_at"]),
                stale_reason=d.get("unavailable_reason") or "latest check failed")


def provider_usage(name):
    if name in USAGE_PROVIDERS:
        return hermes_usage(name)
    if name == "openrouter":
        return openrouter_usage()
    if name == "deepseek":
        return deepseek_usage()
    return {"unavailable_reason": "Provider exposes no usage or balance endpoint"}


_refresh_lock = threading.Lock()  # one refresh at a time: concurrent `hermes auth list` runs fight over auth.lock


def providers_status(force=False):
    """Provider usage, never blocking a status poll: a stale reading is returned at once while a
    background refresh runs (`hermes auth list` can take 25 s+). Only an explicit refresh waits."""
    with _prov_lock:
        data, age = _prov_cache["data"], time.time() - _prov_cache["at"]
    if data and age < PROVIDER_TTL and not force:
        return data
    _kick_provider_refresh(force)  # a manual refresh starts one now; the next poll shows its result
    if data:
        return dict(data, refreshing=True)
    return {"providers": [], "loading": True, "fetched_at": None}


def _kick_provider_refresh(force=False):
    if not _refresh_lock.acquire(blocking=False):
        return  # one is already running; its result is what a manual refresh wants anyway

    def go():
        try:
            _refresh_providers(force)
        except Exception as e:
            print(f"provider refresh failed: {type(e).__name__}: {e}", flush=True)
        finally:
            _refresh_lock.release()
    threading.Thread(target=go, name="provider-refresh", daemon=True).start()


def provider_ledger(homes):
    totals, read_count, missing = {}, 0, 0
    seen = set()
    for _, home in homes:
        path = (home / "state.db").resolve()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        try:
            with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
                rows = db.execute("""
                    SELECT COALESCE(NULLIF(billing_provider, ''), 'unattributed'),
                           COUNT(DISTINCT session_id), SUM(api_call_count), SUM(input_tokens),
                           SUM(output_tokens), MAX(last_seen)
                      FROM session_model_usage GROUP BY 1
                """).fetchall()
        except sqlite3.Error:
            missing += 1
            continue
        read_count += 1
        for name, sessions, calls, inputs, outputs, latest in rows:
            record = totals.setdefault(name, dict(sessions=0, calls=0, input_tokens=0, output_tokens=0))
            for field, amount in (("sessions", sessions), ("calls", calls), ("input_tokens", inputs),
                                  ("output_tokens", outputs)):
                record[field] += amount or 0
            if isinstance(latest, (int, float)):
                record["last_seen"] = max(latest, record.get("last_seen", 0))
    return totals, {"profiles_read": read_count, "profiles_unavailable": missing}


def _refresh_providers(force):
    provs = {}
    for attempt in range(3):
        code, text = run([HERMES_BIN, "auth", "list"])
        provs = parse_auth_list(text) if code == 0 else {}
        if provs:
            break
        print(f"auth list attempt {attempt + 1} failed (exit {code})", flush=True)
        time.sleep(2)
    inventory_error = None
    if not provs:
        inventory_error = "Hermes credential inventory is unavailable"
        with _prov_lock:
            previous = _prov_cache["data"]
            if previous and previous.get("providers"):
                _prov_cache.update(at=time.time() - PROVIDER_TTL + 15,
                                   data=dict(previous, error=inventory_error, stale=True))
                return
    _, cfg_default = _model_default(HOME / "config.yaml")
    ledger, coverage = provider_ledger(profile_homes())
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {n: ex.submit(cached_usage, n, force) for n in provs}
        for n, f in futs.items():
            try:
                u = f.result(timeout=40)
            except Exception as e:
                u = {"unavailable_reason": str(e)}
            provs[n]["usage"] = u
            provs[n]["is_default"] = n == cfg_default
    for name, local in ledger.items():
        provs.setdefault(name, {"provider": name, "historical_only": True, "credentials": [],
                                "is_default": name == cfg_default})["local_usage"] = local
    data = {"ledger": coverage, "error": inventory_error, "fetched_at": datetime.now(timezone.utc).isoformat(), "default_provider": cfg_default,
            "providers": sorted(provs.values(), key=lambda p: (not p["is_default"], p["provider"]))}
    with _prov_lock:
        _prov_cache.update(at=time.time(), data=data)
    return data


# ---------------------------------------------------------------- server
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body: bytes, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path in ("/", "/index.html"):
            return self.send(200, (HERE / "dashboard.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/status":
            payload = full_status(force="refresh=providers" in query)
            return self.send(200, json.dumps(payload, default=str).encode(), "application/json")
        self.send(404, b"not found", "text/plain")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9230)
    args = ap.parse_args()
    _kick_provider_refresh()  # warm the cache
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Hermes status dashboard on http://127.0.0.1:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
