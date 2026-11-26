# Sourced by install.sh and run-bridge.sh: sets PY to the Python that Hermes itself runs on.
#
# Hermes's package manager (pm/) keeps its dependencies in a committed environment under
# $HERMES_HOME/installs/<id>/environments/<generation>/venv, and moves to a new generation on update.
# The in-tree hermes-agent/venv predates that and is left behind on an old interpreter: running the bridge
# on it mixes ABIs and silently uses stale packages. So ask Hermes which environment is current, every
# time, and only fall back to the in-tree venvs for installs that predate the package manager.
#
# Override with HERMES_PYTHON=/path/to/python.

hermes_python() {
  local home="${HERMES_HOME:-$HOME/.hermes}" root boot env cand
  root="$home/hermes-agent"
  if [[ -n "${HERMES_PYTHON:-}" ]]; then
    PY="$HERMES_PYTHON"
    return 0
  fi
  # Any Python 3 can read the package manager's records; prefer the ones Hermes ships.
  for boot in $(ls -1d "$home"/tools/python-*/bin/python3 2>/dev/null | sort -r) "$(command -v python3 2>/dev/null)"; do
    [[ -n "$boot" && -x "$boot" ]] || continue
    env="$(cd "$root" 2>/dev/null && "$boot" -I -c '
import sys
sys.path.insert(0, ".")
from pathlib import Path
try:
    from pm.environments import committed_venv
except Exception:
    sys.exit(0)
env = committed_venv(Path(".").resolve())
print(env or "")' 2>/dev/null)" || env=""
    for cand in "$env/bin/python" "$env/Scripts/python.exe"; do
      if [[ -n "$env" && -x "$cand" ]] && (cd "$root" && "$cand" -c "import hermes_cli.gateway_client") 2>/dev/null; then
        PY="$cand"
        return 0
      fi
    done
    [[ -n "$env" ]] && break   # the records answered; don't ask a second interpreter
  done
  # Installs that predate Hermes's package manager.
  for cand in "$root/.venv/bin/python" "$root/venv/bin/python"; do
    if [[ -x "$cand" ]] && (cd "$root" && "$cand" -c "import hermes_cli.gateway_client") 2>/dev/null; then
      PY="$cand"
      return 0
    fi
  done
  PY=""
  return 1
}
