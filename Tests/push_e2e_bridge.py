"""The real bridge, with a scripted stand-in for Hermes's gateway, for Tests/test_push_e2e.py.

Everything is the shipped code (HTTP server, routes, device grants, turn engine, push) except the gateway
connection: `bridge_turns.connect` and `bridge_turns._rpc` answer like a gateway that accepts the message and
replies. The message text steers it: "[after 1.5]" waits that many seconds before the reply, "[ask]" makes Hermes
ask a question first. Run it with the same environment as the bridge (HERMES_MOBILE_STATE_DIR and friends).
"""
import asyncio
import re
import runpy
import sys
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Bridge"))

import bridge_turns  # noqa: E402


class Gateway:
    def __init__(self):
        self.events = asyncio.Queue()

    def event(self, kind, admission, **payload):
        self.events.put_nowait({"method": "event", "params": {
            "type": kind, "admission_id": admission, "execution_generation": 1, "payload": payload}})


@asynccontextmanager
async def connect(home):
    yield Gateway()


async def rpc(client, method, **params):
    if method == "session.resume":
        sid = params["session_id"]
        return {"session_id": sid, "stored_session_id": sid, "pending": [], "prompts": [],
                "revision": 1, "execution_generation": 1}
    if method == "prompt.submit":
        admission = "adm-" + uuid.uuid4().hex[:12]
        text = params.get("text") or ""
        found = re.search(r"\[after ([0-9.]+)\]", text)
        delay = float(found.group(1)) if found else 0.2

        async def reply():
            await asyncio.sleep(delay)
            if "[ask]" in text:
                client.event("clarify.request", admission, prompt_id="q-" + admission, question="Which branch?",
                             choices=["main", "dev"])
                await asyncio.sleep(delay)
            client.event("message.delta", admission, text="Done.")
            client.event("message.complete", admission, status="complete", outcome="completed", text="Done.",
                         admission_id=admission)

        asyncio.ensure_future(reply())
        return {"admission_id": admission, "status": "started", "execution_generation": 1}
    raise bridge_turns.TurnError("The e2e gateway doesn't script %s." % method, 400)


bridge_turns.connect = connect
bridge_turns._rpc = rpc
sys.argv = [str(ROOT / "Bridge" / "hermes_mobile_bridge.py")]
runpy.run_path(sys.argv[0], run_name="__main__")
