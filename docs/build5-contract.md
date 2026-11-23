# Build 5 contract: editable workspaces (slice A) and owner management (slice B)

Stable wire contract shared by the bridge and the app. Both sides code against this file. All routes sit behind the
existing bearer check. JSON errors are `{"error": "<fixed text>", "code": "<machine code>"}`; the app shows fixed
local text keyed on `code`/status, never server text verbatim for security-relevant failures.

## Owner gate (shared)

- `H.owner_ok()` on the bridge request handler. Slice A ships a placeholder `return self.authed()` (build-4
  single-owner semantics). Slice B replaces it with the real owner scope (below). Every NEW mutation in A and B calls it:
  failure -> `403 {"code":"owner_required"}`.
- Owner scope (slice B): enabled only when `HERMES_MOBILE_OWNER_MANAGED=1` (the ONE owner-mode flag, also used
  for owner-managed workspaces). `/m/login` mints `own: 1, iat: <unix>` only when `HERMES_MOBILE_OWNER_LOGIN` is set,
  `HERMES_MOBILE_TRUST_TAILSCALE_SERVE=1`, the bridge binds loopback, the peer is loopback, and exactly one
  `Tailscale-User-Login` header equals it (no Funnel marker); otherwise an ordinary token (fail closed). See
  docs/build5-deploy.md. `owner_ok` = valid bearer AND `own == 1` AND
  `iat >= owner_epoch` (file `STATE_DIR/owner/owner_epoch`, 0600, created on first owner-mode use). Build-4 tokens have no
  `own` claim, so they keep read/legacy access but cannot use new mutations until the owner signs in again.
  CLI: `--issue-token NAME --owner` (local Mac only), `--rotate-owner-sessions` (bumps epoch).

## Slice A: workspaces on every project

Settings:
- `HERMES_MOBILE_WORKSPACES` (existing JSON `{project: [bots]}`): legacy/operator authority; in owner mode a ONE-TIME
  seed of assignments (store meta key `assign_seeded`).
- `HERMES_MOBILE_OWNER_MANAGED=1` (new, shared with slice B): owner-managed workspaces. Requires a configured catalog.
  Off => build-4 behaviour exactly (only allowlisted projects; assignment read-only).
- `HERMES_MOBILE_WORKSPACE_BOTS` (new, optional JSON list of profile ids): operator-defined eligible set. Absent =>
  union of the bots named in `HERMES_MOBILE_WORKSPACES`. Malformed => empty (fail closed, workspaces still visible).
  Eligible for project P = that set ∩ live `profile_ids()` ∩ not `profile_protected()` ∩ catalog `bot_ids` of P when
  that list is non-empty.
- Active grants (owner mode) for P = stored assignment of P ∩ eligible(P), P in current catalog. Used for chat
  creation, turns (`prepare_workspace_turn`), artifact visibility. Workspace *visibility/editing* needs only that P
  is a valid current catalog project.

Store (`bridge_workspaces.py`, same SQLite DB, additive tables only, old build-4 code ignores them):
`meta(key PK, value)`, `assignments(project, profile, PK(project, profile))`,
`assignment_state(project PK, revision INTEGER)`. Removing a bot never deletes or relinks chats or artifacts.

Routes:
1. `GET /m/workspaces` -> `{projects:[ids], profiles:[active union], mode:"owner"|"operator",
   workspaces:[{id, assigned:[active], eligible:[...]}]}`. Owner mode: `projects` = every valid catalog project.
2. `GET /m/workspaces/<p>` -> build-4 fields (`instructions, files, chats, artifacts, profiles`) plus
   `mode`, `instructions_revision` (sha256 hex of UTF-8 instructions), files gain `sha` and `editable:true`,
   `assignment:{editable:bool, revision:int, assigned:[active], inactive:[stored but not eligible now],
   eligible:[...]}`, `hidden_chats:int` (chats kept for bots not currently active).
3. `PUT /m/workspaces/<p>/assignment` `{"profiles":[...], "revision":int}` -> owner mode + `owner_ok`. Every id
   must be eligible(P) or already stored for P (keeping is not granting); unknown/protected/other => 403
   `code:"not_eligible"`, nothing changed. Stale revision => 409 `code:"stale"` + `assignment`. Max 32. Empty list
   allowed. 200 -> `{assignment:{...}}`. Operator mode => 403 `code:"operator_managed"`.
4. `GET /m/workspaces/<p>/files/<file_id>` -> `{id,name,size,sha,content}` (exact id scoped to P, else 404).
5. `PUT /m/workspaces/<p>/files/<file_id>` `{"content":str, "sha":expected}` -> atomic compare-and-swap in one
   transaction; sha required; mismatch => 409 `code:"stale"` + `current:{id,name,size,sha}`; non-empty, <= 8192
   UTF-8 bytes, no NUL, `.json` must parse; same content as another file of P => 409 `code:"duplicate"`.
   200 -> `{id,name,size,sha}`.
6. `POST /m/workspaces/<p>/files` (existing create/import) also returns `sha`.
7. `PUT /m/workspaces/<p>/instructions` `{"instructions":str, "revision"?:sha}`; when `revision` is present and
   differs => 409 `code:"stale"` + `revision`. 200 -> `{ok:true, revision}`.
- Body cap for `/m/workspace*` raised to 64 KiB (8 KiB file content JSON-escaped).
- Catalog `related_files` stay metadata only; the bridge never opens them. The app offers "Add editable copy":
  a new workspace file with the same basename whose content the owner types or imports from the phone.

## Slice B: owner management of projects and bots

Deletion PIN verifier (`bridge_owner.py`): `STATE_DIR/owner/owner_pin.json`, dir 0700, file 0600, atomic write,
`{"v":1,"kdf":"scrypt","n":32768,"r":8,"p":1,"salt":b64(16),"hash":b64(32)}`; constant-time compare; missing,
unreadable, symlinked, group/other-readable or malformed => fail closed `503 code:"pin_unset"`. Failed-attempt
limit shared by every PIN route, persisted (`STATE_DIR/owner/owner_pin_attempts.json`): 5 failures => lockout 300 s,
doubling to 1 h; `429 code:"pin_locked", retry_after`. Wrong PIN => `403 code:"pin_wrong"`. PIN travels only in a
JSON body field `pin`, never URL/log. App seam: `GET/POST /m/manage/pin` `{pin, confirm, current?}` (owner only; first set needs no verifier on disk, a change needs the current PIN through the shared limiter; tampered verifier => 503, never overwritten). Local seam: `python3 Bridge/hermes_mobile_bridge.py --set-owner-pin`
(getpass twice, exactly 4 digits) and `--clear-owner-pin`.

Managed overlay (`bridge_manage.py`, own DB `STATE_DIR/manage/manage.db`): managed projects, archived ids,
personas, archived bots. The catalog file is never written. Effective catalog = original catalog + managed projects
- archived ids; used by `/m/projects` and workspace grants (archived => 404 on workspace routes, no turn scoping).

Routes (all `owner_ok`; owner mode off => 403 `code:"owner_required"`):
- `POST /m/manage/projects` `{title, summary?, id?}` -> 201 project (`managed:true`); id = validated slug,
  unique across catalog, managed and archived.
- `PATCH /m/manage/projects/<id>` `{title?, summary?}` managed projects only (catalog ones => 403 `read_only`).
- `POST /m/manage/projects/<id>/archive` `{pin}`; `POST /m/manage/projects/<id>/restore`.
- `GET /m/manage/archived` -> `{projects:[...], bots:[...]}`.
- `GET /m/manage/bots` -> `{personas:[...], hosts:[...], manageable:[...]}`.
- `POST /m/manage/bots` `{name, persona, host}` -> 201 persona bot. Host from operator list
  `HERMES_MOBILE_PERSONA_HOSTS` (JSON) ∩ live ∩ not protected; absent => no hosts (fail closed).
- `POST /m/manage/bots/<id>/chats` `{title?}` -> creates a session on the host and links it to the persona.
- `POST /m/manage/bots/<id>/archive` `{pin}`; `.../restore`. Live profiles archivable only if listed in
  `HERMES_MOBILE_MANAGEABLE_BOTS` and never `default` or protected; archive = hidden from `/m/bots` and grants;
  nothing on disk under profiles/ is touched.
