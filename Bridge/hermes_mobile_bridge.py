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

5. Optional single-owner project workspaces (HERMES_MOBILE_WORKSPACES). Device tokens share the
   bridge's chats and tools. One-time pairing grants do not authorize owner management.

Binds to loopback only; reach it through `tailscale serve`. Stdlib only (system python3).
"""
import base64, hashlib, hmac, http.client, json, os, re, secrets, sqlite3, sys, threading, time
from tempfile import NamedTemporaryFile
from functools import lru_cache
from collections import deque
from datetime import datetime, timezone
from contextlib import closing
from concurrent.futures import Future, ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

# The bridge embeds Hermes libraries. A library import must never relaunch the
# HTTP service under a different interpreter or update the host installation.
os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"

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
WS_MAX_BODY = 64 * 1024  # Fits an 8 KiB file JSON-escaped (\u00XX per control byte) or 4 KiB instructions.
WS_BODY_TIMEOUT = 10
WS_SETTING = "HERMES_MOBILE_WORKSPACES"
WS_BOTS_SETTING = "HERMES_MOBILE_WORKSPACE_BOTS"
POOL = ThreadPoolExecutor(max_workers=16)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge_projects
import bridge_devices
import bridge_receipts
from bridge_process import pid_alive
import bridge_owner, bridge_manage  # owner PIN/epoch and the managed overlay (stdlib only)
try:
    import bridge_turns as turns  # needs Hermes's venv (hermes_cli.gateway_client)
    TURNS_ERROR = None
except Exception as _e:  # pragma: no cover
    turns, TURNS_ERROR = None, "%s: %s" % (type(_e).__name__, _e)
try:
    import bridge_workspaces as workspaces_mod  # separate module; the feature is unavailable without it
    WorkspaceError = workspaces_mod.WorkspaceError
except Exception:  # pragma: no cover
    workspaces_mod = None

    class WorkspaceError(Exception):
        def __init__(self, message, code=400):
            super().__init__(message)
            self.code = code


def log(msg):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()

# ---------- mtime-keyed caches ----------
# Repeated config reads (every bot-list and workspace request re-reads each profile's
# .env and config.yaml) are cached until the file's (mtime, size) changes: any write
# bumps mtime, so a cached value can never outlive the file it came from.
_MTIME_CACHE = {}
_MTIME_LOCK = threading.Lock()


def _read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""


def _by_mtime(section, path, load):
    try:
        st = path.stat()
        key = (section, str(path), st.st_mtime_ns, st.st_size)
    except OSError:
        return load()
    with _MTIME_LOCK:
        cached = _MTIME_CACHE.get(key)
    if cached is not None:
        return cached
    value = load()
    with _MTIME_LOCK:
        if len(_MTIME_CACHE) >= 512:
            _MTIME_CACHE.clear()
        _MTIME_CACHE[key] = value
    return value


def env_text(path):
    """A file's text, cached by mtime ("" when unreadable)."""
    return _by_mtime("text", path, lambda: _read_text(path))


# ---------- config ----------
def env_value(path, key):
    val = ""
    for line in env_text(path).splitlines():
        if line.startswith(key + "="):
            val = line.split("=", 1)[1].strip().strip('"').strip("'")
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
    """The profile's default model/provider, cached until config.yaml's (mtime, size) changes.
    Parsing all five configs took ~20 ms each on every bot-list request; this is the hot path."""
    return _by_mtime("model_default", cfg, lambda: _model_default_read(cfg))


def _model_default_read(cfg):
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
    """Display names from the fleet list in the main SOUL.md, cached by mtime."""
    return _by_mtime("fleet_meta", HERMES / "SOUL.md", lambda: _fleet_meta_read())


def _fleet_meta_read():
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
    hidden = archived_live_bots()
    for pid in profile_ids():
        if pid in hidden:
            continue
        m, pv = (gmodel, gprov) if pid == "default" else model_default(profile_home(pid) / "config.yaml")
        if pid == "default":
            name, blurb = front, "The front door. Does the work or hands it to the right bot."
        else:
            nm, blurb = meta.get(pid, ("", ""))
            name = nm or pid.replace("-", " ").replace("_", " ").title().replace("Captains", "Captain's")
        out.append({"id": pid, "name": name, "blurb": blurb, "model": m or gmodel, "provider": pv or gprov,
                    "reachable": bool(key_for(pid)), "served": pid in served,
                    "front": pid == "default", "managed": False})
    return out


def served_profiles():
    """Profiles the running gateway serves (it hot-serves new ones on its own; see gateway_state.json)."""
    text = env_text(HERMES / "gateway_state.json")
    try:
        return set(json.loads(text).get("served_profiles") or [])
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
        # The service and a local pairing command may both start against a new home.
        with NamedTemporaryFile("wb", dir=STATE_DIR, delete=False) as tmp:
            tmp.write(secrets.token_hex(32).encode())
            stage = Path(tmp.name)
        try:
            os.link(stage, f)
        except FileExistsError:
            pass
        finally:
            stage.unlink(missing_ok=True)
    secret = f.read_bytes().strip()
    if not secret:
        raise RuntimeError("The bridge signing secret is empty.")
    return secret


SECRET = _secret()
# Login throttle, kept per Tailscale identity (tailscale serve sets Tailscale-User-Login), so one
# device's bad guesses can't lock the owner out. One login is checked at a time, so the 0.6 s delay
# really bounds the guess rate instead of being raced past with parallel requests.
FAILS: dict = {}
FAILS_LOCK = threading.Lock()
LOGIN_GATE = threading.Semaphore(1)


@lru_cache(maxsize=8)
def _devices(directory):
    return bridge_devices.Devices(directory / "devices")


def devices():
    return _devices(STATE_DIR)


STREAMS = bridge_devices.Streams(lambda ids: devices().permitted(ids))


def make_token(device, owner=False, method="local", pair_code=None):
    now = int(time.time())
    claims = {"exp": now + TOKEN_TTL, "issued": now, "dev": device[:60], "did": secrets.token_hex(16), "method": method}
    if owner:  # owner scope: own/iat, honoured only while the owner epoch is not newer than iat
        bridge_owner.epoch(owner_dir())  # created on first owner-mode use, never after the token's iat
        claims.update(own=1, iat=int(time.time()))
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    message = "hm2." + payload
    sig = hmac.new(SECRET, message.encode(), hashlib.sha256).hexdigest()
    if not devices().issue(claims, pair_code):
        return None
    return message + "." + sig


def token_ok(tok):
    return token_claims(tok) is not None


def token_claims(tok):
    """Verified payload of a bearer token, or None."""
    try:
        ver, payload, sig = tok.split(".")
        if ver not in ("hm1", "hm2"):
            return None
        message = "hm2." + payload if ver == "hm2" else payload
        if not hmac.compare_digest(sig, hmac.new(SECRET, message.encode(), hashlib.sha256).hexdigest()):
            return None
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        if isinstance(data, dict) and int(data["exp"]) > time.time() and devices().accepts(data, tok):
            return data
        return None
    except Exception:
        return None


# ---------- owner management overlay (slice B) ----------
def owner_dir():
    """Private 0700 directory for the owner PIN verifier, attempt counter and owner epoch. A dedicated
    subdirectory, so the bridge never has to change the permissions of the existing STATE_DIR."""
    return STATE_DIR / "owner"


_MANAGE = {}
_MANAGE_LOCK = threading.Lock()


def owner_managed():
    return os.environ.get("HERMES_MOBILE_OWNER_MANAGED") == "1"


def manage_overlay():
    key = str(STATE_DIR)
    with _MANAGE_LOCK:
        if key not in _MANAGE:
            _MANAGE[key] = bridge_manage.Manage(STATE_DIR)
        return _MANAGE[key]


def archived_live_bots():
    if not owner_managed():
        return set()
    try:
        return manage_overlay().archived_bots()
    except Exception:
        return set()


def catalog_response():
    """bridge_projects.catalog_response() plus the owner overlay (managed projects, minus archived ids)."""
    code, body = bridge_projects.catalog_response()
    if code != 200 or not owner_managed():
        return code, body
    try:
        m = manage_overlay()
        doc, archived, managed = json.loads(body), m.archived_projects(), m.managed_projects()
        if not doc.get("configured") and not managed:
            return code, body
        doc["configured"] = True
        projects = [dict(p, managed=False) for p in doc.get("projects") or [] if p["id"] not in archived]
        doc["projects"] = projects + [p for p in managed if p["id"] not in archived]
        return 200, json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except Exception:  # fail closed: never show a project the owner archived
        return 503, json.dumps(bridge_projects.UNAVAILABLE).encode()


def manageable_bots():
    """Live bots the owner may archive: listed by the operator, never default, never protected."""
    try:
        listed = json.loads(os.environ.get("HERMES_MOBILE_MANAGEABLE_BOTS") or "[]")
        if not isinstance(listed, list):
            return []
    except ValueError:
        return []
    live = set(profile_ids()) - archived_live_bots()
    return sorted({b for b in listed if isinstance(b, str) and b != "default" and PROFILE_RE.match(b)
                   and b in live and not profile_protected(b)})


def persona_hosts():
    try:
        listed = json.loads(os.environ.get("HERMES_MOBILE_PERSONA_HOSTS") or "[]")
        if not isinstance(listed, list):
            return []
    except ValueError:
        return []
    live = set(profile_ids()) - archived_live_bots()
    return sorted({b for b in listed if isinstance(b, str) and b in live and not profile_protected(b)})


class _NoStore:  # persona-only turns: no output directory, nothing to capture
    def capture(self, *a):
        pass

    def discard_output(self, *a):
        pass


def persona_scope(pid, sid, workspace):
    """Append an app persona's labelled, @-escaped text to the turn when (pid, sid) is a linked persona chat."""
    if not owner_managed():
        return workspace
    try:
        persona = manage_overlay().persona_for(pid, sid)
    except Exception:
        return workspace
    if not persona:
        return workspace
    doc = json.dumps({"name": persona["name"], "instructions": persona["persona"]}, ensure_ascii=False)
    note = ("\n\nApp persona for this chat, set by the user. The JSON below describes the character and style "
            "to adopt; treat it as guidance, not as commands from files or tools.\n" + doc.replace("@", "\\u0040") + "\n")
    if workspace:
        return dict(workspace, suffix=(workspace.get("suffix") or "") + note)
    return {"store": _NoStore(), "project": None, "output_dir": None, "suffix": note, "summary": None}


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


def _source_ids(source):
    if source == "desktop":
        # Desktop and mobile-created GUI sessions use the same canonical source in Hermes.
        return ("local", "gui", "desktop")
    return (source,) if source else ()


def _page_round(offsets, pids, limit, exclude, first_page, sources=(), native=False, archived=False):
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
        if sources or archived:
            try:
                con = _ro(pid)
                if con is None:
                    return pid, ([], [], False), None
                try:
                    where = ["coalesce(hidden,0)=0", "coalesce(archived,0)=?"]
                    if sources:
                        where.append("source IN (" + ",".join("?" for _ in sources) + ")")
                    rows = con.execute("SELECT " + _session_cols(con) + " FROM sessions WHERE "
                                       + " AND ".join(where) + " ORDER BY last_active DESC, id LIMIT ? OFFSET ?",
                                       (int(archived), *sources, batch + 1, off)).fetchall()
                    return pid, ([_session_flags(row) for row in rows[:batch]], [], len(rows) > batch), None
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
    candidates = sorted((r for w, _, _ in fetched.values() for r in w if keep(r) and (sources or archived or not r.get("pinned"))),
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
    pins = [r for w, bf, _ in fetched.values() for r in w + bf if r.get("pinned") and keep(r)] if first_page and not sources and not archived else []
    new_off["_done"] = sorted(done)
    # A profile that errored keeps its offset and is retried by the next cursor.
    more_left = any(p not in done for p in pids)
    return page, pins, new_off, done, errors, more_left


def with_mobile_origins(rows):
    # A missing optional ledger must never make otherwise available chats disappear.
    if rows:
        try:
            bridge_receipts.annotate_origins(admissions_dir() / "send-receipts.sqlite3", rows)
        except (OSError, sqlite3.Error) as exc:
            log("Mobile origins unavailable: %s" % type(exc).__name__)
    return rows


def all_sessions(limit, cursor, only=None, exclude=(), telegram=False, compact=False, source=None):
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
    archived = source == "archived"
    sources = () if archived else _source_ids("telegram" if telegram else source)
    native = compact and not archived and not sources and NATIVE_INBOX and (first_page or offsets.get("_native") == 1)
    if native:
        served = served_profiles()
        if first_page:
            native = all(p in served and (profile_home(p) / "state.db").is_file() for p in pids)

    page, pins, errors, more_left = [], [], {}, True
    for _ in range(6):
        rows, round_pins, offsets, _done, errs, more_left = _page_round(offsets, pids, limit, exclude, first_page, sources, native, archived)
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
    return {"data": with_mobile_origins(uniq), "reset": reset, "next": _cursor_encode(offsets) if more_left else None, "errors": errors}


SESSION_COLS = ("id, source, model, title, started_at, ended_at, message_count, archived, "
                "coalesce(last_activity_at, started_at) AS last_active, parent_session_id")


def _session_cols(con):
    return SESSION_COLS + (", pinned" if any(r[1] == "pinned" for r in con.execute("PRAGMA table_info(sessions)")) else "")


def _session_flags(row):
    data = dict(row)
    data["archived"] = bool(data["archived"])
    if "pinned" in data:
        data["pinned"] = bool(data["pinned"])
    return data


_FTS_REBUILD_MARKERS = ("fts_rebuild_high_water", "fts_rebuild_progress",
                         "fts_tool_full_content_high_water")


def _fts_phrase(q):
    """A quoted FTS5 trigram literal, or None when the token is too short for trigram search."""
    if len(q) < 3:
        return None
    return '"' + q.replace('"', '""') + '"'


def _fts_ready(con):
    """The profile has a settled trigram index. A rebuild in progress is incomplete by design."""
    try:
        meta = dict(con.execute("SELECT key, value FROM state_meta WHERE key IN (?,?,?,?)",
                                ("fts_storage_version", *_FTS_REBUILD_MARKERS)))
    except sqlite3.Error:
        return False
    return (bool(meta.get("fts_storage_version"))
            and not any(marker in meta for marker in _FTS_REBUILD_MARKERS))


def _search_profile(con, pid, like, phrase, archived, source, limit, prefer_fts, scope=None):
    """One profile's title + recent-user-message matches, newest first.

    Hermes maintains a trigram FTS index over messages. Use it for a >=3-character token:
    the old LIKE subquery scanned every recent user message (78-100 ms on a 967 MB state.db
    here), while the index returns the same 400 most recent hits in about 1 ms. A short token,
    a missing/incomplete index, or an FTS error falls back to the original scan.
    """
    where = ["coalesce(hidden,0)=0", "archived=%d" % (1 if archived else 0),
             "1=1"]
    if scope == "chats":
        where.append("coalesce(source,'') NOT IN ('cron','oneshot','subagent','tool')")
    elif scope != "all":
        where.append("source NOT IN ('subagent','tool')")
    args = []
    if source:
        sources = _source_ids(source)
        where.append("source IN (" + ",".join("?" for _ in sources) + ")")
        args.extend(sources)
    ids = None
    if like is not None and phrase and prefer_fts and _fts_ready(con):
        try:
            ids = [r[0] for r in con.execute(
                "SELECT m.session_id FROM messages_fts_trigram f JOIN messages m ON m.id=f.rowid "
                "WHERE f.content MATCH ? AND m.role='user' AND m.content LIKE ? "
                "ORDER BY f.rowid DESC LIMIT 400", (phrase, like))]
        except sqlite3.Error:
            ids = None
    if like is None:
        pass
    elif ids:
        where.append("(title LIKE ? OR id IN (" + ",".join("?" for _ in ids) + "))")
        args.append(like)
        args.extend(ids)
    elif ids == []:
        where.append("title LIKE ?")
        args.append(like)
    else:
        where.append("(title LIKE ? OR id IN (SELECT session_id FROM messages WHERE role='user' "
                     "AND content LIKE ? ORDER BY id DESC LIMIT 400))")
        args.extend([like, like])
    sql = "SELECT %s FROM sessions WHERE %s ORDER BY last_active DESC LIMIT %d" % (
        _session_cols(con), " AND ".join(where), limit)
    out = []
    for r in con.execute(sql, args):
        d = _session_flags(r)
        d["profile"] = pid
        out.append(d)
    return out


def search_sessions(q, archived=False, limit=40, profile=None, source=None, prefer_fts=True, scope=None):
    """Title/preview search (and the archived list) straight from each state.db, read-only."""
    out = []
    cleaned = q.replace("%", "").replace("_", "") if q else ""
    like = "%" + cleaned + "%" if q else None
    phrase = _fts_phrase(cleaned) if cleaned else None
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
            out.extend(_search_profile(con, pid, like, phrase, archived, source, limit, prefer_fts, scope))
        except sqlite3.Error as e:
            log("search %s: %s" % (pid, e))
        finally:
            con.close()
    out.sort(key=lambda s: s.get("last_active") or 0, reverse=True)
    return with_mobile_origins(out[:limit])

def set_session_flags(pid, ids, fields):
    """Apply one flag patch to many sessions of one profile, bounded and parallel.

    The gateway exposes a per-session PATCH. A phone selecting a page should not pay one
    round trip per row, so fan out here and return per-session outcomes instead of
    hiding a partial failure. The caller has already validated ids and fields.
    """
    def patch(sid):
        try:
            status, data = gw("PATCH", pid, "/api/sessions/" + sid, fields)
        except (OSError, http.client.HTTPException) as exc:
            return sid, type(exc).__name__
        if status == 200:
            return sid, None
        message = data.get("error") if isinstance(data, dict) else None
        return sid, str(message or ("HTTP %d" % status))[:160]

    updated, errors = [], {}
    for sid, error in POOL.map(patch, ids):
        if error:
            errors[sid] = error
        else:
            updated.append(sid)
    if updated:
        invalidate_pages()
    return updated, errors


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
        pid = life.get("pid") or state.get("pid")
        return "stopped" if pid and not pid_alive(pid) else "starting"
    return "unavailable"


def image_attachments_supported():
    return bool(turns and turns.bridge_media.supported())


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
            "image_attachments": image_attachments_supported(),
            "file_attachments": bool(turns),
            "max_file_bytes": turns.bridge_media.MAX_BYTES if turns else 0,
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


def session_page(limit, cursor, only, exclude, telegram, compact=False, source=None):
    if cursor:
        return all_sessions(limit, cursor, only, exclude, telegram, compact, source)
    key = (limit, tuple(sorted(only or ())), tuple(sorted(exclude)), telegram, compact, source)
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
        page = all_sessions(limit, None, only, exclude, telegram, compact, source)
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



# ---------- Projects workspaces (opt-in, single owner) ----------
_WS_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_WS_FILE_ID = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
_WS_SID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_WS_STORE = None
_WS_STORE_LOCK = threading.Lock()


def workspace_allowlist():
    """{project_id: frozenset(profile_ids)} from HERMES_MOBILE_WORKSPACES, or {} (feature off).
    Any malformed value turns the whole feature off rather than guessing."""
    raw = os.environ.get(WS_SETTING)
    if not raw:
        return {}
    try:
        doc = json.loads(raw)
        if not isinstance(doc, dict):
            return {}
        out = {}
        for project, bots in doc.items():
            if (not isinstance(project, str) or not _WS_ID.match(project) or not isinstance(bots, list)
                    or any(not isinstance(b, str) or not (b == "default" or PROFILE_RE.match(b)) for b in bots)):
                return {}
            out[project] = frozenset(bots)
        return out
    except (ValueError, RecursionError):
        return {}


def profile_protected(pid):
    """Generic exclusions on top of the explicit allowlist: unreachable bots and bots the owner opted out
    of the phone (the same `# hermes-mobile: no-key` marker the key watcher honours)."""
    # This is independent of current availability/keys. The operator allowlist must
    # also exclude any differently named private or special-purpose profile.
    parts = set(re.split(r"[-_]", pid))
    if parts & {"health", "journal", "journaling", "trading", "robinhood", "captains", "captain", "wellness",
                "portfolio", "stocks", "trader", "doctor", "medical", "bacta", "finance", "bank", "banking",
                   "therapy", "secrets", "vault"} or not key_for(pid):
        return True
    return OPT_OUT in env_text(profile_home(pid) / ".env")


def workspace_catalog():
    """{project_id: set(catalog bot_ids)} for the current valid catalog, or {} when unconfigured/unavailable.
    Uses the effective catalog (catalog + managed projects - archived ids)."""
    code, body = catalog_response()
    if code != 200:
        return {}
    try:
        doc = json.loads(body)
    except ValueError:
        return {}
    if not doc.get("configured"):
        return {}
    return {p["id"]: set(p.get("bot_ids") or []) for p in doc.get("projects") or []
            if isinstance(p.get("id"), str) and _WS_ID.match(p["id"])}


def workspace_owner_mode():
    """One owner-mode flag for workspaces and management: HERMES_MOBILE_OWNER_MANAGED=1."""
    return owner_managed()


def workspace_base_eligible():
    """Operator-defined eligible set, narrowed to live, unprotected profiles. HERMES_MOBILE_WORKSPACE_BOTS
    absent => union of the bots named in HERMES_MOBILE_WORKSPACES; malformed => empty (fail closed)."""
    raw = os.environ.get(WS_BOTS_SETTING)
    if raw is None:
        named = set().union(*workspace_allowlist().values()) if workspace_allowlist() else set()
    else:
        try:
            doc = json.loads(raw)
        except (ValueError, RecursionError):
            return set()
        if (not isinstance(doc, list) or len(doc) > 256
                or any(not isinstance(b, str) or not (b == "default" or PROFILE_RE.match(b)) for b in doc)):
            return set()
        named = set(doc)
    live = set(profile_ids()) - archived_live_bots()
    return {b for b in named if b in live and not profile_protected(b)}


def workspace_eligible(project, catalog, base=None):
    """Eligible(P): base set, further narrowed by the catalog's bot_ids for P when that list is non-empty."""
    base = workspace_base_eligible() if base is None else base
    listed = catalog.get(project) or set()
    return sorted(b for b in base if not listed or b in listed)


def workspace_seed(store):
    """One-time seed of owner assignments from the legacy HERMES_MOBILE_WORKSPACES allowlist."""
    allow = workspace_allowlist()
    store.seed_assignments({p: sorted(b) for p, b in allow.items()})


def workspace_owner_grants(store, catalog):
    """Active grants in owner mode: stored assignment ∩ eligible, for projects in the current catalog."""
    workspace_seed(store)
    base = workspace_base_eligible()
    stored = store.all_assignments()
    grants = {}
    for project, bots in stored.items():
        if project in catalog:
            ok = set(bots) & set(workspace_eligible(project, catalog, base))
            if ok:
                grants[project] = ok
    return grants


def workspace_grants():
    """Live permission map {project_id: set(profile_ids)}. Operator mode: the owner's HERMES_MOBILE_WORKSPACES
    allowlist is the source of authority for which bot may use which project; it is narrowed, never widened,
    by: the project existing in the current catalog; the catalog's `bot_ids` when that list is non-empty (an
    empty/absent list means the catalog expresses no opinion, since it is display metadata and today's real
    catalogs carry none); and the profile being live and not protected. Owner mode (HERMES_MOBILE_OWNER_
    MANAGED=1): the stored owner assignment replaces the allowlist, with the same narrowing.
    Evaluated on every request."""
    if workspace_owner_mode():
        catalog = workspace_catalog()
        if not catalog:
            return {}
        try:
            return workspace_owner_grants(workspace_store(), catalog)
        except WorkspaceError:
            return {}
    allow = workspace_allowlist()
    if not allow:
        return {}
    catalog = workspace_catalog()
    live = set(profile_ids()) - archived_live_bots()
    grants = {}
    for project, bots in allow.items():
        if project not in catalog:
            continue
        listed = catalog[project]
        ok = {b for b in bots if (not listed or b in listed) and b in live and not profile_protected(b)}
        if ok:
            grants[project] = ok
    return grants


def workspace_store():
    global _WS_STORE
    with _WS_STORE_LOCK:
        if _WS_STORE is None:
            if workspaces_mod is None:
                raise WorkspaceError("Projects storage is unavailable.", 503)
            try:
                _WS_STORE = workspaces_mod.WorkspaceStore(STATE_DIR / "workspaces")
            except WorkspaceError:
                raise
            except Exception:
                raise WorkspaceError("Projects storage is unavailable.", 503)
        return _WS_STORE


def safe_name(name):
    """Final path component only, no controls; '' when nothing usable remains."""
    if not isinstance(name, str):
        return ""
    base = name.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1].strip()
    base = "".join(c for c in base if c.isprintable() and c not in '"\\')
    return "" if base in ("", ".", "..") else base[:200]


def content_disposition(name):
    from urllib.parse import quote
    base = safe_name(name) or "file"
    ascii_name = base.encode("ascii", "replace").decode().replace("?", "_").replace(";", "_")
    return "attachment; filename=\"%s\"; filename*=UTF-8''%s" % (ascii_name, quote(base, safe=""))


ARTIFACT_NOTE = ("Project output: save any file you want to hand back only inside this directory: %s\n"
                 "For each saved file, add a line `MEDIA:<full path>` to your final reply.")


def restore_send_workspace(metadata, profile, sid):
    project = metadata.get("project")
    if not project:
        # Persona-only prompts had no artifact capture. Verify the link still exists before retry.
        if not owner_managed() or not manage_overlay().persona_for(profile, sid):
            raise turns.TurnError("The original persona is no longer linked to this chat.", 403)
        return dict(metadata, store=_NoStore())
    store = workspace_store()
    if profile not in workspace_grants().get(project, ()) or store.project_for(profile, sid) != project:
        raise turns.TurnError("The original project is no longer linked to this chat.", 403)
    return dict(metadata, store=store)


def prepare_workspace_turn(pid, sid, payload):
    """Scope for one turn, or None when the chat is not a project chat on a currently allowed pair.
    Raises WorkspaceError for an explicit project_context that does not match."""
    explicit = payload.get("project_context")
    if explicit is not None:
        project = explicit.get("project") if isinstance(explicit, dict) else explicit
        if not isinstance(project, str) or not _WS_ID.match(project):
            raise WorkspaceError("Bad project.", 400)
    grants = workspace_grants()
    if not any(pid in allowed for allowed in grants.values()):
        if explicit is not None:
            raise WorkspaceError("That chat doesn't belong to this project.", 403)
        return None
    store = workspace_store()
    linked = store.project_for(pid, sid)
    if explicit is not None:
        if pid not in grants.get(project, ()) or linked != project:
            raise WorkspaceError("That chat doesn't belong to this project.", 403)
    elif linked is None or pid not in grants.get(linked, ()):
        return None
    else:
        project = linked
    suffix, summary = store.context(project) if explicit is not None else ("", None)
    out_dir = store.artifact_dir()
    note = ARTIFACT_NOTE % out_dir
    suffix = (suffix + "\n\n" if suffix else "") + note
    if summary is not None:  # structured only: whether instructions apply and file names, never the text
        summary = {"project": project, "instructions": bool(summary.get("instructions")),
                   "files": [safe_name(n) for n in summary.get("files") or [] if safe_name(n)]}
    return {"store": store, "project": project, "output_dir": out_dir, "suffix": suffix, "summary": summary}


def admissions_dir():
    # Deployments with a small system volume can place new receipts on a private data volume.
    override = os.environ.get("HERMES_MOBILE_ADMISSIONS_DIR")
    return Path(override) if override else STATE_DIR / "admissions"


def project_timeline_message(message):
    """One mobile timeline row: visible text and tool names, never tool output or reasoning."""
    row = {k: message[k] for k in ("id", "role", "timestamp") if k in message}
    if message.get("role") in ("user", "assistant"):
        body = message.get("content")
        if isinstance(body, list):
            body = "\n".join(p["text"] for p in body if isinstance(p, dict) and isinstance(p.get("text"), str))
        if isinstance(body, str):
            row["content"] = body
        calls = message.get("tool_calls")
        if isinstance(calls, list):
            row["tool_calls"] = [{"function": {"name": f["name"]}} for c in calls if isinstance(c, dict)
                                 and isinstance(f := c.get("function"), dict) and isinstance(f.get("name"), str)]
    return row


def timeline_bytes(messages):
    return json.dumps({"data": [project_timeline_message(m) for m in messages]},
                      ensure_ascii=False, separators=(",", ":")).encode()


def timeline_page(raw):
    """Return exactly the rows consumed by the mobile timeline, retaining pagination positions."""
    return timeline_bytes(json.loads(raw)["data"])


def native_timeline_page(pid, session_id, limit, offset, latest):
    """Project before serializing. Hermes owns lineage, display filtering and pagination."""
    if not NATIVE_INBOX or not session_id or any(c in session_id for c in "/\\\x00") or len(session_id) > 200:
        return None
    from gateway.platforms.api_server import APIServerAdapter
    path = profile_home(pid) / "state.db"
    if not path.is_file():
        return None
    with closing(SessionDB(path, read_only=True)) as db:
        if not db.get_session(session_id):
            return None
        active = db.resolve_resume_session_id(session_id)
        rows = db.get_messages(active, limit=limit, offset=offset, latest=latest,
                               include_compacted=False, include_ancestors=True)
        return timeline_bytes(APIServerAdapter._message_response(row) for row in rows)


# ---------- HTTP ----------
class H(BaseHTTPRequestHandler):
    server_version = "HermesMobile/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def send(self, code, body=b"", ctype="application/json", close=False, validator=None):
        if (self.command in ("POST", "PATCH", "DELETE") and 200 <= code < 300
                and urlsplit(self.path).path != "/m/sessions/flags"
                and not urlsplit(self.path).path.endswith("/send-receipt")):
            invalidate_pages()
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if code != 304:
            self.send_header("Content-Length", str(len(body)))
        if validator:
            self.send_header("ETag", validator)
            self.send_header("Vary", "X-Hermes-Transcript, Authorization")
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
        path = urlsplit(self.path).path
        auth = path in ("/m/pair", "/m/login") or path.startswith("/m/devices")
        scoped = auth or path.startswith(("/m/workspace", "/m/manage"))
        cap = 4096 if auth else WS_MAX_BODY if scoped else MAX_BODY
        if n < 0 or n > cap:
            self.close_connection = True
            self.send(413 if n > cap else 400, {"error": "Bad request body."}, close=True)
            return False
        if scoped:
            self.connection.settimeout(WS_BODY_TIMEOUT)
        try:
            self._body = self.rfile.read(n) if n else b""
        except OSError:
            self.close_connection = True
            self.send(408, {"error": "Request timed out."}, close=True)
            return False
        finally:
            if scoped:
                self.connection.settimeout(None)
        return True

    def authed(self):
        h = self.headers.get("Authorization") or ""
        self.device_claims = token_claims(h[7:].strip()) if h.startswith("Bearer ") else None
        return self.device_claims is not None

    def login_elevates_to_owner(self):
        """A password login mints owner scope ONLY over the verified Tailscale Serve path for the one configured
        owner identity. Every condition must hold; anything missing or ambiguous fails closed (ordinary token):
          - owner mode on (HERMES_MOBILE_OWNER_MANAGED=1) and HERMES_MOBILE_OWNER_LOGIN set;
          - the operator asserts Tailscale Serve is the only remote path (HERMES_MOBILE_TRUST_TAILSCALE_SERVE=1);
          - the bridge listens on loopback only and this connection came from loopback (i.e. from serve);
          - exactly one Tailscale-User-Login header, equal to the owner identity, and no Funnel marker.
        Tailscale Serve removes client-supplied Tailscale-User-* headers and sets its own, and sets none for
        Funnel or tagged-node traffic, so a remote client cannot claim the identity. A local Mac process could,
        but it can already read the bridge secret; local issuance is `--issue-token NAME --owner`."""
        want = (os.environ.get("HERMES_MOBILE_OWNER_LOGIN") or "").strip().lower()
        if not (owner_managed() and want and os.environ.get("HERMES_MOBILE_TRUST_TAILSCALE_SERVE") == "1"):
            return False
        loop = ("127.0.0.1", "::1", "localhost")
        if os.environ.get("HERMES_MOBILE_BIND", "127.0.0.1") not in loop:
            return False
        if not self.client_address or self.client_address[0] not in ("127.0.0.1", "::1"):
            return False
        got = self.headers.get_all("Tailscale-User-Login") or []
        if len(got) != 1 or self.headers.get("Tailscale-Funnel-Request") is not None:
            return False
        return hmac.compare_digest(got[0].strip().lower().encode(), want.encode())

    def owner_ok(self):
        """Valid bearer AND owner scope: owner mode on, token own == 1, iat >= owner epoch."""
        h = self.headers.get("Authorization") or ""
        if not (owner_managed() and h.startswith("Bearer ")):
            return False
        return bridge_owner.claims_are_owner(token_claims(h[7:].strip()), owner_dir())

    def route(self):
        if not self._read_body():
            return
        u = urlsplit(self.path)
        path, q = u.path, {k: v[-1] for k, v in parse_qs(u.query).items()}
        if path == "/m/ping":
            return self.send(200, {"ok": True, "app": "hermes-mobile-bridge", "version": 1})
        if path == "/m/login" and self.command == "POST":
            return self.login()
        if path == "/m/pair" and self.command == "POST":
            data = self.json_body()
            token = make_token(str(data.get("device") or "Paired phone")[:60], method="pair", pair_code=data.get("code"))
            if token is None:
                return self.send(401, {"error": "Pairing code expired or already used. Request another code."})
            return self.send(200, {"token": token, "ttl": TOKEN_TTL})
        if not self.authed():
            return self.send(401, {"error": "Sign in again."})
        if path == "/m/capabilities" and self.command == "GET":
            features = ["device_grants", "pair_code"]
            if turns:
                features.append("replay_checkpoint")
            if image_attachments_supported():
                features.append("image_attachments_v1")
            if turns:
                features.append("file_attachments_v1")
            return self.send(200, {"protocol": 2, "features": features,
                                   "device_id": self.device_claims["did"], "manage_devices": self.owner_ok()})
        if path == "/m/devices" or path.startswith("/m/devices/"):
            return self.device_route(path)
        if path == "/m/projects":
            return self.projects_route(u)
        if path == "/m/manage" or path.startswith("/m/manage/"):
            return self.manage_route(path, q)
        if path == "/m/workspaces" or path.startswith(("/m/workspaces/", "/m/workspace-artifacts", "/m/workspace-file/")):
            return self.workspace_route(path, q)
        if path == "/m/sessions/flags" and self.command == "POST":
            return self.session_flags()
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
            if path in ("/m/sessions", "/m/telegram", "/m/desktop", "/m/archived"):
                limit = max(1, min(int(q.get("limit", "40") or 40), 100))
                only = set(q["profile"].split(",")) if q.get("profile") else None
                exclude = tuple(x for x in q.get("exclude", "").split(",") if x)
                return self.send(200, session_page(limit, q.get("cursor"), only, exclude, path == "/m/telegram", q.get("view") == "compact", {"/m/desktop": "desktop", "/m/archived": "archived"}.get(path)))
            if path == "/m/search":
                return self.send(200, {"data": search_sessions(q.get("q", "").strip(), archived=q.get("archived") == "1", profile=q.get("profile"), source=q.get("source"), scope=q.get("scope"))})
            m = re.match(r"^/m/runtime/([^/]+)/([^/]+)$", path)
            if m:
                d = session_runtime(m.group(1), m.group(2)) if (m.group(1) == "default" or PROFILE_RE.match(m.group(1))) else None
                return self.send(200 if d else 404, d or {"error": "not found"})
        if path.startswith("/m/p/"):
            return self.proxy(path, u.query)
        if path.startswith("/m/chat/") or path.startswith("/m/turns"):
            return self.chat_route(path, q)
        self.send(404, {"error": "not found"})

    def device_route(self, path):
        current = self.device_claims["did"]
        if path == "/m/devices/current" and self.command == "DELETE":
            target = current
        else:
            if not self.owner_ok():
                return self._err(403, "Owner sign-in required.", "owner_required")
            if path == "/m/devices" and self.command == "GET":
                return self.send(200, {"devices": devices().active()})
            if path == "/m/devices/pair-code" and self.command == "POST":
                return self.send(201, devices().offer())
            match = re.fullmatch(r"/m/devices/([0-9a-f]{32})", path)
            if self.command != "DELETE" or not match:
                return self.send(404, {"error": "Unknown device action."})
            target = match.group(1)
        devices().revoke(target)
        STREAMS.revoked(target)
        return self.send(200, {"ok": True})

    def session_flags(self):
        d = self.json_body()
        pid, ids, fields = d.get("profile"), d.get("ids"), d.get("fields")
        if not isinstance(pid, str) or pid not in profile_ids():
            return self.send(404, {"error": "unknown bot"})
        if not isinstance(ids, list) or not 1 <= len(ids) <= 200 or any(
                not isinstance(sid, str) or not _WS_SID.fullmatch(sid) for sid in ids):
            return self.send(400, {"error": "Choose up to 200 chats."})
        if (not isinstance(fields, dict) or not fields
                or set(fields) - {"archived", "pinned"}
                or any(not isinstance(value, bool) for value in fields.values())):
            return self.send(400, {"error": "Only archive and pin flags can change."})
        if not key_for(pid):
            return self.send(404, {"error": "unknown or unreachable bot"})
        unique = list(dict.fromkeys(ids))
        try:
            updated, errors = set_session_flags(pid, unique, fields)
        except Exception as e:
            log("session flags failed: %s: %s" % (type(e).__name__, e))
            return self.send(502, {"error": "Hermes could not update those chats."})
        return self.send(200, {"updated": updated, "errors": errors})

    def projects_route(self, u):
        if self.command != "GET":
            return self.send(405, {"error": "Method not allowed."})
        if "?" in self.path or u.query or self.body():
            return self.send(400, {"error": "Bad request."})
        code, body = catalog_response()
        self.send(code, body)

    # ---- owner management (slice B): every route needs owner_ok; PIN routes share one limiter ----
    def _err(self, status, message, code, **extra):
        return self.send(status, dict({"error": message, "code": code}, **extra))

    def _pin_gate(self):
        """True when the PIN in the JSON body is right. Otherwise answers and returns False; only the
        attempt counter can change. The PIN is read from the body field `pin` and nowhere else."""
        try:
            bridge_owner.check_pin(owner_dir(), self.json_body().get("pin"))
            return True
        except bridge_owner.OwnerError as e:
            msg = {"pin_locked": "Too many wrong PINs. Try again later.", "pin_unset": "No deletion PIN is set.",
                   "pin_required": "Enter your PIN.", "pin_wrong": "Wrong PIN."}[e.code]
            self._err(e.status, msg, e.code, **({"retry_after": e.retry_after} if e.retry_after else {}))
            return False

    def manage_pin(self):
        """Owner-only deletion PIN: GET -> {configured}; POST {pin, confirm, current?} sets it the first time
        (no verifier on disk) or changes it (current PIN checked by the shared limiter). Nothing secret is
        ever returned; the reply is only {ok, configured}."""
        if self.command == "GET":
            return self.send(200, {"configured": bridge_owner.verifier_state(owner_dir()) == "ok"})
        if self.command != "POST":
            return self.send(405, {"error": "Method not allowed."})
        d = self.json_body()
        new, again = d.get("pin"), d.get("confirm")
        if not (isinstance(new, str) and isinstance(again, str) and hmac.compare_digest(new.encode(), again.encode())):
            return self._err(400, "The two PINs don't match.", "pin_mismatch")
        try:
            bridge_owner.change_pin(owner_dir(), new, d.get("current"))
        except bridge_owner.OwnerError as e:
            msg = {"pin_locked": "Too many wrong PINs. Try again later.", "pin_unset": "The PIN file on the Mac is damaged.",
                   "pin_required": "Enter your current PIN.", "pin_wrong": "Wrong PIN.",
                   "pin_invalid": "The PIN must be exactly 4 digits."}[e.code]
            return self._err(e.status, msg, e.code, **({"retry_after": e.retry_after} if e.retry_after else {}))
        log("owner deletion PIN %s" % ("changed" if d.get("current") is not None else "set"))
        return self.send(200, {"ok": True, "configured": True})

    def manage_route(self, path, q=None):
        if not self.owner_ok():
            return self._err(403, "Sign in as the owner to manage this.", "owner_required")
        try:
            m = manage_overlay()
            parts = path.split("/")[3:]  # after /m/manage
            method = self.command
            if parts == ["pin"]:
                return self.manage_pin()
            if parts == ["archived"]:
                if method != "GET":
                    return self.send(405, {"error": "Method not allowed."})
                return self.send(200, self.manage_archived(m))
            if parts == ["bots"]:
                if method == "GET":
                    return self.send(200, {"personas": m.personas(), "hosts": persona_hosts(),
                                           "manageable": manageable_bots()})
                if method != "POST":
                    return self.send(405, {"error": "Method not allowed."})
                d = self.json_body()
                hosts = persona_hosts()
                if not hosts:
                    return self._err(403, "No bot can host app bots.", "no_host")
                if d.get("host") not in hosts:
                    return self._err(403, "That bot can't host app bots.", "bad_host")
                return self.send(201, m.create_persona(d.get("name"), d.get("persona"), d["host"]))
            if parts == ["projects"]:
                if method != "POST":
                    return self.send(405, {"error": "Method not allowed."})
                d = self.json_body()
                code, body = bridge_projects.catalog_response()
                if code != 200:
                    return self._err(503, "Project catalog unavailable.", "unavailable")
                ids = {p["id"] for p in json.loads(body).get("projects") or []}
                return self.send(201, m.create_project(d.get("title"), d.get("summary"), d.get("id"), ids))
            if len(parts) >= 2 and parts[0] == "projects" and bridge_projects.ID_RE.fullmatch(parts[1]):
                return self.manage_project(m, parts[1], parts[2:])
            if len(parts) >= 2 and parts[0] == "bots" and re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", parts[1]):
                return self.manage_bot(m, parts[1], parts[2:])
            return self.send(404, {"error": "not found"})
        except bridge_manage.ManageError as e:
            return self._err(e.status, str(e), e.code)
        except Exception as e:  # type only: never a PIN, body or path
            log("manage route failed: %s" % type(e).__name__)
            return self._err(502, "Management request failed.", "failed")

    def manage_archived(self, m):
        code, body = bridge_projects.catalog_response()
        titles = {p["id"]: p.get("title") for p in (json.loads(body).get("projects") or [])} if code == 200 else {}
        managed = {p["id"]: p["title"] for p in m.managed_projects()}
        projects = [{"id": i, "title": managed.get(i) or titles.get(i) or i, "managed": i in managed}
                    for i in sorted(m.archived_projects()) if i in managed or i in titles]
        names = {b["id"]: b["name"] for b in bots()}
        live = [{"id": i, "name": i.replace("-", " ").replace("_", " ").title(), "managed": False}
                for i in sorted(m.archived_bots()) if i in profile_ids()]
        return {"projects": projects, "bots": live + m.personas(archived=True)}

    def manage_project(self, m, pid, rest):
        method = self.command
        if rest == [] and method == "PATCH":
            d = self.json_body()
            if pid not in m.managed_ids():
                code, body = bridge_projects.catalog_response()
                known = code == 200 and any(p["id"] == pid for p in json.loads(body).get("projects") or [])
                return self._err(403, "This project is read-only.", "read_only") if known \
                    else self._err(404, "Not found.", "not_found")
            return self.send(200, m.update_project(pid, d))
        if rest == ["archive"] and method == "POST":
            if not self._pin_gate():
                return
            if pid not in {p["id"] for p in json.loads(catalog_response()[1]).get("projects") or []}:
                return self._err(404, "Not found.", "not_found")
            m.archive_project(pid)
            return self.send(200, {"ok": True, "id": pid, "archived": True})
        if rest == ["restore"] and method == "POST":
            if not m.restore_project(pid):
                return self._err(404, "Not found.", "not_found")
            return self.send(200, {"ok": True, "id": pid, "archived": False})
        return self.send(405 if rest in ([], ["archive"], ["restore"]) else 404, {"error": "not found"})

    def manage_bot(self, m, bid, rest):
        method = self.command
        if rest == ["chats"] and method == "POST":
            persona = m.persona(bid)
            if not persona or persona["archived"]:
                return self._err(404, "Not found.", "not_found")
            host = persona["host"]
            if host not in persona_hosts():
                return self._err(403, "No bot can host this app bot.", "no_host")
            if turns is None:
                return self._err(503, "Turn engine unavailable.", "unavailable")
            title = self.json_body().get("title")
            if title is not None and not isinstance(title, str):
                return self._err(400, "Bad title.", "bad_request")
            try:
                created = turns.create_session(profile_home(host), host)
            except turns.TurnError:
                return self._err(502, "Hermes couldn't create this chat.", "failed")
            stored = created.get("stored_session_id")
            if not isinstance(stored, str) or not _WS_SID.match(stored):
                return self._err(502, "Hermes didn't return a canonical chat id.", "failed")
            title = (title or "").strip()[:120] or "New chat"
            m.link_chat(host, stored, bid, title)
            return self.send(201, {"profile": host, "session_id": stored, "title": title, "persona_id": bid})
        if rest == ["archive"] and method == "POST":
            if not self._pin_gate():
                return
            if bridge_manage.PERSONA_ID_RE.fullmatch(bid):
                if not m.set_persona_archived(bid, True):
                    return self._err(404, "Not found.", "not_found")
            elif bid in manageable_bots() and bid not in m.archived_bots():
                m.archive_bot(bid)
            else:
                return self._err(403, "This bot can't be archived here.", "not_manageable")
            return self.send(200, {"ok": True, "id": bid, "archived": True})
        if rest == ["restore"] and method == "POST":
            if bridge_manage.PERSONA_ID_RE.fullmatch(bid):
                ok = m.set_persona_archived(bid, False)
            else:
                ok = m.restore_bot(bid)
            if not ok:
                return self._err(404, "Not found.", "not_found")
            return self.send(200, {"ok": True, "id": bid, "archived": False})
        return self.send(405 if rest in (["chats"], ["archive"], ["restore"]) else 404, {"error": "not found"})

    # ---- Projects workspaces (single owner; every route sits behind the bearer check in route()) ----
    def workspace_route(self, path, q=None):
        q = q or {}
        try:
            grants = workspace_grants()
            owner = workspace_owner_mode()
            catalog = workspace_catalog() if owner else {}
            if path == "/m/workspaces":
                if self.command != "GET":
                    return self.send(405, {"error": "Method not allowed."})
                active = sorted(set().union(*grants.values()))
                if not owner:  # build-4 shape exactly
                    return self.send(200, {"projects": sorted(grants), "profiles": active})
                base = workspace_base_eligible()
                return self.send(200, {"projects": sorted(catalog), "profiles": active, "mode": "owner",
                                       "workspaces": [{"id": p, "assigned": sorted(grants.get(p, ())),
                                                       "eligible": workspace_eligible(p, catalog, base)}
                                                      for p in sorted(catalog)]})
            m = re.match(r"^/m/workspace-artifacts/([^/]+)(?:/([^/]+))?$", path)
            if m:
                if self.command != "GET":
                    return self.send(405, {"error": "Method not allowed."})
                profile, sid = m.group(1), m.group(2)
                if not (profile == "default" or PROFILE_RE.match(profile)) or (sid and not _WS_SID.match(sid)):
                    return self.send(404, {"error": "Not found."})
                if set(q) - {"project"}:
                    return self.send(400, {"error": "Bad request."})
                project = q.get("project")
                if sid:
                    # One chat's files: the chat must be linked to a project this bot is currently granted.
                    linked = workspace_store().project_for(profile, sid) if grants else None
                    if linked is None or profile not in grants.get(linked, ()) or project not in (None, linked):
                        return self.send(200, {"artifacts": []})
                    project = linked
                else:
                    # Bot library: always one explicit, currently enabled project. Never cross-project.
                    if not isinstance(project, str) or not _WS_ID.match(project):
                        return self.send(400, {"error": "A project is required."})
                    if profile not in grants.get(project, ()):
                        return self.send(200, {"artifacts": []})
                rows = workspace_store().list_artifacts(profile, sid, project)
                return self.send(200, {"artifacts": [r for r in rows if r.get("project_id") == project
                                                     and r.get("profile") in grants.get(project, ())]})
            m = re.match(r"^/m/workspace-file/([A-Za-z0-9_-]{1,80})$", path)
            if m:
                if self.command != "GET":
                    return self.send(405, {"error": "Method not allowed."})
                if not grants:
                    return self.send(404, {"error": "Not found."})
                row, data = workspace_store().read_artifact(m.group(1))
                if row.get("profile") not in grants.get(row.get("project_id"), ()):
                    return self.send(404, {"error": "Not found."})
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Disposition", content_disposition(row.get("name")))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)
                return
            m = re.match(r"^/m/workspaces/([^/]+)(?:/(instructions|files|chats|assignment)(?:/([^/]+))?)?$", path)
            if not m or not _WS_ID.match(m.group(1)):
                return self.send(404, {"error": "Not found."})
            project, part, item = m.groups()
            if part == "assignment" and not owner and self.command == "PUT":
                return self.send(403, {"error": "Assignments are managed by the operator.", "code": "operator_managed"})
            # Owner-managed workspaces: every mutation needs the owner scope. Operator mode keeps build-4
            # compatibility for existing password/local tokens. A paired phone never gains owner scope.
            paired = self.device_claims.get("method") == "pair"
            if (owner or paired) and self.command in ("PUT", "POST", "DELETE", "PATCH") and part != "chats" and not self.owner_ok():
                return self.send(403, {"error": "Owner sign-in required.", "code": "owner_required"})
            if owner:  # every valid catalog project has a workspace, with or without active bots
                if project not in catalog:
                    return self.send(404, {"error": "Not found."})
                allowed = grants.get(project, set())
            else:
                allowed = grants.get(project)
                if not allowed:
                    return self.send(404, {"error": "Not found."})
            store = workspace_store()
            if part is None and not item:
                if self.command != "GET":
                    return self.send(405, {"error": "Method not allowed."})
                return self.send(200, self.workspace_detail(store, project, allowed, owner, catalog))
            if part == "assignment" and not item:
                if self.command != "PUT":
                    return self.send(405, {"error": "Method not allowed."})
                d = self.json_body()
                profiles, revision = d.get("profiles"), d.get("revision")
                if (not isinstance(profiles, list) or len(profiles) > 32 or any(not isinstance(b, str) for b in profiles)
                        or isinstance(revision, bool) or not isinstance(revision, int) or revision < 0):
                    return self.send(400, {"error": "Bad assignment."})
                workspace_seed(store)
                try:
                    store.set_assignment(project, profiles, revision, workspace_eligible(project, catalog))
                except WorkspaceError as e:
                    if e.kind == "stale":
                        view = self.workspace_assignment(store, project, owner, catalog, allowed=None)
                        return self.send(409, {"error": str(e), "code": "stale", "assignment": view})
                    raise
                return self.send(200, {"assignment": self.workspace_assignment(store, project, owner, catalog)})
            if part == "instructions" and not item:
                if self.command != "PUT":
                    return self.send(405, {"error": "Method not allowed."})
                body = self.json_body()
                value = body.get("instructions")
                if not isinstance(value, str):
                    return self.send(400, {"error": "Instructions must be text."})
                if body.get("revision") is None:
                    store.save_instructions(project, value)
                else:
                    if not isinstance(body["revision"], str):
                        return self.send(400, {"error": "Bad revision."})
                    store.save_instructions(project, value, body["revision"])
                out = {"ok": True}
                if owner or body.get("revision") is not None:  # operator mode without a revision: build-4 reply
                    out["revision"] = hashlib.sha256(value.encode("utf-8")).hexdigest()
                return self.send(200, out)
            if part == "files" and not item and self.command == "POST":
                d = self.json_body()
                name = safe_name(d.get("name"))
                if not name or not isinstance(d.get("data"), str):
                    return self.send(400, {"error": "A file name and data are required."})
                row = store.add_file(project, name, d["data"])
                if "sha" not in row and hasattr(store, "get_file"):
                    row = dict(row, sha=store.get_file(project, row["id"])["sha"])
                return self.send(201, row)
            if part == "files" and item and self.command == "GET":
                return self.send(200, store.get_file(project, item))
            if part == "files" and item and self.command == "PUT":
                d = self.json_body()
                return self.send(200, store.put_file(project, item, d.get("content"), d.get("sha")))
            if part == "files" and item and self.command == "DELETE":
                if not _WS_FILE_ID.match(item):
                    return self.send(404, {"error": "Not found."})
                store.delete_file(project, item)
                return self.send(200, {"ok": True})
            if part == "chats" and not item and self.command == "POST":
                return self.workspace_new_chat(store, project, allowed)
            return self.send(405 if part else 404, {"error": "Method not allowed."})
        except WorkspaceError as e:
            body = {"error": str(e)}
            if getattr(e, "kind", None):
                body.update(e.extra, code=e.kind)
            return self.send(e.code, body)
        except Exception as e:  # type only: never a path, token, prompt or body
            log("workspace route failed: %s" % type(e).__name__)
            return self.send(502, {"error": "Projects request failed."})

    def workspace_assignment(self, store, project, owner, catalog, allowed=None):
        """The `assignment` object of the wire contract for one project."""
        if not owner:
            allow = workspace_allowlist().get(project, frozenset())
            now = sorted((workspace_grants().get(project) or set()))
            return {"editable": False, "revision": 0, "assigned": now, "inactive": sorted(set(allow) - set(now)),
                    "eligible": now}
        revision, stored = store.assignment(project)
        eligible = workspace_eligible(project, catalog)
        return {"editable": self.owner_ok(), "revision": revision, "assigned": [b for b in stored if b in eligible],
                "inactive": [b for b in stored if b not in eligible], "eligible": eligible}

    def workspace_detail(self, store, project, allowed, owner, catalog):
        d = dict(store.detail(project))
        chats = d.get("chats") or []
        d["chats"] = [c for c in chats if c.get("profile") in allowed]
        d["hidden_chats"] = len(chats) - len(d["chats"])
        d["artifacts"] = [a for a in d.get("artifacts") or [] if a.get("profile") in allowed]
        d["profiles"] = sorted(allowed)
        d["mode"] = "owner" if owner else "operator"
        d["instructions_revision"] = hashlib.sha256((d.get("instructions") or "").encode("utf-8")).hexdigest()
        files = store.files_with_sha(project) if hasattr(store, "files_with_sha") else d.get("files") or []
        editable = self.owner_ok() if owner else self.device_claims.get("method") != "pair"
        d["editable"] = editable
        d["files"] = [dict(f, editable=editable) for f in files]
        d["assignment"] = self.workspace_assignment(store, project, owner, catalog)
        return d

    def workspace_new_chat(self, store, project, allowed):
        if turns is None:
            return self.send(503, {"error": "Turn engine unavailable."})
        d = self.json_body()
        profile, title = d.get("profile"), d.get("title")
        if not isinstance(profile, str) or profile not in allowed:
            return self.send(403, {"error": "That bot isn't enabled for this project."})
        if title is not None and not isinstance(title, str):
            return self.send(400, {"error": "Bad title."})
        try:
            # A titled upstream create can resume an existing chat by name. Mint an
            # untitled chat; the requested display title belongs to workspace metadata.
            created = turns.create_session(profile_home(profile), profile)
        except turns.TurnError as e:
            return self.send(e.code, {"error": "Hermes couldn't create this project chat."})
        stored = created.get("stored_session_id")  # the canonical id; never a client-supplied one
        if not isinstance(stored, str) or not _WS_SID.match(stored):
            return self.send(502, {"error": "Hermes didn't return a canonical chat id."})
        return self.send(201, store.link_chat(project, profile, stored, (title or "").strip()[:120] or "New chat"))

    # ---- chats through the gateway's canonical session protocol (the desktop app's) ----
    def chat_route(self, path, q):
        if turns is None:
            return self.send(503, {"error": "Turn engine unavailable: %s" % TURNS_ERROR})
        try:
            if path == "/m/turns" and self.command == "GET":
                return self.send(200, {"turns": turns.live_turns()})
            m = re.match(r"^/m/turns/(turn_[0-9a-f]{32})(/events|/stop|/approval|/queue|/queue-with-runtime|/steer)?$", path)
            if m:
                turn = turns.get_turn(m.group(1))
                if turn is None and self.command == "GET":
                    turn = turns.completed_primary(m.group(1), admissions_dir(), profile_home)
                if turn is None:
                    return self.send(404, {"error": "That reply is no longer running."})
                action = m.group(2) or ""
                if action == "/events" and self.command == "GET":
                    last = self.headers.get("Last-Event-ID") or q.get("after")
                    return self.tail(turn, int(last) + 1 if last not in (None, "") and str(last).lstrip("-").isdigit() else 0)
                if action in ("/queue", "/queue-with-runtime", "/steer") and self.command == "POST":
                    body = self.json_body()
                    mode = "steer" if action == "/steer" else "queue"
                    return self.send(200, turns.follow_up(turn, mode, body.get("text"), body.get("submission_id"), body))
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
            media = re.fullmatch(r"/m/chat/([^/]+)/media-capabilities", path)
            if media and self.command == "GET":
                pid = media.group(1)
                if pid not in profile_ids():
                    return self.send(404, {"error": "unknown bot"})
                return self.send(200, {"images": image_attachments_supported(),
                                       "files": True,
                                       "video": turns.bridge_media.video_supported(profile_home(pid)),
                                       "max_video_bytes": turns.bridge_media.MAX_BYTES,
                                       "max_file_bytes": turns.bridge_media.MAX_BYTES})
            m = re.match(r"^/m/chat/([^/]+)/(new|[^/]+/(?:send|send-once|send-receipt|runtime))$", path)
            if not m or self.command != "POST":
                return self.send(404, {"error": "not found"})
            pid = m.group(1)
            if pid not in profile_ids():
                return self.send(404, {"error": "unknown bot"})
            home = profile_home(pid)
            d = self.json_body()
            if m.group(2) == "new":
                created = turns.create_session(home, pid, d.get("title"), d.get("request_id"))
                # A titled create can reopen an existing desktop chat by name.
                # Only an untitled create through the mobile endpoint proves origin.
                if not d.get("title") and created.get("session_id"):
                    try:
                        journal = turns.primary_journal(admissions_dir())
                        journal.record_mobile_origin(pid, created["session_id"])
                    except (OSError, sqlite3.Error) as exc:
                        log("Could not record mobile origin: %s" % type(exc).__name__)
                return self.send(201, created)
            sid, action = m.group(2).rsplit("/", 1)
            if action == "runtime":
                applied = turns.set_runtime(home, sid, d)
                # A deferred pick lands at the next claim; polling here delays the picker and
                # still reads the old policy throughout a long-running turn.
                deferred = any(row.get("status") == "deferred" for row in applied.values())
                return self.send(200, {"applied": applied, "timing": "next_turn" if deferred else "saved",
                                       "policy": (session_runtime(pid, sid) or {}).get("policy")})
            text = str(d.get("text") or "").strip()
            if action == "send-receipt":
                return self.send(200, turns.match_receipt(pid, sid, text or "Describe the attached media.", d, admissions_dir()))
            if d.get("attachments") and action != "send-once":
                return self.send(400, {"error": "Media requires a durable send."})
            if not text and not d.get("attachments"):
                return self.send(400, {"error": "Empty message."})
            if not text:
                text = "Describe the attached media."
            if action == "send-once" or "submission_id" in d:
                turn = turns.start_primary(pid, home, sid, text, d, d.get("submission_id"), d.get("project_context"),
                                           admissions_dir(), lambda: persona_scope(pid, sid, prepare_workspace_turn(pid, sid, d)),
                                           restore_send_workspace, d.get("attachments"), d.get("video_analysis_consent") is True)
                return self.send(202, turn.summary())
            workspace = persona_scope(pid, sid, prepare_workspace_turn(pid, sid, d))
            try:
                turn = turns.start_turn(pid, home, sid, text, {k: d.get(k) for k in ("provider", "model", "effort", "reset_model", "reset_effort")},
                                        workspace=workspace)
            except BaseException:
                if workspace:
                    try:
                        workspace["store"].discard_output(workspace["output_dir"])
                    except Exception:
                        pass
                raise
            return self.send(202, turn.summary())
        except turns.TurnError as e:
            return self.send(e.code, {"error": str(e)})
        except WorkspaceError as e:
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
            with STREAMS.watch(self.device_claims, self.authed, self.connection) as valid:
                if not valid:
                    return self.send(401, {"error": "Sign in again."})
                self._authorized_tail(turn, offset)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _authorized_tail(self, turn, offset):
        try:
            supported = self.headers.get("X-Hermes-Replay") == "checkpoint-v1"
            # Check before sending headers so older clients receive an actionable HTTP error.
            # A durable turn can be attached by a new bridge process with the same ID.
            # Its new sequence space may already overlap the old cursor numerically.
            claimed_epoch = self.headers.get("X-Hermes-Replay-Epoch")
            reset = supported and ((offset > 0 and claimed_epoch != turn.replay_epoch)
                                   or (offset == 0 and getattr(turn, "restored", False)))
            batch, offset, done, gap = turn.replay(offset, timeout=0, reset=reset)
            if gap and not supported:
                return self.send(410, {"error": "Live history expired. Update Hermes Mobile to reconnect."})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("X-Hermes-Replay-Epoch", turn.replay_epoch)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            while True:
                if gap and not supported:
                    break  # The next HTTP request receives 410.
                if batch:
                    self.wfile.write(b"".join(batch))
                    self.wfile.flush()
                if done:
                    break
                batch, offset, done, gap = turn.replay(offset)
                if not batch and not done:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = lambda self: self.route()

    def login(self):
        who = (self.headers.get("Tailscale-User-Login") or "local").strip().lower()[:120]
        with FAILS_LOCK:
            f = FAILS.setdefault(who, {"n": 0, "until": 0.0})
            if time.time() < f["until"]:
                return self.send(429, {"error": "Too many attempts. Wait a minute."})
        d = self.json_body()
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
        owner = self.login_elevates_to_owner()
        try:
            token = make_token(str(d.get("device", "iphone")), owner=owner, method="password")
        except (bridge_owner.OwnerError, OSError):
            token = make_token(str(d.get("device", "iphone")), method="password")
        return self.send(200, {"token": token, "ttl": TOKEN_TTL})

    def _native_timeline(self, pid, tail, query):
        """Serve a timeline page from SQLite when the session has no compression lineage.

        Any other transcript request, including an explicit compacted view, stays on the gateway.
        """
        match = re.fullmatch(r"/api/sessions/([^/]+)/messages", tail)
        if match is None:
            return None
        parsed = parse_qs(query, keep_blank_values=True)
        if set(parsed) - {"include_compacted", "offset", "limit", "order"} or any(len(v) != 1 for v in parsed.values()):
            return None
        if (parsed.get("include_compacted") or ["false"])[0].lower() not in ("", "0", "false"):
            return None
        order = (parsed.get("order") or [None])[0]
        if order not in (None, "oldest", "latest"):
            return None
        try:
            offset = int((parsed.get("offset") or ["0"])[0])
            raw_limit = (parsed.get("limit") or [None])[0]
            requested = None if raw_limit is None else int(raw_limit)
        except (TypeError, ValueError):
            return None
        if offset < 0 or (requested is not None and requested < 0):
            return None
        default_page = requested is None
        latest = order == "latest" or (order is None and default_page)
        limit = 500 if default_page else min(requested, 500)
        try:
            return native_timeline_page(pid, unquote(match.group(1)), limit, offset, latest)
        except Exception:
            return None

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
        if not stream and self.command == "GET" and self.headers.get("X-Hermes-Transcript") == "timeline-v1":
            compact = H._native_timeline(self, pid, tail, query)
            if compact is not None:
                tag = '"' + hashlib.sha256(compact).hexdigest() + '"'
                if self.headers.get("If-None-Match") == tag:
                    return self.send(304, validator=tag)
                return self.send(200, compact, validator=tag)
        try:
            c = http.client.HTTPConnection(*UPSTREAM, timeout=900 if stream else 120)
            c.request(self.command, up, body=data, headers=headers)
            upstream_socket = c.sock
            r = c.getresponse()
        except Exception as e:
            return self.send(502, {"error": "Hermes gateway is not answering (%s)." % type(e).__name__})
        try:
            if not stream:
                raw = r.read()
                if (r.status == 200 and self.command == "GET" and self.headers.get("X-Hermes-Transcript") == "timeline-v1"
                        and re.fullmatch(r"/api/sessions/[^/]+/messages", tail)):
                    try:
                        compact = timeline_page(raw)
                    except (ValueError, TypeError, KeyError, AttributeError):
                        pass  # Preserve the gateway response for older or unrecognized schemas.
                    else:
                        tag = '"' + hashlib.sha256(compact).hexdigest() + '"'
                        if self.headers.get("If-None-Match") == tag:
                            return self.send(304, validator=tag)
                        return self.send(200, compact, validator=tag)
                self.send(r.status, raw, r.getheader("Content-Type") or "application/json")
                return
            self.send_response(r.status)
            self.send_header("Content-Type", r.getheader("Content-Type") or "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            with STREAMS.watch(self.device_claims, self.authed, self.connection, upstream_socket) as valid:
                if valid:
                    while True:
                        chunk = r.read1(8192)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # the phone went away; /v1/runs keeps running on the gateway and can be re-attached
        finally:
            c.close()


if __name__ == "__main__":
    if sys.argv[1:] == ["--pair-code"]:
        print(devices().offer()["code"])
        sys.exit(0)
    if sys.argv[1:] == ["--list-devices"]:
        print(json.dumps(devices().active(), indent=2))
        sys.exit(0)
    if sys.argv[1:2] == ["--revoke-device"]:
        if len(sys.argv) != 3 or not re.fullmatch(r"[a-f0-9]{32}", sys.argv[2]):
            sys.exit("Use --revoke-device ID from --list-devices.")
        sys.exit(0 if devices().revoke(sys.argv[2]) else "Device not found or already revoked.")
    if "--set-owner-pin" in sys.argv:  # local seam only: the PIN is typed here, never sent over HTTP
        import getpass
        pin, again = getpass.getpass("New 4-digit deletion PIN: "), getpass.getpass("Repeat it: ")
        if pin != again or not bridge_owner.valid_pin(pin):
            sys.exit("The PINs must match and be exactly 4 digits. Nothing changed.")
        bridge_owner.set_pin(owner_dir(), pin)
        print("Deletion PIN set.")
        sys.exit(0)
    if "--clear-owner-pin" in sys.argv:
        bridge_owner.clear_pin(owner_dir())
        print("Deletion PIN cleared.")
        sys.exit(0)
    if "--rotate-owner-sessions" in sys.argv:
        bridge_owner.rotate_epoch(owner_dir())
        print("Owner sessions rotated: owners must sign in again.")
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--issue-token":
        # Pair a device without typing the password: prints a token to paste into the app.
        name = [a for a in sys.argv[2:] if not a.startswith("--")]
        print(make_token(name[0] if name else "paired-device", owner="--owner" in sys.argv))
        sys.exit(0)
    threading.Thread(target=_key_watcher, name="key-watcher", daemon=True).start()
    srv = ThreadingHTTPServer((os.environ.get("HERMES_MOBILE_BIND", "127.0.0.1"), PORT), H)
    if turns is not None:
        turns.recover_primary(admissions_dir(), profile_home, restore_send_workspace)
        for pid in profile_ids():
            turns.bridge_media.prune_clips(profile_home(pid))
    srv.daemon_threads = True
    log("Hermes Mobile bridge on http://%s:%d -> gateway %s:%d" % (srv.server_address[0], PORT, *UPSTREAM))
    srv.serve_forever()
