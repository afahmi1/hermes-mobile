"""Turn engine: drives chats through the gateway's canonical session protocol, the same one the Hermes
desktop app speaks (JSON-RPC over the gateway's /api/ws, authenticated with a same-user ticket from the
private control socket via Hermes's own ``hermes_cli.gateway_client``; no password, no API key).

Why not the API server's /v1/runs: under the gateway's session authority an API run may only bind to an
``api_server``-sourced session (``gateway/session_api.py``), so desktop, iMessage and terminal chats can't
be continued that way, and API sessions carry stored per-run settings that override per-turn reasoning.

Model / provider / effort switching is what the desktop does: ``session.mutate`` (operations ``model``
and ``reasoning``) persists the pick on the session in state.db, so every device sees it. The same pick
also rides the turn as ``model_override`` (the CLI's ``/model --once`` path), so the turn runs on it even
for session types that keep their own routing.

Each turn runs on its own connection held by this process, so the phone can lock, lose signal or close
the app; the turn keeps going and the phone re-attaches to the buffered event log by sequence number.
"""
from __future__ import annotations

import asyncio
import inspect
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

LOOP = asyncio.new_event_loop()
threading.Thread(target=LOOP.run_forever, name="turn-loop", daemon=True).start()
TURNS: dict[str, "Turn"] = {}
TURNS_LOCK = threading.Lock()
EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}


def run(coro, timeout=60):
    return asyncio.run_coroutine_threadsafe(coro, LOOP).result(timeout)


class TurnError(Exception):
    def __init__(self, message, code=400):
        super().__init__(message)
        self.code = code


def _endpoint(home: Path):
    """The served gateway endpoint for a profile home. Read-only discovery: never starts a gateway."""
    from hermes_cli.gateway_runtime import attachable, discover_gateway_endpoint
    d = discover_gateway_endpoint(home)
    if not attachable(d):
        raise TurnError("The Hermes gateway for this bot is %s%s." % (d.state, f" ({d.reason_code})" if d.reason_code else ""), 503)
    return d.endpoint


@asynccontextmanager
async def connect(home: Path):
    from hermes_cli.gateway_client import connect_gateway
    ep = await asyncio.to_thread(_endpoint, home)
    # Older Hermes clients own their WebSocket frame limit internally.
    options = {"max_size": 64 * 1024 * 1024} if "max_size" in inspect.signature(connect_gateway).parameters else {}
    async with connect_gateway(endpoint=ep, **options) as c:
        yield c


async def _rpc(c, method, **params):
    from hermes_cli.gateway_client import GatewayRPCError
    try:
        return await c.rpc(method, **params)
    except GatewayRPCError as e:
        raise TurnError("%s: %s" % (method, e), 409 if str(e) in ("session_busy", "revision_conflict") else 400)


async def _mutate(c, sid, operation, payload):
    snap = await _rpc(c, "session.resume", session_id=sid)
    res = await _rpc(c, "session.mutate", session_id=sid, request_id=uuid.uuid4().hex, operation=operation,
                     expected_revision=snap["revision"], expected_generation=snap["execution_generation"],
                     payload=payload) or {}
    if res.get("status") == "confirmation_required":
        # A guarded model (cost / capability warning). The phone already confirmed by picking it.
        res = await _rpc(c, "session.mutate", session_id=sid, request_id=uuid.uuid4().hex, operation=operation,
                         expected_revision=snap["revision"], expected_generation=snap["execution_generation"],
                         payload={**payload, "confirm": res.get("confirm")}) or {}
    return res


def clean_choice(choice: dict | None) -> dict:
    choice = choice or {}
    out = {}
    if isinstance(choice.get("model"), str) and choice["model"].strip():
        out["model"] = choice["model"].strip()[:200]
    if isinstance(choice.get("provider"), str) and choice["provider"].strip():
        out["provider"] = choice["provider"].strip()[:80]
    eff = str(choice.get("effort") or "").strip().lower()
    if eff in EFFORTS:
        out["effort"] = eff
    # Back to the bot's own setting (the desktop's "/model reset" and "/reasoning reset").
    if choice.get("reset_model") is True and "model" not in out:
        out["reset_model"] = True
    if choice.get("reset_effort") is True and "effort" not in out:
        out["reset_effort"] = True
    return out


async def _apply(c, sid, choice: dict) -> dict:
    applied = {}
    if choice.get("model"):
        payload = {"model": choice["model"], **({"provider": choice["provider"]} if choice.get("provider") else {})}
        applied["model"] = await _mutate(c, sid, "model", payload)
    elif choice.get("reset_model"):
        applied["model"] = await _mutate(c, sid, "model", {"model": "reset"})
    if choice.get("effort"):
        applied["reasoning"] = await _mutate(c, sid, "reasoning", {"effort": choice["effort"]})
    elif choice.get("reset_effort"):
        applied["reasoning"] = await _mutate(c, sid, "reasoning", {"effort": None})
    return applied


# ---------- one-shot operations ----------

async def _create(home, profile, title):
    async with connect(home) as c:
        params = {"profile": profile, "source": "gui"}
        if title:
            params["title"] = title[:120]
        created = await _rpc(c, "session.create", **params)
        sid = created.get("session_id") or created.get("stored_session_id")
        if not sid:
            raise TurnError("session.create returned no session id", 502)
        return {"session_id": sid}


def create_session(home, profile, title=None):
    return run(_create(home, profile, title))


async def _set_runtime(home, sid, choice):
    async with connect(home) as c:
        return await _apply(c, sid, choice)


def set_runtime(home, sid, choice):
    choice = clean_choice(choice)
    if not choice:
        raise TurnError("Nothing to change.")
    return run(_set_runtime(home, sid, choice))


async def _interrupt(turn):
    """Stop a turn. session.interrupt is generation-fenced; a turn still queued is cancelled instead."""
    async def go(c):
        snap = await _rpc(c, "session.resume", session_id=turn.canonical_sid)
        gen = turn.generation if turn.generation is not None else snap.get("execution_generation")
        row = next((r for r in snap.get("pending") or [] if r.get("admission_id") == turn.admission), {})
        if turn.admission and row.get("status") == "queued":
            return await _rpc(c, "prompt.cancel", session_id=turn.canonical_sid, admission_id=turn.admission)
        return await _rpc(c, "session.interrupt", session_id=turn.canonical_sid, execution_generation=gen)
    if turn.client is not None:
        return await go(turn.client)
    async with connect(turn.home) as c:
        return await go(c)


async def _approve(turn, choice, prompt_id, generation):
    async def go(c):
        res = await _rpc(c, "approval.respond", session_id=turn.canonical_sid, execution_generation=generation,
                         prompt_id=prompt_id, choice=choice)
        turn.push("approval.resolved", request_id=prompt_id, choice=choice)
        return res
    if turn.client is not None:
        return await go(turn.client)
    async with connect(turn.home) as c:
        await _rpc(c, "session.resume", session_id=turn.canonical_sid)
        return await go(c)


# ---------- live turns ----------

class Turn:
    def __init__(self, profile, home, sid, text, choice):
        self.id = "turn_" + uuid.uuid4().hex
        self.profile, self.home, self.sid, self.text, self.choice = profile, home, sid, text, choice
        self.events: list[dict] = []
        self.cond = threading.Condition()
        self.done = False
        self.started = time.time()
        self.ended = 0.0
        self.canonical_sid = sid
        self.submission = None
        self.admission = None
        self.generation = None
        self.client = None
        self.steer_receipts = {}
        self.prompts: dict = {}  # prompt_id -> execution_generation of approvals still open
        self.served = {}

    def push(self, name, **fields):
        with self.cond:
            ev = {"event": name, "seq": len(self.events), "turn_id": self.id, "session_id": self.sid,
                  "timestamp": time.time(), **fields}
            self.events.append(ev)
            self.cond.notify_all()

    def finish(self):
        with self.cond:
            self.done, self.ended = True, time.time()
            self.cond.notify_all()

    def summary(self):
        return {"turn_id": self.id, "profile": self.profile, "session_id": self.sid, "done": self.done,
                "age": int(time.time() - self.started), "events": len(self.events)}


def _tool_name(pl):
    t = pl.get("tool")
    if isinstance(t, dict):
        return t.get("name") or t.get("tool_name") or "tool"
    return pl.get("name") or pl.get("tool_name") or (t if isinstance(t, str) else None) or "tool"


_STATUS_OUTCOME = {"complete": "completed", "completed": "completed",
                   "interrupted": "cancelled", "cancelled": "cancelled", "stopped": "cancelled"}


def _settle(turn, pl):
    """End the turn from a completion payload. Only a real completion counts as success: an outcome of
    ``unknown`` (a lost worker), ``failed`` or any error status is reported as a failure."""
    status = str(pl.get("status") or "").lower()
    outcome = str(pl.get("outcome") or "").lower()
    # Both fields describe the same terminal event. An unknown or conflicting value
    # cannot confirm that a reply completed.
    kinds = {_STATUS_OUTCOME.get(value, "failed") for value in (status, outcome) if value}
    kind = kinds.pop() if len(kinds) == 1 else "failed"
    if kind == "cancelled":
        turn.push("run.cancelled", output=pl.get("content") or pl.get("text") or "")
    elif kind == "failed":
        msg = pl.get("error") or pl.get("content") or pl.get("text") or "The turn did not finish."
        if outcome == "unknown":
            msg = "Hermes lost track of this reply. Check the chat on your Mac before sending it again."
        turn.push("run.failed", error=msg)
    else:
        u = pl.get("usage") or {}
        if u.get("model"):
            turn.served["model"] = u["model"]
        turn.push("run.completed", output=pl.get("content") or pl.get("text") or "",
                  runtime=dict(turn.served), outcome=outcome or "completed")


async def _recover_gap(c, turn):
    """The event stream lost frames. True when the turn turned out to be finished (and was settled)."""
    snap = await _rpc(c, "session.resume", session_id=turn.canonical_sid)
    row = next((r for r in snap.get("pending") or [] if r.get("admission_id") == turn.admission), None)
    if row is not None and row.get("status") != "unknown":
        return False  # still queued or running: its completion is still owed to this socket
    try:
        receipt = await _rpc(c, "prompt.receipt", session_id=turn.canonical_sid, admission_id=turn.admission, include_result=True)
    except TurnError:
        receipt = {}
    result = receipt.get("result") if isinstance(receipt.get("result"), dict) else {}
    if receipt.get("status") in ("started", "queued"):
        return False
    # "terminal" includes cancellation and worker loss. The admission's outcome
    # determines which event the phone should paint after a gap.
    outcome = receipt.get("outcome") if receipt.get("status") == "terminal" else "unknown"
    _settle(turn, {**result, "status": result.get("status") or "", "outcome": outcome or "unknown"})
    return True


async def _drive(turn: Turn):
    try:
        async with connect(turn.home) as c:
            snapshot = await _rpc(c, "session.resume", session_id=turn.sid)
            turn.canonical_sid = snapshot.get("session_id") or turn.sid
            following_queue = turn.admission is not None
            applied = await _apply(c, turn.sid, turn.choice) if turn.choice else {}
            params = {"session_id": turn.sid, "submission_id": uuid.uuid4().hex, "text": turn.text}
            if turn.choice.get("model"):
                params["model_override"] = {k: v for k, v in (
                    ("model", turn.choice.get("model")), ("provider", turn.choice.get("provider")),
                    ("reasoning", turn.choice.get("effort"))) if v}
            if following_queue:
                if await _recover_gap(c, turn):
                    return
            else:
                params["session_id"] = turn.canonical_sid
                receipt = await _rpc(c, "prompt.submit", **params)
                turn.admission = receipt["admission_id"]
                turn.generation = receipt.get("execution_generation")
            turn.client = c
            turn.push("run.started", requested=turn.choice, applied=bool(applied))
            deadline = time.time() + 3 * 3600
            while time.time() < deadline:
                try:
                    frame = await asyncio.wait_for(c.events.get(), 20 if following_queue else 1800)
                except asyncio.TimeoutError:
                    if not following_queue:
                        raise
                    if await _recover_gap(c, turn):
                        return
                    continue
                if isinstance(frame, BaseException):
                    # The gateway connection died (restart, sleep, crash): nothing more will arrive here.
                    turn.push("run.failed", error="Lost the connection to Hermes. The reply may still finish on "
                              "your Mac; pull down in the chat to refresh.")
                    return
                if not isinstance(frame, dict):
                    continue
                method = frame.get("method")
                p = frame.get("params") or {}
                pl = p.get("payload") if isinstance(p.get("payload"), dict) else {}
                if method and method != "event" and "id" in frame:
                    # A server->client request (older surfaces). Approvals arrive as events below.
                    if "clarify" in method:
                        turn.push("notice", text="Hermes asked a question it needs answered in the desktop app: "
                                  + str(p.get("question") or p.get("prompt") or "")[:300])
                    continue
                # Only this turn's own frames: the session may run other turns (a desktop prompt, a queued
                # one ahead of ours) on the same subscription.
                admission = p.get("admission_id") or pl.get("admission_id")
                if turn.admission and admission and admission != turn.admission:
                    continue
                if following_queue and not admission and (turn.generation is None or
                        p.get("execution_generation") != turn.generation) and p.get("type") != "session.replay_gap":
                    continue
                if p.get("execution_generation") is not None:
                    turn.generation = p["execution_generation"]
                t = p.get("type")
                if t == "message.delta":
                    turn.push("message.delta", delta=pl.get("text") or pl.get("delta") or "")
                elif t == "reasoning.delta":
                    turn.push("reasoning.delta", delta=pl.get("text") or "")
                elif t == "thinking.delta" and pl.get("text"):
                    turn.push("status", text=pl.get("text"))
                elif t in ("tool.start", "tool.started"):
                    turn.push("tool.started", tool_name=_tool_name(pl), preview=str(pl.get("preview") or "")[:200])
                elif t in ("tool.complete", "tool.completed"):
                    turn.push("tool.completed", tool_name=_tool_name(pl))
                elif t == "approval.request":
                    pid, gen = pl.get("prompt_id"), pl.get("execution_generation", turn.generation)
                    if pid:
                        turn.prompts[pid] = gen
                    turn.push("approval.request", request_id=pid, execution_generation=gen,
                              command=pl.get("command") or "", description=pl.get("description") or "",
                              choices=pl.get("choices") or ["once", "deny"])
                elif t in ("approval.responded", "approval.resolved"):
                    pid = pl.get("prompt_id")
                    turn.prompts.pop(pid, None)
                    turn.push("approval.resolved", request_id=pid)
                elif t == "clarify.request":
                    turn.push("notice", text="Hermes asked a question it needs answered in the desktop app: "
                              + str(pl.get("question") or "")[:300])
                elif t == "session.usage":
                    u = pl.get("usage") or {}
                    if u.get("model"):
                        turn.served["model"] = u["model"]
                    turn.served["reasoning_tokens"] = u.get("reasoning")
                elif t == "session.info" and pl.get("provider"):
                    turn.served["provider"] = pl["provider"]
                elif t == "session.replay_gap":
                    if await _recover_gap(c, turn):
                        return
                elif t == "message.complete":
                    if not pl.get("admission_id") and not pl.get("outcome") and not pl.get("status"):
                        continue  # an interim summary, not this turn's end
                    _settle(turn, pl)
                    return
                elif t in ("error", "turn.failed"):
                    turn.push("run.failed", error=pl.get("message") or pl.get("error") or "The turn failed.")
                    return
            turn.push("run.failed", error="The turn ran too long without finishing.")
    except asyncio.TimeoutError:
        turn.push("run.failed", error="Hermes went quiet for 30 minutes; check the chat on your Mac.")
    except TurnError as e:
        turn.push("run.failed", error=str(e))
    except Exception as e:  # never leave the phone hanging
        turn.push("run.failed", error="%s: %s" % (type(e).__name__, str(e)[:300]))
    finally:
        turn.client = None
        turn.finish()


def start_turn(profile, home, sid, text, choice) -> Turn:
    purge()
    with TURNS_LOCK:
        busy = [t for t in TURNS.values() if t.sid == sid and t.profile == profile and not t.done]
        if busy:
            raise TurnError("This chat is still working on the last message.", 409)
        turn = Turn(profile, home, sid, text, clean_choice(choice))
        TURNS[turn.id] = turn
    asyncio.run_coroutine_threadsafe(_drive(turn), LOOP)
    return turn


def get_turn(turn_id) -> Turn | None:
    with TURNS_LOCK:
        return TURNS.get(turn_id)


def live_turns():
    purge()
    with TURNS_LOCK:
        return [t.summary() for t in TURNS.values()]


def purge():
    now = time.time()
    with TURNS_LOCK:
        for k in [k for k, t in TURNS.items() if t.done and now - t.ended > 1800]:
            del TURNS[k]


def stop(turn: Turn):
    return run(_interrupt(turn))


def approve(turn: Turn, choice, prompt_id, generation=None):
    if not prompt_id:
        raise TurnError("Missing the approval's id.")
    gen = generation if generation is not None else turn.prompts.get(prompt_id, turn.generation)
    return run(_approve(turn, choice, prompt_id, gen))


async def _follow_up(turn, mode, text, submission):
    if mode == "queue":
        try:
            submission = uuid.UUID(str(submission)).hex
        except ValueError:
            raise TurnError("A stable submission ID is required.")
        with TURNS_LOCK:
            prior = next((t for t in TURNS.values() if t.profile == turn.profile and
                          t.sid == turn.sid and t.submission == submission), None)
        if prior:
            if prior.text != text:
                raise TurnError("Submission ID already used for another message.", 409)
            return {"status": "queued", "turn_id": prior.id}
    steer_id = None
    if mode == "steer" and submission is not None:
        try:
            steer_id = uuid.UUID(str(submission)).hex
        except ValueError:
            raise TurnError("Invalid steer submission ID.")
        prior = turn.steer_receipts.get(steer_id)
        if prior:
            if prior[0] != text:
                raise TurnError("Submission ID already used for another steer.", 409)
            return await asyncio.shield(prior[1])
    client = turn.client
    if turn.done or client is None:
        raise TurnError("This turn is no longer accepting input. Refresh the conversation.", 409)
    if mode == "steer":
        if turn.generation is None:
            raise TurnError("The gateway has not started this turn yet.", 409)
        async def steer(generation):
            result = await _rpc(client, "session.steer", session_id=turn.canonical_sid, text=text,
                                execution_generation=generation)
            if result.get("status") != "queued":
                raise TurnError("Hermes declined this instruction. You can send it as the next turn.", 409)
            return {"status": "steer_accepted", "execution_generation": generation}

        if steer_id is None:
            return await steer(turn.generation)
        delivery = asyncio.create_task(steer(turn.generation))
        turn.steer_receipts[steer_id] = (text, delivery)
        return await asyncio.shield(delivery)

    receipt = await _rpc(client, "prompt.submit", session_id=turn.canonical_sid,
                         text=text, submission_id=submission)
    admission = receipt.get("admission_id")
    if not admission or receipt.get("status") not in ("queued", "started", "terminal"):
        raise TurnError("Hermes could not confirm admission. Check the chat before retrying.", 409)
    with TURNS_LOCK:
        existing = next((t for t in TURNS.values() if t.admission == admission and t.profile == turn.profile
                         and t.sid == turn.sid), None)
        if existing:
            return {"status": "queued", "turn_id": existing.id}
        queued = Turn(turn.profile, turn.home, turn.sid, text, {})
        queued.canonical_sid = turn.canonical_sid
        queued.admission = admission
        queued.submission = submission
        if receipt.get("status") == "started":
            queued.generation = receipt.get("execution_generation")
        TURNS[queued.id] = queued
    asyncio.create_task(_drive(queued))
    return {"status": "queued", "turn_id": queued.id}


def follow_up(turn, mode, text, submission=None):
    if mode not in ("queue", "steer") or not isinstance(text, str) or not text.strip():
        raise TurnError("Enter a message to queue or steer.")
    return run(_follow_up(turn, mode, text.strip(), submission))
