"""APNs push for Hermes Mobile: tells the phone a reply landed after iOS has suspended the app.

The bridge keeps following every turn to the end whether or not a phone is attached, so it is the one
place that always knows when a run finishes, fails or waits on an approval. This module decides whether
the phone still needs telling, builds the (privacy-safe) payload and sends it over APNs HTTP/2.

Configuration comes from the environment and is optional. Without a key, push is a silent no-op:

    HERMES_MOBILE_APNS_KEY_PATH  path to the AuthKey_XXXX.p8 from Apple Developer > Keys
    HERMES_MOBILE_APNS_KEY_ID    the key's 10-character ID
    HERMES_MOBILE_APNS_TEAM_ID   the Apple team's 10-character ID
    HERMES_MOBILE_APNS_TOPIC     the app's bundle ID (default com.example.hermesmobile)

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
import tempfile
import threading
import time

DEFAULT_TOPIC = "com.example.hermesmobile"  # HERMES_BUNDLE_ID's default in App/Config/Base.xcconfig
HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
JWT_LIFETIME = 50 * 60  # Apple rejects tokens older than an hour and throttles tokens refreshed too often
AWAY_GRACE = 35  # the app holds a ~30 s background task and posts its own notification inside it
TOKEN_RE = re.compile(r"[0-9a-f]{32,400}")
ACCOUNT_RE = re.compile(r"[A-Za-z0-9._:-]{1,128}")
DEAD_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}

COPY = {  # Generic on purpose: commands, errors and reply excerpts can be private on a locked phone.
    "run.completed": ("{bot}", "Your reply is ready."),
    "approval.request": ("{bot} needs your approval", "Open the chat to review the request."),
    "run.failed": ("{bot} could not finish", "Open the chat for details."),
}


def destination_identifier(account, profile, session):
    """Mirror of ReplyDestination.identifier in App/Sources/ReplyNotifier.swift."""
    return "".join("%d:%s" % (len(part.encode()), part) for part in (account, profile, session))


def collapse_id(account, profile, session):
    """apns-collapse-id allows 64 bytes, so the phone and the bridge both use a SHA-256 prefix of the identifier.
    The phone uses the same value as its local notification's request identifier."""
    return hashlib.sha256(destination_identifier(account, profile, session).encode()).hexdigest()[:32]


def payload(event, bot, account, profile, session):
    title, body = COPY[event]
    return {"aps": {"alert": {"title": title.format(bot=bot), "body": body}, "sound": "default",
                    "thread-id": destination_identifier(account, profile, session)},
            "account": account, "profile": profile, "session": session}


def should_push(attached, away_since, now):
    """Whether the phone has to be told about an event.

    Not attached: nobody is reading the stream, so push. Attached and in the foreground: the chat on screen
    shows it. Attached but reported away for longer than the background grace window: iOS has suspended the
    app, and the socket can stay open on the bridge for minutes, so treat it as gone. Inside the grace window
    the app posts its own local notification, which shares the collapse id, so pushing too would double up."""
    if not attached:
        return True
    return away_since is not None and now - away_since > AWAY_GRACE


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
    if not isinstance(key, ec.EllipticCurvePrivateKey):
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
    def __init__(self, key_path, key_id, team_id, topic):
        self.key_path, self.key_id, self.team_id, self.topic = key_path, key_id, team_id, topic

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        key = (env.get("HERMES_MOBILE_APNS_KEY_PATH") or "").strip()
        key_id = (env.get("HERMES_MOBILE_APNS_KEY_ID") or "").strip()
        team = (env.get("HERMES_MOBILE_APNS_TEAM_ID") or "").strip()
        if not (key and key_id and team and Path(key).expanduser().is_file()):
            return None
        topic = (env.get("HERMES_MOBILE_APNS_TOPIC") or "").strip() or DEFAULT_TOPIC
        return cls(str(Path(key).expanduser()), key_id, team, topic)


class Pusher:
    """`devices` is a bridge_devices.Devices; `config` a callable returning Config or None (read per use so
    a key added later works after a restart without code changes); `title` maps a profile id to a bot name."""

    def __init__(self, devices, config=lambda: Config.from_env(), title=lambda profile: profile,
                 send=curl_send, sign=sign_es256, clock=time.time, log=lambda message: None, inline=False):
        self.devices, self.config, self.title = devices, config, title
        self.send, self.sign, self.clock, self.log = send, sign, clock, log
        self.inline = inline  # tests run the send on the calling thread
        self.away = {}  # device id -> when the app reported it left the foreground
        self.lock = threading.Lock()
        self.jwt = None
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="apns")

    def presence(self, device, away):
        with self.lock:
            if away:
                # Overwrite, never keep an old timestamp: the phone says "away now" and means now.
                self.away[device] = self.clock()
            else:
                self.away.pop(device, None)

    def _bearer(self, config):
        now = self.clock()
        with self.lock:
            cached = self.jwt
            if cached and cached[0] == (config.key_path, config.key_id, config.team_id) and now - cached[1] < JWT_LIFETIME:
                return cached[2]
            token = make_jwt(config.key_path, config.key_id, config.team_id, now, self.sign)
            self.jwt = ((config.key_path, config.key_id, config.team_id), now, token)
            return token

    def targets(self, turn):
        rows = self.devices.push_targets(turn.device_id)
        now = self.clock()
        out = []
        for row in rows:
            with turn.cond:
                attached = turn.watchers.get(row["device_id"], 0) > 0
            with self.lock:
                since = self.away.get(row["device_id"])
            if should_push(attached, since, now):
                out.append(row)
        return out

    def notify(self, turn, event, fields):
        """Called from Turn.push for terminal and approval events. Never raises, never blocks the turn."""
        try:
            if event not in COPY or self.config() is None:
                return
            key = event if event != "approval.request" else "approval:%s" % fields.get("request_id")
            with turn.cond:
                if key in turn.alerted or (event != "approval.request" and turn.notified):
                    return
                turn.alerted.add(key)
                if event != "approval.request":
                    turn.notified = True
            if self.inline:
                self._deliver(turn.profile, turn.sid, event, self.targets(turn))
            else:
                rows = self.targets(turn)
                if rows:
                    self.pool.submit(self._deliver, turn.profile, turn.sid, event, rows)
        except Exception as exc:
            self.log("push skipped: %s" % type(exc).__name__)

    def _deliver(self, profile, session, event, rows):
        try:
            config = self.config()
            if config is None:
                return
            bot = self.title(profile)
            for row in rows:
                self._one(config, row, event, bot, profile, session)
        except Exception as exc:
            self.log("push failed: %s" % type(exc).__name__)

    def _one(self, config, row, event, bot, profile, session):
        account = row["account"]
        if not account:
            return
        body = json.dumps(payload(event, bot, account, profile, session), separators=(",", ":"), ensure_ascii=True)
        headers = {"authorization": "bearer " + self._bearer(config), "apns-topic": config.topic,
                   "apns-push-type": "alert", "apns-priority": "10",
                   "apns-collapse-id": collapse_id(account, profile, session),
                   "content-type": "application/json"}
        url = "%s/3/device/%s" % (HOSTS.get(row["env"], HOSTS["production"]), row["token"])
        status, reason = self.send(url, headers, body)
        if status == 200:
            return
        if status == 410 or (status == 400 and reason in DEAD_REASONS):
            self.devices.drop_push_token(row["token"])
            self.log("push token dropped (APNs %s %s)" % (status, reason))
        elif status == 403 and reason in ("InvalidProviderToken", "ExpiredProviderToken"):
            with self.lock:
                self.jwt = None
            self.log("APNs rejected the provider token: %s" % reason)
        else:
            self.log("APNs answered %s %s" % (status, reason))
