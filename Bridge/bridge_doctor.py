"""`hermes_mobile_bridge.py --doctor [--json]`: one pass over everything the phone needs, each problem with its fix.

Written for people and for agents setting this up on someone's behalf. It only reads: it never edits config,
starts services or prints secrets (keys are reported present or missing, never shown). Exit code is 0 when
nothing is broken (warnings allowed), 1 otherwise.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
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


def _tailscale():
    for cand in (shutil.which("tailscale"), "/usr/local/bin/tailscale",
                 "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                 r"C:\Program Files\Tailscale\tailscale.exe"):
        if cand and os.path.exists(cand):
            return cand
    return None


def run(hermes_home: Path, port: int, profiles, profile_home) -> list[dict]:
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
        import hermes_cli
        version = getattr(hermes_cli, "__version__", "unknown")
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
        _check(r, "gateway", OK if endpoint else FAIL,
               "The Hermes gateway is running." if endpoint else "No running Hermes gateway found.",
               "" if endpoint else "Start it: hermes gateway run   (or the Hermes desktop app)")
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
