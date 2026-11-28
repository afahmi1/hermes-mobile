"""`hermes_mobile_bridge.py --doctor [--json]`: one pass over everything the phone needs, each problem with its fix.

Written for people and for agents setting this up on someone's behalf. It only reads: it never edits config,
starts services or prints secrets (keys are reported present or missing, never shown). Exit code is 0 when
nothing is broken (warnings allowed), 1 otherwise.
"""
from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

OK, WARN, FAIL = "ok", "warn", "fail"


def _check(results, name, status, detail, fix=""):
    results.append({"check": name, "status": status, "detail": detail, "fix": fix})


def _env_has(path: Path, key: str) -> bool:
    try:
        return any(line.split("=", 1)[0].strip() == key and line.split("=", 1)[1].strip()
                   for line in path.read_text().splitlines() if "=" in line and not line.lstrip().startswith("#"))
    except OSError:
        return False


APNS_KEYS = ("HERMES_MOBILE_APNS_KEY_PATH", "HERMES_MOBILE_APNS_KEY_ID", "HERMES_MOBILE_APNS_TEAM_ID")
APNS_SETTINGS = APNS_KEYS + ("HERMES_MOBILE_APNS_TOPIC", "HERMES_MOBILE_APNS_HOST")
APPLE_ID_RE = re.compile(r"[A-Z0-9]{10}")  # Key IDs and Team IDs are 10 upper-case letters and digits
PUSH_FIX = ("Set HERMES_MOBILE_APNS_KEY_PATH, HERMES_MOBILE_APNS_KEY_ID and HERMES_MOBILE_APNS_TEAM_ID, then run "
            "Bridge/install.sh again (README, Push notifications).")
# What a failed APNs answer means and what fixes it. Keys are APNs reasons (or the status when there's no reason).
APNS_FIXES = {
    "InvalidProviderToken": (FAIL, "APNs refused the signing key: the Key ID, Team ID and .p8 don't belong together.",
                             "Check HERMES_MOBILE_APNS_KEY_ID (the key's ID) and HERMES_MOBILE_APNS_TEAM_ID (the team that "
                             "made the key), then run Bridge/install.sh again."),
    "ExpiredProviderToken": (FAIL, "APNs says the bridge's signed token is too old.",
                             "Check the Mac's clock (System Settings > General > Date & Time: set automatically)."),
    "DeviceTokenNotForTopic": (FAIL, "APNs refused the topic: the bundle ID the bridge used isn't the app on the phone.",
                               "Set HERMES_MOBILE_APNS_TOPIC to the bundle ID of the build on the phone (TestFlight: App "
                               "Store Connect > the app > App Information) and run Bridge/install.sh, or update the app: "
                               "newer builds report their own bundle ID."),
    "TopicDisallowed": (FAIL, "APNs won't let this key push to the app's bundle ID.",
                        "The key must come from the Apple Developer team that owns the app's bundle ID."),
    "BadTopic": (FAIL, "APNs refused the topic as malformed.", "Set HERMES_MOBILE_APNS_TOPIC to the app's bundle ID."),
    "BadDeviceToken": (WARN, "A phone's push token was invalid in both APNs environments and was removed.",
                       "Open the app on that phone so it registers again."),
    "Unregistered": (WARN, "A phone's push token is no longer valid (app deleted or notifications reset) and was removed.",
                     "Open the app on that phone so it registers again."),
    "TooManyProviderTokenUpdates": (WARN, "APNs saw the bridge's signed token change too often.",
                                    "Nothing to do: the bridge waits 20 minutes before minting another one."),
    "transport": (WARN, "The bridge couldn't reach APNs.", "Check the Mac's internet connection; the next reply tries again."),
}


def _clock(at):
    return time.strftime("%b %d %H:%M", time.localtime(at)) if isinstance(at, (int, float)) else "?"


def push_env(env=None, service=None) -> dict:
    """APNs settings as the bridge service sees them: the shell's when it sets any, else the installed service's."""
    env = os.environ if env is None else env
    if any((env.get(k) or "").strip() for k in APNS_KEYS):
        return {k: env[k] for k in APNS_SETTINGS if env.get(k)}
    service = _service_env() if service is None else service
    return {k: service[k] for k in APNS_SETTINGS if service.get(k)}


def push_check(env=None, service=None, sign=None) -> tuple[str, str, str]:
    """(status, detail, fix) for APNs push configuration. Reports what is wrong, never the values."""
    source = push_env(env, service)
    have = [k for k in APNS_KEYS if (source.get(k) or "").strip()]
    if not have:
        return WARN, "Push notifications are not configured (optional: replies still arrive while the app is open).", PUSH_FIX
    if len(have) < len(APNS_KEYS):
        missing = ", ".join(k for k in APNS_KEYS if k not in have)
        return FAIL, "Push is half configured: %s missing, so push stays off." % missing, PUSH_FIX
    key = Path(source["HERMES_MOBILE_APNS_KEY_PATH"].strip()).expanduser()
    if not key.is_file():
        return FAIL, "Push is configured but the APNs key file isn't there, so push stays off.", \
            "Put the .p8 back at the configured HERMES_MOBILE_APNS_KEY_PATH, or point the setting at it and reinstall."
    if not os.access(key, os.R_OK):
        return FAIL, "The APNs key file is there but this user can't read it, so push fails.", \
            "Make it yours and private: chown $USER <key> && chmod 600 <key> (the configured HERMES_MOBILE_APNS_KEY_PATH)."
    bad = [k for k in APNS_KEYS[1:] if not APPLE_ID_RE.fullmatch(source[k].strip())]
    if bad:
        return FAIL, "%s isn't a 10-character Apple ID (upper-case letters and digits)." % " and ".join(bad), \
            "Copy the Key ID from Apple Developer > Keys and the Team ID from Membership details, then reinstall."
    try:
        import bridge_push
        bridge_push.make_jwt(str(key), source["HERMES_MOBILE_APNS_KEY_ID"].strip(),
                             source["HERMES_MOBILE_APNS_TEAM_ID"].strip(), time.time(), sign or bridge_push.sign_es256)
    except Exception:
        return FAIL, "The APNs key file isn't a usable .p8 key (an EC P-256 private key), so push fails.", \
            "Download a new key from Apple Developer > Keys (APNs ticked) and point HERMES_MOBILE_APNS_KEY_PATH at it."
    host = (source.get("HERMES_MOBILE_APNS_HOST") or "").strip()
    if host:
        return WARN, "Push is configured but goes to a test server (HERMES_MOBILE_APNS_HOST is set), not Apple.", \
            "Remove it: HERMES_MOBILE_APNS_HOST= Bridge/install.sh"
    topic = "your setting" if (source.get("HERMES_MOBILE_APNS_TOPIC") or "").strip() else "the default"
    if os.name == "posix" and key.stat().st_mode & 0o077:
        return WARN, "Push is configured, but other users on this Mac can read the APNs key.", "chmod 600 <the .p8 file>"
    return OK, ("Push notifications are configured (key readable and valid; the app reports its own bundle ID, "
                "older builds use %s)." % topic), ""


def push_last_check(state_dir) -> tuple[str, str, str] | None:
    """(status, detail, fix) from the last APNs answers the bridge kept, or None before the first push."""
    if state_dir is None:
        return None
    try:
        import bridge_push
        state = bridge_push.last_result(Path(state_dir) / "push" / "status.json")
    except Exception:
        state = None
    last = (state or {}).get("last")
    if not isinstance(last, dict):
        return None
    if last.get("status") == 200:
        error = (state or {}).get("last_error")
        earlier = ""
        if isinstance(error, dict):
            earlier = " Earlier error: APNs %s %s at %s." % (error.get("status"), error.get("reason") or "", _clock(error.get("at")))
        return OK, "Last push delivered at %s (%s).%s" % (_clock(last.get("at")), last.get("env"), earlier), ""
    reason = last.get("reason") or ("transport" if not last.get("status") else str(last.get("status")))
    status, detail, fix = APNS_FIXES.get(reason, (WARN, "APNs answered %s %s." % (last.get("status"), reason),
                                                 "Run --push-test; if it repeats, check Apple's system status."))
    return status, "%s (APNs %s %s at %s)" % (detail, last.get("status"), reason, _clock(last.get("at"))), fix


def push_phones_check(state_dir, configured) -> tuple[str, str, str] | None:
    """(status, detail, fix) for the phones registered for push. Read-only."""
    if state_dir is None:
        return None
    try:
        import bridge_devices
        summary = bridge_devices.push_summary(Path(state_dir) / "devices")
    except Exception:
        summary = None
    if summary is None:
        return None
    if not summary["phones"]:
        return (WARN if configured else OK), "No phone has registered for push yet.", \
            "Open the app on the phone and allow notifications when it asks (Settings > Notifications > Prometheus)."
    envs = ", ".join("%s %d" % item for item in sorted(summary["envs"].items()))
    own = summary["own_topic"]
    note = "" if own == summary["phones"] else " %d of them use an older app build that doesn't report its bundle ID." % (
        summary["phones"] - own)
    return OK, "%d phone(s) registered for push (%s).%s" % (summary["phones"], envs, note), ""


def push_test(devices, status_path, log=lambda message: None, env=None, service=None, send=None) -> int:
    """`--push-test`: one test notification to every phone registered for push, with APNs's answer for each.
    Uses the installed service's APNs settings when the shell has none. Prints no tokens, IDs or key paths."""
    import bridge_push
    status, detail, fix = push_check(env, service)
    if status == FAIL or (status == WARN and "not configured" in detail):
        print("✗ %s" % detail)
        print("  → %s" % fix)
        return 1
    config = bridge_push.Config.from_env(push_env(env, service))
    if config is None:
        print("✗ Push isn't configured.\n  → %s" % PUSH_FIX)
        return 1
    pusher = bridge_push.Pusher(devices, config=lambda: config, log=log, inline=True, status=status_path,
                                **({"send": send} if send else {}))
    names = {d["id"]: d["name"] for d in devices.active()}
    results = pusher.test()
    if not results:
        print("✗ No phone has registered for push yet.")
        print("  → Open the app on the phone and allow notifications, then run --push-test again.")
        return 1
    failed = 0
    for row, code, reason, dropped in results:
        name = names.get(row["device_id"], "A phone")
        if code == 200:
            print("✓ %s (%s): delivered. Look for \"Push notifications from your Mac work.\"" % (name, row["env"]))
            continue
        failed += 1
        meaning = APNS_FIXES.get(reason or ("transport" if not code else ""))
        print("✗ %s (%s): APNs %s %s%s" % (name, row["env"], code, reason, " (token removed)" if dropped else ""))
        if meaning:
            print("  → %s %s" % (meaning[1], meaning[2]))
    return 1 if failed else 0


def _service_env(home: Path | None = None) -> dict:
    """The installed service's environment (launch agent plist or systemd unit), for settings the shell lacks."""
    home = home or Path.home()
    out: dict = {}
    try:
        import plistlib
        for plist in sorted((home / "Library" / "LaunchAgents").glob("*hermes-mobile*.plist")):
            with plist.open("rb") as f:
                out.update({k: str(v) for k, v in (plistlib.load(f).get("EnvironmentVariables") or {}).items()})
    except Exception:
        pass
    try:
        for unit in sorted((home / ".config" / "systemd" / "user").glob("hermes-mobile*.service")):
            for line in unit.read_text().splitlines():
                line = line.strip()
                if line.startswith("Environment="):
                    pair = line[len("Environment="):].strip("'\"")
                    if "=" in pair:
                        k, v = pair.split("=", 1)
                        out[k] = v
    except Exception:
        pass
    return out


def gateway_check(found: bool, port: int, probe=None) -> tuple[str, str, str]:
    """(status, detail, fix) for the gateway. A process is not a service: a gateway that was found but
    doesn't answer /health is still starting (Hermes connects every bot's MCP servers before it listens,
    which can take minutes) or is stuck, and either way the phone gets 502s. *probe* is injectable for tests."""
    start = "Start it: hermes gateway run   (or the Hermes desktop app)"
    if not found:
        return FAIL, "No running Hermes gateway found.", start
    if probe is None:
        def probe(p):
            with urllib.request.urlopen("http://127.0.0.1:%d/health" % p, timeout=4) as resp:
                return resp.status == 200
    try:
        answers = bool(probe(port))
    except Exception:
        answers = False
    if answers:
        return OK, "The Hermes gateway is running and answers on 127.0.0.1:%d." % port, ""
    return (FAIL, "The Hermes gateway process is there but doesn't answer on 127.0.0.1:%d." % port,
            "It may still be starting: wait a few minutes and run this again. If it stays down: hermes gateway restart")


def _tailscale():
    for cand in (shutil.which("tailscale"), "/usr/local/bin/tailscale",
                 "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                 r"C:\Program Files\Tailscale\tailscale.exe"):
        if cand and os.path.exists(cand):
            return cand
    return None


def hermes_version():
    """Hermes's own version. Newer Hermes serves ``hermes_cli.__version__`` only from an install stamp,
    so a git checkout reads "0.0.0" there; ``version_info.get_version_info()`` is the in-tree authority."""
    import hermes_cli
    try:
        from hermes_cli.version_info import get_version_info
        version = get_version_info().base_version
        if version and version != "0.0.0":
            return version
    except Exception:
        pass
    return getattr(hermes_cli, "__version__", "unknown")


def run(hermes_home: Path, port: int, profiles, profile_home, state_dir: Path | None = None) -> list[dict]:
    r: list[dict] = []
    system = platform.system()
    root = hermes_home / "hermes-agent"

    # 1. The interpreter. Hermes's package manager owns the real environment; the in-tree venv is legacy.
    try:
        sys.path.insert(0, str(root))
        from pm.environments import committed_venv
        env = committed_venv(root.resolve())
    except Exception:
        env = None
    # A venv's python is a symlink to its base interpreter, so compare prefixes, not resolved executables.
    exe = Path(sys.prefix).resolve()
    if env and Path(env).resolve() == exe:
        _check(r, "python", OK, "Running on Hermes's own environment (Python %d.%d)." % sys.version_info[:2])
    elif env:
        _check(r, "python", FAIL, "Running on %s, but Hermes now uses %s. Stale packages and mixed Python "
               "versions break attachments and imports." % (exe, env),
               "Reinstall the service so it resolves Hermes's Python at start: Bridge/install.sh "
               "(Windows: Windows\\Install-HermesMobile.ps1)")
    else:
        _check(r, "python", OK, "Python %d.%d at %s (this Hermes predates its package manager)." % (*sys.version_info[:2], exe))

    # 2. Hermes itself.
    try:
        version = hermes_version()
        status = OK if str(version).startswith("0.23.") else WARN
        _check(r, "hermes", status, "Hermes Agent %s." % version,
               "" if status == OK else "Tested with Hermes 0.23.x. Update Hermes or this bridge if anything misbehaves.")
    except Exception as exc:
        _check(r, "hermes", FAIL, "Can't import Hermes (%s)." % type(exc).__name__,
               "Install Hermes Agent first: https://hermes-agent.nousresearch.com/docs")
        return r

    # 3. Each bot: a gateway that answers, and an API key so the API server serves it.
    try:
        ids = list(profiles())
    except Exception:
        ids = ["default"]
    auto_keys = os.environ.get("HERMES_MOBILE_AUTO_KEYS", "1") != "0"
    for pid in ids:
        home = profile_home(pid)
        if not _env_has(home / ".env", "API_SERVER_KEY"):
            add = ('Add-Content "%s" "API_SERVER_KEY=$(-join ((1..32) | %%{ \'{0:x2}\' -f (Get-Random -Max 256) }))"' % (home / ".env")
                   if system == "Windows" else 'echo "API_SERVER_KEY=$(openssl rand -hex 32)" >> "%s"' % (home / ".env"))
            _check(r, "api-key:" + pid, WARN, "Bot '%s' has no API_SERVER_KEY, so the phone can't chat with it yet." % pid,
                   ("The running bridge adds one within a minute, or add it yourself: " if auto_keys else "Add one: ") + add)
    try:
        from hermes_cli.gateway_runtime import discover_gateway_endpoint
        endpoint = discover_gateway_endpoint(hermes_home)
        _check(r, "gateway", *gateway_check(bool(endpoint), int(os.environ.get("HERMES_API_PORT", "8642"))))
    except Exception as exc:
        _check(r, "gateway", FAIL, "No running Hermes gateway found (%s)." % type(exc).__name__,
               "Start it: hermes gateway run   (or the Hermes desktop app)")

    # 4. A way to sign in from the phone.
    try:
        import yaml  # Hermes ships PyYAML
        cfg = yaml.safe_load((hermes_home / "config.yaml").read_text()) or {}
    except Exception:
        cfg = {}
    auth = ((cfg.get("dashboard") or {}).get("basic_auth") or {})
    has_login = bool(auth.get("username") and auth.get("password"))
    _check(r, "sign-in", OK if has_login else WARN,
           "Password sign-in is set up." if has_login else "No dashboard password; the phone can still pair with a code.",
           "" if has_login else "Pair instead: python Bridge/hermes_mobile_bridge.py --pair-code   (single use, enter it in the app)")

    # 5. The bridge service and port.
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/m/ping" % port, timeout=3) as resp:
            alive = resp.status == 200
    except Exception:
        alive = False
    service_fix = {"Darwin": "Bridge/install.sh", "Linux": "Bridge/install.sh",
                   "Windows": r"powershell -ExecutionPolicy Bypass -File Windows\Install-HermesMobile.ps1"}.get(system, "Bridge/install.sh")
    _check(r, "bridge", OK if alive else FAIL,
           "The bridge answers on 127.0.0.1:%d." % port if alive else "Nothing answers on 127.0.0.1:%d." % port,
           "" if alive else "Install or restart the service: " + service_fix)

    # 6. Reachable from the phone: a Tailscale Serve route to that port.
    ts = _tailscale()
    if not ts:
        _check(r, "tailscale", FAIL, "Tailscale isn't installed.", "Install it from https://tailscale.com/download and sign in.")
    else:
        try:
            out = subprocess.run([ts, "serve", "status", "--json"], capture_output=True, text=True, timeout=10).stdout
            data = json.loads(out or "{}")
            routes = []
            for host, web in (data.get("Web") or {}).items():
                for path, handler in (web.get("Handlers") or {}).items():
                    if str(handler.get("Proxy", "")).rstrip("/").endswith(":%d" % port):
                        routes.append("https://" + host.replace(":443", ""))
            if routes:
                _check(r, "tailscale", OK, "Phone address: %s" % routes[0])
            else:
                _check(r, "tailscale", FAIL, "Tailscale is installed but doesn't serve the bridge.",
                       "%s serve --bg --https=10001 http://127.0.0.1:%d" % ("tailscale" if shutil.which("tailscale") else ts, port))
        except Exception as exc:
            _check(r, "tailscale", WARN, "Couldn't read Tailscale Serve (%s). Is Tailscale signed in?" % type(exc).__name__,
                   "tailscale up   then: tailscale serve --bg --https=10001 http://127.0.0.1:%d" % port)

    # 7. Room for receipts and attachments.
    free = shutil.disk_usage(hermes_home).free
    _check(r, "disk", OK if free > 2 * 1024 ** 3 else WARN, "%.1f GB free where Hermes keeps its data." % (free / 1024 ** 3),
           "" if free > 2 * 1024 ** 3 else "Free some space: attachments and receipts need room to stage.")

    # 8. Voice memos become text the way Telegram's do, if speech-to-text is configured.
    stt = cfg.get("stt") or {}
    enabled = bool(stt) and stt.get("enabled", True) is not False
    _check(r, "voice", OK if enabled else WARN,
           "Voice memos are transcribed (%s)." % (stt.get("provider") or "configured") if enabled
           else "Speech-to-text isn't configured; audio arrives as a file Hermes can't hear.",
           "" if enabled else "hermes config set stt.provider local   (or groq/openai with a key; see Hermes docs, Voice)")

    # 9. Push notifications (optional): the settings, the phones registered, and what APNs said last.
    push = push_check()
    _check(r, "push", *push)
    configured = push[0] == OK or "test server" in push[1]
    for name, extra in (("push-phones", push_phones_check(state_dir, configured)), ("push-last", push_last_check(state_dir))):
        if extra:
            _check(r, name, *extra)
    return r


def report(results, as_json=False) -> int:
    broken = any(x["status"] == FAIL for x in results)
    if as_json:
        print(json.dumps({"ok": not broken, "checks": results}, indent=2))
        return 1 if broken else 0
    mark = {OK: "✓", WARN: "!", FAIL: "✗"}
    for x in results:
        print("%s %-12s %s" % (mark[x["status"]], x["check"], x["detail"]))
        if x["fix"] and x["status"] != OK:
            print("  → %s" % x["fix"])
    print("\nAll good." if not broken else "\nFix the ✗ lines above, then run --doctor again.")
    return 1 if broken else 0
