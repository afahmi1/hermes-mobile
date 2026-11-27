# Message delivery: where a message lives, and what survives what

This is the contract. If you change send, queue, steer or recovery code, keep this table true and keep the tests that
prove it passing (`Tests/test_queue_controls.py`, `Tests/test_primary_receipts.py`, the Swift `DeviceAccounts` suite).

There are three kinds of outgoing message:

| Kind | What the person did | Hermes verb |
|---|---|---|
| **First send** | Send, while nothing is running | `prompt.submit` (journaled by the bridge) |
| **Send next** (queue) | Send, while a reply is running | `prompt.submit` again; Hermes queues it behind the running turn |
| **Guide this reply** (steer) | Touch and hold Send, then Guide | `session.steer` |

## The life of a message

```
 phone disk ──▶ bridge ──▶ Hermes state.db (session_admissions) ──▶ running ──▶ transcript
 (outbox)       (relay)     queued / started / unknown / terminal
```

1. **On the phone.** The message is written to the app's protected Application Support folder
   (`HermesOutbox/<account>/<chat>`, `.completeFileProtection`, excluded from backups) **before** any network call.
   First sends use the one-slot `PendingSend` record. Send next and Guide use the `.followups` list (`Outgoing`). Each has a
   UUID minted once, at the moment of Send.
2. **On the Mac.** The phone posts with that UUID. Hermes keys admissions by `(principal, session, submission_id)`, so a
   retry of a message that already arrived returns the **same** admission instead of filing a copy. From here the
   message is in Hermes's `state.db`, not in the bridge's memory.
3. **Running.** Once Hermes starts it, it leaves the phone's outbox and appears in the transcript.

## What survives what

| Failure | First send | Send next (queue) | Guide (steer) |
|---|---|---|---|
| App closed, killed or crashed before it reached the Mac | Kept on disk. Sent again with the same UUID next time the chat opens. | Kept on disk. Same. | Kept on disk. Sent when the chat opens; if that reply has finished by then it goes as the next message, with a note saying so. |
| Phone offline / Mac asleep / Tailscale down | Waits, retries quietly (backoff 2 s to 30 s, wakes on foreground). | Same. The tray says "Saved on this phone · sends when your Mac answers". | Same. |
| Request reached the Mac but the reply to the phone was lost | The retry uses the same UUID; Hermes returns the existing admission. One copy. | Same. | Same within the bridge's lifetime (steer receipts are kept per running turn). |
| The reply it was queued behind finished before it got there | n/a | Goes out as an ordinary next message, same UUID. | Goes out as the next message, with a note. |
| **Bridge restarts** | The bridge journal (`bridge_receipts`) resumes the admission and reads its final receipt. | Safe: the queued admission is in Hermes's `state.db`. The phone still lists it and reconciles against `GET …/queue`. | A steer already handed to Hermes is applied or not by Hermes; the phone shows its receipt. |
| **Gateway restarts while a reply is running** | That reply is marked `unknown` by Hermes (it never silently replays started work). The phone shows "Hermes lost track of this reply". | **Kept.** Queued rows stay `queued` across the restart. Hermes then **pauses the queue** behind the lost reply until someone acknowledges it. The phone shows *Hermes restarted mid-reply* with **Continue** (`prompt.resolve_unknown`), and the bridge keeps following the queued message across the reconnect instead of reporting failure. | A steer that was in flight is marked `interrupted` by Hermes (never replayed). |
| Gateway restarts while the message is only queued | n/a | Kept, and runs when its turn comes. | n/a |
| The bridge refuses the content (too big, bad type) | Returned to the composer with the reason. | Stays in the tray marked "Didn't send", with the reason. Tap to edit. Later messages wait behind it so order is kept. | Same. |

Two things are deliberately **not** automatic:

* **A lost reply is never resent automatically.** Hermes may have run tools before the restart. Resending could repeat
  them, so the person decides (Copy cut-off message, then send it again if they want).
* **A paused queue is not resumed automatically.** Messages queued after a lost reply often depend on it. Continue is
  one tap.

## Editing and cancelling

| Where the message is | Edit | Remove / back to message box | Guide now |
|---|---|---|---|
| Only on the phone, never attempted | Instant, local. | Instant. | Switches it to a steer. |
| Attempted, not confirmed (maybe on the Mac) | Saved as a pending edit. The original is confirmed with its UUID first, then edited on the Mac. No duplicate either way. | Cancels on the Mac if it got there. | |
| On the Mac, still queued | `prompt.replace_queued`: cancel plus a new admission in one write. It keeps its place behind the running reply. | `prompt.cancel`. | `prompt.steer_queued`. |
| Already started | Refused ("Hermes already started that message"); the edit goes to the message box. | Refused; it is running. Use Stop. | n/a |
| A steer that may have reached the running reply | Not editable (it can't be taken back). | Allowed (removes the local copy only). | n/a |

The bridge advertises these controls as `queue_controls_v1` in `GET /m/capabilities`. An older bridge still delivers
queued messages; the phone then hides edit and remove for rows already on the Mac.

## Big files (videos, screen recordings, long audio)

Files over 8 MB don't ride inside the message. The phone keeps the file in its own upload folder
(`HermesUploads/`, by name, so app updates can't break the path) and sends it to the bridge in 8 MB chunks.

1. `POST /m/uploads {upload_id, filename, mime, size, sha256}`. The id comes from the file's own checksum, so a
   retry or a relaunch always resumes the same upload. Announcing again returns where it got to.
2. `PATCH /m/uploads/<id>` with `Upload-Offset: <n>` and the raw bytes. A chunk at the wrong offset answers 409 with
   the real one (a lost acknowledgment never duplicates data); the phone just continues from there.
3. After the last byte the bridge checks the SHA-256. A mismatch answers 422 and restarts from 0.
4. The message then carries `{filename, mime, upload_id}` instead of base64. The bridge hard-links the finished file
   into the bot's staging folder (no second copy) and Hermes reads it by path.

Wi-Fi to cellular, a Tailscale blip or the Mac waking up: the phone waits 2 s to 30 s, asks for the offset, and
continues. The limit per file is `HERMES_MOBILE_UPLOAD_MAX_BYTES` (default 2 GB). The bridge refuses up front if the
Mac doesn't have room. Unfinished uploads are removed after 24 hours; the phone removes its copies after 30 days.
For videos the app also offers **Send the original video file**: the recording exactly as made, no re-encoding.

## Chat actions (archive, pin, flags)

Archive, unarchive, pinning a chat and pinning or unpinning a message work offline too. When the Mac can't be
reached (no route, timeout, or the bridge or Tailscale Serve answering 502/503/504), the action is saved to
`HermesOutbox/actions.json` on the phone and the list updates right away. A bar at the bottom of the chat list says
"N changes waiting for your Mac". The phone sends them oldest first when the app comes back, when the network
changes, or after a quiet backoff (2 s, doubling to 30 s).

Each of these actions sets a final state, so replaying one that already landed changes nothing. If the Mac refuses
one (for example, a chat gained pins in the meantime), it stays in the bar as "didn't apply" until you cancel it.
Actions belong to the gateway they were taken on and wait if you switch to another.

## Bridge API

```
GET  /m/chat/<bot>/<chat>/queue                       → {pending:[…], paused, lost, running}
POST /m/chat/<bot>/<chat>/queue/<admission>/edit      {text, submission_id}
POST /m/chat/<bot>/<chat>/queue/<admission>/cancel
POST /m/chat/<bot>/<chat>/queue/<admission>/steer
POST /m/chat/<bot>/<chat>/queue/<admission>/resolve   (only for the lost row: unpauses the queue)
```

Each row has `admission_id`, `status` (`queued | started | steering | unknown`), `text`, and
`can_edit / can_steer / can_cancel`. Refusals come back as plain sentences with HTTP 409 or 404, never raw gateway
codes.

## How to check it yourself

* Unit: `python -m unittest Tests.test_queue_controls` covers queue listing, paused detection, edit re-pointing the
  live follower, resolve with the lost row's generation, cancel, plain-word refusals, and a queued follow-up that
  survives a dropped gateway connection.
* Live, read-only: resume any chat through the bridge code and call `prompt.replace_queued`, `prompt.steer_queued` and
  `prompt.cancel` with a made-up admission id. A current gateway answers `not_found` for each (the verb exists);
  an old one answers `unknown method`.
* End to end, with a disposable chat: send a long prompt, queue two messages, edit the second from the tray, force-quit
  the app, reopen. Both should be listed, the edit applied, and each should run exactly once.
