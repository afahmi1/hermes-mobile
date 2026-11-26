# Build 5: deploy, owner setup, migration and rollback

Build 5 adds two opt-in features to the bridge and the app:
- **Workspaces on every project.** You can assign bots and edit instructions and workspace files from the app.
- **Owner management.** You can add projects and app-made bots, and archive or restore them with a deletion PIN.

Everything is off until the operator turns it on. With the new settings unset, the bridge behaves exactly like build 4.

## Settings (bridge environment, e.g. the LaunchAgent plist)

| Setting | Default | Meaning |
|---|---|---|
| `HERMES_MOBILE_OWNER_MANAGED=1` | off | The single owner-mode flag. It turns on workspaces for every catalog project, owner-editable bot assignment and `/m/manage`. |
| `HERMES_MOBILE_OWNER_LOGIN` | unset | The owner's Tailscale login, e.g. `owner@example.com`. If unset, a password login never gets owner scope. |
| `HERMES_MOBILE_TRUST_TAILSCALE_SERVE=1` | off | The operator states that Tailscale Serve is the bridge's only remote path. It is required for login elevation. |
| `HERMES_MOBILE_WORKSPACE_BOTS` | union of the bots in `HERMES_MOBILE_WORKSPACES` | JSON list of the profiles the owner may assign. Malformed means none. |
| `HERMES_MOBILE_PERSONA_HOSTS` | none | JSON list of the existing bots that may host app-made bots. If unset, Add bot is refused. |
| `HERMES_MOBILE_MANAGEABLE_BOTS` | none | JSON list of live bots the owner may archive. `default` and protected names are always refused. |
| `HERMES_MOBILE_WORKSPACES` (existing) | — | The legacy pilot allowlist. In owner mode it seeds assignments once, on first use. |

The eligible, host and manageable lists are narrowed further on every request. A bot is dropped if it is no longer live, lacks an API key, is opted out with `# hermes-mobile: no-key`, or isn't in the project's catalog `bot_ids` (when that list is non-empty).

A bot you name in one of these lists (`HERMES_MOBILE_WORKSPACE_BOTS`, `_PERSONA_HOSTS`, `_MANAGEABLE_BOTS`, or a project in `HERMES_MOBILE_WORKSPACES`) skips the protected-name check, so a health or journal bot works from projects when you list it. It still needs an API key and no opt-out marker. A bot you don't name is never reachable through these paths. When `HERMES_MOBILE_WORKSPACE_BOTS` is absent, the bots named in `HERMES_MOBILE_WORKSPACES` count as named. Only list bots you would hand project files to.

## Owner authentication (required for every new mutation)

- **Ordinary sign-ins are never elevated.** Build-4 and ordinary tokens keep their existing read and chat access. Every new mutation returns `403 owner_required` for them.
- **Owner scope is the token claim `own:1` plus `iat`.** The claim is honoured only while `iat` is at or after the owner epoch, and only while owner mode is on. A token gets the claim in exactly one of two ways:
  1. **Password login over Tailscale Serve.** All of the following must hold:
     - Owner mode is on.
     - `HERMES_MOBILE_OWNER_LOGIN` and `HERMES_MOBILE_TRUST_TAILSCALE_SERVE=1` are set.
     - The bridge is bound to loopback (`HERMES_MOBILE_BIND` unset or loopback).
     - The connection comes from loopback, i.e. from Serve.
     - The request has exactly one `Tailscale-User-Login` header, and it equals the configured login.
     - There is no `Tailscale-Funnel-Request` header.

     Tailscale Serve removes client-supplied `Tailscale-User-*` headers and sets its own. It sets none for Funnel or tagged-node traffic, so those cannot be elevated. Do not put any other reverse proxy in front of the bridge.
  2. **Explicit local issuance.** On the Mac, run `python3 Bridge/hermes_mobile_bridge.py --issue-token <device> --owner`. Paste the printed token into the app; it is the same flow as the existing pairing token. Local Mac access is already full trust.
- **Revoke all owner tokens:** run `python3 Bridge/hermes_mobile_bridge.py --rotate-owner-sessions`. Ordinary access is unaffected.
- **Before you rely on login elevation,** confirm on the Mac that Serve is the only exposure: `tailscale serve status` should show only the bridge port, and Funnel should be off for it.

## Deletion PIN (each install chooses its own; there is no default)

- **Storage.** The PIN is stored only as a salted scrypt verifier in `<HERMES_HOME>/mobile/owner/owner_pin.json`. The directory is 0700 and the file 0600, and the write is atomic.
- **One limiter for everything.** The failed-attempt limiter is shared and persisted across restarts: 5 failures lock for 5 minutes, doubling up to 1 hour. It covers project archive, bot archive and PIN change.
- **Fail closed.** A missing, loose, linked or tampered verifier means archive is refused (`503 pin_unset`). The app never overwrites a damaged verifier.
- **Set it in the app (owner token).** Settings → Deletion PIN. The first time, enter the new PIN twice. To change it, enter the current PIN and then the new PIN twice. The reply is only `{ok, configured}`.
- **Set it on the Mac.** `python3 Bridge/hermes_mobile_bridge.py --set-owner-pin` prompts twice and doesn't echo. `--clear-owner-pin` removes the verifier and the attempt counter, which is the only way to recover a forgotten or damaged PIN.
- **What the PIN guards.** Only archiving projects and bots. Restore, unassigning a bot and editing settings never ask for it.
- **Never.** The PIN is never part of a URL, a log line, an error, a response or this repository.

## Migration (opt-in)

1. **Stop the bridge and back up** `<HERMES_HOME>/mobile/` (it holds `workspaces.db`, which contains the pilot's instructions, chats and artifacts).
2. **Deploy the full Bridge and Status directories together.** The services import sibling modules for per-device grants, host process checks and turn recovery.
   - Start it with no new settings first. Check that the existing project and normal login behave exactly as before. The test suite proves operator mode returns the build-4 shapes.
3. **Add the owner settings** from the tables above and restart.
   - On first owner-mode use, the pilot `{project: [bots]}` map is copied into assignments, once.
   - No other project gets bots automatically.
   - Existing chats and artifacts are untouched.
   - The schema change is additive (`CREATE TABLE IF NOT EXISTS`, plus a separate `mobile/manage/manage.db`).
4. **Get an owner token** (Serve login or `--issue-token --owner`), then choose the deletion PIN.

## Rollback

- **Soft.** Unset `HERMES_MOBILE_OWNER_MANAGED` and restart. You get build-4 behaviour and the legacy allowlist again. Stored assignments and overlay data stay on disk and are ignored.
- **Full.** Redeploy the build-4 bridge files. Build 4 ignores the new tables and files. Restore the backup from migration step 1 if you want the database exactly as it was.
- **Clean up owner state.** `--clear-owner-pin`, then delete `<HERMES_HOME>/mobile/owner/` and, if wanted, `<HERMES_HOME>/mobile/manage/`.

## Limits

- **App-made bots are personas, not Hermes profiles.**
  - Each one runs on an operator-listed host bot: new chats are created on the host, and the persona text is appended to each of those chats' turns as labelled guidance.
  - They have no credentials, profile directory or model of their own.
  - They cannot be assigned to project workspaces; only real eligible profiles can (`not_eligible`).
  - A true new runtime profile needs `hermes profile create` with `.env` and API-key provisioning on the Mac, which the bridge deliberately never does.
- **Catalog reference files (README.md, SOUL.md entries) are metadata only.** The bridge never opens them. "New Workspace file named X" starts a separate, empty workspace file with that name. It does not copy, read or change the Mac file. Users can type the text or import it from the phone.
- **Archive is logical.** No repo, vault file, chat, artifact, profile directory or service is ever deleted. Archived projects return 404 on every workspace route until restored.
