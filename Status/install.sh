#!/bin/bash
# Install the Hermes status dashboard (http://127.0.0.1:9230) as a per-user launch agent.
# The phone app's Status tab reads it through the bridge.
#
#   ./install.sh             install (or update) and start it
#   ./install.sh --uninstall stop and remove it
#
# Env overrides: HERMES_STATUS_PORT (default 9230), HERMES_STATUS_LABEL (default local.hermes-mobile.status),
# HERMES_BIN (path to the `hermes` CLI; used for provider usage).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${HERMES_STATUS_PORT:-9230}"
LABEL="${HERMES_STATUS_LABEL:-local.hermes-mobile.status}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/hermes-status.log"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

PY="$(command -v python3 || true)"
if [[ -z "$PY" ]]; then echo "python3 not found." >&2; exit 1; fi
HB="${HERMES_BIN:-$(command -v hermes || echo "$HOME/.local/bin/hermes")}"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && ! launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "Port $PORT is already in use (a status dashboard may already be running). Set HERMES_STATUS_PORT to use another;" >&2
  echo "the bridge then needs HERMES_STATUS_URL=http://127.0.0.1:<port>/api/status." >&2
  exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s#__LABEL__#$LABEL#g" -e "s#__PYTHON__#$PY#g" -e "s#__SERVER__#$HERE/hermes_status_server.py#g" \
    -e "s#__PORT__#$PORT#g" -e "s#__LOG__#$LOG#g" -e "s#__PATH__#$(dirname "$HB"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin#g" \
    "$HERE/hermes-status.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
if curl -fsS "http://127.0.0.1:$PORT/api/status" >/dev/null; then
  echo "Status dashboard running: http://127.0.0.1:$PORT (log: $LOG)"
else
  echo "The dashboard didn't answer yet; check $LOG" >&2
fi
