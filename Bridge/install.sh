#!/bin/bash
# Install the Hermes Mobile bridge as a per-user service: a launch agent on macOS, a systemd user service on Linux.
# (Windows: Windows/Install-HermesMobile.ps1.)
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
# Push notifications (optional, see README "Push notifications"): HERMES_MOBILE_APNS_KEY_PATH (the .p8),
# HERMES_MOBILE_APNS_KEY_ID, HERMES_MOBILE_APNS_TEAM_ID and HERMES_MOBILE_APNS_TOPIC (the app's bundle ID;
# defaults to HERMES_BUNDLE_ID from App/Config/Signing.xcconfig). Set all three of key path, key ID and team ID or none.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PORT="${HERMES_MOBILE_PORT:-9131}"
LABEL="${HERMES_MOBILE_LABEL:-local.hermes-mobile.bridge}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HERMES_HOME/mobile/bridge.log"

OS="$(uname -s)"
UNIT="$HOME/.config/systemd/user/hermes-mobile-bridge.service"

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ "$OS" == "Linux" ]]; then
    systemctl --user disable --now hermes-mobile-bridge.service 2>/dev/null || true
    rm -f "$UNIT"; systemctl --user daemon-reload 2>/dev/null || true
  else
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
  fi
  echo "Removed the bridge service. (Your Tailscale serve route, if any, is still there: tailscale serve --https=10001 off)"
  exit 0
fi

# The bridge runs on Hermes's own Python (it uses Hermes's gateway client). run-bridge.sh resolves it again at
# every start, so a Hermes update that moves its environment never strands the service.
# shellcheck source=hermes-python.sh
source "$HERE/hermes-python.sh"
if ! hermes_python; then
  echo "Couldn't find Hermes's Python under $HERMES_HOME (is Hermes Agent installed?)." >&2
  echo "Set HERMES_PYTHON=/path/to/python and run again." >&2
  exit 1
fi
# Run from a private copy, not from the clone: macOS refuses launch agents access to ~/Desktop, ~/Documents and
# ~/Downloads (where people clone things), and a copy keeps running while you edit or pull the repo.
SRC="$HERE"
STAMP="$(git -C "$SRC/.." rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/hermes-mobile"
REL="$SHARE/releases/$STAMP"
mkdir -p "$REL/Bridge"
chmod 700 "$SHARE" "$SHARE/releases" 2>/dev/null || true
if command -v rsync >/dev/null; then
  rsync -a --delete --exclude __pycache__ "$SRC/" "$REL/Bridge/"
else
  rm -rf "$REL/Bridge" && cp -R "$SRC" "$REL/Bridge" && rm -rf "$REL/Bridge/__pycache__"
fi
ln -sfn "$REL" "$SHARE/current"
HERE="$SHARE/current/Bridge"
chmod +x "$HERE/run-bridge.sh"
# Keep the three newest releases; older copies are dead weight. Never remove one a service still runs from.
in_use="$(cat "$HOME"/Library/LaunchAgents/*hermes-mobile*.plist "$HOME"/.config/systemd/user/hermes-mobile*.service 2>/dev/null || true)"
ls -1dt "$SHARE/releases"/*/ 2>/dev/null | tail -n +4 | while read -r old; do
  old="${old%/}"
  [[ "$old" == "$REL" ]] && continue
  grep -qF "$old/" <<<"$in_use" && continue
  rm -rf "$old"
done
echo "Installed to $REL"
VERSION="$(cd "$HERMES_HOME/hermes-agent" && "$PY" -c "import hermes_cli; print(hermes_cli.__version__)" 2>/dev/null || echo unknown)"
echo "Hermes Python: $PY (hermes-agent $VERSION)"
case "$VERSION" in 0.23.*) ;; *) echo "Note: built and tested against Hermes 0.23.x; other versions may not work." ;; esac

# The bridge reaches each profile through the gateway API server; it needs API_SERVER_KEY set.
if ! grep -q '^API_SERVER_KEY=' "$HERMES_HOME/.env" 2>/dev/null; then
  echo "Warning: no API_SERVER_KEY in $HERMES_HOME/.env, so the gateway API server won't answer the bridge." >&2
fi

ours() { if [[ "$OS" == "Linux" ]]; then systemctl --user is-active --quiet hermes-mobile-bridge.service; else launchctl list "$LABEL" >/dev/null 2>&1; fi; }
if command -v lsof >/dev/null && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && ! ours; then
  echo "Port $PORT is already in use by something else. Pick another with HERMES_MOBILE_PORT=..." >&2
  exit 1
fi

# Push notifications (optional, see README "Push notifications"): all three of key path, key ID and team ID, or none.
TOPIC="${HERMES_MOBILE_APNS_TOPIC:-}"
if [[ -n "${HERMES_MOBILE_APNS_KEY_PATH:-}" ]]; then
  if [[ -z "${HERMES_MOBILE_APNS_KEY_ID:-}" || -z "${HERMES_MOBILE_APNS_TEAM_ID:-}" ]]; then
    echo "Push needs HERMES_MOBILE_APNS_KEY_ID and HERMES_MOBILE_APNS_TEAM_ID as well as the key path." >&2
    exit 1
  fi
  if [[ -z "$TOPIC" && -f "$SRC/../App/Config/Signing.xcconfig" ]]; then
    TOPIC="$(sed -n 's#^[[:space:]]*HERMES_BUNDLE_ID[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*#\1#p' "$SRC/../App/Config/Signing.xcconfig" | head -1)"
  fi
fi

mkdir -p "$HERMES_HOME/mobile"
if [[ "$OS" == "Linux" ]]; then
  # A systemd user service. `loginctl enable-linger $USER` keeps it running when you're logged out.
  mkdir -p "$(dirname "$UNIT")"
  {
    echo "[Unit]"
    echo "Description=Hermes Mobile bridge (phone companion for Hermes Agent)"
    echo "After=network-online.target"
    echo
    echo "[Service]"
    echo "ExecStart=/bin/bash $HERE/run-bridge.sh"
    echo "Environment=HERMES_HOME=$HERMES_HOME"
    echo "Environment=HERMES_MOBILE_PORT=$PORT"
    [[ -n "${HERMES_PYTHON:-}" ]] && echo "Environment=HERMES_PYTHON=$HERMES_PYTHON"
    [[ -n "${HERMES_MOBILE_PROJECTS_CATALOG:-}" ]] && echo "Environment=HERMES_MOBILE_PROJECTS_CATALOG=$HERMES_MOBILE_PROJECTS_CATALOG"
    [[ -n "${HERMES_MOBILE_WORKSPACES:-}" ]] && echo "Environment='HERMES_MOBILE_WORKSPACES=$HERMES_MOBILE_WORKSPACES'"
    if [[ -n "${HERMES_MOBILE_APNS_KEY_PATH:-}" ]]; then
      echo "Environment=HERMES_MOBILE_APNS_KEY_PATH=$HERMES_MOBILE_APNS_KEY_PATH"
      echo "Environment=HERMES_MOBILE_APNS_KEY_ID=$HERMES_MOBILE_APNS_KEY_ID"
      echo "Environment=HERMES_MOBILE_APNS_TEAM_ID=$HERMES_MOBILE_APNS_TEAM_ID"
      [[ -n "$TOPIC" ]] && echo "Environment=HERMES_MOBILE_APNS_TOPIC=$TOPIC"
    fi
    echo "Restart=always"
    echo "RestartSec=5"
    echo "StandardOutput=append:$LOG"
    echo "StandardError=append:$LOG"
    echo
    echo "[Install]"
    echo "WantedBy=default.target"
  } > "$UNIT"
  systemctl --user daemon-reload
  systemctl --user enable --now hermes-mobile-bridge.service
  systemctl --user restart hermes-mobile-bridge.service
else
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s#__LABEL__#$LABEL#g" -e "s#__RUNNER__#$HERE/run-bridge.sh#g" \
      -e "s#__PORT__#$PORT#g" -e "s#__LOG__#$LOG#g" -e "s#__HERMES_HOME__#$HERMES_HOME#g" \
      "$HERE/hermes-mobile-bridge.plist.template" > "$PLIST"
  if [[ -n "${HERMES_PYTHON:-}" ]]; then
    plutil -insert EnvironmentVariables.HERMES_PYTHON -string "$HERMES_PYTHON" "$PLIST"
  fi
  if [[ -n "${HERMES_MOBILE_PROJECTS_CATALOG:-}" ]]; then
    plutil -insert EnvironmentVariables.HERMES_MOBILE_PROJECTS_CATALOG -string "$HERMES_MOBILE_PROJECTS_CATALOG" "$PLIST"
  fi
  if [[ -n "${HERMES_MOBILE_WORKSPACES:-}" ]]; then
    plutil -insert EnvironmentVariables.HERMES_MOBILE_WORKSPACES -string "$HERMES_MOBILE_WORKSPACES" "$PLIST"
  fi
  if [[ -n "${HERMES_MOBILE_APNS_KEY_PATH:-}" ]]; then
    plutil -insert EnvironmentVariables.HERMES_MOBILE_APNS_KEY_PATH -string "$HERMES_MOBILE_APNS_KEY_PATH" "$PLIST"
    plutil -insert EnvironmentVariables.HERMES_MOBILE_APNS_KEY_ID -string "$HERMES_MOBILE_APNS_KEY_ID" "$PLIST"
    plutil -insert EnvironmentVariables.HERMES_MOBILE_APNS_TEAM_ID -string "$HERMES_MOBILE_APNS_TEAM_ID" "$PLIST"
    [[ -n "$TOPIC" ]] && plutil -insert EnvironmentVariables.HERMES_MOBILE_APNS_TOPIC -string "$TOPIC" "$PLIST"
  fi
  plutil -lint "$PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
sleep 2
if curl -fsS "http://127.0.0.1:$PORT/m/ping" >/dev/null; then
  echo "Bridge running on http://127.0.0.1:$PORT (log: $LOG)."
else
  echo "The bridge didn't answer yet; check $LOG" >&2
fi
echo
echo "Checking everything the phone needs:"
HERMES_MOBILE_PORT="$PORT" "$HERE/run-bridge.sh" --doctor || true
cat <<MSG

If Tailscale isn't serving it yet (tailnet only, real HTTPS, nothing exposed to the internet):
  tailscale serve --bg --https=10001 http://127.0.0.1:$PORT
Then in the app, sign in with https://<this-machine>.<your-tailnet>.ts.net:10001 using your Hermes dashboard
username and password, or a one-time pairing code:
  $HERE/run-bridge.sh --pair-code
MSG
