#!/bin/bash
# Install the Hermes Mobile bridge as a per-user launch agent on this Mac.
#
#   ./install.sh            install (or update) and start it
#   ./install.sh --uninstall stop and remove it
#
# Env overrides: HERMES_HOME (default ~/.hermes), HERMES_PYTHON (Hermes's venv python),
# HERMES_MOBILE_PORT (default 9131), HERMES_MOBILE_LABEL (default local.hermes-mobile.bridge),
# HERMES_MOBILE_PROJECTS_CATALOG (optional absolute path to a project catalog JSON; off if unset),
# HERMES_MOBILE_WORKSPACES (optional JSON, off if unset: {"<catalog project id>": ["<exact bot id>", ...]}
# opts those project/bot pairs in to Project instructions, files, chats and output files. Needs the catalog.
# Single owner only. Paired phones can chat and approve tools, while owner grants control workspace changes.
# Do not enable it on a shared or multi-user bridge.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PORT="${HERMES_MOBILE_PORT:-9131}"
LABEL="${HERMES_MOBILE_LABEL:-local.hermes-mobile.bridge}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HERMES_HOME/mobile/bridge.log"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL. (Your Tailscale serve route, if any, is still there: tailscale serve --https=10001 off)"
  exit 0
fi

# The bridge runs on Hermes's own Python: it uses Hermes's gateway client.
PY="${HERMES_PYTHON:-}"
for cand in "$PY" "$HERMES_HOME/hermes-agent/.venv/bin/python" "$HERMES_HOME/hermes-agent/venv/bin/python"; do
  if [[ -n "$cand" && -x "$cand" ]] && "$cand" -c "import hermes_cli.gateway_client" 2>/dev/null; then PY="$cand"; break; fi
  PY=""
done
if [[ -z "$PY" ]]; then
  echo "Couldn't find Hermes's Python (looked in $HERMES_HOME/hermes-agent/.venv)." >&2
  echo "Set HERMES_PYTHON=/path/to/hermes/venv/bin/python and run again." >&2
  exit 1
fi
VERSION="$("$PY" -c "import hermes_cli; print(hermes_cli.__version__)" 2>/dev/null || echo unknown)"
echo "Hermes Python: $PY (hermes-agent $VERSION)"
case "$VERSION" in 0.23.*) ;; *) echo "Note: built and tested against Hermes 0.23.x; other versions may not work." ;; esac

# The bridge reaches each profile through the gateway API server; it needs API_SERVER_KEY set.
if ! grep -q '^API_SERVER_KEY=' "$HERMES_HOME/.env" 2>/dev/null; then
  echo "Warning: no API_SERVER_KEY in $HERMES_HOME/.env, so the gateway API server won't answer the bridge." >&2
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && ! launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "Port $PORT is already in use by something else. Pick another with HERMES_MOBILE_PORT=..." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HERMES_HOME/mobile"
sed -e "s#__LABEL__#$LABEL#g" -e "s#__PYTHON__#$PY#g" -e "s#__BRIDGE__#$HERE/hermes_mobile_bridge.py#g" \
    -e "s#__PORT__#$PORT#g" -e "s#__LOG__#$LOG#g" "$HERE/hermes-mobile-bridge.plist.template" > "$PLIST"
if [[ -n "${HERMES_MOBILE_PROJECTS_CATALOG:-}" ]]; then
  plutil -insert EnvironmentVariables.HERMES_MOBILE_PROJECTS_CATALOG -string "$HERMES_MOBILE_PROJECTS_CATALOG" "$PLIST"
fi
if [[ -n "${HERMES_MOBILE_WORKSPACES:-}" ]]; then
  plutil -insert EnvironmentVariables.HERMES_MOBILE_WORKSPACES -string "$HERMES_MOBILE_WORKSPACES" "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
if curl -fsS "http://127.0.0.1:$PORT/m/ping" >/dev/null; then
  echo "Bridge running on http://127.0.0.1:$PORT (log: $LOG)."
else
  echo "The bridge didn't answer yet; check $LOG" >&2
fi
cat <<MSG

Next, make it reachable from your phone over Tailscale (tailnet only, real HTTPS):
  tailscale serve --bg --https=10001 http://127.0.0.1:$PORT
Then in the app, sign in with https://<this-mac>.<your-tailnet>.ts.net:10001 and your Hermes dashboard
username and password (dashboard.basic_auth in $HERMES_HOME/config.yaml).
MSG
