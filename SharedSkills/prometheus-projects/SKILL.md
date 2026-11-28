---
name: prometheus-projects
description: Use when asked to make a chat into a project, or to notice a recurring topic across chats. Turn chats into populated Prometheus projects.
---

# prometheus-projects

Let Hermes make a project from a chat, right from inside the chat. The project lands in the Prometheus (Hermes
Mobile) phone app's Projects tab with its title, summary, instructions, context, relevant files and the source
chats linked. No form, no manual setup.

## When

- He asks in words: "make this a project", "turn this into a project", "add this to my projects", "project this",
  or anything that means the same. Do it in that chat, no questions, no confirmation.
- He did NOT ask but the same topic keeps coming back across several chats over days. You may notice it and offer,
  or just make a "Spotted by Hermes" project for him to keep or dismiss on the phone. Do not nag: one project per
  topic, never re-suggest a topic he dismissed.

The bridge also scans on its own (daily), so noticing by hand is optional and secondary to the explicit trigger.

## How (explicit trigger)

From any terminal on the Mac, run:

    hm-project create --profile <profile> --session <session_id>

- `<profile>`: the bot's profile id. `default` is the main bot; a profile under ~/.hermes/profiles/<name> uses
  `<name>`.
- `<session_id>`: the canonical id of this conversation (what you have as the current session). It may be the
  active or a parent session; the CLI resolves the whole conversation.

The command talks to the bridge on 127.0.0.1, signs itself with a key only a local process can derive, and prints
the new project id and title when done. It blocks until the draft is written, so wait for it. On failure it prints
the reason; report it and offer to try again, do not fabricate a result.

To preview what the background pass would create without making anything:

    hm-project detect            # dry run: prints candidate topics and what it would title them
    hm-project detect --live     # really make one spotted project now (the daily pass already does this)

## Rules

- Only make a project for a real, ongoing piece of work. Never for a routine (check-ins, status pings) or chats
  that merely share a word. The detector re-checks this with one LLM pass; you should apply the same judgment.
- Never pool trading, portfolio or finance chats into a project. The bridge refuses those profiles on its own.
- The project is built from the chats themselves. Do not hand it secrets, keys or tokens; the bridge skips any
  file that looks like a credential.
- Idempotent: re-running on the same chats updates that project instead of making a duplicate.
- If the project already exists, prefer linking the chat to it (or just say it exists) over making a new one.

## What the project contains

Title and summary; instructions in his voice (short, spartan, no em dashes); a Context.md with key facts,
decisions, open questions and current state; files the chats named that still exist on disk; and the chats linked.

## Troubleshooting

- `hm-project: command not found`: the bridge isn't installed on this Mac yet. Point him to Bridge/install.sh.
- "Bad or reused local signature" or "This is only for Hermes on this Mac": the command must run on the same Mac
  as the bridge, as the same user.
- "This bot isn't set up for projects": the profile isn't in the workspace allowlist, or the bridge can't read
  its chats. Report it plainly; do not work around it.
