# Mobile engine and beta plan

The app has two jobs. A fleet operator needs to find the right bot, see whether it can take work, and answer its pending requests. Someone using one busy bot needs to find yesterday's Telegram conversation among thousands of sessions, reopen at the latest reply, and continue it after the phone locks. Both workflows should keep the Hermes session ID through a disconnect.

## What this branch addresses

- Hermes 0.22.2 accepts the gateway endpoint argument but rejects the newer frame-size keyword. Inspect the installed connector signature before opening a socket. The regression suite exercises both versions. A native Windows gateway completed a new turn through the HTTPS bridge and returned the saved assistant message through the session API.
- The phone uses the last accepted sequence number when reattaching to a stream. Overlapping frames do not append content twice. Empty or failed connections back off with jitter. The bridge now distinguishes a cancelled admission from a completed one when recovering a receipt. Tests cover missing and contradictory outcomes.
- Telegram has its own paged inbox of visible, unarchived Hermes sessions. The first page can seek directly within each bot's local SQLite database. Search accepts a profile and source before applying the result limit. Long chats open at the newest 500 stored messages and refresh when the tail changes even if the page size stays constant.
- The chat list and conversation header show the authenticated gateway's health. The app probes on foreground entry and every 15 seconds while active. A live run also reports its own reconnection state. A healthy gateway can still have an unavailable model provider.
- The Windows launcher uses the Hermes environment and its existing profile keys. Both services listen on loopback. The bridge can be published separately using Tailscale Serve. Status checks use a wait-only Windows handle for process liveness. The POSIX signal-zero idiom has different semantics on Windows. [Python process control](https://docs.python.org/3/library/os.html#os.kill)

## Other companions worth studying

These are repository and documentation comparisons. Device acceptance results below apply to this project.

| Project | Idea worth adapting | Where it fits |
| --- | --- | --- |
| [Hermes Mobile](https://github.com/goncharik/hermes-mobile) | Diagnose connectivity during setup and return users to their previous place after reauthentication. | Explain whether Tailscale, bridge login, or the Hermes gateway needs attention. Retain the selected bot and chat. |
| [HermesCompanion](https://github.com/chibitek/HermesCompanion) | Separate server identities and page through full history. | Key cached rows by server, profile and session. Add an older-message cursor above the latest page and maintain scroll position. |
| [Hermes Mobile for iPhone and Android](https://github.com/michaeldimuro/hermes-mobile) | Offline cache, native Windows setup, bot fleet and optional outbound relay. | Open recent chat titles immediately. Mark them with a last-sync time until the authenticated refresh arrives. Keep Tailscale as the simple default for users already on it. |
| [Pomelu](https://github.com/ateymoori/pomelu) | Actionable approval and clarification cards, optional encrypted push. | Give the operator a queue grouped by bot. Bind every action to an outstanding prompt and its execution generation. |
| [Hermes Mobile Adapter](https://github.com/geniok1980/hermes-mobile-adapter) | Per-device identity, streaming event contract, SDKs and a server-advertised command catalog. | Negotiate optional features before rendering them. Support individual device revocation and expiry. |

## Relay and routing evidence

Ably explicitly distinguishes stream continuity from history catch-up. PubNub uses an ordered message cursor. AWS AppSync recommends jittered exponential retries on transport failures. Hermes already owns transcripts, so short interruptions can replay from the cursor. A bridge restart should recover through Hermes's durable admission receipt and transcript. The current bridge still keeps the replay buffer in memory. [Ably recovery](https://ably.com/docs/platform/architecture/connection-recovery) · [PubNub architecture](https://www.pubnub.com/docs/architecture/how-pubnub-works) · [AWS AppSync client](https://docs.aws.amazon.com/appsync/latest/devguide/real-time-websocket-client.html)

OpenRouter exposes provider ordering and performance preferences. LiteLLM separates deployment health, cooldown and fallbacks. Expose the user's requested provider, the provider that actually answered, and the failure reason whenever Hermes reports all three. Automatic provider changes belong behind an explicit gateway policy because repeating an agent turn can repeat tool actions. RouteLLM evaluates quality versus cost for learned routing. That suggests an offline evaluation on representative tasks before adding automatic selection. [OpenRouter](https://openrouter.ai/docs/guides/routing/provider-selection) · [LiteLLM](https://docs.litellm.ai/docs/routing) · [RouteLLM paper](https://arxiv.org/abs/2406.18665)

Anderton and Young found that simplified contention models can mispredict the winner when collision costs differ. Their experiments concern wireless contention. For this app, measure simultaneous reconnect attempts, replay bytes, first usable row, time to resumed text, and duplicate submissions on actual devices. [Is Our Model for Contention Resolution Wrong?](https://arxiv.org/abs/1705.09271)

## Engineering sequence

| Order | Change | Acceptance test |
| --- | --- | --- |
| 1 | Persist client-generated submission IDs and an admission receipt across retries. Cap replay retention by bytes and time. Return an explicit history gap when a cursor expires. | Cut connectivity after the gateway accepts a turn and before the phone gets the acknowledgment. Resume on the same admission. Count one submission, one tool action and one final answer across reconnect, app kill and bridge restart. |
| 2 | Page older messages on demand. Add a protected local inbox cache with a stale indicator. Key the cache and model preferences by server, profile and session. | Seed 10,000 sessions and a 2,000-message thread. Open the newest turn, scroll back past 500 without a jump, change servers, and verify profile isolation. Compare cold and warm launch p50/p95 on device. |
| 3 | Add per-device pairing and revocation, capability negotiation and a connection diagnostics screen. Limit status polling to the foreground and cache slow provider checks separately. | Revoke one phone while another streams. The revoked device signs out. The other finishes its existing turn. Simulate reachable bridge with a stopped gateway and a healthy gateway with an unavailable provider. Verify distinct labels. |
| 4 | Prototype a Rust transport service using Tokio, Axum and a bounded per-turn replay queue. Keep a small adapter in Hermes's own Python environment for the version-specific session RPC. | Run both implementations against identical replay fixtures with 1, 10 and 50 simulated phones. Compare resident memory, disconnect recovery time and gateway calls. Migrate only after protocol parity and a measured operational improvement. |

## Running the checks

From the repository root, run the following on macOS with Python 3.11+ and Xcode installed.

```sh
python3 -m unittest discover -s Tests -v
swiftc App/Sources/StreamRecovery.swift Tests/StreamRecoveryTests.swift -o /tmp/hermes-recovery-tests
/tmp/hermes-recovery-tests
xcodebuild -project App/HermesMobile.xcodeproj -scheme HermesMobile -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a Windows host using the per-user Hermes installer, copy the Bridge, Status and Windows directories into one persistent folder. Run Windows/Install-HermesMobile.ps1 as the logged-in Hermes user. Confirm loopback ports 9131 and 9230 are listening, then follow the Tailscale Serve step in the main README. Test unauthenticated rejection, authenticated health, bot discovery, Telegram pagination, transcript read, a new turn and the persisted reply. Each tester enters their own host and bridge credentials. Google sign-in to Tailscale establishes network access. Hermes's dashboard credentials sign into the application.

For TestFlight, record the upload date, processed build number and actual expiration in App Store Connect. Test cold sign-in on a fresh install, because a development installation may already have a token. Upload a replacement before the current beta expires. Apple permits testing a build for up to 90 days. [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
