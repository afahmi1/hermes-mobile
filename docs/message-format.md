# Message format

This is the contract between Hermes (and any agent writing into a Hermes chat) and the phone. It says what
each kind of message is on the wire, how the bridge shapes it, and how the app renders it. Agents can use the
last section as a style guide: write replies this way and they read well on a phone.

Source of truth:
- Bridge: `Bridge/bridge_transcript.py` (`project_timeline_message`, `activity_details`, `safe_file`)
- App: `App/Sources/Models.swift` (`StoredMessage`, `ActivityEntry`, `MarkdownBlock`),
  `App/Sources/ChatModel.swift` (`ChatModel.transcript`), `App/Sources/Views/MarkdownText.swift`,
  `App/Sources/Views/ChatView.swift` (`MessageRow`, `ActivityCard`, `TranscriptFile`)
- Tests: `Tests/MessageFormatTests.swift`, `Tests/test_activity_cards.py`, `Tests/test_reply_files.py`

## 1. Layers

```
Hermes state.db row ─▶ bridge projection (one timeline row) ─▶ app ChatItem ─▶ MessageRow view
```

| Layer | Shape | Who decides |
|---|---|---|
| state.db `messages` | `role`, `content`, `tool_calls`, `display_kind`, `display_metadata` | Hermes |
| timeline row | `id`, `role`, `content`, `timestamp`, optional `media[]`, `tool_calls[]`, `notice`, `ok`, `activity[]` | bridge |
| `ChatItem` | `kind` = user, assistant, tools, activity, notice, control | app |

Rows with `display_kind: "hidden"` never reach the phone. Reasoning never reaches the phone.

## 2. Kinds

| Kind | Comes from | Renders as |
|---|---|---|
| **user** | `role: user` with text or media | Right-aligned accent bubble. Long messages (over 700 characters or 14 lines) fold to 10 lines with "Show full message". |
| **assistant** | `role: assistant` with text or media | Full width, no bubble, rendered Markdown (section 3). The last reply of a finished turn gets an action row: Copy, Pin, Quote, Share, model, time. |
| **tools** | assistant `tool_calls` | One collapsed line summarizing the group ("Explored 3 places, Ran 2 commands · 1 failed"). Open it for one row per call with an icon per tool kind; running calls pulse. |
| **activity** | `display_kind` `process_complete` or `async_delegation_complete`, or a body starting `[IMPORTANT: Background process`, `[ASYNC DELEGATION ...`, `[SUBAGENT`, `[BACKGROUND PROCESS` | An activity card (section 4). |
| **notice** | Slash command results, stops, local notes | Small centered caption. |
| **control** | A "Send next" or "Guide this reply" the phone sent | Right-aligned receipt: "Queued for the next turn · 2 files" or "Steer received by Hermes". |

A new calendar day in the transcript gets a separator: Today, Yesterday, the weekday, or the date.

## 3. Markdown in replies

The app parses replies into blocks (`MarkdownBlock.parse`). Inline styling inside a block uses Apple's
Markdown parser (bold, italic, strikethrough, links, `code`).

| Block | Syntax | Renders as |
|---|---|---|
| Paragraph | plain lines | Text, single newlines kept |
| Heading | `#` to `######` and a space | Bold title; `#hashtag` stays text |
| List | `-`, `*`, `+`, `1.`, `1)`; `- [ ]` and `- [x]` | Hanging indent, nested by two spaces, checkboxes ☐ ☑; indented lines continue the item |
| Quote | `> text` | Grey rule and secondary text |
| Callout | `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]` | Tinted box with an icon and title |
| Code | ```` ```lang ```` or `~~~` | Card with a header and the code below (see below) |
| Table | `| a | b |` with a `|---|` rule | Scrollable grid with a "Copy table" button that copies Markdown |
| Rule | `---`, `***`, `___` | Divider |

**Code blocks**
- The header shows the file name when the fence names one (`python title=build.py`, `file=`, or a bare
  `build.py`), otherwise the language in words (`bash` reads Bash, `cpp` reads C++, no language reads Code).
- Header buttons: **Wrap** toggles line wrapping (off by default, so code scrolls sideways) and **Copy**
  copies the code without its trailing newline, then shows a checkmark for 1.2 seconds.
- Long-press the code for Copy, Copy as Markdown (fenced), Wrap Lines and Share.
- Blocks over 28 lines fold to 24 with "Show all N lines".
- An unclosed fence (a reply still streaming) already renders as code with a spinner; Copy waits until it closes.

**Inline code** is a monospaced chip. Tapping it copies it. This is deliberate: short tokens such as a path, a
flag or an id are the thing people most often want on the clipboard.

**Message actions** (long-press any message):
- Copy (assistant: plain text with Markdown markers removed and code kept verbatim)
- Copy as Markdown (assistant)
- Select Text (opens the message in a sheet where any span can be selected)
- Copy Code (one block), or a submenu with every block
- Reply with Quote (puts `> quoted lines` in front of the draft)
- Edit as New Message (user messages: replaces the draft)
- Pin or Unpin
- Share

Every copy confirms itself with a small "Copied" pill and a haptic.

## 4. Activity cards (background work)

The bridge parses background results into `activity[]`. Old app builds still get `notice` and a short `content`.

```json
{
  "role": "system",
  "display_kind": "process_complete",
  "notice": "2 commands finished · 1 failed",
  "ok": false,
  "activity": [
    {"type": "process", "status": "ok", "exit_code": 0, "label": "build.py --mesh", "cwd": "plate B",
     "command": "cd … && python build.py --mesh", "output": "last lines…"},
    {"type": "task", "status": "failed", "state": "interrupted", "label": "Render the reprints",
     "duration": "7m25s", "api_calls": 14, "model": "gpt-6.2-astra", "output": "result summary…"}
  ]
}
```

- `status`: `ok`, `failed`, `stopped` (signals -15, -9, 137, 143, or no exit code) or `warning`.
- `label` names the program that mattered, not the plumbing (`command_label`). It skips `cd`, `env`, variable
  assignments, `timeout`, `nohup` and similar wrappers, redirections and pipes, and long hex ids. It names the
  script rather than the interpreter (`build.py --mesh`, not `python`). `cwd` is the folder from the last `cd`.
- Titles read like sentences: "run-swift.sh finished", "brute was stopped", "oracle4.py failed (exit 2)",
  "2 subagent tasks finished · 1 failed".
- The card shows each entry with a status glyph and a meta line ("in plate B", "gpt-6.2-astra · 14 calls ·
  7m25s"). An exit code appears only when it is not zero, in red. Open the card for the exact command and the
  last lines of output, each in a code block with Copy.

## 5. Files and images in replies

A reply hands the phone a file with a line of its own:

```
MEDIA:/absolute/path/to/file.pdf
```

`![alt](/absolute/path.png)` and `[Image attached at: /path]` also work. The bridge removes the marker from the
text and attaches `{"name", "digest", "kind": "image" | "file"}`. Images show inline; other files show as a chip
that downloads the file and opens it in Quick Look (read, play, view 3D/AR, share, save to Files).

Rules (`safe_file`):
- Types: images, PDF, text and code, Office and iWork files, EPUB, ZIP, audio and video, STL, 3MF, OBJ, USDZ and
  STEP. Up to 32 MB.
- Hermes's own replies may point anywhere in the Mac user's home folder. What a phone typed is confined to the
  Hermes home. Set `HERMES_MOBILE_REPLY_FILES=hermes` to confine replies too.
- Never served, whatever a message says: dotted folders other than `.hermes` and `.t3` (`.ssh`, `.aws`,
  `.config`…), names that look like credentials (`auth`, `token`, `secret`, `password`, `credential`,
  `cookie`, `id_rsa`…), `.env`, `.pem`, `.key`, `.p12`, databases, and any file at the top of a Hermes home or
  profile (`config.yaml`, `.env`, `auth.json`).

## 6. Pins

Pins are per chat, per bridge, newest first, at most 100 per chat. See `Bridge/bridge_pins.py`.
- `GET /m/pins/<bot>/<chat>`, `POST` it with `{"message_id": n}`, `DELETE` it (unpin all) or
  `DELETE /m/pins/<bot>/<chat>/<message id>`.
- The bridge snapshots the message text from state.db at pin time, so a pin survives compression.
- Session rows carry `pin_count`. Archiving a chat with pins needs `confirm_pins: true` (409 `has_pins` without
  it); archiving never deletes pins.

## 7. Writing replies for the phone (agents)

Write so the useful part can be lifted with one tap:
1. Put anything meant to be pasted (a command, a config block, a message draft, a URL list) in its own fenced
   block, one block per thing to paste, with a language: ```` ```bash ````, ```` ```json ````, ```` ```text ````.
   Name the file when it is one: ```` ```yaml title=config.yaml ````.
2. Put short copyable tokens (a path, an id, a flag, a model name) in `inline code`.
3. Lead with the answer. Use short headings and lists for steps. Number steps that must run in order.
4. Use `> [!WARNING]` for anything destructive or irreversible, and `> [!NOTE]` for side information.
5. Keep tables to three or four narrow columns; wide data belongs in a code block or a file.
6. Send files with `MEDIA:/absolute/path` on its own line instead of pasting a long file into the chat.
7. Don't wrap a whole reply in a code block. The copy button should copy one useful thing.
