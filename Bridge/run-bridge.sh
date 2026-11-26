#!/bin/bash
# What launchd (macOS) and systemd (Linux) start. Resolves Hermes's current Python on every start, so a
# Hermes update that moves its environment never leaves the bridge on a stale or deleted interpreter.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hermes-python.sh
source "$HERE/hermes-python.sh"
if ! hermes_python; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') Hermes Mobile bridge: couldn't find Hermes's Python under ${HERMES_HOME:-$HOME/.hermes}." \
       "Set HERMES_PYTHON in the service definition, or run Bridge/install.sh again." >&2
  exit 78   # EX_CONFIG: launchd/systemd throttle instead of spinning
fi
exec "$PY" "$HERE/hermes_mobile_bridge.py" "$@"
