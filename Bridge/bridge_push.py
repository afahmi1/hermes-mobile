"""APNs push for Hermes Mobile: tells the phone a reply landed after iOS has suspended the app.

The bridge keeps following every turn to the end whether or not a phone is attached, so it is the one
place that always knows when a run finishes, fails or waits on an approval or a question. This module decides
whether the phone still needs telling, builds the (privacy-safe) payload and sends it over APNs HTTP/2.

Configuration comes from the environment and is optional. Without a key, push is a silent no-op:

    HERMES_MOBILE_APNS_KEY_PATH  path to the AuthKey_XXXX.p8 from Apple Developer > Keys
    HERMES_MOBILE_APNS_KEY_ID    the key's 10-character ID
    HERMES_MOBILE_APNS_TEAM_ID   the Apple team's 10-character ID
    HERMES_MOBILE_APNS_TOPIC     the app's bundle ID, for app builds that don't report their own
                                 (default com.example.hermesmobile)
    HERMES_MOBILE_APNS_HOST      testing only: send to this https origin (a local mock APNs) instead of Apple

Standard library only. ES256 signing uses `cryptography` when the bridge's Python has it and otherwise
the system `openssl`; delivery uses the system `curl --http2`. Tokens, the JWT and key contents are never
logged, and the JWT never appears on a command line.
"""
from concurrent.futures import ThreadPoolExecutor
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

DEFAULT_TOPIC = "com.example.hermesmobile"  # HERMES_BUNDLE_ID's default in App/Config/Base.xcconfig
HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
JWT_LIFETIME = 50 * 60  # Apple rejects tokens older than an hour...
JWT_MIN_INTERVAL = 20 * 60  # ...and answers TooManyProviderTokenUpdates to a new one sooner than this
AWAY_GRACE = 35  # the app holds a ~30 s background task and posts its own notification inside it
TOKEN_RE = re.compile(r"[0-9a-f]{32,400}")
ACCOUNT_RE = re.compile(r"[A-Za-z0-9._:-]{1,128}")
TOPIC_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,154}")  # a bundle ID
HOST_RE = re.compile(r"https://[A-Za-z0-9.-]+(:[0-9]{1,5})?")
# The token itself is dead. DeviceTokenNotForTopic is not here: it means the topic (configuration) is wrong,
# and dropping on it would erase every phone's token over a typo in HERMES_MOBILE_APNS_TOPIC.
DEAD_REASONS = {"BadDeviceToken", "Unregistered"}
TOPIC_REASONS = {"DeviceTokenNotForTopic", "TopicDisallowed", "BadTopic", "MissingTopic"}
PROVIDER_REASONS = {"InvalidProviderToken", "ExpiredProviderToken", "MissingProviderToken"}

COPY = {  # Generic on purpose: commands, errors and reply excerpts can be private on a locked phone.
    "run.completed": ("{bot}", "Your reply is ready."),
    "approval.request": ("{bot} needs your approval", "Open the chat to review the request."),
    "clarify.request": ("{bot} has a question", "Open the chat to answer."),
    "run.failed": ("{bot} could not finish", "Open the chat for details."),
    "push.test": ("{bot}", "Push notifications from your Mac work."),
}
# Turn events that push. A prompt (approval or question) pushes once per prompt id, an outcome once per turn.
PROMPT_EVENTS = ("approval.request", "clarify.request")
TURN_EVENTS = ("run.completed", "run.failed") + PROMPT_EVENTS
TEST_COLLAPSE_ID = "hermes-push-test"


def destination_identifier(account, profile, session):
    """Mirror of ReplyDestination.identifier in App/Sources/ReplyNotifier.swift."""
    return "".join("%d:%s" % (len(part.encode()), part) for part in (account, profile, session))


def collapse_id(account, profile, session):
    """apns-collapse-id allows 64 bytes, so the phone and the bridge both use a SHA-256 prefix of the identifier.
    The phone uses the same value as its local notification's request identifier."""
    return hashlib.sha256(destination_identifier(account, profile, session).encode()).hexdigest()[:32]


def payload(event, bot, account, profile, session):
    title, body = COPY[event]
    if event == "push.test":  # no chat to open: a tap just brings the app forward
        return {"aps": {"alert": {"title": title.format(bot=bot), "body": body}, "sound": "default",
                        "thread-id": TEST_COLLAPSE_ID}}
    return {"aps": {"alert": {"title": title.format(bot=bot), "body": body}, "sound": "default",
                    "thread-id": destination_identifier(account, profile, session)},
            "account": account, "profile": profile, "session": session}


def should_push(attached, away_since, now, grace=AWAY_GRACE):
    """Whether the phone has to be told about an event.

    Not attached: nobody is reading the stream, so push. Attached and in the foreground: the chat on screen
    shows it. Attached but reported away for longer than its grace window: iOS has suspended the app, and the
    socket can stay open on the bridge for minutes, so treat it as gone. Inside the grace window the app posts
    its own local notification, which shares the collapse id, so pushing too would double up. A phone that says
    it stopped following (its background time ran out or ended) has a grace of zero."""
    if not attached:
        return True
    return away_since is not None and now - away_since >= grace


def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _der_to_raw(der):
    """ECDSA DER signature to the fixed 64-byte r||s that JWS ES256 wants."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("bad signature")
    pos = 2 + (der[1] & 0x7F if der[1] & 0x80 else 0)
    parts = []
    for _ in range(2):
        if der[pos] != 0x02:
            raise ValueError("bad signature")
        size = der[pos + 1]
        parts.append(int.from_bytes(der[pos + 2:pos + 2 + size], "big"))
        pos += 2 + size
    return b"".join(value.to_bytes(32, "big") for value in parts)


def _sign_cryptography(key_path, message):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    key = serialization.load_pem_private_key(Path(key_path).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise ValueError("APNs keys are P-256")
    r, s = decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _sign_openssl(key_path, message):
    openssl = shutil.which("openssl") or "/usr/bin/openssl"
    done = subprocess.run([openssl, "dgst", "-sha256", "-sign", str(key_path)], input=message,
                          capture_output=True, timeout=10, check=True)
    return _der_to_raw(done.stdout)


def sign_es256(key_path, message):
    try:
        return _sign_cryptography(key_path, message)
    except ImportError:
        return _sign_openssl(key_path, message)


def make_jwt(key_path, key_id, team_id, now, sign=sign_es256):
    head = _b64(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64(json.dumps({"iss": team_id, "iat": int(now)}, separators=(",", ":")).encode())
    signing_input = ("%s.%s" % (head, claims)).encode()
    return "%s.%s" % (signing_input.decode(), _b64(sign(key_path, signing_input)))


def _curl_quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def curl_send(url, headers, body, timeout=20):
    """POST over HTTP/2 with the system curl. Returns (status, reason). The request, including the
    authorization header, goes to curl on stdin as a config file so it never shows in `ps`."""
    lines = ["url = " + _curl_quote(url), "request = POST", "http2", "silent", "show-error",
             "max-time = %d" % timeout, 'write-out = "\\n%{http_code}"']
    lines += ["header = " + _curl_quote("%s: %s" % item) for item in headers.items()]
    lines.append("data-raw = " + _curl_quote(body))
    try:
        done = subprocess.run(["/usr/bin/curl", "--config", "-"], input="\n".join(lines).encode(),
                              capture_output=True, timeout=timeout + 5)
    except (OSError, subprocess.SubprocessError):
        return 0, "transport"
    out = done.stdout.decode("utf-8", "replace")
    text, _, code = out.rpartition("\n")
    if not code.isdigit() or int(code) == 0:
        return 0, "transport"
    reason = ""
    if int(code) != 200:
        try:
            reason = str(json.loads(text).get("reason") or "")
        except (ValueError, AttributeError):
            pass
    return int(code), reason


class Config:
    def __init__(self, key_path, key_id, team_id, topic, host=None):
        self.key_path, self.key_id, self.team_id, self.topic = key_path, key_id, team_id, topic
        self.host = host  # None: Apple's hosts. Set only to test against a local mock APNs.

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        key = (env.get("HERMES_MOBILE_APNS_KEY_PATH") or "").strip()
        key_id = (env.get("HERMES_MOBILE_APNS_KEY_ID") or "").strip()
        team = (env.get("HERMES_MOBILE_APNS_TEAM_ID") or "").strip()
        if not (key and key_id and team and Path(key).expanduser().is_file()):
            return None
        topic = (env.get("HERMES_MOBILE_APNS_TOPIC") or "").strip() or DEFAULT_TOPIC
        host = (env.get("HERMES_MOBILE_APNS_HOST") or "").strip().rstrip("/")
        return cls(str(Path(key).expanduser()), key_id, team, topic, host if HOST_RE.fullmatch(host) else None)

    def url(self, env, token):
        return "%s/3/device/%s" % (self.host or HOSTS.get(env, HOSTS["production"]), token)


class Pusher:
    """`devices` is a bridge_devices.Devices; `config` a callable returning Config or None (read per use so
    a key added later works after a restart without code changes); `title` maps a profile id to a bot name;
    `status` is a JSON file that keeps the last APNs answers for `--doctor` (no tokens, no secrets)."""

    def __init__(self, devices, config=lambda: Config.from_env(), title=lambda profile: profile,
                 send=curl_send, sign=sign_es256, clock=time.time, log=lambda message: None, inline=False,
                 status=None):
        self.devices, self.config, self.title = devices, config, title
        self.send, self.sign, self.clock, self.log = send, sign, clock, log
        self.inline = inline  # tests run the send on the calling thread
        self.status = Path(status) if status else None
        self.away = {}  # device id -> (when the app reported it left the foreground, its grace in seconds)
        self.lock = threading.Lock()
        self.jwt = None  # (key identity, minted at, token, rejected by APNs)
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="apns")

    def presence(self, device, away, following=True):
        """`following` False: the app is away and no longer following its runs (its background time ended),
        so an attached stream is a suspended socket and an event pushes at once."""
        with self.lock:
            if away:
                # Always the newest report: a stale timestamp would skip the next grace window and double up
                # the app's own notification with a push.
                self.away[device] = (self.clock(), AWAY_GRACE if following else 0)
            else:
                self.away.pop(device, None)

    def _bearer(self, config):
        now = self.clock()
        ident = (config.key_path, config.key_id, config.team_id)
        with self.lock:
            cached = self.jwt
            if cached and cached[0] == ident:
                age = now - cached[1]
                # A token APNs rejected is replaced, but never sooner than JWT_MIN_INTERVAL after the last one.
                if 0 <= age < JWT_LIFETIME and (not cached[3] or age < JWT_MIN_INTERVAL):
                    return cached[2]
            token = make_jwt(config.key_path, config.key_id, config.team_id, now, self.sign)
            self.jwt = (ident, now, token, False)
            return token

    def _rejected(self, token):
        with self.lock:
            if self.jwt and self.jwt[2] == token:
                self.jwt = self.jwt[:3] + (True,)

    def targets(self, turn):
        rows = self.devices.push_targets(turn.device_id)
        now = self.clock()
        out = []
        for row in rows:
            with turn.cond:
                attached = turn.watchers.get(row["device_id"], 0) > 0
            with self.lock:
                since, grace = self.away.get(row["device_id"], (None, AWAY_GRACE))
            if should_push(attached, since, now, grace):
                out.append(row)
        return out

    def notify(self, turn, event, fields):
        """Called from Turn.push for terminal, approval and question events. Never raises, never blocks the turn."""
        try:
            if event not in TURN_EVENTS or self.config() is None:
                return
            prompt = event in PROMPT_EVENTS
            key = "%s:%s" % (event, fields.get("request_id")) if prompt else event
            with turn.cond:
                if key in turn.alerted or (not prompt and turn.notified):
                    return
                turn.alerted.add(key)
                if not prompt:
                    turn.notified = True
            if self.inline:
                self._deliver(turn.profile, turn.sid, event, self.targets(turn))
            else:
                rows = self.targets(turn)
                if rows:
                    self.pool.submit(self._deliver, turn.profile, turn.sid, event, rows)
        except Exception as exc:
            self.log("push skipped: %s" % type(exc).__name__)

    def _bot(self, profile):
        try:
            return self.title(profile) or profile
        except Exception:  # a bot list that can't be read must not cost the notification
            return profile

    def _deliver(self, profile, session, event, rows):
        try:
            config = self.config()
            if config is None:
                return
            bot = self._bot(profile)
            for row in rows:
                self._one(config, row, event, bot, profile, session)
        except Exception as exc:
            self.log("push failed: %s" % type(exc).__name__)

    def test(self, bot="Prometheus"):
        """One test notification to every phone registered for push. [(row, status, reason, dropped)]."""
        config = self.config()
        if config is None:
            return []
        return [(row,) + self._one(config, row, "push.test", bot, "", "") for row in self.devices.push_targets()]

    def _post(self, config, env, row, collapse, bearer, body, topic):
        headers = {"authorization": "bearer " + bearer, "apns-topic": topic,
                   "apns-push-type": "alert", "apns-priority": "10", "apns-collapse-id": collapse,
                   "content-type": "application/json"}
        return self.send(config.url(env, row["token"]), headers, body)

    def _one(self, config, row, event, bot, profile, session):
        """Send to one phone. Returns (status, reason, dropped)."""
        account = row["account"]
        if not account:
            return 0, "no account", False
        topic = row.get("topic") or config.topic
        collapse = TEST_COLLAPSE_ID if event == "push.test" else collapse_id(account, profile, session)
        body = json.dumps(payload(event, bot, account, profile, session), separators=(",", ":"), ensure_ascii=True)
        bearer = self._bearer(config)
        env = row["env"] if row["env"] in HOSTS else "production"
        status, reason = self._post(config, env, row, collapse, bearer, body, topic)
        if status == 400 and reason == "BadDeviceToken" and config.host is None:
            # A token is only valid in the APNs environment its build was signed for. The phone reports one from
            # its build configuration; a Release build signed for development (or the reverse) gets it wrong.
            other = "sandbox" if env == "production" else "production"
            retry = self._post(config, other, row, collapse, bearer, body, topic)
            if retry[0] == 200:
                self.devices.set_push_env(row["token"], other)
                self.log("push token moved to the APNs %s environment" % other)
                env, (status, reason) = other, retry
            elif retry[0] not in (400, 410):
                status, reason = retry  # couldn't tell: keep the token, report what happened
        self._record(event, env, status, reason)
        if status == 200:
            self.log("push delivered: %s (%s)" % (event, env))
            return status, reason, False
        if status == 410 or (status == 400 and reason in DEAD_REASONS):
            self.devices.drop_push_token(row["token"])
            self.log("push token dropped (APNs %s %s)" % (status, reason))
            return status, reason, True
        if status == 403 and reason in PROVIDER_REASONS:
            self._rejected(bearer)
            self.log("APNs rejected the provider token: %s (check the key ID, team ID and .p8)" % reason)
        elif reason in TOPIC_REASONS:
            self.log("APNs refused the topic: %s (the app's bundle ID and the key's team must match)" % reason)
        else:
            self.log("APNs answered %s %s" % (status, reason))
        return status, reason, False

    def _record(self, event, env, status, reason):
        """Keep the last answer (and the last error) for `--doctor`. Best effort; never raises."""
        if not self.status:
            return
        entry = {"at": int(self.clock()), "event": event, "env": env, "status": status, "reason": reason}
        try:
            with self.lock:
                try:
                    state = json.loads(self.status.read_text())
                    if not isinstance(state, dict):
                        state = {}
                except (OSError, ValueError):
                    state = {}
                state["last"] = entry
                if status != 200:
                    state["last_error"] = entry
                self.status.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                tmp = self.status.with_name(self.status.name + ".tmp")
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as f:
                    json.dump(state, f)
                os.replace(tmp, self.status)
        except OSError:
            pass


def last_result(path):
    """The status file `Pusher` keeps, or None. Read-only; for `--doctor`."""
    try:
        state = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    return state if isinstance(state, dict) else None
