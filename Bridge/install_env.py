#!/usr/bin/env python3
"""Collect the HERMES_MOBILE_* settings install.sh writes into the service definition.

Defaults come from the service already installed under the same label (a launchd plist or a systemd user
unit), so re-running the installer never drops a setting. The caller's environment overrides them: a
variable set to a value replaces the old one, a variable set to the empty string removes it.

    install_env.py --plist PATH | --unit PATH      prints NAME NUL VALUE NUL records on stdout
    (names only, never values, go to stderr)

HERMES_MOBILE_LABEL is installer-only and never carried.
"""
import os
import plistlib
import re
import sys

PREFIX = "HERMES_MOBILE_"
INSTALLER_ONLY = {"HERMES_MOBILE_LABEL"}
NAME_RE = re.compile(r"^HERMES_MOBILE_[A-Z0-9_]+$")
_ESC = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "'": "'", "s": " "}


def carried(name):
    return bool(NAME_RE.match(name)) and name not in INSTALLER_ONLY


def read_plist(path):
    try:
        with open(path, "rb") as f:
            env = (plistlib.load(f) or {}).get("EnvironmentVariables") or {}
    except (OSError, ValueError, plistlib.InvalidFileException):
        return {}
    return {k: v for k, v in env.items() if isinstance(k, str) and isinstance(v, str) and carried(k)}


def _words(text):
    """Split an Environment= value the way systemd does: whitespace-separated, '...' and "..." quoting,
    backslash escapes, %% for a literal percent."""
    out, cur, quote, i, started = [], [], None, 0, False
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            cur.append(_ESC.get(text[i + 1], text[i + 1]))
            i += 2
            started = True
            continue
        if quote:
            if c == quote:
                quote = None
            else:
                cur.append(c)
        elif c in "\"'":
            quote, started = c, True
        elif c.isspace():
            if started:
                out.append("".join(cur))
                cur, started = [], False
        else:
            cur.append(c)
            started = True
        i += 1
    if started:
        out.append("".join(cur))
    return [w.replace("%%", "%") for w in out]


def read_unit(path):
    env = {}
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return env
    for line in lines:
        line = line.strip()
        if not line.startswith("Environment="):
            continue
        for word in _words(line[len("Environment="):]):
            name, sep, value = word.partition("=")
            if sep and carried(name):
                env[name] = value
    return env


def merge(existing, environ):
    """Returns (merged, adopted_names, overridden_names, removed_names)."""
    merged = dict(existing)
    overridden, removed = [], []
    for name, value in environ.items():
        if not carried(name):
            continue
        if value == "":
            if name in merged:
                removed.append(name)
            merged.pop(name, None)
        else:
            if name in existing and existing[name] != value:
                overridden.append(name)
            merged[name] = value
    adopted = sorted(n for n in existing if n in merged and n not in environ)
    return merged, adopted, sorted(overridden), sorted(removed)


def main(argv):
    if len(argv) != 3 or argv[1] not in ("--plist", "--unit"):
        sys.stderr.write(__doc__)
        return 2
    existing = read_plist(argv[2]) if argv[1] == "--plist" else read_unit(argv[2])
    merged, adopted, overridden, removed = merge(existing, os.environ)
    if adopted:
        sys.stderr.write("Kept from the existing service: %s\n" % ", ".join(adopted))
    if overridden:
        sys.stderr.write("Replaced by your environment: %s\n" % ", ".join(overridden))
    if removed:
        sys.stderr.write("Removed (set to empty): %s\n" % ", ".join(removed))
    out = sys.stdout.buffer
    for name in sorted(merged):
        out.write(name.encode() + b"\0" + merged[name].encode() + b"\0")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
