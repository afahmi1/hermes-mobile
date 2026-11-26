"""Test bootstrap: point the bridge's state dir at a throwaway temp dir.

Import this BEFORE hermes_mobile_bridge. The bridge reads HERMES_MOBILE_STATE_DIR at import
time, so its signing secret, devices DB, pins, receipts, owner files, workspaces and thumbs
all land in the temp dir instead of the live ~/.hermes/mobile. Subprocesses inherit the env var.
"""
import atexit
import os
import shutil
import tempfile
from pathlib import Path

REAL_STATE_DIR = (Path.home() / ".hermes" / "mobile").resolve()

if not os.environ.get("HERMES_MOBILE_STATE_DIR"):
    _tmp = tempfile.mkdtemp(prefix="hermes-mobile-test-state-")
    os.environ["HERMES_MOBILE_STATE_DIR"] = _tmp
    atexit.register(shutil.rmtree, _tmp, ignore_errors=True)


def inside_real_state(path) -> bool:
    p = Path(path).resolve()
    return p == REAL_STATE_DIR or REAL_STATE_DIR in p.parents
