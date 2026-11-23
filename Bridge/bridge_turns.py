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
import functools
import bridge_receipts
import bridge_media
import json
import sys
from collections import OrderedDict
import threading
import time
import uuid
import weakref
import sqlite3
from contextlib import asynccontextmanager, closing
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


@functools.lru_cache(maxsize=1)
def _resume_options():
    try:
        from tui_gateway.contracts.canonical_sessions import CanonicalResumeParams
        return {"omit_messages": True} if "omit_messages" in CanonicalResumeParams.__annotations__ else {}
    except ImportError:
        return {}


async def _resume(c, sid):
    # The phone already pages the transcript. Controls and send need only the session metadata.
    return await _rpc(c, "session.resume", session_id=sid, **_resume_options())


async def _mutate(c, sid, operation, payload):
    snap = await _resume(c, sid)
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


def _admission_runtime(choice):
    """Freeze the selected route on this admission, including a queued turn."""
    if not choice.get("model"):
        return {}
    return {"model_override": {key: choice[field] for key, field in (
        ("model", "model"), ("provider", "provider"), ("reasoning", "effort")) if choice.get(field)}}


async def _apply(c, sid, choice: dict) -> dict:
    applied = {}
    if choice.get("model"):
        payload = {"model": choice["model"], **({"provider": choice["provider"]} if choice.get("provider") else {})}
        if choice.get("effort"):
            # The gateway commits (or defers) a model plus reasoning as one fenced mutation.
            payload["reasoning"] = choice["effort"]
        applied["model"] = await _mutate(c, sid, "model", payload)
    elif choice.get("reset_model"):
        applied["model"] = await _mutate(c, sid, "model", {"model": "reset"})
    if choice.get("effort") and not choice.get("model"):
        applied["reasoning"] = await _mutate(c, sid, "reasoning", {"effort": choice["effort"]})
    elif choice.get("reset_effort"):
        applied["reasoning"] = await _mutate(c, sid, "reasoning", {"effort": None})
    return applied


# ---------- one-shot operations ----------

@functools.lru_cache(maxsize=1)
def _supports_create_id():
    try:
        from tui_gateway.contracts.canonical_sessions import CanonicalCreateParams
        return "request_id" in CanonicalCreateParams.__annotations__
    except ImportError:
        return False


def _created_draft(home, request_id, title):
    """Read the native creation receipt left behind when the WebSocket reply is lost."""
    try:
        from gateway.owner_identity import host_owner_subject
        from hermes_state_keys import local_identity
        from hermes_state_local import POLICY_PREFIX
        from hermes_cli.gateway_runtime import gateway_profile_home
        profile_id = str(gateway_profile_home(home))
        subject = host_owner_subject()
        sid = local_identity(profile_id, subject, request_id)
        uri = (Path(home) / "state.db").resolve().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True, timeout=0.1)) as db:
            row = db.execute("""
                SELECT 1 FROM state_meta r JOIN sessions s ON s.id = ?
                WHERE r.key = ? AND json_extract(r.value, '$.policy.source') = 'gui'
                AND (? IS NULL OR s.title = ?)
                AND json_extract(r.value, '$.session_id') = s.id
                AND json_extract(r.value, '$.request_id') = ?
                AND json_extract(r.value, '$.profile_id') = ?
                AND json_extract(r.value, '$.principal_id') = ?
                """, (sid, POLICY_PREFIX + sid, title, title, request_id, profile_id, subject)).fetchone()
        return {"session_id": sid, "stored_session_id": sid} if row else None
    except (ImportError, OSError, ValueError, sqlite3.Error):
        # Remote-only and older installs keep using the canonical gateway RPC.
        return None


async def _create(home, profile, title, request_id=None):
    params = {"source": "gui"}
    if title:
        params["title"] = title[:120]
    key = None
    if request_id is not None and _supports_create_id():
        try:
            key = uuid.UUID(str(request_id)).hex
        except ValueError:
            raise TurnError("Invalid draft ID.") from None
        params["request_id"] = key
        previous = await asyncio.to_thread(_created_draft, home, key, params.get("title"))
        if previous:
            return previous
    try:
        async with connect(home) as c:
            created = await _rpc(c, "session.create", **params)
    except Exception as exc:
        # Only transport failures can hide an acknowledged creation. Preserve RPC refusals.
        if key and (isinstance(exc, OSError) or isinstance(exc.__cause__, OSError)):
            previous = await asyncio.to_thread(_created_draft, home, key, params.get("title"))
            if previous:
                return previous
        raise
    sid = created.get("session_id") or created.get("stored_session_id")
    if not sid:
        raise TurnError("session.create returned no session id", 502)
    out = {"session_id": sid}
    if created.get("stored_session_id"):
        out["stored_session_id"] = created["stored_session_id"]
    return out


def create_session(home, profile, title=None, request_id=None):
    return run(_create(home, profile, title, request_id))


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
    if not turn.admission:
        raise TurnError("Hermes is still confirming this send. Try Stop again once it starts.", 409)

    async def go(c):
        snap = await _resume(c, turn.canonical_sid)
        row = next((r for r in snap.get("pending") or [] if r.get("admission_id") == turn.admission), {})
        if row.get("status") == "queued":
            return await _rpc(c, "prompt.cancel", session_id=turn.canonical_sid, admission_id=turn.admission)
        gen = turn.generation
        if gen is None and row.get("status") == "started":
            gen = row.get("execution_generation")
        if gen is None:
            raise TurnError("This reply has no confirmed execution to stop. Refresh the conversation.", 409)
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
        await _resume(c, turn.canonical_sid)
        return await go(c)


# ---------- live turns ----------

# Per-turn SSE history. All readers share the immutable wire representation.
REPLAY_BYTES = 2 * 1024 * 1024
REPLAY_SECONDS = 600
REPLAY_BATCH_BYTES = 64 * 1024
REPLAY_BATCH_FRAMES = 128
_SSE_ENCODER = json.JSONEncoder(separators=(",", ":"))


def _sse(event):
    payload = _SSE_ENCODER.encode(event).encode()
    return b"id: %d\ndata: " % event["seq"] + payload + b"\n\n"


class Turn:
    def __init__(self, profile, home, sid, text, choice, workspace=None):
        self.id = "turn_" + uuid.uuid4().hex
        self.profile, self.home, self.sid, self.text, self.choice = profile, home, sid, text, choice
        self.replay_epoch = uuid.uuid4().hex
        self._frames = OrderedDict()  # absolute sequence -> (monotonic insertion time, wire bytes)
        self._wire_bytes = 0
        self._head = 0  # next sequence; independent of eviction
        self._approval_frames = {}
        self._terminal = None
        self.cond = threading.Condition()
        self.done = False
        self.started = time.time()
        self.ended = 0.0
        self.journal = None
        self.prepared = False
        self.frozen_text = None
        self.media = []
        self.restored = False
        self.canonical_sid = sid
        self.submission = None
        self.admission = None
        self.generation = None
        self.client = None
        self.steer_receipts = {}
        self.prompts: dict = {}  # prompt_id -> execution_generation of approvals still open
        self.served = {}
        # Projects scope for this one turn (None = off): {store, project, profile, output_dir, suffix, summary}.
        self.workspace = workspace
        self.captured = False
        self.steered = False

    def _trim(self, now):
        while self._frames:
            when, _ = next(iter(self._frames.values()))
            if self._wire_bytes <= REPLAY_BYTES and now - when < REPLAY_SECONDS:
                break
            _, (_, wire) = self._frames.popitem(last=False)
            self._wire_bytes -= len(wire)

    def push(self, name, **fields):
        with self.cond:
            ev = {**fields, "event": name, "seq": self._head, "turn_id": self.id,
                  "session_id": self.sid, "timestamp": time.time()}
            wire = _sse(ev)
            now = time.monotonic()
            self._frames[self._head] = (now, wire)
            self._head += 1
            self._wire_bytes += len(wire)
            self._trim(now)
            prompt = fields.get("request_id")
            if name == "approval.request" and prompt:
                self._approval_frames[prompt] = ev
            elif name == "approval.resolved":
                self._approval_frames.pop(prompt, None)
            elif name in ("run.failed", "run.completed", "run.cancelled"):
                # The transcript holds the answer. Keep just its outcome after replay expires.
                self._terminal = {"event": name, "error": str(fields.get("error", ""))[:2000]}
                self._approval_frames.clear()
            self.cond.notify_all()

    def replay(self, offset, timeout=15, *, reset=False):
        """Return immutable frames, next offset, completion and whether this is a checkpoint."""
        with self.cond:
            self._trim(time.monotonic())
            if not reset and offset == self._head and not self.done:
                self.cond.wait_for(lambda: self._head != offset or self.done, timeout)
                self._trim(time.monotonic())
            first = next(iter(self._frames), self._head)
            if reset or offset < first or offset > self._head:
                checkpoint = {"event": "stream.checkpoint", "seq": self._head - 1, "turn_id": self.id,
                              "session_id": self.sid, "approvals": list(self._approval_frames.values()),
                              "terminal": self._terminal}
                return [_sse(checkpoint)], self._head, self.done, True
            frames = []
            size = 0
            while offset < self._head and len(frames) < REPLAY_BATCH_FRAMES and size < REPLAY_BATCH_BYTES:
                wire = self._frames[offset][1]
                frames.append(wire)
                size += len(wire)
                offset += 1
            return frames, offset, self.done and offset == self._head, False

    @property
    def events(self):
        """Decoded retained history for diagnostic callers. SSE readers use replay()."""
        with self.cond:
            self._trim(time.monotonic())
            return [json.loads(wire.split(b"\ndata: ", 1)[1]) for _, wire in self._frames.values()]

    def finish(self):
        with self.cond:
            self.done, self.ended = True, time.time()
            self.cond.notify_all()

    def summary(self):
        return {"turn_id": self.id, "profile": self.profile, "session_id": self.sid, "done": self.done,
                "age": int(time.time() - self.started), "events": self._head,
                "attachments": [{"mime": m["mime"], "status": "staged" if self.admission is None else "submitted"}
                                for m in self.media]}


def _tool_name(pl):
    t = pl.get("tool")
    if isinstance(t, dict):
        return t.get("name") or t.get("tool_name") or "tool"
    return pl.get("name") or pl.get("tool_name") or (t if isinstance(t, str) else None) or "tool"


_STATUS_OUTCOME = {"complete": "completed", "completed": "completed",
                   "interrupted": "cancelled", "cancelled": "cancelled", "stopped": "cancelled"}


async def _capture(turn, pl, kind):
    """Save a project turn's output files, only from this turn's own successful terminal admission."""
    ws = turn.workspace
    if not ws or turn.captured:
        return
    turn.captured = True  # one attempt; whatever happens the output directory is gone afterwards
    admission = pl.get("admission_id")
    text = pl.get("content") or pl.get("text") or ""
    matched = bool(turn.admission) and admission == turn.admission and not turn.steered and isinstance(text, str)
    try:
        if kind == "completed" and matched:
            await asyncio.to_thread(ws["store"].capture, ws["project"], turn.profile, turn.canonical_sid,
                                    ws["output_dir"], text)
    except Exception as e:  # never echo paths or content; only the store's own fixed limit message
        full = getattr(e, "code", None) == 507 and type(e).__name__ == "WorkspaceError"
        turn.push("status", text=str(e) if full else "Couldn't save this turn's project files.")
    finally:
        try:
            await asyncio.to_thread(ws["store"].discard_output, ws["output_dir"])
        except Exception:
            pass


def _outcome(pl):
    status = str(pl.get("status") or "").lower()
    outcome = str(pl.get("outcome") or "").lower()
    # Both fields describe the same terminal event. An unknown or conflicting value
    # cannot confirm that a reply completed.
    kinds = {_STATUS_OUTCOME.get(value, "failed") for value in (status, outcome) if value}
    return kinds.pop() if len(kinds) == 1 else "failed"


def _record_runtime(turn, usage):
    """A policy's provider can differ from the provider that answered after a fallback."""
    if not isinstance(usage, dict):
        return
    model = usage.get("fallback_model") or usage.get("model")
    if model:
        if turn.served.get("model") != model:
            turn.served.pop("provider", None)
        turn.served["model"] = model
    if model and (provider := usage.get("billing_provider") or usage.get("provider")):
        turn.served["provider"] = provider
    if usage.get("fallback_model"):
        turn.served["fallback"] = True
    if usage.get("reasoning") is not None:
        turn.served["reasoning_tokens"] = usage["reasoning"]


def _settle(turn, pl):
    """End the turn from a completion payload. An unknown outcome never confirms completion."""
    kind = _outcome(pl)
    outcome = str(pl.get("outcome") or "").lower()
    if kind == "cancelled":
        turn.push("run.cancelled", output=pl.get("content") or pl.get("text") or "")
    elif kind == "failed":
        msg = pl.get("error") or pl.get("content") or pl.get("text") or "The turn did not finish."
        if outcome == "unknown":
            msg = "Hermes lost track of this reply. Check the chat on your Mac before sending it again."
        turn.push("run.failed", error=msg)
    else:
        _record_runtime(turn, pl.get("usage"))
        # Native admission receipts report the actual route at the top level.
        if pl.get("model"):
            _record_runtime(turn, {"model": pl["model"], "provider": pl.get("provider")})
        turn.push("run.completed", output=pl.get("content") or pl.get("text") or "",
                  runtime=dict(turn.served), requested_model=turn.choice.get("model"), outcome=outcome or "completed")
    return kind


async def _recover_gap(c, turn, snapshot=None):
    """The event stream lost frames. True when the turn turned out to be finished (and was settled)."""
    snap = snapshot if snapshot is not None else await _resume(c, turn.canonical_sid)
    row = next((r for r in snap.get("pending") or [] if r.get("admission_id") == turn.admission), None)
    if row is not None and row.get("status") != "unknown":
        return False  # still queued or running: its completion is still owed to this socket
    try:
        receipt = await _rpc(c, "prompt.receipt", session_id=turn.canonical_sid, admission_id=turn.admission, include_result=True)
    except TurnError:
        receipt = {}
    result = receipt.get("result")
    if not isinstance(result, dict):
        result = {}
    if receipt.get("status") in ("started", "queued"):
        return False
    # "terminal" includes cancellation and worker loss. The admission's outcome
    # determines which event the phone should paint after a gap.
    outcome = receipt.get("outcome") if receipt.get("status") == "terminal" else "unknown"
    merged = {**result, "text": result.get("text") or result.get("final_response") or "",
              "status": result.get("status") or "", "outcome": outcome or "unknown",
              "admission_id": receipt.get("admission_id") or result.get("admission_id")}
    await _capture(turn, merged, _outcome(merged))
    _settle(turn, merged)
    return True


def _turn_text(turn):
    if turn.frozen_text is not None:
        return turn.frozen_text
    text = turn.text
    suffix = (turn.workspace or {}).get("suffix")
    if suffix:
        text = (text + "\n\n" if text else "") + suffix
    for item in turn.media:
        if item["mime"] == bridge_media.MP4:
            text += ("\n\nThe user attached a video clip and consented to auxiliary video processing. "
                     "Use video_analyze with video_url set to the following local file path to answer their question. "
                     "If analysis fails, explain the limitation. Local file path: " + json.dumps(item["path"]))
        elif item["mime"] != bridge_media.JPEG:
            name = item.get("name") or Path(item["path"]).name
            size = item.get("size")
            if not isinstance(size, int) or size <= 0:
                try:
                    size = Path(item["path"]).stat().st_size
                except OSError:
                    size = 0
            text += ("\n\nThe user attached a file named %s (%s, %d bytes). It is saved at the following "
                     "local path. Use an appropriate available tool to read or process it; do not execute it. "
                     "Local file path: %s" % (json.dumps(name), item["mime"], size, json.dumps(item["path"])))
    return text


async def _drive_connection(turn: Turn):
    if turn.journal and turn.admission is None and time.time() - turn.started >= 3 * 3600:
        turn.push("run.failed", error="The original send expired. Check the saved chat before sending again.")
        return
    async with connect(turn.home) as c:
        snapshot = await _resume(c, turn.sid)
        canonical = snapshot.get("session_id") or turn.sid
        if turn.prepared and turn.canonical_sid != canonical:
            raise TurnError("The original chat identity changed. Check its history before sending again.", 409)
        turn.canonical_sid = canonical
        if turn.workspace and (snapshot.get("stored_session_id") != turn.sid or turn.canonical_sid != turn.sid):
            # The chat the phone named is not the one the gateway resumed: send nothing, attach nothing.
            turn.push("run.failed", error="This chat's identity could not be confirmed. Nothing was sent.")
            return
        following_queue = turn.admission is not None
        applied = await _apply(c, turn.sid, turn.choice) if turn.choice and not following_queue and not turn.prepared else {}
        if turn.journal and not turn.prepared:
            await asyncio.to_thread(turn.journal.prepared, turn)
            turn.prepared = True
        params = {"session_id": turn.sid, "submission_id": turn.submission or uuid.uuid4().hex, "text": _turn_text(turn)}
        images = [m for m in turn.media if m["mime"] == bridge_media.JPEG]
        if images:
            params["attachments"] = [{"path": m["path"], "mime": m["mime"]} for m in images]
        params.update(_admission_runtime(turn.choice))
        if following_queue:
            if await _recover_gap(c, turn, snapshot):
                return
            for prompt in snapshot.get("prompts") or []:
                if (prompt.get("kind") == "approval" and prompt.get("prompt_id") and turn.generation is not None
                        and prompt.get("execution_generation") == turn.generation):
                    pid = prompt["prompt_id"]
                    turn.prompts[pid] = turn.generation
                    turn.push("approval.request", request_id=pid, execution_generation=turn.generation,
                              command=prompt.get("command") or "", description=prompt.get("description") or "",
                              choices=prompt.get("choices") or ["once", "deny"])
        else:
            params["session_id"] = turn.canonical_sid
            receipt = await _rpc(c, "prompt.submit", **params)
            turn.admission = receipt["admission_id"]
            turn.generation = receipt.get("execution_generation")
            if turn.journal:
                await asyncio.to_thread(turn.journal.admitted, turn)
                await asyncio.to_thread(bridge_media.discard, images)
                if receipt.get("status") == "terminal" and await _recover_gap(c, turn):
                    return
        turn.client = c
        extra = {"project_context": turn.workspace["summary"]} if (turn.workspace or {}).get("summary") else {}
        turn.push("run.started", requested=turn.choice, applied=bool(applied), **extra)
        deadline = turn.started + 3 * 3600
        while time.time() < deadline:
            try:
                frame = await asyncio.wait_for(c.events.get(), 20 if following_queue or turn.journal else 1800)
            except asyncio.TimeoutError:
                if not following_queue and not turn.journal:
                    raise
                if await _recover_gap(c, turn):
                    return
                continue
            if isinstance(frame, BaseException):
                if turn.journal:
                    raise ConnectionError("Hermes disconnected before confirming the final receipt.")
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
                _record_runtime(turn, pl.get("usage"))
            elif t == "session.replay_gap":
                if await _recover_gap(c, turn):
                    return
            elif t == "message.complete":
                if not pl.get("admission_id") and not pl.get("outcome") and not pl.get("status"):
                    continue  # an interim summary, not this turn's end
                await _capture(turn, {**pl, "admission_id": admission}, _outcome(pl))
                _settle(turn, pl)
                return
            elif t in ("error", "turn.failed"):
                turn.push("run.failed", error=pl.get("message") or pl.get("error") or "The turn failed.")
                return
        turn.push("run.failed", error="The turn ran too long without finishing.")

async def _drive(turn: Turn):
    try:
        # RPC acknowledgments can be lost after a durable write. Reopening the same
        # canonical session with the same native submission_id retrieves that write.
        delay = 1
        while True:
            try:
                await _drive_connection(turn)
                break
            except Exception as exc:
                unavailable = isinstance(exc, (OSError, asyncio.TimeoutError, EOFError)) or (
                    isinstance(exc, TurnError) and exc.code == 503
                ) or type(exc).__name__ in ("ConnectionClosed", "ConnectionClosedError", "ConnectionClosedOK",
                                             "GatewayClientError", "GatewayUnavailableError")
                if not turn.journal or not unavailable:
                    raise
                if time.time() - turn.started > 3 * 3600:
                    turn.push("run.failed", error="The receipt is unavailable. Check the saved chat before sending again.")
                    break
                turn.client = None
                turn.push("status", text="Reconnecting to your original send…")
                await asyncio.sleep(delay)
                delay = min(60, delay * 2)
    except asyncio.TimeoutError:
        turn.push("run.failed", error="Hermes went quiet for 30 minutes; check the chat on your Mac.")
    except TurnError as e:
        turn.push("run.failed", error="Hermes couldn't process this project turn." if turn.workspace else str(e))
    except Exception as e:  # never leave the phone hanging
        turn.push("run.failed", error="Hermes couldn't process this project turn." if turn.workspace else
                  "%s: %s" % (type(e).__name__, str(e)[:300]))
    finally:
        turn.client = None
        ws = turn.workspace
        if ws and not turn.captured:
            turn.captured = True
            try:
                ws["store"].discard_output(ws["output_dir"])
            except Exception:
                pass
        try:
            if turn.journal and turn._terminal:
                await asyncio.to_thread(bridge_media.discard, turn.media)
                await asyncio.to_thread(turn.journal.terminal, turn, turn._terminal)
        finally:
            turn.finish()


# Contenders keep their lock alive while waiting. Idle chat/submission keys disappear.
_admission_locks = weakref.WeakValueDictionary()
_admission_registry_lock = threading.Lock()


def _admission_lock(key):
    with _admission_registry_lock:
        lock = _admission_locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _admission_locks[key] = lock
        return lock


def start_turn(profile, home, sid, text, choice, workspace=None) -> Turn:
    purge()
    with _admission_lock((profile, sid)), TURNS_LOCK:
        busy = [t for t in TURNS.values() if t.sid == sid and t.profile == profile and not t.done]
        if busy:
            raise TurnError("This chat is still working on the last message.", 409)
        turn = Turn(profile, home, sid, text, clean_choice(choice), workspace)
        TURNS[turn.id] = turn
    asyncio.run_coroutine_threadsafe(_drive(turn), LOOP)
    return turn


@functools.lru_cache(maxsize=8)
def primary_journal(directory):
    return bridge_receipts.Journal(directory)


def restored_turn(row, home, journal, restore_workspace):
    metadata = json.loads(row["workspace"] or "null")
    workspace = restore_workspace(metadata, row["profile"], row["sid"]) if metadata else None
    turn = Turn(row["profile"], home, row["sid"], "", json.loads(row["choice"]), workspace)
    turn.id = row["id"]
    turn.media = json.loads(row["media"] or "[]")
    turn.submission = turn.id[5:]
    turn.journal, turn.restored = journal, True
    turn.started, turn.steered = row["started"], bool(row["steered"])
    turn.prepared = row["canonical"] is not None
    turn.canonical_sid = row["canonical"] or turn.sid
    turn.admission, turn.generation, turn.frozen_text = row["admission"], row["generation"], row["prompt"]
    if row["terminal"]:
        marker = json.loads(row["terminal"])
        turn.push(marker["event"], **({"error": marker["error"]} if marker.get("error") else {}))
        turn.finish()
    else:
        turn.push("turn.restored")
    with TURNS_LOCK:
        TURNS[turn.id] = turn
    if not turn.done:
        asyncio.run_coroutine_threadsafe(_drive(turn), LOOP)
    return turn


def match_receipt(profile, sid, text, request, directory):
    """Read-only confirmation of the exact durable send, even after media cleanup."""
    try:
        turn_id = "turn_" + uuid.UUID(str(request.get("submission_id"))).hex
    except ValueError:
        raise TurnError("Invalid submission ID.") from None
    manifest = request.get("manifest")
    if not isinstance(manifest, list) or not 1 <= len(manifest) <= bridge_media.MAX_ITEMS:
        raise TurnError("Invalid attachment manifest.")
    frames = []
    for item in manifest:
        if not isinstance(item, dict) or any(not isinstance(item.get(k), str) for k in ("filename", "mime", "sha256")):
            raise TurnError("Invalid attachment manifest.")
        frames.append((item["filename"], item["sha256"], None, item["mime"]))
    row = primary_journal(directory).get(turn_id)
    if row is None or row["media_types"] is None:
        # Older receipts omitted image/video types from their fingerprint. Use
        # the original validated upload path when those types cannot be proved.
        raise TurnError("No media receipt available.", 404)
    digest = bridge_receipts.fingerprint(profile, sid, text, clean_choice(request), request.get("project_context"), frames)
    if row["fingerprint"] != digest or json.loads(row["media_types"]) != [frame[3] for frame in frames]:
        raise TurnError("This submission ID belongs to a different send.", 409)
    return {"turn_id": turn_id}


def start_primary(profile, home, sid, text, choice, submission, project, directory, prepare, restore_workspace, attachments=None, video_consent=False):
    try:
        id = "turn_" + uuid.UUID(str(submission)).hex
    except (TypeError, ValueError):
        raise TurnError("A stable submission UUID is required.")
    choice = clean_choice(choice)
    try:
        frames = bridge_media.decode(attachments)
    except bridge_media.MediaError as exc:
        raise TurnError(str(exc)) from None
    clip = bool(frames and frames[0][3] == bridge_media.MP4)
    if clip and video_consent is not True:
        raise TurnError("Select the clip option to allow auxiliary video processing.")
    digest = bridge_receipts.fingerprint(profile, sid, text, choice, project, frames)
    journal = primary_journal(directory)
    # Probe outside the global admission lock. A retry of an existing request
    # still recovers its original receipt if the profile later disables video.
    if clip and journal.get(id) is None and not bridge_media.video_supported(home):
        raise TurnError("This bot cannot analyze video clips. Send reviewed frames instead.")
    purge()
    # Always take submission then chat. Disk staging and SQLite commits must not
    # block unrelated sends, stop/steer lookups, or a different phone's live list.
    with _admission_lock(id), _admission_lock((profile, sid)):
        existing = journal.get(id)
        if existing:
            if (existing["fingerprint"] != digest or
                    existing["media_types"] is not None and json.loads(existing["media_types"]) != [frame[3] for frame in frames]):
                raise TurnError("This submission ID belongs to a different send.", 409)
            return get_turn(id) or restored_turn(existing, home, journal, restore_workspace)
        with TURNS_LOCK:
            if any(t.profile == profile and t.sid == sid and not t.done for t in TURNS.values()):
                raise TurnError("This chat is still working on the last message.", 409)
        ws = prepare()
        turn = Turn(profile, home, sid, text, choice, ws)
        turn.id, turn.submission, turn.journal = id, id[5:], journal
        try:
            turn.media = bridge_media.stage(frames, home)
            journal.create(turn, digest, _turn_text(turn))
        except BaseException:
            bridge_media.discard(turn.media)
            if ws:
                ws["store"].discard_output(ws["output_dir"])
            raise
        with TURNS_LOCK:
            TURNS[id] = turn
        asyncio.run_coroutine_threadsafe(_drive(turn), LOOP)
        return turn


def recover_primary(directory, profile_home, restore_workspace):
    journal = primary_journal(directory)
    # A phone can restore a staged send after months offline. Its UUID must still resolve to
    # the original outcome; terminal() already removes the prompt, workspace and media.
    for row in journal.pending():
        with _admission_lock(row["id"]), _admission_lock((row["profile"], row["sid"])):
            if get_turn(row["id"]) is not None:
                continue
            try:
                restored_turn(row, profile_home(row["profile"]), journal, restore_workspace)
            except Exception as error:
                # TurnError: a project grant or identity was withdrawn, so never revive its context.
                # Anything else (workspace storage offline, a damaged row) fails this one send. Letting
                # it escape would stop the bridge at startup and loop under its supervisor.
                if not isinstance(error, TurnError):
                    print("Could not recover send %s: %s" % (row["id"], type(error).__name__), file=sys.stderr, flush=True)
                try:
                    turn = Turn(row["profile"], profile_home(row["profile"]), row["sid"], "", {})
                    turn.id = row["id"]
                    bridge_media.discard(json.loads(row["media"] or "[]"))
                    journal.terminal(turn, {"event": "run.failed"})
                except Exception as nested:
                    print("Could not close send %s: %s" % (row["id"], type(nested).__name__), file=sys.stderr, flush=True)


def completed_primary(turn_id, directory, profile_home):
    with _admission_lock(turn_id):
        live = get_turn(turn_id)
        if live is not None:
            return live
        journal = primary_journal(directory)
        row = journal.get(turn_id)
        if row is not None and row["terminal"]:
            return restored_turn(row, profile_home(row["profile"]), journal, None)
    return None


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


async def _follow_up(turn, mode, text, submission, choice=None):
    choice = clean_choice(choice) if mode == "queue" else {}
    if choice.get("effort") and not choice.get("model"):
        raise TurnError("Select a model to set an effort for this queued message.")
    if mode == "queue":
        try:
            submission = uuid.UUID(str(submission)).hex
        except ValueError:
            raise TurnError("A stable submission ID is required.")
        with TURNS_LOCK:
            prior = next((t for t in TURNS.values() if t.profile == turn.profile and
                          t.sid == turn.sid and t.submission == submission), None)
        if prior:
            if prior.text != text or prior.choice != choice:
                raise TurnError("Submission ID already used for another message or runtime.", 409)
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
            if turn.journal and turn.workspace:
                # A lost steer acknowledgment must never allow mixed project output to be captured.
                await asyncio.to_thread(turn.journal.suppress_capture, turn)
                turn.steered = True
            result = await _rpc(client, "session.steer", session_id=turn.canonical_sid, text=text,
                                execution_generation=generation)
            if result.get("status") != "queued":
                raise TurnError("Hermes declined this instruction. You can send it as the next turn.", 409)
            turn.steered = True  # the answer may now blend a second instruction: never captured as project output
            return {"status": "steer_accepted", "execution_generation": generation}

        if steer_id is None:
            return await steer(turn.generation)
        delivery = asyncio.create_task(steer(turn.generation))
        turn.steer_receipts[steer_id] = (text, delivery)
        return await asyncio.shield(delivery)

    receipt = await _rpc(client, "prompt.submit", session_id=turn.canonical_sid,
                         text=text, submission_id=submission, **_admission_runtime(choice))
    admission = receipt.get("admission_id")
    if not admission or receipt.get("status") not in ("queued", "started", "terminal"):
        raise TurnError("Hermes could not confirm admission. Check the chat before retrying.", 409)
    with TURNS_LOCK:
        existing = next((t for t in TURNS.values() if t.admission == admission and t.profile == turn.profile
                         and t.sid == turn.sid), None)
        if existing:
            return {"status": "queued", "turn_id": existing.id}
        queued = Turn(turn.profile, turn.home, turn.sid, text, choice)
        queued.canonical_sid = turn.canonical_sid
        queued.admission = admission
        queued.submission = submission
        if receipt.get("status") == "started":
            queued.generation = receipt.get("execution_generation")
        TURNS[queued.id] = queued
    asyncio.create_task(_drive(queued))
    return {"status": "queued", "turn_id": queued.id}


def follow_up(turn, mode, text, submission=None, choice=None):
    if mode not in ("queue", "steer") or not isinstance(text, str) or not text.strip():
        raise TurnError("Enter a message to queue or steer.")
    return run(_follow_up(turn, mode, text.strip(), submission, choice))
