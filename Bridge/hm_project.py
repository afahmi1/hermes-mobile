#!/usr/bin/env python3
"""`hm-project`: let Hermes make a project from a chat, from inside a chat.

    hm-project create --profile default --session <sid> [--json]
    hm-project detect [--live] [--json]
    hm-project detect --dry-run [--json]      # default; prints what it would make, makes nothing

The `create` command is what Hermes runs when he's asked to "make this a project" in words. It talks to the
bridge on 127.0.0.1 over the bridge's own local-only path, signed with a key derived from the bridge secret,
so it needs no API key, PIN or bearer token and works from any bot's terminal. It returns the new project id
(and title) and polls until the draft is done.

Stdlib only. Installed by Bridge/install.sh into ~/.local/bin.
"""
import argparse
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bridge_autoprojects  # noqa: E402  (signing helpers; also resolves the state dir, below)


def _service_env():
    try:
        import bridge_doctor
        return bridge_doctor._service_env()
    except Exception:
        return {}


def _state_dir():
    env = dict(os.environ)
    if env.get("HERMES_MOBILE_STATE_DIR"):
        return Path(env["HERMES_MOBILE_STATE_DIR"]).expanduser()
    service = _service_env()
    if service.get("HERMES_MOBILE_STATE_DIR"):
        return Path(service["HERMES_MOBILE_STATE_DIR"]).expanduser()
    return Path(env.get("HERMES_HOME", str(Path.home() / ".hermes"))) / "mobile"


def _port():
    env = dict(os.environ)
    if env.get("HERMES_MOBILE_PORT"):
        return int(env["HERMES_MOBILE_PORT"])
    service = _service_env()
    if service.get("HERMES_MOBILE_PORT"):
        return int(service["HERMES_MOBILE_PORT"])
    return 9131


def _secret(state_dir):
    return (state_dir / "secret").read_bytes().strip()


def _request(path, body, state_dir, port, method="POST"):
    data = json.dumps(body).encode("utf-8")
    header = bridge_autoprojects.local_header(_secret(state_dir), method, path, data)
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header(bridge_autoprojects.LOCAL_HEADER, header)
    with urllib.request.urlopen(req, timeout=300) as resp:
        raw = resp.read()
    return resp.status, json.loads(raw) if raw else None


def cmd_create(args):
    state_dir, port = _state_dir(), _port()
    status, job = _request("/m/local/autoprojects/from-chat",
                           {"profile": args.profile, "session_id": args.session}, state_dir, port)
    if status != 202 or not isinstance(job, dict):
        print("The bridge couldn't start this (HTTP %d)." % status, file=sys.stderr)
        if isinstance(job, dict) and job.get("error"):
            print(job["error"], file=sys.stderr)
        return 1
    jid = job.get("id")
    while True:
        _, cur = _request("/m/local/autoprojects/jobs/" + jid, {}, state_dir, port, method="GET")
        if not isinstance(cur, dict) or cur.get("state") in ("done", "failed"):
            break
        time.sleep(1)
    if cur.get("state") == "done":
        result = cur.get("result") or {}
        if args.json:
            print(json.dumps(result, ensure_ascii=False))
        else:
            print("Project %s: %s" % (result.get("project_id"), result.get("title")))
            print("  chats linked: %d, files kept: %d" % (result.get("chats"), result.get("files")))
        return 0
    print("Making the project failed: %s" % (cur.get("error") or "unknown error"), file=sys.stderr)
    return 1


def cmd_detect(args):
    state_dir, port = _state_dir(), _port()
    body = {"dry_run": not args.live, "force": args.live}
    status, report = _request("/m/local/autoprojects/detect", body, state_dir, port)
    if status != 200 or not isinstance(report, dict):
        print("The bridge couldn't scan (HTTP %d)." % status, file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    if report.get("skipped"):
        print("Skipped: %s (last pass %s)." % (report["skipped"], report.get("last_run")))
        return 0
    print("Scanned %d chats." % report.get("scanned", 0))
    for c in report.get("candidates") or []:
        tag = "  (%s)" % c["skip"] if c.get("skip") else ""
        print("- %s: %d chats across %d days%s" % (" ".join(c.get("terms") or []), c.get("chats"), c.get("days"), tag))
    made = report.get("would_create") or report.get("created") or []
    if made:
        print("Would make:" if report.get("would_create") else "Made:")
        for p in made:
            print("  - %s" % p.get("title"))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="hm-project", description="Let Hermes make a project from a chat.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create", help="make the project for one chat")
    c.add_argument("--profile", required=True, help="the bot's profile id (default for the main one)")
    c.add_argument("--session", required=True, help="the chat's session id")
    c.add_argument("--json", action="store_true")
    c.set_defaults(fn=cmd_create)
    d = sub.add_parser("detect", help="scan recent chats for a recurring topic")
    d.add_argument("--live", action="store_true", help="really make a spotted project (default: dry-run)")
    d.add_argument("--json", action="store_true")
    d.set_defaults(fn=cmd_detect)
    args = parser.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
