"""Owner deletion-PIN verifier, shared persisted attempt limiter and owner-session epoch.

Stdlib only. Nothing here ever logs, returns or stores the PIN itself: the verifier file holds only a
salted scrypt hash, errors carry fixed text, and no exception or repr includes the candidate.
Every unreadable / loose / symlinked / malformed state fails closed.
"""
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import stat
import threading
import time

PIN_FILE = "owner_pin.json"
ATTEMPTS_FILE = "owner_pin_attempts.json"
EPOCH_FILE = "owner_epoch"
KDF = {"n": 32768, "r": 8, "p": 1}
MAXMEM = 128 * 1024 * 1024
MAX_FAILS = 5
BASE_LOCK = 300
MAX_LOCK = 3600
_LOCK = threading.Lock()  # one PIN check at a time: parallel guesses cannot beat the counter


class OwnerError(Exception):
    """Fixed-text failure. `code` is the machine code, `status` the HTTP status."""
    def __init__(self, code, status, retry_after=None):
        super().__init__(code)
        self.code, self.status, self.retry_after = code, status, retry_after


def valid_pin(pin):
    return isinstance(pin, str) and len(pin) == 4 and pin.isascii() and pin.isdigit()


# ---------- safe file plumbing ----------
def _flags():
    return os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


def _check_dir(d, create=False):
    """The state directory must be a real directory owned by us with no group/other access."""
    d = str(d)
    if create:
        os.makedirs(d, 0o700, exist_ok=True)
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
        raise OwnerError("pin_unset", 503)
    if st.st_mode & 0o077:
        if create:
            os.chmod(d, 0o700)
        else:
            raise OwnerError("pin_unset", 503)


def _read_private(d, name):
    """Bytes of a 0600 regular single-link file we own, opened without following links; else raises."""
    _check_dir(d)
    path = os.path.join(str(d), name)
    fd = os.open(path, os.O_RDONLY | _flags())
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.geteuid()
                or st.st_mode & 0o077 or st.st_size > 4096):
            raise OwnerError("pin_unset", 503)
        return os.read(fd, 4097)
    finally:
        os.close(fd)


def _write_private(d, name, data):
    """Atomic 0600 write: exclusive no-follow temp file, fsync, then os.replace."""
    _check_dir(d, create=True)
    final = os.path.join(str(d), name)
    try:  # refuse to replace something that is not a plain file of ours
        st = os.lstat(final)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.geteuid():
            raise OwnerError("pin_unset", 503)
    except FileNotFoundError:
        pass
    tmp = os.path.join(str(d), ".%s.%s.tmp" % (name, os.urandom(6).hex()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | _flags(), 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, final)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------- PIN verifier ----------
def _hash(pin, salt, n=KDF["n"], r=KDF["r"], p=KDF["p"]):
    return hashlib.scrypt(pin.encode("ascii"), salt=salt, n=n, r=r, p=p, maxmem=MAXMEM, dklen=32)


def set_pin(state_dir, pin):
    if not valid_pin(pin):
        raise ValueError("The PIN must be exactly 4 digits.")
    salt = os.urandom(16)
    doc = {"v": 1, "kdf": "scrypt", "n": KDF["n"], "r": KDF["r"], "p": KDF["p"],
           "salt": base64.b64encode(salt).decode(), "hash": base64.b64encode(_hash(pin, salt)).decode()}
    with _LOCK:
        _write_private(state_dir, PIN_FILE, json.dumps(doc).encode())
        _write_attempts(state_dir, {"fails": 0, "level": 0, "until": 0})


def clear_pin(state_dir):
    with _LOCK:
        for name in (PIN_FILE, ATTEMPTS_FILE):
            try:
                os.unlink(os.path.join(str(state_dir), name))
            except FileNotFoundError:
                pass


def _load_verifier(state_dir):
    try:
        doc = json.loads(_read_private(state_dir, PIN_FILE))
        if (doc["v"], doc["kdf"], doc["n"], doc["r"], doc["p"]) != (1, "scrypt", KDF["n"], KDF["r"], KDF["p"]):
            raise ValueError
        salt, want = base64.b64decode(doc["salt"], validate=True), base64.b64decode(doc["hash"], validate=True)
        if len(salt) != 16 or len(want) != 32:
            raise ValueError
        return salt, want
    except OwnerError:
        raise
    except (OSError, ValueError, KeyError, TypeError, binascii.Error):
        raise OwnerError("pin_unset", 503) from None


def verifier_state(state_dir):
    """'absent' (no file at all), 'ok' (a well-formed private verifier) or 'invalid' (present but tampered,
    loose, linked or malformed). Never reveals anything about the PIN."""
    try:
        os.lstat(os.path.join(str(state_dir), PIN_FILE))
    except FileNotFoundError:
        return "absent"
    except OSError:
        return "invalid"
    return "ok" if pin_configured(state_dir) else "invalid"


def change_pin(state_dir, new_pin, current=None):
    """Owner PIN set/change for the app route. First set only when no verifier file exists at all; a change
    needs the current PIN through the shared limiter (check_pin). An invalid/tampered verifier is never
    overwritten from the network: the operator clears it locally (--clear-owner-pin)."""
    if not valid_pin(new_pin):
        raise OwnerError("pin_invalid", 400)
    st = verifier_state(state_dir)
    if st == "invalid":
        raise OwnerError("pin_unset", 503)
    if st == "ok":
        check_pin(state_dir, current)  # raises pin_required / pin_wrong / pin_locked
    set_pin(state_dir, new_pin)


def pin_configured(state_dir):
    try:
        _load_verifier(state_dir)
        return True
    except OwnerError:
        return False


# ---------- shared persisted limiter ----------
def _read_attempts(state_dir):
    try:
        doc = json.loads(_read_private(state_dir, ATTEMPTS_FILE))
        return {"fails": int(doc["fails"]), "level": int(doc["level"]), "until": float(doc["until"])}
    except FileNotFoundError:
        return {"fails": 0, "level": 0, "until": 0.0}
    except (OwnerError, OSError, ValueError, KeyError, TypeError):
        # Unreadable or tampered counters must not become a free reset: lock for the maximum time.
        return {"fails": 0, "level": 99, "until": time.time() + MAX_LOCK}


def _write_attempts(state_dir, doc):
    try:
        _write_private(state_dir, ATTEMPTS_FILE, json.dumps(doc).encode())
    except OwnerError:
        raise
    except OSError:
        raise OwnerError("pin_unset", 503) from None


def check_pin(state_dir, pin):
    """Run the gate in the contract's order (after bearer + owner_ok): lockout -> verifier -> PIN.
    Returns None when the PIN is right; raises OwnerError(pin_locked 429 | pin_unset 503 |
    pin_required 400 | pin_wrong 403). Only the attempt counter ever changes on failure."""
    with _LOCK:
        try:
            _check_dir(state_dir)
        except OSError:
            raise OwnerError("pin_unset", 503) from None
        now = time.time()
        a = _read_attempts(state_dir)
        if now < a["until"]:
            raise OwnerError("pin_locked", 429, int(a["until"] - now) + 1)
        salt, want = _load_verifier(state_dir)
        if pin is None:
            raise OwnerError("pin_required", 400)
        ok = valid_pin(pin) and hmac.compare_digest(_hash(pin, salt), want)
        if ok:
            if a["fails"] or a["level"] or a["until"]:
                _write_attempts(state_dir, {"fails": 0, "level": 0, "until": 0})
            return None
        a["fails"] += 1
        if a["fails"] >= MAX_FAILS:
            span = min(BASE_LOCK * (2 ** min(a["level"], 10)), MAX_LOCK)
            a = {"fails": 0, "level": a["level"] + 1, "until": now + span}
        _write_attempts(state_dir, a)
        if a["until"] > now:
            raise OwnerError("pin_locked", 429, int(a["until"] - now) + 1)
        raise OwnerError("pin_wrong", 403)


# ---------- owner session epoch ----------
def epoch(state_dir, create=True):
    """Tokens minted before this unix second lose owner rights. Created on first owner-mode use."""
    try:
        return int(_read_private(state_dir, EPOCH_FILE).decode().strip())
    except (OwnerError, OSError, ValueError):
        if not create:
            raise OwnerError("owner_required", 403) from None
    with _LOCK:
        _check_dir(state_dir, create=True)
        try:
            return int(_read_private(state_dir, EPOCH_FILE).decode().strip())
        except FileNotFoundError:
            pass
        except (OwnerError, OSError, ValueError):
            raise OwnerError("owner_required", 403) from None
        now = int(time.time())
        _write_private(state_dir, EPOCH_FILE, str(now).encode())
        return now


def rotate_epoch(state_dir):
    with _LOCK:
        new = max(int(time.time()), _safe_epoch(state_dir)) + 1
        _write_private(state_dir, EPOCH_FILE, str(new).encode())
        return new


def _safe_epoch(state_dir):
    try:
        return int(_read_private(state_dir, EPOCH_FILE).decode().strip())
    except (OwnerError, OSError, ValueError):
        return 0


def claims_are_owner(claims, state_dir):
    """True for a verified token payload with own == 1 and iat >= the owner epoch. Fails closed."""
    try:
        if not isinstance(claims, dict) or claims.get("own") != 1 or isinstance(claims.get("own"), bool):
            return False
        iat = claims.get("iat")
        if isinstance(iat, bool) or not isinstance(iat, int):
            return False
        return iat >= epoch(state_dir)
    except Exception:
        return False
