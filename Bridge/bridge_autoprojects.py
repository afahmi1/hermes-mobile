"""Projects that make themselves from chats (Build 54).

Two triggers, one result:

- Asked: "make this a project" in a chat. The phone's chat menu calls POST /m/autoprojects/from-chat, and Hermes
  itself runs the `hm-project` CLI (Bridge/hm_project.py) when asked in words.
- Noticed: a background pass finds a topic he came back to in >= 3 chats on >= 3 days within 30 days that no
  project holds yet, and makes a "Spotted by Hermes" project he can keep or dismiss.

Either way the chats' titles and opening messages are clustered cheaply first, then ONE auxiliary LLM call on the
bot's own Hermes config (agent.auxiliary_client.call_llm, task "project_drafting", in a child process like
bridge_titles) confirms the topic and drafts title, summary, instructions and context. Files the chats made or
named are copied in when they sit inside the home, are not secrets, and are small. Everything lands in storage
that already exists: a managed project (bridge_manage), its workspace instructions, a Context.md context file,
small text files as context files, other files as the chats' artifacts (bridge_workspaces), and the chats linked.

Stdlib only. The bridge hands in everything that touches its state (an Env object), so tests run on fakes.
Nothing from a transcript is ever logged.
"""
import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

import bridge_manage
import bridge_transcript as transcript
import bridge_workspaces
from bridge_workspaces import WorkspaceError

SETTING = "HERMES_MOBILE_AUTOPROJECTS"   # "0" turns the background pass off; asking still works
WINDOW_DAYS = 30
HISTORY_DAYS = 180                       # the longer look back that tells a recurring topic from a common word
MAX_HISTORY = 1000                       # chats per bot in that look back
MIN_CHATS = 3
MIN_DAYS = 3
MAX_CHATS_SCANNED = 400                  # per bot, newest first
MAX_LLM_CALLS = 2                        # per background pass
MAX_CREATED = 1                          # per background pass: one new suggestion a day at most
RUN_EVERY = 20 * 3600                    # the pass runs at most this often, restarts included
START_DELAY = 180                        # after the bridge starts, before the first pass
REJECT_TTL = 14 * 86400                  # a topic the model turned down is re-asked only after this, and grown
MAX_RELATED = 5                          # other chats offered to the model when one chat is made a project
MAX_FILE_CANDIDATES = 25
MAX_FILES = 8
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_FILES_BYTES = 24 * 1024 * 1024
PROMPT_BUDGET = 16000                    # characters of transcript excerpts in one prompt
TITLE_MAX, SUMMARY_MAX = 60, 300
INSTRUCTIONS_MAX = 2400                  # the store allows 4096 bytes
CONTEXT_MAX = 6000                       # a context file holds 8192 bytes
CONTEXT_NAME = "Context.md"
CONTEXT_FILE_BYTES = 8192
CONTEXT_EXTS = {".md", ".txt", ".csv", ".json"}
SKIP_SOURCES = ("subagent", "tool", "cron", "oneshot")
# Money bots never feed a project, whatever an operator list says: their chats stay in their own profile.
MONEY_PARTS = frozenset({"trading", "robinhood", "portfolio", "stocks", "trader", "finance", "bank", "banking",
                         "captain", "captains", "journal", "health", "bacta", "medical", "doctor", "wellness"})

LOCAL_HEADER = "X-Hermes-Local"
LOCAL_SKEW = 120


class AutoError(Exception):
    def __init__(self, message, status=400, code="bad_request"):
        super().__init__(message)
        self.status, self.code = status, code


def is_money_bot(pid):
    return bool(set(re.split(r"[-_]", str(pid))) & MONEY_PARTS)


# ---------- local CLI signature ----------
def local_key(secret):
    """The key the CLI signs with: derived from the bridge secret, so only a process that can read it can sign."""
    return hmac.new(bytes(secret), b"hermes-mobile local cli v1", hashlib.sha256).digest()


def local_signature(key, method, path, ts, nonce, body=b""):
    msg = "\n".join(["v1", method.upper(), path, str(int(ts)), nonce, hashlib.sha256(body or b"").hexdigest()])
    return hmac.new(key, msg.encode(), hashlib.sha256).hexdigest()


def local_header(secret, method, path, body=b"", now=None):
    ts, nonce = int(now if now is not None else time.time()), secrets.token_hex(12)
    return "v1 %d %s %s" % (ts, nonce, local_signature(local_key(secret), method, path, ts, nonce, body))


class Nonces:
    """Replay guard for signed local requests: each nonce works once inside the clock window."""

    def __init__(self):
        self._seen, self._lock = {}, threading.Lock()

    def check(self, secret, header, method, path, body, now=None):
        now = time.time() if now is None else now
        parts = (header or "").split(" ")
        if len(parts) != 4 or parts[0] != "v1" or not parts[1].isdigit() or not re.fullmatch(r"[0-9a-f]{16,64}", parts[2]):
            return False
        ts, nonce, sig = int(parts[1]), parts[2], parts[3]
        if abs(now - ts) > LOCAL_SKEW:
            return False
        want = local_signature(local_key(secret), method, path, ts, nonce, body)
        if not hmac.compare_digest(want.encode(), sig.encode()):
            return False
        with self._lock:
            for n, t in list(self._seen.items()):
                if now - t > 2 * LOCAL_SKEW:
                    del self._seen[n]
            if nonce in self._seen:
                return False
            self._seen[nonce] = now
        return True


# ---------- words ----------
_STOP = frozenset("""
a about above after again against all almost also am an and any are aren as at be because been before being below
between both but by can cannot could did didn do does doesn doing don done down during each either else even ever
every few for from further get gets getting got had has have having he her here hers him his how i if in into is
isn it its itself just let lets like make makes making made me might more most much my need needs no nor not now of
off on once one only or other our out over own please same she should so some still such than that the their them
then there these they this those through to too two under until up upon us very want wants was we were what when
where which while who whom why will with without would yes you your yours ok okay hey hi hello thanks thank sure
really maybe thing things stuff way use uses using used see look looks looking try tries trying tried go going goes
gonna know think right back fix fixes fixed fixing add adds added adding set sets setting setup check checks checked
checking test tests tested testing run runs ran running update updates updated updating help issue issues error
errors problem problems change changes changed work works worked working show shows find finds create creates created
today tomorrow yesterday time day days week chat chats message messages reply replies hermes new old good bad
something anything everything nothing why what into via per etc vs again already instead another next last first
model models context token tokens usage cost costs session sessions prompt prompts app apps bot bots agent agents
file files folder folders path paths image images screenshot screenshots photo photos jpg jpeg png heic pdf http
https www com url urls link links user users mac macos iphone phone repo repos github code tool tools project
projects documents desktop download downloads afahmi local setting settings config option options thing turn
""".split())
_WORD = re.compile(r"[a-z][a-z0-9]+|[0-9]+[a-z][a-z0-9]*")
# What the bridge appends to a message it forwards (workspace context, the output-folder note, an app persona).
_BRIDGE_TAIL = re.compile(r"\s*(?:Workspace context, supplied by the user for this request|Project output: save any file"
                          r"|App persona for this chat, set by the user)")
# Markers, links and paths: they name files, not topics.
_NOISE = re.compile(r"\[(?:Image attached at|Pasted text #\d+|User sent audio)[^\]]*\]|MEDIA:\S+|@\w+:\S+"
                    r"|https?://\S+|(?:~|/)(?:[\w.@+-]+/)+[\w.@+-]*")


def person_message(raw):
    """What he typed in one user turn: harness walls, notices and the bridge's own appended notes removed."""
    text = _text(raw)
    if not text:
        return ""
    verdict, body, _ = transcript.classify_user_text(text)
    if verdict != "user" or transcript._is_wall(body):
        return ""
    m = _BRIDGE_TAIL.search(body)
    return (body[:m.start()] if m else body).strip()


def person_words(raw):
    """person_message without markers, links and paths: the words a topic is made of."""
    return _NOISE.sub(" ", person_message(raw)).replace("`", " ").strip()


def stem(word):
    w = word
    if len(w) > 4 and w.endswith("ies"):
        w = w[:-3] + "y"
    elif len(w) > 3 and w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    if len(w) > 5 and w.endswith("ing"):
        w = w[:-3]
    elif len(w) > 4 and w.endswith("ed"):
        w = w[:-2]
    return w


def terms(text):
    """The distinctive words of a text: lowercase, no stopwords, lightly stemmed."""
    out = set()
    for raw in _WORD.findall((text or "").lower()):
        if len(raw) < 3 and not any(ch.isdigit() for ch in raw):
            continue
        if raw in _STOP:
            continue
        w = stem(raw)
        if w in _STOP or len(w) < 2:
            continue
        out.add(w)
    return out


def jaccard(a, b):
    a, b = set(a), set(b)
    return len(a & b) / len(a | b) if (a or b) else 0.0


# ---------- chats ----------
class Chat:
    """One conversation as the phone shows it: a root session plus its compression continuations."""
    __slots__ = ("profile", "sid", "title", "terms", "title_terms", "days", "last", "ids", "messages", "cwd")

    def __init__(self, profile, sid, title, terms_, days, last, ids, messages, cwd=None, title_terms=None):
        self.profile, self.sid, self.title, self.terms = profile, sid, title, set(terms_)
        self.days, self.last, self.ids, self.messages, self.cwd = set(days), last, list(ids), messages, cwd
        self.title_terms = set(title_terms) if title_terms is not None else terms(title)

    @property
    def key(self):
        return (self.profile, self.sid)


def _cols(con, table):
    try:
        return {r[1] for r in con.execute("PRAGMA table_info(%s)" % table)}
    except Exception:
        return set()


def _text(raw):
    if not isinstance(raw, str):
        return ""
    s = raw.strip()
    if s.startswith("[{"):
        try:
            parts = json.loads(s)
        except ValueError:
            return s
        if isinstance(parts, list):
            return " ".join(p["text"] for p in parts if isinstance(p, dict) and isinstance(p.get("text"), str))
    return s


def _day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(float(ts)))


class _Sessions:
    """Read-only lookups on one bot's state.db, tolerant of older and newer schemas."""

    def __init__(self, con):
        self.con = con
        self.cols = _cols(con, "sessions")
        self.mcols = _cols(con, "messages")
        self._rows = {}

    def _select(self):
        def opt(c, default="NULL"):
            return c if c in self.cols else "%s AS %s" % (default, c)
        last = "coalesce(last_activity_at, started_at)" if "last_activity_at" in self.cols else "started_at"
        return ("SELECT id, %s, started_at, %s AS last, %s, %s, %s, %s, %s, %s, %s FROM sessions" % (
            opt("title"), last, opt("parent_session_id"), opt("end_reason"), opt("cwd"), opt("message_count", "0"),
            opt("source", "''"), opt("hidden", "0"), opt("archived", "0")), last)

    def row(self, sid):
        if sid not in self._rows:
            sql, _ = self._select()
            r = self.con.execute(sql + " WHERE id=?", (sid,)).fetchone()
            self._rows[sid] = dict(r) if r is not None else None
        return self._rows[sid]

    def recent(self, since, limit):
        sql, last = self._select()
        where = [last + " >= ?"]
        if "hidden" in self.cols:
            where.append("coalesce(hidden,0)=0")
        if "archived" in self.cols:
            where.append("coalesce(archived,0)=0")
        if "source" in self.cols:
            where.append("coalesce(source,'') NOT IN (%s)" % ",".join("'%s'" % s for s in SKIP_SOURCES))
        rows = [dict(r) for r in self.con.execute(sql + " WHERE " + " AND ".join(where) + " ORDER BY last DESC LIMIT %d"
                                                  % int(limit), (since,))]
        for r in rows:
            self._rows[r["id"]] = r
        return rows

    def root(self, sid):
        """The chat a session belongs to: walk up while the parent ended by compression (a continuation)."""
        cur, seen = sid, set()
        while cur not in seen and len(seen) < 32:
            seen.add(cur)
            row = self.row(cur)
            if row is None or not row.get("parent_session_id"):
                break
            parent = self.row(row["parent_session_id"])
            if parent is None or parent.get("end_reason") != "compression":
                break
            cur = parent["id"]
        return cur

    def lineage(self, root):
        """The root and every compression continuation after it."""
        out, todo = [root], [root]
        while todo and len(out) < 64:
            cur = todo.pop()
            row = self.row(cur)
            if row is None or row.get("end_reason") != "compression":
                continue
            for (child,) in self.con.execute("SELECT id FROM sessions WHERE parent_session_id=?", (cur,)):
                if child not in out:
                    out.append(child)
                    todo.append(child)
        return out

    def user_text(self, ids, newest=False):
        """His first (or latest) words in this chat, skipping harness walls and notices."""
        if not {"session_id", "role", "content"} <= self.mcols or not ids:
            return ""
        order = "timestamp DESC" if "timestamp" in self.mcols and newest else ("timestamp" if "timestamp" in self.mcols else "id")
        q = ",".join("?" for _ in ids)
        for (content,) in self.con.execute("SELECT content FROM messages WHERE session_id IN (%s) AND role='user' "
                                           "ORDER BY %s LIMIT 12" % (q, order), list(ids)):
            text = person_words(content)
            if text:
                return text
        return ""

    def user_days(self, ids, since):
        if not {"session_id", "role", "timestamp"} <= self.mcols or not ids:
            return set()
        q = ",".join("?" for _ in ids)
        return {_day(ts) for (ts,) in self.con.execute(
            "SELECT timestamp FROM messages WHERE session_id IN (%s) AND role='user' AND timestamp >= ?" % q,
            list(ids) + [since]) if ts is not None}

    def chat(self, profile, root, since):
        row = self.row(root)
        if row is None or (row.get("source") or "") in SKIP_SOURCES:
            return None
        ids = self.lineage(root)
        rows = [r for r in (self.row(i) for i in ids) if r is not None]
        title = next((r.get("title") for r in reversed(rows) if r.get("title")), "") or ""
        first, latest = self.user_text(ids), self.user_text(ids, newest=True)
        messages = sum(int(r.get("message_count") or 0) for r in rows)
        days = self.user_days(ids, since)
        words = terms(title) | terms(first[:400]) | terms(latest[:300])
        last = max(float(r.get("last") or r.get("started_at") or 0) for r in rows)
        return Chat(profile, root, title.strip()[:200], words, days, last, ids, messages, row.get("cwd"),
                    title_terms=terms(title))


def list_chats(con, profile, since, limit=MAX_CHATS_SCANNED):
    """Chats active since `since`, newest first, one per conversation (continuations folded into their root)."""
    s = _Sessions(con)
    if not {"id", "started_at"} <= s.cols:
        return []
    out, done = [], set()
    for r in s.recent(since, limit):
        root = s.root(r["id"])
        if root in done:
            continue
        done.add(root)
        c = s.chat(profile, root, since)
        if c is not None and c.messages >= 2 and c.terms and c.days:
            out.append(c)
    return out


def chat_for(con, profile, sid, since):
    """The one chat holding session `sid` (its root), or None when Hermes has no such session."""
    s = _Sessions(con)
    if not {"id", "started_at"} <= s.cols or s.row(sid) is None:
        return None
    chat = s.chat(profile, s.root(sid), since)
    if chat is None:
        raise AutoError("Background and helper chats can't become projects.", 409, "not_a_chat")
    return chat


# ---------- clustering ----------
class Cluster:
    __slots__ = ("terms", "chats", "days", "score")

    def __init__(self, terms_, chats, days, score):
        self.terms, self.chats, self.days, self.score = set(terms_), list(chats), days, score

    @property
    def keys(self):
        return {c.key for c in self.chats}

    @property
    def fp(self):
        return bridge_manage.topic_fp(self.terms)


def generic_terms(history, window):
    """Words too common across his longer history to name a topic: in many chats overall, and not concentrated
    in the recent window (a topic he came back to recently is bursty). Needs a history longer than the window."""
    if len(history) < 2 * max(len(window), 1):
        return set()
    n = len(history)
    df_all = Counter(t for c in history for t in c.terms)
    df_win = Counter(t for c in window for t in c.terms)
    return {t for t, k in df_all.items() if k >= max(8, 0.06 * n) and df_win.get(t, 0) / k < 0.5}


def clusters(chats, min_chats=MIN_CHATS, min_days=MIN_DAYS, generic=None):
    """Topics that recur: a word (or words that travel together) named in >= 2 chat titles, shared by
    >= min_chats chats across >= min_days days, and not so common that it names nothing. Best first."""
    generic = generic or set()
    n = len(chats)
    if n < min_chats:
        return []
    df = Counter(t for c in chats for t in c.terms)
    titled = Counter(t for c in chats for t in c.title_terms)
    cap = max(min_chats + 3, int(0.2 * n))
    by_members = {}
    for t, k in df.items():
        if min_chats <= k <= cap and titled[t] >= 2 and t not in generic:
            members = frozenset(i for i, c in enumerate(chats) if t in c.terms)
            by_members.setdefault(members, set()).add(t)
    groups = []
    for members, words in sorted(by_members.items(), key=lambda kv: (-len(kv[0]), sorted(kv[1]))):
        for g in groups:
            if len(g[0] & members) / len(g[0] | members) >= 0.6:
                g[0].update(members)
                g[1].update(words)
                break
        else:
            groups.append((set(members), set(words)))
    out = []
    for members, words in groups:
        days = set().union(*(chats[i].days for i in members))
        if len(members) < min_chats or len(days) < min_days:
            continue
        words = set(sorted(words, key=lambda t: (df[t], t))[:6])  # the rarest words name the topic
        weight = sum(math.log(n / df[t]) for t in words) / len(words)
        score = len(members) * max(weight, 0.05) * (1 + 0.15 * (len(words) - 1)) * (1 + 0.1 * len(days))
        ordered = sorted((chats[i] for i in members), key=lambda c: -c.last)
        out.append(Cluster(words, ordered, len(days), score))
    return sorted(out, key=lambda c: (-c.score, sorted(c.terms)))


def dismissed_match(cluster, dismissed):
    """True when he already dismissed this topic: the same words, or mostly the same chats."""
    keys = cluster.keys
    for d in dismissed:
        if d.get("terms") and jaccard(cluster.terms, d["terms"]) >= 0.5:
            return True
        chats = d.get("chats") or set()
        if chats and len(keys & chats) * 2 >= max(1, len(keys)):
            return True
    return False


def covering_project(cluster_terms, projects):
    """The id of an existing project this topic already is, judged by its title and summary words."""
    for p in projects:
        title = terms(p.get("title") or "")
        hit = set(cluster_terms) & (title | terms(p.get("summary") or ""))
        if hit and ((title and title <= set(cluster_terms)) or len(hit) >= 2 or hit == set(cluster_terms)):
            return p.get("id")
    return None


def related(source, chats, limit=MAX_RELATED):
    """Other chats most likely about the same work as `source`, by shared distinctive words."""
    n = max(len(chats) + 1, 2)
    df = Counter(t for c in chats for t in c.terms)
    scored = []
    for c in chats:
        if c.key == source.key:
            continue
        shared = source.terms & c.terms
        weight = sum(math.log(n / max(df[t], 1)) for t in shared)
        if len(shared) >= 2 or (shared and weight >= math.log(n / 2)):
            scored.append((weight, c.last, c))
    return [c for _, _, c in sorted(scored, key=lambda x: (-x[0], -x[1]))[:limit]]


# ---------- files ----------
_SECRET_PATTERNS = [re.compile(p) for p in (
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"\b(?:sk|rk)-(?:proj-|ant-|live-)?[A-Za-z0-9_-]{20,}",
    r"\bgh[pousr]_[A-Za-z0-9]{30,}", r"\bgithub_pat_[A-Za-z0-9_]{30,}",
    r"\bxox[abprs]-[A-Za-z0-9-]{10,}", r"\bAKIA[0-9A-Z]{16}\b", r"\bAIza[0-9A-Za-z_-]{30,}",
    r"(?m)^\s*(?:export\s+)?[A-Za-z0-9_]*(?:API_KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_]*\s*[=:]\s*['\"]?[^\s'\"]{8,}",
)]


def looks_secret(text):
    return any(p.search(text or "") for p in _SECRET_PATTERNS)


def redact(text):
    for p in _SECRET_PATTERNS:
        text = p.sub("[redacted]", text)
    return text


def read_file(path, roots):
    """(Path, bytes) for a file a chat named, or None: inside the allowed roots, a known type, not a credential
    (bridge_transcript.safe_file), under the size cap, and no secret inside a text file."""
    real = transcript.safe_file(str(path), roots)
    if real is None:
        return None
    try:
        size = real.stat().st_size
        if size <= 0 or size > MAX_FILE_BYTES:
            return None
        data = real.read_bytes()
    except OSError:
        return None
    if len(data) > MAX_FILE_BYTES:
        return None
    try:
        text = data[:512 * 1024].decode("utf-8")
    except UnicodeDecodeError:
        text = None
    if text is not None and looks_secret(text):
        return None
    return real, data


def candidate_files(entries, roots, limit=MAX_FILE_CANDIDATES):
    """Files the chats attached, made or named, newest mention first: [(path, size, chat_key)].
    `entries` are (chat_key, role, text) in transcript order."""
    seen, out = set(), []
    for key, role, text in reversed(list(entries)):
        found = list(transcript._marker_paths(text)) + list(transcript.mentioned_paths(text))
        for raw in found:
            if len(out) >= limit:
                return out
            raw = (raw or "").strip()
            if raw.startswith("~"):
                raw = str(Path.home()) + raw[1:]
            if not raw.startswith("/") or raw in seen:
                continue
            seen.add(raw)
            got = read_file(raw, roots)
            if got is None:
                continue
            real, data = got
            if str(real) in seen and str(real) != raw:
                continue
            seen.add(str(real))
            out.append((str(real), len(data), key))
    return out


def file_name(path):
    name = os.path.basename(path).strip()
    name = "".join(ch for ch in name if ch.isprintable() and ch not in "/\\")
    while name.startswith("."):
        name = name[1:]
    if not name:
        return "file.txt"
    if len(name) > 120:
        stem_, ext = os.path.splitext(name)
        name = stem_[:120 - len(ext)] + ext
    return name


# ---------- drafting ----------
SYSTEM = """You turn a person's chats with their AI agent (Hermes) into a project page in their phone app.
Reply with one JSON object only, matching the schema. No prose around it.

Write for the agent that will work in this project later. His style: short sentences, active voice, spartan,
plain words. Never use em dashes or en dashes. No filler, no hype, no first person.

Fields:
- is_project: true when these chats are one ongoing piece of work with a goal (build, research, plan, decide,
  fix something over time). False for routines or chats that only share a word (daily journal entries,
  check-ins, status pings, unrelated one-off questions).
- reason: one short sentence on why.
- existing: the id of a listed existing project when these chats are plainly ongoing work on that exact
  project, else "".
- title: 2 to 5 words, no quotes, no trailing punctuation.
- summary: 1 to 2 sentences: what it is and where it stands now.
- instructions: how Hermes should work in this project. 4 to 8 lines, each starting with "- ". Goals, his
  preferences and rules seen in the chats (tools, style, what to avoid, how to verify, where things live).
- context: markdown with the sections "## Key facts", "## Decisions", "## Open questions" and
  "## Current state", each a short bullet list. Concrete names, paths, numbers and dates from the chats.
  Nothing invented. Never copy keys, tokens or passwords.
- files: up to 8 paths copied exactly from the candidate file list that matter for this project. Only paths
  from that list. [] when none.
- chats: the numbers of the chats that belong to this project."""

FORMAT = {"type": "json_schema", "json_schema": {"name": "project_draft", "strict": True, "schema": {
    "type": "object", "additionalProperties": False,
    "required": ["is_project", "reason", "existing", "title", "summary", "instructions", "context", "files", "chats"],
    "properties": {
        "is_project": {"type": "boolean"}, "reason": {"type": "string"}, "existing": {"type": "string"},
        "title": {"type": "string"}, "summary": {"type": "string"}, "instructions": {"type": "string"},
        "context": {"type": "string"}, "files": {"type": "array", "items": {"type": "string"}},
        "chats": {"type": "array", "items": {"type": "integer"}}}}}}


def _clip(text, limit):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def excerpt(bodies, budget):
    """A chat in its own words within `budget` characters: how it started, then its latest turns. His turns
    are what he typed (harness walls and the bridge's appended notes dropped)."""
    msgs = []
    for r, t in bodies:
        if r == "user":
            t = person_message(t)
        if r in ("user", "assistant") and t and t.strip():
            msgs.append((r, t))
    if not msgs:
        return ""
    head = [m for m in msgs if m[0] == "user"][:2]
    tail = msgs[-6:]
    picked, seen = [], set()
    for m in head + tail:
        if id(m) not in seen:
            seen.add(id(m))
            picked.append(m)
    per = max(200, budget // max(len(picked), 1))
    lines = ["%s: %s" % ("He" if r == "user" else "Hermes", _clip(redact(t), per)) for r, t in picked]
    out = "\n".join(lines)
    return out[:budget]


def build_prompt(chats, bodies, files, projects, explicit):
    budget = max(1500, PROMPT_BUDGET // max(len(chats), 1))
    lines = []
    if explicit:
        lines.append("He asked to make chat [1] a project, so it is one: set is_project true and include chat 1. "
                     "Chats 2 and up may be related; include them only when they are the same work.")
    else:
        lines.append("Hermes noticed he kept coming back to this topic. Decide whether it is a project.")
    lines.append("")
    lines.append("Existing projects (id: title):")
    lines += ["- %s: %s" % (p["id"], _clip(p.get("title") or "", 80)) for p in projects[:40]] or ["- none"]
    lines.append("")
    lines.append("Candidate files (path, size):")
    home = str(Path.home())
    lines += ["- %s (%s)" % ("~" + p[len(home):] if p.startswith(home + "/") else p, _size(n)) for p, n, _ in files] or ["- none"]
    lines.append("")
    lines.append("Chats:")
    for i, c in enumerate(chats, 1):
        days = ", ".join(sorted(c.days)[-6:])
        lines.append("[%d] bot %s, \"%s\", active %s" % (i, c.profile, _clip(c.title or "Untitled", 90), days))
        lines.append(excerpt(bodies.get(c.key) or [], budget))
        lines.append("")
    return "\n".join(lines)


def _size(n):
    return "%d B" % n if n < 1024 else ("%.0f KB" % (n / 1024) if n < 1024 * 1024 else "%.1f MB" % (n / 1048576))


_DASHES = re.compile(r"\s*[\u2014\u2013]\s*")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean(text, limit, multiline=False, max_bytes=None):
    if not isinstance(text, str):
        return ""
    text = _CONTROL.sub("", text.replace("\r\n", "\n"))
    text = _DASHES.sub(", ", text)
    text = redact(text)
    if not multiline:
        text = " ".join(text.split())
    else:
        text = "\n".join(line.rstrip() for line in text.strip().splitlines())
        text = re.sub(r"\n{3,}", "\n\n", text)
    if len(text) > limit:
        cut = text[:limit]
        text = (cut.rsplit("\n", 1)[0] if multiline and "\n" in cut else cut.rstrip()).rstrip()
    if max_bytes is not None:
        while len(text.encode("utf-8")) > max_bytes:
            text = text[:-max(1, (len(text.encode("utf-8")) - max_bytes) // 4)]
    return text.strip()


def _json_object(text):
    if not isinstance(text, str):
        return None
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        obj = json.loads(text[start:end + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def parse_draft(text, n_chats, files, explicit=False):
    """The model's JSON as a checked draft: texts cleaned and capped, chats as 0-based indexes within range,
    files only from the candidates. None when nothing usable came back."""
    obj = _json_object(text)
    if obj is None:
        return None
    title = clean(obj.get("title"), TITLE_MAX, max_bytes=bridge_manage.TITLE_MAX).strip(" .\"'")
    summary = clean(obj.get("summary"), SUMMARY_MAX, max_bytes=bridge_manage.SUMMARY_MAX)
    if not title:
        return None
    by_path = {p: (p, n, k) for p, n, k in files}
    home = str(Path.home())
    picked = []
    for raw in obj.get("files") if isinstance(obj.get("files"), list) else []:
        if not isinstance(raw, str):
            continue
        p = raw.strip().strip("`\"'")
        if p.startswith("~"):
            p = home + p[1:]
        if p in by_path and by_path[p] not in picked:
            picked.append(by_path[p])
        if len(picked) >= MAX_FILES:
            break
    idx = []
    for n in obj.get("chats") if isinstance(obj.get("chats"), list) else []:
        if type(n) is int and 1 <= n <= n_chats and n - 1 not in idx:
            idx.append(n - 1)
    if explicit and 0 not in idx:
        idx.insert(0, 0)
    return {"is_project": bool(obj.get("is_project")) or explicit,
            "reason": clean(obj.get("reason"), 200),
            "existing": obj.get("existing").strip() if isinstance(obj.get("existing"), str) else "",
            "title": title, "summary": summary,
            "instructions": clean(obj.get("instructions"), INSTRUCTIONS_MAX, multiline=True,
                                  max_bytes=bridge_workspaces.MAX_INSTRUCTIONS_BYTES),
            "context": clean(obj.get("context"), CONTEXT_MAX, multiline=True, max_bytes=CONTEXT_FILE_BYTES),
            "files": picked, "chats": sorted(idx)}


_DRAFT = r"""
import json, os, sys
try:
    from hermes_cli.config import load_env
    for k, v in (load_env() or {}).items():
        os.environ.setdefault(k, v)
except Exception:
    pass
req = json.loads(sys.stdin.read())
try:
    from agent.auxiliary_client import call_llm, extract_content_or_reasoning
    kw = dict(task="project_drafting", messages=[{"role": "system", "content": req["system"]},
              {"role": "user", "content": req["user"]}], max_tokens=req["max_tokens"], temperature=None,
              timeout=req["timeout"], reasoning_config={"enabled": False})
    if req.get("format"):
        kw["extra_body"] = {"response_format": req["format"]}
    print(json.dumps({"text": extract_content_or_reasoning(call_llm(**kw)) or ""}))
except Exception as e:
    print(json.dumps({"error": type(e).__name__}))
"""


def llm_call(home, system, user, timeout=150, python=None):
    """One auxiliary LLM call with this bot's own config and keys (auxiliary.project_drafting picks the route;
    unset, Hermes uses the bot's main model). In a child process, so a provider SDK never loads into the bridge.
    Returns the reply text, or None."""
    try:
        import hermes_cli
        cwd = str(Path(hermes_cli.__file__).resolve().parents[1])
    except Exception:
        cwd = None
    env = {**os.environ, "HERMES_HOME": str(home)}
    payload = json.dumps({"system": system, "user": user, "max_tokens": 4000, "timeout": timeout, "format": FORMAT})
    try:
        done = subprocess.run([python or sys.executable, "-c", _DRAFT], input=payload, capture_output=True, text=True,
                              timeout=timeout + 60, env=env, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in reversed((done.stdout or "").strip().splitlines()):
        try:
            out = json.loads(line)
        except ValueError:
            continue
        if isinstance(out, dict):
            return out.get("text") or None
    return None


# ---------- applying a draft ----------
def _sha(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def _b64(data):
    return base64.b64encode(data).decode("ascii")


def _project_row(m, pid):
    return next((p for p in m.managed_projects() if p["id"] == pid), None)


def apply_draft(env, draft, chats, origin, topic_terms, target=None, existing=None):
    """Create or update the project for these chats. Idempotent: a chat already in a project Hermes made updates
    that project; what he edited since (title, summary, instructions, Context.md) is left alone.
    Returns {"project_id", "action", "title", "chats", "files", "instructions", "context"}."""
    m, store = env.manage(), env.store()
    metas = {x["id"]: x for x in m.all_meta()}
    links = store.chat_links()
    action = "updated" if target else None
    if target is None:
        for c in chats:
            pid = links.get(c.key)
            if pid in metas:
                target, action = pid, "updated"
                break
    if target is None and existing:
        target, action = existing, "linked"
    if target is None:
        made = m.create_project(draft["title"], draft["summary"] or None, None, env.catalog_ids())
        target, action = made["id"], "created"
    meta = metas.get(target)
    ours = action in ("created", "updated")
    written = dict(meta["written"]) if meta else {}
    if action == "created":
        written.update(title=_sha(draft["title"]), summary=_sha(draft["summary"] or ""))
    elif action == "updated":
        row = _project_row(m, target)
        body = {}
        if row and _sha(row["title"]) == written.get("title") and row["title"] != draft["title"]:
            body["title"] = draft["title"]
        if row and _sha(row.get("summary") or "") == written.get("summary") and (row.get("summary") or "") != draft["summary"]:
            body["summary"] = draft["summary"]
        if body:
            m.update_project(target, body)
            written.update({k: _sha(v) for k, v in body.items()})

    linked = []
    for c in chats:
        try:
            store.link_chat(target, c.profile, c.sid, c.title or "Chat")
            linked.append(c)
        except WorkspaceError:
            pass  # held by another project: never moved
    keys = {c.key for c in linked}
    keys |= set(meta["chats"]) if meta else set()

    revision, stored = store.assignment(target)
    eligible = set(env.eligible(target))
    want = sorted(set(stored) | {c.profile for c in linked if c.profile in eligible})
    if want != stored:
        try:
            store.set_assignment(target, want, revision, sorted(eligible))
        except WorkspaceError as e:
            env.log("autoprojects: assignment for %s not saved (%s)" % (target, getattr(e, "kind", None) or e.code))

    instructions = context = False
    if ours and draft["instructions"]:
        current = store.detail(target)["instructions"]
        if not current or _sha(current) == written.get("instructions"):
            if current != draft["instructions"]:
                store.save_instructions(target, draft["instructions"])
            written["instructions"] = _sha(draft["instructions"])
            instructions = True
    if ours and draft["context"]:
        data = draft["context"].encode("utf-8")[:CONTEXT_FILE_BYTES]
        text = data.decode("utf-8", "ignore")
        have = store.file_named(target, CONTEXT_NAME)
        try:
            if have is None:
                store.add_file(target, CONTEXT_NAME, _b64(text.encode("utf-8")))
                written["context"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
                context = True
            elif have[1] == written.get("context"):
                if have[1] != hashlib.sha256(text.encode("utf-8")).hexdigest():
                    store.put_file(target, have[0], text, have[1])
                written["context"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
                context = True
        except WorkspaceError as e:
            env.log("autoprojects: context file for %s not saved (%s)" % (target, e.code))

    files = _copy_files(env, store, target, draft["files"], linked, context_files=ours)
    if ours:
        state = "spotted" if origin == "spotted" else "kept"
        days = len(set().union(*(c.days for c in chats))) if chats else 0
        m.save_meta(target, origin if not meta else meta["origin"], meta["state"] if meta else state,
                    topic_terms, keys, written, days)
    return {"project_id": target, "action": action, "title": draft["title"], "chats": len(linked),
            "files": files, "instructions": instructions, "context": context}


def _copy_files(env, store, project, picked, linked, context_files=True):
    """Small text files become context files while there's room (only in projects Hermes made: a project he set
    up keeps exactly the context files he chose); the rest are kept as the chats' artifacts."""
    if not picked or not linked:
        return 0
    roots = env.file_roots()
    by_key = {c.key: c for c in linked}
    total = copied = 0
    room = max(0, bridge_workspaces.MAX_FILES - len(store.files_with_sha(project))) if context_files else 0
    for path, _size_, key in picked:
        got = read_file(path, roots)
        if got is None:
            continue
        real, data = got
        if total + len(data) > MAX_FILES_BYTES:
            break
        name = file_name(str(real))
        owner = by_key.get(key) or linked[0]
        try:
            if room and os.path.splitext(name)[1].lower() in CONTEXT_EXTS and len(data) <= CONTEXT_FILE_BYTES \
                    and name.lower() != CONTEXT_NAME.lower():
                try:
                    store.add_file(project, name, _b64(data))
                    room -= 1
                    copied += 1
                    total += len(data)
                    continue
                except WorkspaceError:
                    pass  # same name or same bytes already there, or not valid for its type: keep it as an artifact
            if store.import_artifact(project, owner.profile, owner.sid, name, data) is not None:
                copied += 1
                total += len(data)
        except WorkspaceError as e:
            env.log("autoprojects: a file for %s was not kept (%s)" % (project, e.code))
    return copied


# ---------- the two triggers ----------
def _bodies(env, chats):
    out = {}
    for c in chats:
        try:
            out[c.key] = env.bodies(c.profile, c.sid) or []
        except Exception as e:  # noqa: BLE001
            env.log("autoprojects: transcript unreadable (%s)" % type(e).__name__)
            out[c.key] = []
    return out


def _files(env, chats, bodies):
    entries = [(c.key, role, text) for c in chats for role, text in bodies.get(c.key) or []]
    return candidate_files(entries, env.file_roots())


def _drafting_bot(chats):
    count = Counter(c.profile for c in chats)
    top = max(count.values())
    return "default" if count.get("default") == top else sorted(p for p, k in count.items() if k == top)[0]


def from_chat(env, profile, sid, stage=lambda name: None):
    """Make (or refresh) the project for one chat, because he asked."""
    if profile not in env.profiles():
        raise AutoError("This bot isn't set up for projects on the Mac. Add it to HERMES_MOBILE_WORKSPACE_BOTS.",
                        403, "not_eligible")
    since = env.now() - WINDOW_DAYS * 86400
    con = env.ro(profile)
    if con is None:
        raise AutoError("This bot has no saved chats.", 404, "not_found")
    try:
        source = chat_for(con, profile, sid, since=0)
        if source is None:
            raise AutoError("That chat isn't on the Mac.", 404, "not_found")
        others = [c for c in list_chats(con, profile, since) if c.key != source.key]
    finally:
        con.close()
    stage("reading")
    m, store = env.manage(), env.store()
    links = store.chat_links()
    metas = {x["id"]: x for x in m.all_meta()}
    held = links.get(source.key)
    target = None
    if held is not None:
        if held in m.archived_projects():
            m.restore_project(held)
        if held not in metas:
            title = next((p["title"] for p in env.projects() if p["id"] == held), held)
            return {"project_id": held, "action": "exists", "title": title, "chats": 0, "files": 0,
                    "instructions": False, "context": False}
        target = held
        known = set(metas[held]["chats"])
        others = [c for c in others if c.key in known] + [c for c in others if c.key not in known and c.key not in links]
    else:
        others = [c for c in others if c.key not in links]
    for pid in [p for p in env.profiles() if p != profile]:
        con = env.ro(pid)
        if con is None:
            continue
        try:
            others += [c for c in list_chats(con, pid, since) if c.key not in links]
        finally:
            con.close()
    candidates = [source] + related(source, others)
    bodies = _bodies(env, candidates)
    files = _files(env, candidates, bodies)
    stage("drafting")
    projects = [p for p in env.projects() if p["id"] != target]
    text = env.llm(profile, SYSTEM, build_prompt(candidates, bodies, files, projects, explicit=True))
    draft = parse_draft(text, len(candidates), files, explicit=True)
    if draft is None:
        raise AutoError("Hermes couldn't draft this project right now. Try again in a minute.", 502, "draft_failed")
    stage("saving")
    picked = [candidates[i] for i in draft["chats"]]
    existing = draft["existing"] if target is None and draft["existing"] in {p["id"] for p in projects} else None
    shared = source.terms & set().union(*(c.terms for c in picked[1:])) if len(picked) > 1 else set()
    topic = set(sorted(shared or source.terms)[:12])
    with env.lock:
        result = apply_draft(env, draft, picked, "chat", topic, target=target, existing=existing)
        meta = m.meta(result["project_id"])
        if meta and meta["state"] == "spotted":
            m.keep_project(result["project_id"])  # he asked for it: no longer just a suggestion
    return result


def detect(env, dry_run=False, force=False, use_llm=True):
    """The background pass: find topics he keeps returning to and make one into a spotted project.
    Returns a report; `dry_run` writes nothing (no project, no memory, no run stamp)."""
    m, store = env.manage(), env.store()
    now = env.now()
    last = m.detector_get("last_run", 0) or 0
    if not force and not dry_run and now - float(last) < RUN_EVERY:
        return {"skipped": "recent", "last_run": last}
    since = now - WINDOW_DAYS * 86400
    start_day = _day(since)
    links = store.chat_links()
    dismissed = m.dismissed_topics()
    gone = set().union(*(d["chats"] for d in dismissed)) if dismissed else set()
    history, recent, chats = [], [], []
    for pid in env.profiles():
        con = env.ro(pid)
        if con is None:
            continue
        try:
            for c in list_chats(con, pid, now - HISTORY_DAYS * 86400, limit=MAX_HISTORY):
                history.append(c)
                days = {d for d in c.days if d >= start_day}
                if c.last < since or not days:
                    continue
                c.days = days
                recent.append(c)
                if c.key in links or c.key in gone or env.owned(pid, c.cwd):
                    continue
                chats.append(c)
        finally:
            con.close()
    generic = generic_terms(history, recent)
    projects = env.projects()
    rejected = m.detector_get("rejected", {}) or {}
    report = {"scanned": len(chats), "candidates": [], "created": [], "would_create": [], "rejected": []}
    calls = 0
    for cl in clusters(chats, generic=generic)[:12]:
        entry = {"terms": sorted(cl.terms), "chats": len(cl.chats), "days": cl.days}
        if dismissed_match(cl, dismissed):
            entry["skip"] = "dismissed"
        elif covering_project(cl.terms, projects):
            entry["skip"] = "has_project"
        else:
            seen = rejected.get(cl.fp)
            if seen and now - float(seen.get("ts", 0)) < REJECT_TTL and len(cl.chats) <= int(seen.get("n", 0)) + 1:
                entry["skip"] = "rejected"
        report["candidates"].append(entry)
        if entry.get("skip") or not use_llm or calls >= MAX_LLM_CALLS or len(report["created"]) >= MAX_CREATED:
            continue
        calls += 1
        candidates = cl.chats[:8]
        bodies = _bodies(env, candidates)
        files = _files(env, candidates, bodies)
        text = env.llm(_drafting_bot(candidates), SYSTEM, build_prompt(candidates, bodies, files, projects, explicit=False))
        draft = parse_draft(text, len(candidates), files)
        picked = [candidates[i] for i in draft["chats"]] if draft else []
        days = set().union(*(c.days for c in picked)) if picked else set()
        ok = (draft is not None and draft["is_project"] and not draft["existing"]
              and len(picked) >= MIN_CHATS and len(days) >= MIN_DAYS)
        if not ok:
            reason = "no_draft" if draft is None else ("existing" if draft["existing"] else "not_a_project")
            report["rejected"].append({"terms": sorted(cl.terms), "reason": reason})
            if not dry_run and draft is not None:
                rejected[cl.fp] = {"ts": now, "n": len(cl.chats)}
            continue
        if dry_run:
            report["would_create"].append({"title": draft["title"], "summary": draft["summary"],
                                           "chats": len(picked), "days": len(days), "files": len(draft["files"])})
            continue
        with env.lock:
            # Re-check under the lock: he may have linked one of these chats a moment ago.
            if any(c.key in store.chat_links() for c in picked):
                continue
            result = apply_draft(env, draft, picked, "spotted", cl.terms)
        report["created"].append(result)
    if not dry_run:
        fresh = {fp: v for fp, v in rejected.items() if now - float(v.get("ts", 0)) < REJECT_TTL}
        m.detector_set("rejected", fresh)
        m.detector_set("last_run", now)
    return report


# ---------- jobs: long calls, polled by the phone and the CLI ----------
class Jobs:
    STAGES = ("queued", "reading", "drafting", "saving", "done", "failed")

    def __init__(self, keep=32, ttl=3600):
        self._jobs, self._lock, self.keep, self.ttl = {}, threading.Lock(), keep, ttl

    def start(self, kind, work):
        """Run `work(stage)` on a thread; `stage(name)` moves the job along. Returns the job's first view."""
        jid = "apj_" + secrets.token_hex(12)
        job = {"id": jid, "kind": kind, "state": "queued", "result": None, "error": None, "code": None,
               "started": time.time(), "updated": time.time()}
        with self._lock:
            now = time.time()
            for k, v in list(self._jobs.items()):
                if now - v["updated"] > self.ttl:
                    del self._jobs[k]
            while len(self._jobs) >= self.keep:
                del self._jobs[min(self._jobs, key=lambda k: self._jobs[k]["updated"])]
            self._jobs[jid] = job

        def stage(name):
            with self._lock:
                job.update(state=name, updated=time.time())

        def run():
            try:
                result = work(stage)
                with self._lock:
                    job.update(state="done", result=result, updated=time.time())
            except AutoError as e:
                with self._lock:
                    job.update(state="failed", error=str(e), code=e.code, updated=time.time())
            except Exception as e:  # noqa: BLE001  (the type only: never a path or a transcript)
                with self._lock:
                    job.update(state="failed", error="Making the project failed (%s)." % type(e).__name__,
                               code="failed", updated=time.time())
        threading.Thread(target=run, name="autoproject-" + kind, daemon=True).start()
        return self.view(jid)

    def view(self, jid):
        with self._lock:
            job = self._jobs.get(jid)
            return dict(job) if job else None
