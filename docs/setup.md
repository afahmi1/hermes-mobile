# Setup runbook (for people and for agents)

For anyone, human or AI agent, asked to "set this app up for me and my Hermes". Steps are ordered and each one has a
check.

## What the pieces are

```
iPhone app (App/)  ──HTTPS over Tailscale──▶  bridge (Bridge/, port 9131)  ──▶  Hermes gateway  ──▶  ~/.hermes/state.db
```

* The **bridge** runs on the machine that runs Hermes (macOS, Linux or Windows). It has no server or account of its own.
* The phone reaches it only through **Tailscale Serve** (tailnet-only HTTPS). Never expose 9131 to the internet.
* The bridge must run on **Hermes's own Python**. Hermes's package manager keeps that in a committed environment
  under `$HERMES_HOME/installs/…/environments/…/venv`, and moves it on every Hermes update. The launchers
  (`Bridge/run-bridge.sh`, `Windows/Start-HermesMobile.ps1`) look it up at every start. Never pin a Python path in a
  service definition. Never use the in-tree `hermes-agent/venv` either: it's a stale leftover from older installs.

## Steps

0. **Preflight.** Hermes Agent is installed and its gateway is running (`hermes gateway run`, the desktop app, or the
   gateway service). Tailscale is installed and signed in, on the same tailnet, on both the host and the phone.
1. **Install the bridge service.**

   | OS | Command | Service |
   |---|---|---|
   | macOS | `Bridge/install.sh` | launch agent `local.hermes-mobile.bridge` |
   | Linux | `Bridge/install.sh`, then `loginctl enable-linger $USER` | systemd user unit `hermes-mobile-bridge.service` |
   | Windows | `powershell -ExecutionPolicy Bypass -File Windows\Install-HermesMobile.ps1` | scheduled tasks `HermesMobileBridge`, `HermesMobileStatus` |

   * On macOS and Linux the installer copies the bridge to `~/.local/share/hermes-mobile/releases/<commit>` and runs it
     from `…/current`.
   * macOS blocks launch agents from reading `~/Desktop`, `~/Documents` and `~/Downloads`, so a service can't run
     straight from a clone there.
   * **Code-only redeploy:** run `Bridge/install.sh` again. With unchanged settings the service definition is identical
     (it points at the `current` symlink), so the installer skips the launchd reload and restarts the loaded job with
     `launchctl kickstart -k`. That works from automation that can't run `launchctl bootstrap`. A first install, a
     changed setting or port, or an unloaded job still does bootout and bootstrap. On Linux it runs `daemon-reload`
     only when the unit changed, and always restarts. The installer prints which path it took.
   * The installer keeps the three newest releases and never deletes one that a service still runs from.
   * Optional: `Status/install.sh` (macOS) adds the status dashboard on port 9230.
2. **Put it on the tailnet:** `tailscale serve --bg --https=10001 http://127.0.0.1:9131`
3. **Check everything:** `Bridge/run-bridge.sh --doctor`. On Windows: `Windows\Start-HermesMobile.ps1 -Service Bridge --doctor`.
   * You get one ✓/!/✗ line per check, and the exact fix for anything that fails. Add `--json` for machine-readable output.
   * It only reads: it never edits config and never prints secrets.
   * Exit code 0 means the setup is usable. Fix every ✗, then run it again.
4. **Sign the phone in.** In the app, enter the address the doctor printed (`https://<host>.<tailnet>.ts.net:10001`).
   Then either:
   * use the Hermes dashboard login (`dashboard.basic_auth` in `config.yaml`), or
   * use a single-use pairing code from `Bridge/run-bridge.sh --pair-code` (Windows: `… -Service Bridge --pair-code`).

   Never paste a code or password into a chat log.
5. **Done** when the doctor exits 0 and the phone lists the person's chats.

**Reinstalling keeps your settings.** `install.sh` writes every `HERMES_MOBILE_*` variable in its environment
(`OWNER_LOGIN`, `OWNER_MANAGED`, `TRUST_TAILSCALE_SERVE`, `WORKSPACE_BOTS`, `PERSONA_HOSTS`, `MANAGEABLE_BOTS`, the push
settings and so on) into the service, except the installer-only `HERMES_MOBILE_LABEL`. If a service with the same label
is already installed, its `HERMES_MOBILE_*` settings are the defaults, and your environment overrides them. A variable
set to the empty string removes that setting. The installer prints the names it kept, never the values. A systemd unit
can't hold a newline in a value; the installer refuses it with a message.

**Uninstall:** run `Bridge/install.sh --uninstall`, or remove the Windows scheduled tasks. The Tailscale route stays
until you run `tailscale serve --https=10001 off`.

## Things that look broken but aren't

* **A bot shows no chats or refuses messages.** It has no `API_SERVER_KEY`. On macOS and Linux the bridge adds one
  within a minute. On Windows automatic keys are off, so add it the way the doctor says.
* **Status says Degraded.** A configured platform (often Telegram) is failing on the gateway. Fix or disable that
  platform in Hermes. The phone itself is fine.
* **A message says "Saved on this phone".** The phone can't reach the bridge. Check Tailscale on both ends. Nothing is
  lost; see [delivery.md](delivery.md).
* **"Hermes restarted mid-reply".** The gateway restarted during a reply. Queued messages are safe. Tap Continue.

## Working on the code

* **Restarts.** Don't restart someone's gateway or bridge while replies are running. Check that
  `~/.hermes/gateway_state.json` shows `active_agents == 0` first.
* **Git.** Branch from `main` and open a PR. Never push to `main`.
* **Python tests.** Use Hermes's Python:
  `source Bridge/hermes-python.sh && hermes_python && "$PY" -m unittest discover -s Tests -p 'test_*.py'`
* **Swift tests.** `bash Tests/run-swift.sh <simulator-udid> > build/swift.log; echo $?`. Don't pipe it: piping hides the exit code.
* **Delivery contract.** [delivery.md](delivery.md) says where every outgoing message lives and what survives what.
  Keep it true. `Tests/test_queue_controls.py` proves the bridge side.
* **How replies render.** [message-format.md](message-format.md).
* **TestFlight.**
  1. Bump `CURRENT_PROJECT_VERSION` in `App/Config/Base.xcconfig`.
  2. Archive with `-allowProvisioningUpdates` and an App Store Connect API key.
  3. Export with `App/ExportOptions.plist`.
  4. Add the build to every internal tester group. Not all groups get builds automatically.
