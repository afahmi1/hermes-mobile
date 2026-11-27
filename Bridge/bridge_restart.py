"""Restart Hermes (the gateway) or this bridge from the phone.

Hermes, gently: SIGUSR1 to the running gateway, the same signal `hermes gateway restart` and `/restart`
send. The gateway keeps serving, restarts at the first moment nothing is running (replies, background
sub-agents, watched processes), and its service manager starts the new one.

Hermes, now: `hermes gateway restart --yes`, which interrupts whatever is running. Also the way back when
no gateway is running at all (`hermes gateway start`).

The bridge: answer first, then exit non-zero so launchd (KeepAlive) or systemd (Restart=always) starts it
again with whatever release `current` points at.
"""
import json
import os
import shutil
import signal
import subprocess
import threading
import time

BRIDGE_EXIT_CODE = 75  # EX_TEMPFAIL: a restart, never a clean stop a service manager would leave down


def gateway_pid(home):
    """The live gateway's pid from `$HERMES_HOME/gateway.pid`, or None. Only a record that names itself a
    Hermes gateway and points at a running process counts, so a stale or foreign pid is never signalled."""
    try:
        with open(os.path.join(str(home), "gateway.pid"), encoding="utf-8") as f:
            text = f.read().strip()
    except OSError:
        return None
    if text.isdigit():  # older Hermes wrote the bare number
        rec = {"pid": int(text), "kind": "hermes-gateway"}
    else:
        try:
            rec = json.loads(text)
        except ValueError:
            return None
    if not isinstance(rec, dict) or rec.get("kind", "hermes-gateway") != "hermes-gateway":
        return None
    pid = rec.get("pid")
    if isinstance(pid, str) and pid.isdigit():
        pid = int(pid)
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1 or pid == os.getpid():
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        return None  # someone else's process: not ours to signal
    return pid


def hermes_command(home):
    """The `hermes` launcher. launchd and systemd give the bridge a short PATH, so the usual install places
    are tried after it."""
    found = shutil.which("hermes")
    if found:
        return found
    for path in (os.path.join(str(home), "hermes-agent", ".hermes", "bin", "hermes"),
                 os.path.expanduser("~/.local/bin/hermes"), "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def _spawn(argv, home):
    """Run a hermes command detached from this request: its output goes to the bridge log, and a bridge
    restart in the meantime never takes it down."""
    env = dict(os.environ, HERMES_HOME=str(home))
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     env=env, start_new_session=True, close_fds=True)


def restart_hermes(home, now=False, kill=os.kill, spawn=_spawn):
    """-> (status, body). `now` interrupts running replies; otherwise Hermes restarts once it is idle."""
    pid = gateway_pid(home)
    if pid and not now:
        try:
            kill(pid, signal.SIGUSR1)
        except (ProcessLookupError, PermissionError, OSError):
            pid = None
        else:
            return 202, {"ok": True, "target": "hermes", "mode": "when_idle",
                         "message": "Hermes will restart as soon as nothing is running. Replies in progress finish first."}
    cmd = hermes_command(home)
    if not cmd:
        return 503, {"error": "Couldn't find the hermes command on the Mac. Run `hermes gateway restart` there."}
    if pid:
        spawn([cmd, "gateway", "restart", "--yes", "--detach"], home)
        return 202, {"ok": True, "target": "hermes", "mode": "now",
                     "message": "Restarting Hermes now. Anything running was stopped."}
    spawn([cmd, "gateway", "start"], home)
    return 202, {"ok": True, "target": "hermes", "mode": "start",
                 "message": "Hermes wasn't running. Starting it."}


def restart_bridge(delay=0.6, exit_fn=os._exit, sleep=time.sleep):
    """Exit shortly after the reply has gone out; the service manager starts the bridge again."""
    def later():
        sleep(delay)
        exit_fn(BRIDGE_EXIT_CODE)
    threading.Thread(target=later, name="bridge-restart", daemon=True).start()
    return 202, {"ok": True, "target": "bridge", "mode": "now",
                 "message": "Restarting the phone connection. Back in a few seconds."}
