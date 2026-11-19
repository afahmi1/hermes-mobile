# Hermes Mobile

A native SwiftUI iPhone app for [Hermes Agent](https://github.com/NousResearch/hermes-agent). It shows every chat and every bot
(profile) on your Mac, lets you continue any of them, and switches model, provider and reasoning effort per chat. The
switch is saved on the chat inside Hermes, so the desktop app sees the same setting.

It also has a **Status** tab, the same view as the Mac status dashboard (`Status/`, a web page on port 9230). It shows:
- what's running right now: chats, subagents and cron runs;
- every bot and every cron job;
- incidents, recent runs, provider usage, and a "What's new" log.

Both the Mac page and the phone re-discover everything on each refresh, so a bot or cron job you create shows up within
seconds, with a "new" badge for a day. Removals and renames show up too. The phone refreshes every 5 s while the Status
tab is open and every 30 s otherwise, badges the tab, and shows a banner when something is created or removed.

The app has no server of its own. Each person who installs it points it at **their own Mac**, which runs Hermes, a
small bridge (`Bridge/`) that the app talks to over Tailscale, and the status dashboard.

```
iPhone app  ──HTTPS over your tailnet──▶  Bridge on your Mac (127.0.0.1:9131, exposed with `tailscale serve`)
                                             └─▶ Hermes gateway (API server + the desktop app's session protocol)
                                                   └─▶ Hermes state.db: the same chats the desktop app shows
```

---

## Part 1: publishing to TestFlight (for whoever owns the Apple Developer account)

You need a paid Apple Developer Program membership, a Mac and a recent Xcode (this was built with Xcode 27.2; the
app targets iOS 17).

### 1. Set your team and bundle ID

```bash
git clone <this repo>
cd hermes-mobile/App
cp Config/Signing.xcconfig.example Config/Signing.xcconfig
```

Edit `App/Config/Signing.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345                 // your 10-character Team ID
HERMES_BUNDLE_ID = com.yourname.hermesmobile  // any bundle ID you own
```

`Signing.xcconfig` is git-ignored, so your team ID stays out of the repo. Everything else is set in
`App/Config/Base.xcconfig`. Nothing in the Xcode project needs editing.

### 2. Create the app in App Store Connect

In [App Store Connect](https://appstoreconnect.apple.com), go to Apps, then **+**, then New App. Choose platform iOS, any name
(for example "Hermes Mobile"), and select the same bundle ID as `HERMES_BUNDLE_ID`. If the bundle ID isn't listed yet, register it
first under Certificates, Identifiers & Profiles, then Identifiers. Xcode can also register it for you on the first archive.

### 3. Archive and upload

**From Xcode:** open `App/HermesMobile.xcodeproj` and choose the **HermesMobile** scheme with destination
**Any iOS Device (arm64)**. Then go to Product, Archive. In the Organizer, choose Distribute App, then App Store Connect, then Upload.

**From the command line:**

```bash
cd App
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Hermes.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION=1 archive
xcodebuild -exportArchive -archivePath build/Hermes.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

**Every new upload needs a higher build number.** Bump `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`, or pass
`CURRENT_PROJECT_VERSION=2`, `3` and so on, as in the command above. Export compliance is answered in `Info.plist`: the app uses
only standard HTTPS (`ITSAppUsesNonExemptEncryption = NO`).

### 4. Add testers

Once the build finishes processing (a few minutes to an hour), it appears under the app's **TestFlight** tab.

- **Internal testing** (fastest, no review). The tester must be a user on your App Store Connect team: Users and Access, then
  **+**, with any role (for example *Developer* or *Customer Support*). Then add them to an internal testing group.
- **External testing** (up to 10,000 people, by email or public link). The first build goes through Beta App Review.
  The app only works against the tester's own self-hosted server, so say that in the review notes ("requires the user's own Hermes
  server on their Mac over Tailscale; no demo account is possible"). A reviewer may still reject a build they can't sign in to,
  so internal testing is the safer route for a few friends.

Testers install the **TestFlight** app on their iPhone and accept the invite. TestFlight builds expire after 90 days, so
upload a new one before then.

---

## Part 2: running it (for each person who installs the app)

Everyone needs their own Mac running Hermes. The app only ever talks to the address you type in.

### On your Mac

1. **Hermes Agent** installed and its gateway running (`hermes gateway run`, or however you normally run it). Tested with
   Hermes **0.23.x**. The bridge uses Hermes's internal desktop protocol, so a much older or newer Hermes may not work.
2. Hermes's API server needs a key: `API_SERVER_KEY` in `~/.hermes/.env`. Each named profile you want on the phone needs its
   own `API_SERVER_KEY` in `~/.hermes/profiles/<name>/.env`. Generate keys with `openssl rand -hex 32`.
3. A dashboard login in `~/.hermes/config.yaml`. The app signs in with it:

   ```yaml
   dashboard:
     basic_auth:
       username: you
       password: a-long-password
   ```

4. Install the bridge (a per-user launch agent on port 9131 that starts at login) and the status dashboard (port 9230):

   ```bash
   Bridge/install.sh          # each one takes --uninstall to remove it
   Status/install.sh          # then open http://127.0.0.1:9230 on the Mac
   ```

   **New bots work on the phone automatically.** Hermes's API server refuses a bot without an `API_SERVER_KEY`, so when
   a bot appears that the gateway serves but that has never had a key, the bridge backs up its `.env` to
   `~/.hermes/backups/hermes-mobile-auto/` and adds one, once the `.env` has been unchanged for 30 s. Each bot gets this
   once only: a key you remove later stays removed. To opt one bot out, add a line `# hermes-mobile: no-key` to its
   `.env`. To turn the feature off entirely, set `HERMES_MOBILE_AUTO_KEYS=0` for the bridge.

5. Make it reachable from your phone with [Tailscale](https://tailscale.com). This is tailnet-only with a real HTTPS
   certificate, and nothing is exposed to the internet:

   ```bash
   tailscale serve --bg --https=10001 http://127.0.0.1:9131
   ```

   Your address is then `https://<your-mac>.<your-tailnet>.ts.net:10001` (run `tailscale serve status` to see it).

### On your iPhone

1. Install Tailscale, sign in to the same tailnet and keep it connected.
2. Open Hermes Mobile and enter your address from step 5, plus the dashboard username and password from step 3.

That's it. Your chats from the desktop app, iMessage, the terminal and scheduled runs all show up, and new chats you start
on the phone appear in the desktop app's Recents.

---

## Project layout

| Path | What it is |
|---|---|
| `App/Sources/` | SwiftUI app (iOS 17+). `API.swift` is the client, `ChatModel.swift` holds chat and streaming state, `Views/` has the screens. |
| `App/Config/` | `Base.xcconfig` (shared settings) and `Signing.xcconfig.example` (your team and bundle ID). |
| `App/project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. The generated `.xcodeproj` is committed, so XcodeGen is optional. After editing `project.yml`, run `xcodegen generate`. |
| `Bridge/hermes_mobile_bridge.py` | The bridge: login tokens, merged session list across profiles, read-only state.db queries, pass-through to the gateway. |
| `Bridge/bridge_turns.py` | Runs chat turns through Hermes's gateway session protocol (the desktop app's), so any chat can be continued and model/effort switches are saved on the session. |
| `Bridge/install.sh` | Installs the bridge as a launch agent. |
| `Status/hermes_status_server.py`, `Status/dashboard.html` | The status dashboard: gateway, bots, cron jobs, running agents, incidents, provider usage, and what's new. It is read-only toward Hermes; its only state is `~/Library/Application Support/hermes-status/seen.json` (what it has seen, for the "new" badges). |
| `Status/install.sh` | Installs the dashboard as a launch agent on port 9230. The bridge's `/m/status` reads it (`HERMES_STATUS_URL` overrides the address). |

### Development tips

- Debug builds accept `-HMServer http://127.0.0.1:9131 -HMToken <token>` as launch arguments to skip the sign-in screen in the
  Simulator. Get a token with `~/.hermes/hermes-agent/.venv/bin/python Bridge/hermes_mobile_bridge.py --issue-token sim`.
- The bridge keeps nothing but a signing secret (`~/.hermes/mobile/secret`) and its log (`~/.hermes/mobile/bridge.log`).
  Every chat and setting lives in Hermes's own `state.db`.
