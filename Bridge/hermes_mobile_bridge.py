#!/usr/bin/env python3
"""Hermes Mobile bridge: the iPhone app's single, login-gated door into the Hermes gateway.

Thin by design. Hermes's own state.db files are the only source of truth; this process keeps no
chat state. It does three things the gateway API server cannot do for a phone on its own:

1. One sign-in (the dashboard username/password) yields a signed bearer token, so the phone never
   holds the eleven per-profile API_SERVER_KEYs. The keys stay in this process.
2. One list of every session across every profile (merged by last activity, cursor-paged),
   plus title search and archived sessions, read-only from each profile's state.db.
3. A whitelisted pass-through to /p/<profile>/... (sessions, runs, model catalog) that adds the
   right key and streams SSE untouched.

Binds to loopback only; reach it through `tailscale serve`. Stdlib only (system python3).
"""
import base64, hashlib, hmac, http.client, json, os, re, secrets, sqlite3, sys, threading, time
from collections import deque
from datetime import datetime, timezone
from contextlib import closing
from concurrent.futures import Future, ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HOME = Path.home()
HERMES = Path(os.environ.get("HERMES_HOME", HOME / ".hermes"))
STATE_DIR = HERMES / "mobile"
PORT = int(os.environ.get("HERMES_MOBILE_PORT", "9131"))
UPSTREAM = ("127.0.0.1", int(os.environ.get("HERMES_API_PORT", "8642")))
TOKEN_TTL = 180 * 86400
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
# Gateway paths the phone may reach (relative to /p/<profile>/).
PASS = re.compile(r"^/(api/sessions(/[^/]+(/(messages|model|fork))?)?|v1/runs(/[^/]+(/(events|stop|approval|steer))?)?"
                  r"|api/model/options|v1/models|health)$")
MAX_BODY = 12 * 1024 * 1024
POOL = ThreadPoolExecutor(max_workers=16)
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import bridge_turns as turns  # needs Hermes's venv (hermes_cli.gateway_client)
    TURNS_ERROR = None
except Exception as _e:  # pragma: no cover
    turns, TURNS_ERROR = None, "%s: %s" % (type(_e).__name__, _e)


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


# ---------- config ----------
def env_value(path, key):
    val = ""
    try:
        for line in path.read_text().splitlines():
            if line.startswith(key + "="):
                val = line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return val  # last one wins, like dotenv


def basic_auth():
    text = (HERMES / "config.yaml").read_text()
    m = re.search(r"^dashboard:\n(?:[ \t]+.*\n)*?[ \t]+basic_auth:\n((?:[ \t]{4,}.*\n)+)", text, re.M)
    block = m.group(1) if m else ""

    def get(k):
        mm = re.search(r"^\s+%s:\s*(.+)$" % k, block, re.M)
        return mm.group(1).strip().strip('"').strip("'") if mm else ""
    return get("username"), get("password")


def model_default(cfg):
    try:
        text = cfg.read_text()
    except OSError:
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


def fleet_meta():
    """Display names and one-line roles from the fleet list in the main SOUL.md."""
    meta = {}
    try:
        text = (HERMES / "SOUL.md").read_text()
    except OSError:
        return meta, "Hermes"
    for m in re.finditer(r"^- `([a-z0-9_-]+)`(?: \(([^)]+)\))?:\s*(.+(?:\n  \S.*)*)", text, re.M):
        blurb = re.sub(r"\s+", " ", m.group(3)).replace("`", "").strip()
        meta[m.group(1)] = (m.group(2) or "", (blurb[:1].upper() + blurb[1:])[:140])
    me = re.search(r"^I'm ([^\s—-]+(?: [A-Z][^\s—-]+)?)\s*[—-]", text, re.M)
    return meta, (me.group(1) if me else "Hermes")


def profile_home(pid):
    return HERMES if pid == "default" else HERMES / "profiles" / pid


# Hermes's own rule (hermes_constants.named_profile_is_live): a folder under profiles/ is a bot when it
# carries an identity marker and has no deletion tombstone. A brand-new bot has no config.yaml yet.
_PROFILE_MARKERS = ("config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db")


def is_live_profile(home):
    return (home.is_dir() and not home.name.startswith(".")
            and any((home / m).is_file() or (home / m).is_symlink() for m in _PROFILE_MARKERS)
            and not (home.parent / ".deleted" / home.name).exists())

def profile_ids():
    out = ["default"]
    pdir = HERMES / "profiles"
    if pdir.is_dir():
        out += sorted(p.name for p in pdir.iterdir() if PROFILE_RE.match(p.name) and is_live_profile(p))
    return out


def key_for(pid):
    if pid != "default" and not PROFILE_RE.match(pid):
        return ""
    return env_value(profile_home(pid) / ".env", "API_SERVER_KEY")


def bots():
    meta, front = fleet_meta()
    gmodel, gprov = model_default(HERMES / "config.yaml")
    served = served_profiles()
    out = []
    for pid in profile_ids():
        m, pv = (gmodel, gprov) if pid == "default" else model_default(profile_home(pid) / "config.yaml")
        if pid == "default":
            name, blurb = front, "The front door. Does the work or hands it to the right bot."
        else:
            nm, blurb = meta.get(pid, ("", ""))
            name = nm or pid.replace("-", " ").replace("_", " ").title().replace("Captains", "Captain's")
        out.append({"id": pid, "name": name, "blurb": blurb, "model": m or gmodel, "provider": pv or gprov,
                    "reachable": bool(key_for(pid)), "served": pid in served,
                    "front": pid == "default"})
    return out


def served_profiles():
    """Profiles the running gateway serves (it hot-serves new ones on its own; see gateway_state.json)."""
    try:
        return set(json.loads((HERMES / "gateway_state.json").read_text()).get("served_profiles") or [])
    except Exception:
        return set()


# ---------- new bots: give them an API key so the phone can reach them ----------
AUTO_KEYS = os.environ.get("HERMES_MOBILE_AUTO_KEYS", "1") != "0"
KEY_SETTLE_S = 30  # leave a bot's .env alone until nothing has written to it for this long


OPT_OUT = "# hermes-mobile: no-key"
KEYS_STATE = STATE_DIR / "auto_keys.json"


def _keys_state():
    try:
        d = json.loads(KEYS_STATE.read_text())
        return {"had_key": set(d.get("had_key") or []), "given": set(d.get("given") or [])}
    except Exception:
        return {"had_key": set(), "given": set()}


def _save_keys_state(st):
    tmp = KEYS_STATE.with_name(".auto_keys.%s" % secrets.token_hex(4))
    tmp.write_text(json.dumps({k: sorted(v) for k, v in st.items()}))
    os.replace(tmp, KEYS_STATE)


def ensure_profile_keys():
    """A bot created after setup has no API_SERVER_KEY, and the gateway's API server refuses a profile
    without one, so the phone couldn't list or open its chats. For each bot the gateway already serves,
    back up its .env and append a fresh key (the gateway notices .env changes and picks it up live).

    Only ever for a bot that has never had a key, and only once: a key you remove stays removed.
    Opt a bot out with a line `# hermes-mobile: no-key` in its .env, or all of them with
    HERMES_MOBILE_AUTO_KEYS=0."""
    if not AUTO_KEYS:
        return []
    added = []
    served = served_profiles()
    st = _keys_state()
    before = {k: set(v) for k, v in st.items()}
    for pid in profile_ids():
        if pid == "default":
            continue
        if key_for(pid):
            st["had_key"].add(pid)
            continue
        if pid not in served or pid in st["had_key"] or pid in st["given"]:
            continue
        env = profile_home(pid) / ".env"
        try:
            if env.is_symlink():
                continue  # managed elsewhere; never write through a link
            if env.exists() and OPT_OUT in env.read_text():
                continue
            if env.exists() and time.time() - env.stat().st_mtime < KEY_SETTLE_S:
                continue  # Hermes may still be setting the bot up
            backup = HERMES / "backups" / "hermes-mobile-auto" / time.strftime("%Y%m%d-%H%M%S") / pid
            backup.mkdir(parents=True, exist_ok=True)
            old = env.read_text() if env.exists() else ""
            if env.exists():
                (backup / ".env").write_text(old)
                os.chmod(backup / ".env", 0o600)
            sep = "" if not old or old.endswith("\n") else "\n"
            with open(env, "a") as f:
                f.write("%s\n# Added by Hermes Mobile %s so the phone app can reach this bot\nAPI_SERVER_KEY=%s\n"
                        % (sep, time.strftime("%Y-%m-%d"), secrets.token_hex(32)))
            os.chmod(env, 0o600)
            st["given"].add(pid)
            added.append(pid)
            log("gave new bot %r an API_SERVER_KEY (backup in %s)" % (pid, backup))
        except Exception as e:
            log("could not add an API key for %r: %s" % (pid, e))
    if st != before:
        try:
            _save_keys_state(st)
        except Exception as e:
            log("could not save %s: %s" % (KEYS_STATE, e))
    return added


def _key_watcher():
    while True:
        try:
            ensure_profile_keys()
        except Exception as e:
            log("key watcher: %s" % e)
        time.sleep(20)


# ---------- status (the Mac status dashboard's data, for the phone) ----------
STATUS_URL = os.environ.get("HERMES_STATUS_URL", "http://127.0.0.1:9230/api/status")


def status_payload(refresh_providers=False):
    """The status dashboard's /api/status (bots, cron jobs, what's running, providers, what's new),
    plus the turns the phone itself has running through this bridge."""
    url = STATUS_URL + ("?refresh=providers" if refresh_providers else "")
    parts = urlsplit(url)
    c = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=90)
    try:
        c.request("GET", parts.path + ("?" + parts.query if parts.query else ""))
        r = c.getresponse()
        raw = r.read()
        if r.status != 200:
            return None
        d = json.loads(raw)
    finally:
        c.close()
    if turns is not None:
        agents = d.setdefault("agents", [])
        for t in turns.live_turns():
            if t["done"]:
                continue
            same = next((a for a in agents if a.get("profile") == t["profile"]
                         and a.get("session_id") == t["session_id"]), None)
            if same:
                same["kind"] = "phone"  # the gateway's own lease for this turn
            else:
                agents.append({"kind": "phone", "profile": t["profile"], "session_id": t["session_id"],
                               "title": "Reply started from the phone", "age_s": t["age"]})
                for b in d.get("bots") or []:
                    if b.get("id") == t["profile"]:
                        b["running"] = (b.get("running") or 0) + 1
    return d


# ---------- auth ----------
def _secret():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    f = STATE_DIR / "secret"
    if not f.exists():
        f.write_text(secrets.token_hex(32))
        os.chmod(f, 0o600)
    return f.read_text().strip().encode()


SECRET = _secret()
# Login throttle, kept per Tailscale identity (tailscale serve sets Tailscale-User-Login), so one
# device's bad guesses can't lock the owner out. One login is checked at a time, so the 0.6 s delay
# really bounds the guess rate instead of being raced past with parallel requests.
FAILS: dict = {}
FAILS_LOCK = threading.Lock()
LOGIN_GATE = threading.Semaphore(1)


def make_token(device):
    payload = base64.urlsafe_b64encode(json.dumps(
        {"exp": int(time.time()) + TOKEN_TTL, "dev": device[:60], "n": secrets.token_hex(4)}).encode()).decode().rstrip("=")
    sig = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()
    return "hm1." + payload + "." + sig


def token_ok(tok):
    try:
        ver, payload, sig = tok.split(".")
        if ver != "hm1" or not hmac.compare_digest(sig, hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()):
            return False
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return int(data["exp"]) > time.time()
    except Exception:
        return False


# ---------- gateway ----------
def gw(method, pid, path, body=None, timeout=20):
    """One JSON request to the gateway for profile `pid`. Returns (status, parsed-json-or-None)."""
    key = key_for(pid)
    if not key:
        return 401, {"error": "profile %s has no API_SERVER_KEY" % pid}
    up = path if pid == "default" else "/p/%s%s" % (pid, path)
    headers = {"Authorization": "Bearer " + key, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    c = http.client.HTTPConnection(*UPSTREAM, timeout=timeout)
    try:
        c.request(method, up, body=data, headers=headers)
        r = c.getresponse()
        raw = r.read()
        try:
            return r.status, json.loads(raw) if raw else None
        except ValueError:
            return r.status, None
    finally:
        c.close()


def _ro(pid):
    db = profile_home(pid) / "state.db"
    if not db.exists():
        return None
    con = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    con.row_factory = sqlite3.Row
    return con


def _cursor_decode(raw):
    try:
        return json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))) if raw else {}
    except Exception:
        return {}


def _cursor_encode(d):
    return base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).decode().rstrip("=")


def _ts(s):
    return s.get("last_active") or s.get("started_at") or 0


# Use Hermes's own visibility, compression lineage and ordering rules. Older
# installs keep the gateway listing path and its existing cursor format.
try:
    runtime = HERMES / "hermes-agent"
    if runtime.is_dir() and str(runtime) not in sys.path:
        sys.path.insert(1, str(runtime))
    from hermes_state import SessionDB
    from inspect import signature
    NATIVE_INBOX = ("read_only" in signature(SessionDB).parameters and
                    {"compact_rows", "include_pinned", "exclude_sources"}.issubset(
                        signature(SessionDB.list_sessions_rich).parameters))
    INBOX_FALLBACK = None if NATIVE_INBOX else "Unsupported Hermes listing API"
except (ImportError, AttributeError, ValueError, TypeError) as exc:
    NATIVE_INBOX = False
    INBOX_FALLBACK = type(exc).__name__


def native_inbox_window(pid, offset, limit, exclude, first_page):
    def summary(row):
        # Native rich rows can contain session metadata private to the gateway.
        fields = ("id", "source", "model", "title", "preview", "started_at",
                  "ended_at", "last_active", "message_count")
        return {**{k: row.get(k) for k in fields}, "pinned": bool(row.get("pinned")),
                "archived": bool(row.get("archived"))}

    with closing(SessionDB(profile_home(pid) / "state.db", read_only=True)) as db:
        options = dict(compact_rows=True, exclude_sources=list(exclude), order_by_last_active=True)
        rows = db.list_sessions_rich(limit=limit + 1, offset=offset, **options)
        pins = db.list_sessions_rich(limit=0, include_pinned=True, **options) if first_page else []
    return [summary(r) for r in rows[:limit]], [summary(r) for r in pins], len(rows) > limit


def _page_round(offsets, pids, limit, exclude, first_page, telegram=False, native=False):
    """One fetch round across profiles. Returns (rows, pins, new_offsets, done, errors, more_left)."""
    exhausted = set(offsets.get("_done", []))
    live = [p for p in pids if p not in exhausted]
    batch = min(100, limit * (3 if exclude else 1))
    eligible_profiles = served_profiles() if native else set()

    def fetch(pid):
        off = int(offsets.get(pid, 0))
        if native:
            try:
                if pid not in eligible_profiles:
                    return pid, None, "Profile unavailable"
                return pid, native_inbox_window(pid, off, limit, exclude, first_page), None
            except Exception as error:
                return pid, None, type(error).__name__
        if telegram:
            try:
                con = _ro(pid)
                if con is None:
                    return pid, ([], [], False), None
                try:
                    rows = con.execute("SELECT " + SESSION_COLS + " FROM sessions WHERE source='telegram' "
                                       "AND coalesce(hidden,0)=0 AND coalesce(archived,0)=0 "
                                       "ORDER BY last_active DESC, id LIMIT ? OFFSET ?", (batch + 1, off)).fetchall()
                    return pid, ([dict(row, archived=False) for row in rows[:batch]], [], len(rows) > batch), None
                finally:
                    con.close()
            except sqlite3.Error as error:
                return pid, None, type(error).__name__
        try:
            st, d = gw("GET", pid, "/api/sessions?limit=%d&offset=%d" % (batch, off))
        except Exception as e:
            return pid, None, type(e).__name__
        if st != 200 or not isinstance(d, dict):
            return pid, None, "HTTP %s" % st
        data = d.get("data") or []
        # The gateway's window is LIMIT/OFFSET over every row (pinned ones included); pins the window
        # missed are back-filled after it. The window therefore ends at the last unpinned row.
        last_unpinned = max((i for i, r in enumerate(data) if not r.get("pinned")), default=-1)
        window, backfill = data[:last_unpinned + 1], data[last_unpinned + 1:]
        more = len(window) >= batch  # the gateway's own has_more ignores in-window pins
        return pid, (window, backfill, more), None

    fetched, errors = {}, {}
    for pid, res, err in POOL.map(fetch, live):
        if err:
            errors[pid] = err
            continue
        for r in res[0] + res[1]:
            r["profile"] = pid
        fetched[pid] = res
    keep = lambda r: r.get("source") not in exclude
    # A profile that still has rows may hold unseen rows as new as its last fetched one: nothing
    # older than that may be emitted yet, or those rows would land on a later page out of order.
    safe = max((_ts(w[-1]) for w, _, more in fetched.values() if more and w), default=None)
    candidates = sorted((r for w, _, _ in fetched.values() for r in w if keep(r) and not r.get("pinned")),
                        key=_ts, reverse=True)
    eligible = [r for r in candidates if safe is None or _ts(r) >= safe]
    if len(eligible) >= limit:
        cutoff = _ts(eligible[limit - 1])
    else:
        cutoff = safe  # None: every profile is exhausted, so everything fetched is final
    page = [r for r in eligible if cutoff is None or _ts(r) >= cutoff]  # ties stay together
    new_off, done = {}, set(exhausted)
    for pid in pids:
        off = int(offsets.get(pid, 0))
        if pid not in fetched:
            new_off[pid] = off
            continue
        window, _, more = fetched[pid]
        used = len(window) if cutoff is None else sum(1 for r in window if _ts(r) >= cutoff)
        new_off[pid] = off + used
        if not more and used >= len(window):
            done.add(pid)
    pins = [r for w, bf, _ in fetched.values() for r in w + bf if r.get("pinned") and keep(r)] if first_page else []
    new_off["_done"] = sorted(done)
    # A profile that errored keeps its offset and is retried by the next cursor.
    more_left = any(p not in done for p in pids)
    return page, pins, new_off, done, errors, more_left


def all_sessions(limit, cursor, only=None, exclude=(), telegram=False, compact=False):
    """Merge every profile's /api/sessions (each sorted by last activity) into one page.

    The cursor holds a per-profile offset. Excluded sources (cron, one-shot...) are skipped but still
    consumed. Rows are only emitted down to the newest point every unfinished profile has reached, so
    paging stays exact while the lists interleave; a round that yields nothing fetches again."""
    offsets = _cursor_decode(cursor)
    reset = bool(offsets.get("_native")) and not NATIVE_INBOX
    if reset:
        offsets = {}
    first_page = not offsets
    pids = [p for p in profile_ids() if (not only or p in only) and key_for(p)]
    native = compact and not telegram and NATIVE_INBOX and (first_page or offsets.get("_native") == 1)
    if native:
        served = served_profiles()
        if first_page:
            native = all(p in served and (profile_home(p) / "state.db").is_file() for p in pids)

    page, pins, errors, more_left = [], [], {}, True
    for _ in range(6):
        rows, round_pins, offsets, _done, errs, more_left = _page_round(offsets, pids, limit, exclude, first_page, telegram, native)
        page += rows
        pins += round_pins
        errors.update(errs)
        first_page = False
        if len(page) >= limit or not more_left or (errs and not rows):
            break
    seen, uniq = set(), []
    for r in sorted(pins, key=_ts, reverse=True) + page:
        k = (r["profile"], r["id"])
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    if native:
        offsets["_native"] = 1
    return {"data": uniq, "reset": reset, "next": _cursor_encode(offsets) if more_left else None, "errors": errors}


SESSION_COLS = ("id, source, model, title, started_at, ended_at, message_count, archived, "
                "coalesce(last_activity_at, started_at) AS last_active, parent_session_id")


def search_sessions(q, archived=False, limit=40, profile=None, source=None):
    """Title/preview search (and the archived list) straight from each state.db, read-only."""
    out = []
    like = "%" + q.replace("%", "").replace("_", "") + "%" if q else None
    for pid in profile_ids():
        if profile is not None and pid != profile:
            continue
        try:
            con = _ro(pid)
        except Exception:
            continue
        if con is None:
            continue
        try:
            where = ["coalesce(hidden,0)=0", "archived=%d" % (1 if archived else 0),
                     "source NOT IN ('subagent','tool')"]
            args = []
            if source:
                where.append("source=?")
                args.append(source)
            if like:
                where.append("(title LIKE ? OR id IN (SELECT session_id FROM messages WHERE role='user' AND content LIKE ? "
                             "ORDER BY id DESC LIMIT 400))")
                args += [like, like]
            sql = "SELECT %s FROM sessions WHERE %s ORDER BY last_active DESC LIMIT %d" % (
                SESSION_COLS, " AND ".join(where), limit)
            for r in con.execute(sql, args):
                d = dict(r)
                d["profile"] = pid
                d["archived"] = bool(d["archived"])
                out.append(d)
        except sqlite3.Error as e:
            log("search %s: %s" % (pid, e))
        finally:
            con.close()
    out.sort(key=lambda s: s.get("last_active") or 0, reverse=True)
    return out[:limit]


def session_runtime(pid, sid):
    """What actually served the session's latest turn, from state.db — the proof the app shows."""
    con = _ro(pid)
    if con is None:
        return None
    try:
        r = con.execute("SELECT id, model, billing_provider, model_config, reasoning_tokens, input_tokens, "
                        "output_tokens, api_call_count, coalesce(last_activity_at, started_at) AS last_active "
                        "FROM sessions WHERE id=?", (sid,)).fetchone()
        if not r:
            return None
        d = dict(r)
        try:
            mc = json.loads(d.pop("model_config") or "{}")
        except ValueError:
            mc = {}
        rt = mc.get("gateway_runtime") or {}
        lock = mc.get("browser_model_lock") or {}
        d["provider"] = rt.get("provider") or d.get("billing_provider") or mc.get("provider") or ""
        d["fallback_active"] = bool(rt.get("fallback_active"))
        opts = lock.get("model_options") or {}
        d["lock"] = {"provider": lock.get("provider") or "", "model": lock.get("model") or "",
                     "effort": ((opts.get("reasoning") or {}).get("effort") or opts.get("reasoning_effort") or ""),
                     "confirmed": bool(lock.get("confirmed"))} if lock else None
        # The session's own setting (what session.mutate wrote; what the desktop shows and the next turn runs).
        d["policy"] = None
        try:
            row = con.execute("SELECT value FROM state_meta WHERE key=?", ("gateway.local_policy.v1:" + sid,)).fetchone()
            pol = (json.loads(row[0]) or {}).get("policy") or {} if row else {}
            cfg = json.loads(pol.get("config_json") or "{}") if pol else {}
            if pol:
                d["policy"] = {"model": pol.get("model") or (cfg.get("model") or {}).get("default") or "",
                               "provider": (cfg.get("model") or {}).get("provider") or "",
                               "effort": (cfg.get("agent") or {}).get("reasoning_effort") or ""}
        except (sqlite3.Error, ValueError, TypeError):
            pass
        # Hermes's own per-model ledger for this session: which models actually answered, with reasoning tokens.
        try:
            # One row per model + provider (Hermes keeps separate rows per endpoint / task).
            d["models_used"] = [dict(r) for r in con.execute(
                "SELECT model, billing_provider AS provider, SUM(api_call_count) AS calls, "
                "SUM(reasoning_tokens) AS reasoning_tokens, MAX(last_seen) AS last_seen "
                "FROM session_model_usage WHERE session_id=? GROUP BY model, billing_provider "
                "ORDER BY MAX(last_seen) DESC LIMIT 8", (sid,))]
        except sqlite3.Error:
            d["models_used"] = []
        return d
    finally:
        con.close()


_health_history = deque(maxlen=8)
_health_lock = threading.Lock()
_last_probe = 0.0


def _signal(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _recent(value, now):
    try:
        age = now - datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        return -5 <= age < 120
    except (TypeError, AttributeError, ValueError, OverflowError):
        return False


def gateway_phase(ok, api_state, state, life, now):
    fresh = _recent(state.get("updated_at"), now)
    state_name = str(state.get("gateway_state") or "").lower()
    api_state = str(api_state or "").lower()
    if ok and api_state in ("running", "healthy", "ready", "ok") and state_name != "draining":
        return "running"
    if fresh and state.get("restart_requested") is True:
        return "restarting"
    if api_state in ("starting", "restarting", "draining", "stopping"):
        return api_state
    if ok and api_state not in ("stopped", "down", "failed", "offline"):
        return "running"
    if fresh and state_name in ("starting", "restarting", "draining", "stopping"):
        return state_name
    if fresh and state_name == "stopped" and life.get("phase") != "running":
        return "stopped"
    if life.get("phase") == "exited" and _recent(life.get("exited_at"), now):
        return "restarting" if "restart" in str(life.get("exit_reason", "")).lower() else "stopped"
    if life.get("phase") == "running" and _recent(life.get("started_at"), now):
        return "starting"
    return "unavailable"


def health():
    global _last_probe
    started = time.monotonic()
    try:
        st, data = gw("GET", "default", "/health/detailed", timeout=4)
        info = data if isinstance(data, dict) else {}
        ok = st == 200
        reason = None if ok else "Gateway health returned HTTP %d" % st
    except (OSError, http.client.HTTPException, ValueError) as exc:
        info, ok = {}, False
        reason = "Gateway probe timed out" if isinstance(exc, TimeoutError) else "Gateway did not accept the connection"
    api_state = info.get("gateway_state") or info.get("status")
    now = time.time()
    phase = gateway_phase(ok, api_state, _signal(HERMES / "gateway_state.json"),
                          _signal(HERMES / "state" / "gateway.lifecycle.json"), now)
    with _health_lock:
        # Some supervisors gracefully stop then spawn a replacement without
        # declaring restart intent. Show that bounded handoff as waiting.
        if phase in ("unavailable", "stopped") and any(
            e["phase"] in ("draining", "stopping", "restarting") and 0 <= now - e["at"] < 45
            for e in _health_history
        ) and _health_history[-1]["phase"] in ("draining", "stopping", "restarting", "waiting"):
            phase = "waiting"
        if started >= _last_probe:
            _last_probe = started
            if not _health_history or _health_history[-1]["phase"] != phase:
                _health_history.append({"phase": phase, "at": now})
        history = list(reversed(_health_history))
    return {"ok": ok, "gateway_state": api_state, "phase": phase, "reason": reason,
            "recent": history, "version": info.get("version"), "platforms": list((info.get("platforms") or {}).keys()),
            "inbox_reader": "native" if NATIVE_INBOX else "gateway", "inbox_fallback": INBOX_FALLBACK}


# Short-lived first-page cache shared by tabs/devices on this single-user bridge.
# Cursors are always evaluated fresh. Concurrent readers share the upstream fetch.
_page_lock = threading.Lock()
_pages = {}
_pending_pages = {}
_page_epoch = 0


def invalidate_pages():
    global _page_epoch
    with _page_lock:
        _page_epoch += 1
        _pages.clear()


def session_page(limit, cursor, only, exclude, telegram, compact=False):
    if cursor:
        return all_sessions(limit, cursor, only, exclude, telegram, compact)
    key = (limit, tuple(sorted(only or ())), tuple(sorted(exclude)), telegram, compact)
    with _page_lock:
        epoch = _page_epoch
        cached = _pages.get(key)
        if cached and time.monotonic() < cached[0]:
            return cached[1]
        flight = (_page_epoch, key)
        future = _pending_pages.get(flight)
        owner = future is None
        if owner:
            future = _pending_pages[flight] = Future()
    if not owner:
        return future.result()
    try:
        page = all_sessions(limit, None, only, exclude, telegram, compact)
        with _page_lock:
            if not page["errors"] and epoch == _page_epoch:
                if len(_pages) >= 24 and key not in _pages:
                    del _pages[next(iter(_pages))]
                _pages[key] = (time.monotonic() + 6, page)
        future.set_result(page)
        return page
    except Exception as error:
        future.set_exception(error)
        raise
    finally:
        with _page_lock:
            _pending_pages.pop(flight, None)


# ---------- HTTP ----------
class H(BaseHTTPRequestHandler):
    server_version = "HermesMobile/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def send(self, code, body=b"", ctype="application/json", close=False):
        if self.command in ("POST", "PATCH", "DELETE") and 200 <= code < 300:
            invalidate_pages()
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if close:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self):
        return getattr(self, "_body", b"")

    def _read_body(self):
        """Read the declared body before anything else, so no reply can leave unread bytes on a
        keep-alive connection (tailscale serve pools one upstream connection across clients; leftover
        bytes would be parsed as somebody else's request). Returns False after answering a bad body."""
        self._body = b""
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            self.send(400, {"error": "Chunked bodies are not supported."}, close=True)
            return False
        raw = self.headers.get("Content-Length") or "0"
        try:
            n = int(raw)
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            self.close_connection = True
            self.send(413 if n > MAX_BODY else 400, {"error": "Bad request body."}, close=True)
            return False
        self._body = self.rfile.read(n) if n else b""
        return True

    def authed(self):
        h = self.headers.get("Authorization") or ""
        return h.startswith("Bearer ") and token_ok(h[7:].strip())

    def route(self):
        if not self._read_body():
            return
        u = urlsplit(self.path)
        path, q = u.path, {k: v[-1] for k, v in parse_qs(u.query).items()}
        if path == "/m/ping":
            return self.send(200, {"ok": True, "app": "hermes-mobile-bridge", "version": 1})
        if path == "/m/login" and self.command == "POST":
            return self.login()
        if not self.authed():
            return self.send(401, {"error": "Sign in again."})
        if self.command == "GET":
            if path == "/m/health":
                return self.send(200, health())
            if path == "/m/bots":
                return self.send(200, {"bots": bots()})
            if path == "/m/status":
                why = "it answered with an error"
                try:
                    d = status_payload(q.get("refresh") == "providers")
                except Exception as e:
                    d, why = None, "%s: %s" % (type(e).__name__, str(e)[:120])
                if d is None:
                    return self.send(503, {"error": "The Hermes status dashboard on your Mac (%s) isn't answering: %s."
                                                    % (STATUS_URL, why)})
                return self.send(200, d)
            if path in ("/m/sessions", "/m/telegram"):
                limit = max(1, min(int(q.get("limit", "40") or 40), 100))
                only = set(q["profile"].split(",")) if q.get("profile") else None
                exclude = tuple(x for x in q.get("exclude", "").split(",") if x)
                return self.send(200, session_page(limit, q.get("cursor"), only, exclude, path == "/m/telegram", q.get("view") == "compact"))
            if path == "/m/search":
                return self.send(200, {"data": search_sessions(q.get("q", "").strip(), archived=q.get("archived") == "1", profile=q.get("profile"), source=q.get("source"))})
            m = re.match(r"^/m/runtime/([^/]+)/([^/]+)$", path)
            if m:
                d = session_runtime(m.group(1), m.group(2)) if (m.group(1) == "default" or PROFILE_RE.match(m.group(1))) else None
                return self.send(200 if d else 404, d or {"error": "not found"})
        if path.startswith("/m/p/"):
            return self.proxy(path, u.query)
        if path.startswith("/m/chat/") or path.startswith("/m/turns"):
            return self.chat_route(path, q)
        self.send(404, {"error": "not found"})

    # ---- chats through the gateway's canonical session protocol (the desktop app's) ----
    def chat_route(self, path, q):
        if turns is None:
            return self.send(503, {"error": "Turn engine unavailable: %s" % TURNS_ERROR})
        try:
            if path == "/m/turns" and self.command == "GET":
                return self.send(200, {"turns": turns.live_turns()})
            m = re.match(r"^/m/turns/(turn_[0-9a-f]{32})(/events|/stop|/approval|/queue|/steer)?$", path)
            if m:
                turn = turns.get_turn(m.group(1))
                if turn is None:
                    return self.send(404, {"error": "That reply is no longer running."})
                action = m.group(2) or ""
                if action == "/events" and self.command == "GET":
                    last = self.headers.get("Last-Event-ID") or q.get("after")
                    return self.tail(turn, int(last) + 1 if last not in (None, "") and str(last).lstrip("-").isdigit() else 0)
                if action in ("/queue", "/steer") and self.command == "POST":
                    body = self.json_body()
                    return self.send(200, turns.follow_up(turn, action[1:], body.get("text"), body.get("submission_id")))
                if action == "/stop" and self.command == "POST":
                    turns.stop(turn)
                    return self.send(200, {"ok": True})
                if action == "/approval" and self.command == "POST":
                    d = self.json_body()
                    turns.approve(turn, str(d.get("choice") or "deny"), d.get("request_id"), d.get("execution_generation"))
                    return self.send(200, {"ok": True})
                if not action and self.command == "GET":
                    return self.send(200, turn.summary())
                return self.send(405, {"error": "method not allowed"})
            m = re.match(r"^/m/chat/([^/]+)/(new|[^/]+/(?:send|runtime))$", path)
            if not m or self.command != "POST":
                return self.send(404, {"error": "not found"})
            pid = m.group(1)
            if pid not in profile_ids():
                return self.send(404, {"error": "unknown bot"})
            home = profile_home(pid)
            d = self.json_body()
            if m.group(2) == "new":
                return self.send(201, turns.create_session(home, pid, d.get("title")))
            sid, action = m.group(2).rsplit("/", 1)
            if action == "runtime":
                before = (session_runtime(pid, sid) or {}).get("policy")
                applied = turns.set_runtime(home, sid, d)
                # Hermes writes the session's policy row a moment after session.mutate answers: wait for
                # it, so the phone's next read shows the new setting instead of the old one.
                after = before
                for _ in range(20):
                    after = (session_runtime(pid, sid) or {}).get("policy")
                    if after != before:
                        break
                    time.sleep(0.1)
                return self.send(200, {"applied": applied, "policy": after})
            text = str(d.get("text") or "").strip()
            if not text:
                return self.send(400, {"error": "Empty message."})
            turn = turns.start_turn(pid, home, sid, text, {k: d.get(k) for k in ("provider", "model", "effort", "reset_model", "reset_effort")})
            return self.send(202, turn.summary())
        except turns.TurnError as e:
            return self.send(e.code, {"error": str(e)})
        except Exception as e:
            log("chat route %s failed: %s: %s" % (path, type(e).__name__, e))
            return self.send(502, {"error": "%s: %s" % (type(e).__name__, str(e)[:200])})

    def json_body(self):
        try:
            d = json.loads(self.body() or b"{}")
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def tail(self, turn, offset):
        """SSE of a turn's buffered events from `offset`; resumable with Last-Event-ID."""
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            idle = 0
            while True:
                with turn.cond:
                    if len(turn.events) <= offset and not turn.done:
                        turn.cond.wait(15)
                    batch = turn.events[offset:]
                    done = turn.done
                for ev in batch:
                    self.wfile.write(("id: %d\ndata: %s\n\n" % (ev["seq"], json.dumps(ev))).encode())
                offset += len(batch)
                if batch:
                    self.wfile.flush()
                    idle = 0
                elif done:
                    break
                else:
                    idle += 1
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    do_GET = do_POST = do_PATCH = do_DELETE = lambda self: self.route()

    def login(self):
        who = (self.headers.get("Tailscale-User-Login") or "local").strip().lower()[:120]
        with FAILS_LOCK:
            f = FAILS.setdefault(who, {"n": 0, "until": 0.0})
            if time.time() < f["until"]:
                return self.send(429, {"error": "Too many attempts. Wait a minute."})
        try:
            d = json.loads(self.body() or b"{}")
        except Exception:
            d = {}
        user, pw = basic_auth()
        with LOGIN_GATE:  # one check at a time: parallel requests can't multiply the guess rate
            with FAILS_LOCK:
                if time.time() < f["until"]:
                    return self.send(429, {"error": "Too many attempts. Wait a minute."})
            ok = (bool(pw) and hmac.compare_digest(str(d.get("username", "")).encode(), user.encode())
                  and hmac.compare_digest(str(d.get("password", "")).encode(), pw.encode()))
            if not ok:
                time.sleep(0.6)
                with FAILS_LOCK:
                    f["n"] += 1
                    if f["n"] >= 5:
                        f["n"], f["until"] = 0, time.time() + 60
                log("login failed for %r" % who)
                return self.send(401, {"error": "Wrong username or password."})
            with FAILS_LOCK:
                f["n"] = 0
        log("login ok for %r device %r" % (who, str(d.get("device", ""))[:60]))
        return self.send(200, {"token": make_token(str(d.get("device", "iphone"))), "ttl": TOKEN_TTL})

    def proxy(self, path, query):
        m = re.match(r"^/m/p/([^/]+)(/.*)$", path)
        if not m or not PASS.match(m.group(2)) or ".." in path:
            return self.send(404, {"error": "not found"})
        pid, tail = m.group(1), m.group(2)
        # Reads, plus PATCH of a session's flags (pin / archive / title). Turns, model switches and
        # anything else that writes go through /m/chat, never straight to the gateway.
        if not (self.command == "GET" or (self.command == "PATCH" and re.match(r"^/api/sessions/[^/]+$", tail))):
            return self.send(405, {"error": "method not allowed"})
        key = key_for(pid)
        if not key:
            return self.send(404, {"error": "unknown or unreachable bot"})
        data = self.body() if self.command in ("POST", "PATCH") else None
        up = (tail if pid == "default" else "/p/%s%s" % (pid, tail)) + ("?" + query if query else "")
        headers = {"Authorization": "Bearer " + key, "Accept": self.headers.get("Accept", "*/*")}
        for h in ("Last-Event-ID", "Idempotency-Key"):
            if self.headers.get(h):
                headers[h] = self.headers[h]
        if data:
            headers["Content-Type"] = self.headers.get("Content-Type", "application/json")
        stream = tail.endswith("/events")
        try:
            c = http.client.HTTPConnection(*UPSTREAM, timeout=900 if stream else 120)
            c.request(self.command, up, body=data, headers=headers)
            r = c.getresponse()
        except Exception as e:
            return self.send(502, {"error": "Hermes gateway is not answering (%s)." % type(e).__name__})
        try:
            if not stream:
                raw = r.read()
                self.send(r.status, raw, r.getheader("Content-Type") or "application/json")
                return
            self.send_response(r.status)
            self.send_header("Content-Type", r.getheader("Content-Type") or "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            while True:
                chunk = r.read1(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the phone went away; /v1/runs keeps running on the gateway and can be re-attached
        finally:
            c.close()


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--issue-token":
        # Pair a device without typing the password: prints a token to paste into the app.
        print(make_token(sys.argv[2] if len(sys.argv) > 2 else "paired-device"))
        sys.exit(0)
    threading.Thread(target=_key_watcher, name="key-watcher", daemon=True).start()
    srv = ThreadingHTTPServer((os.environ.get("HERMES_MOBILE_BIND", "127.0.0.1"), PORT), H)
    srv.daemon_threads = True
    log("Hermes Mobile bridge on http://%s:%d -> gateway %s:%d" % (srv.server_address[0], PORT, *UPSTREAM))
    srv.serve_forever()
