# Projects catalog (V1)

The Projects tab reads a curated JSON file from your Mac bridge. It does not infer projects from chats or create Obsidian notes. Inventory and backfill can generate the file separately. Projects have their own stable IDs; a project can have zero, one, or many bots, and a bot can appear in several projects.

## Configure the Mac bridge

1. Save the catalog **outside** the bridge checkout in a private directory. Use a regular file with a single hard link and an absolute path with no symlink components; use the real path if an alias or a symlink is in the typed path. Use restrictive permissions (e.g. `0600` for the file). Do not commit the catalog.
2. On setup or when enabling Projects, supply the setting to the bridge installer (this restarts the bridge LaunchAgent):

   ```sh
   HERMES_MOBILE_PROJECTS_CATALOG=/absolute/private/path/projects.json Bridge/install.sh
   ```

   A manually launched bridge also accepts the setting as a process environment variable. To disable Projects, omit it. Updating or atomically replacing the file at the same path doesn't require a restart; pull to refresh in the app.

The filename is known only to the local process. Every valid bridge bearer token can read the entire catalog, so include only metadata you intend to see from signed-in devices. There is no provider scan, vault scan, file download, URL fetch, file write, or new Mac permission. The app displays and can copy named relative references but does not open the files. Windows can run the rest of the bridge with this setting unset; the catalog reader requires POSIX no-follow directory access.

## File format

```json
{
  "schema_version": 1,
  "roots": [
    {"id": "sample-repo", "label": "Sample repository", "kind": "repo"},
    {"id": "sample-notes", "label": "Sample vault", "kind": "vault"}
  ],
  "projects": [
    {
      "id": "sample-atlas",
      "title": "Sample Atlas",
      "summary": "Prepare the first draft.",
      "bot_ids": ["default", "sample-reviewer"],
      "sources": [
        {"provider": "GitHub", "source": "Sample issue tracker"},
        {"provider": "Hermes", "source": "Sample planning conversation"}
      ],
      "related_files": [
        {"root": "sample-repo", "path": "docs/plan.md"},
        {"root": "sample-notes", "path": "Projects/Sample Atlas.md"}
      ]
    },
    {"id": "sample-index", "title": "Sample Index", "bot_ids": ["sample-reviewer"]},
    {"id": "sample-review", "title": "Sample Review"}
  ]
}
```

- The top-level keys are `schema_version` (integer `1`), `roots`, and `projects`. Use `[]` for an empty list. No unknown fields or duplicate JSON keys.
- Root `id`s and project `id`s are unique within their own lists, 1–64 characters: lowercase ASCII letters or digits first, then lowercase letters, digits, hyphens or underscores. Preserve project IDs when a title, provider or bot mapping changes. Root labels are display names, not filesystem paths; use `repo` or `vault` for `kind`.
- A project requires `id` and `title`; `summary`, `bot_ids`, `sources`, and `related_files` are optional. Omit `summary` or use `null` when absent. The response supplies empty arrays for omitted associations. Bot IDs are existing Hermes profile ID syntax (1–41 characters, same alphabet as project IDs). They need not resolve at load time. Provenance is display-only `provider` and `source`, not a chat transcript or a remote fetch URL.
- Each `related_files` entry names a declared root ID and a POSIX relative path. Spaces and Unicode are allowed; absolute paths, `~` prefixes, backslashes, colons, `%`, `#`, `?`, empty segments and `.`/`..` segments are not. Never include absolute paths, root mappings, note content, credentials or chat text in display fields. Use a vault-relative `.md` path, not an Obsidian URL or `[[wikilink]]` expression.
- Limits: 256 KiB for the UTF-8 input and response; 64 roots, 300 projects, and per project 32 bot IDs, 32 sources and 64 related files. Label/title/provider/source are at most 120 bytes each, summary 1,000 bytes, and a relative path 512 bytes. Strings are nonempty with no surrounding whitespace, control or format characters. Duplicated associations within one project are invalid. An invalid catalog is rejected as a whole.

## HTTP contract

`GET /m/projects` uses the existing bridge bearer authentication. It accepts no query or body and returns `Cache-Control: no-store`. The bridge adds `configured: true` to a valid catalog; that field does not go in the file. Without a configured file, it returns `200` with `{"schema_version":1,"configured":false,"roots":[],"projects":[]}`. An explicitly configured but unreadable or invalid file returns a generic `503`, without paths or catalog content. An older bridge returns `404`; the app shows an upgrade hint and keeps the other tabs usable.

## Project workspaces (optional, off by default)

`HERMES_MOBILE_WORKSPACES` is a JSON object mapping a catalog project ID to the exact bot IDs you opt in, for example `{"alpha":["bot-a"]}`. **This allowlist is the source of authority**: nothing is inferred, and no bot is enabled unless you list it. Each request narrows it by the live state:

- the project must exist in the current catalog;
- if the catalog project lists `bot_ids`, the bot must also be listed there (an empty or omitted `bot_ids` adds no restriction, because the catalog is display metadata and the real catalog carries none);
- the bot must be a live profile with an API key, not marked `# hermes-mobile: no-key`, and, unless you named it here, not a protected profile (names containing health, journal, trading, robinhood, captain, wellness, portfolio, stocks, doctor, medical, bacta, finance, bank, therapy, secrets, vault). Naming a bot in `HERMES_MOBILE_WORKSPACES` (or `HERMES_MOBILE_WORKSPACE_BOTS`) is your explicit decision and skips only that name check; the key and opt-out checks still apply. Do not allowlist any bot you would not hand project files to.

Malformed JSON disables the feature. It never reads or writes extra paths named in the catalog.

Visibility: files a bot produced are shown only inside the project and chat that produced them. The chat view requires the chat to be linked to a currently enabled project/bot pair. The bot library is per project (`/m/workspace-artifacts/<bot>?project=<id>` is required; there is no cross-project list). Disabling a project or bot hides its chats, files and downloads immediately.

Storage limits (all fail closed with HTTP 507 and a message; nothing is dropped silently or partly saved): per file 8 KiB (4 per project, 128 total, 64 projects holding data); per artifact 8 MiB, 10 per turn, 50 per chat, 200 / 64 MiB per project, 1000 / 256 MiB overall; 200 chats per project, 1000 overall; 32 concurrent turn output directories (stale ones are swept after 24 h). There is no in-app delete for generated files yet; when a limit is reached, free space by removing `workspaces.db` under the bridge state directory (this deletes all project data) or ask for a pruning tool.

Generated files: only `MEDIA:/abs/path` lines in a completed reply, only direct regular-file children of that turn's private output directory (no symlinks, hard links, special files or foreign owners), allowed types only, content-checked, copied into the bridge database. Downloads serve those stored bytes as `attachment`/`nosniff`, never a path. The bot itself runs with its normal profile permissions and can copy any file it can read into that directory; the bridge cannot sandbox the bot, so allowlist only bots you trust with that.

Single owner only: every sign-in verifies the one shared dashboard credential, so any valid token is the owner; the token's device label and nonce identify nobody. Don't enable this on a shared or multi-user bridge.
