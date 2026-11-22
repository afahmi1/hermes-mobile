# Mobile engine and beta plan

The app has two jobs. A fleet operator needs to find the right bot, see whether it can take work, and answer its pending requests. Someone using one busy bot needs to find yesterday's Telegram conversation among thousands of sessions, reopen at the latest reply, and continue it after the phone locks. Both workflows should keep the Hermes session ID through a disconnect.

## What this branch addresses

- Hermes 0.22.2 accepts the gateway endpoint argument but rejects the newer frame-size keyword. Inspect the installed connector signature before opening a socket. The regression suite exercises both versions. A native Windows gateway completed a new turn through the HTTPS bridge and returned the saved assistant message through the session API.
- The phone uses the last accepted sequence number when reattaching to a stream. Overlapping frames do not append content twice. Empty or failed connections back off with jitter. The bridge now distinguishes a cancelled admission from a completed one when recovering a receipt. Tests cover missing and contradictory outcomes.
- Telegram has its own paged inbox of visible, unarchived Hermes sessions. The first page can seek directly within each bot's local SQLite database. Search accepts a profile and source before applying the result limit. Long chats open at the newest 100 stored messages. A reader can load older pages in place. The tail refreshes even when its size stays constant.
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

## Connection patterns in upstream code

| Source | What this app takes from it |
| --- | --- |
| [T3 Code mobile connection cache](https://github.com/pingdotgg/t3code/blob/a09738fb435120d08707db0142ca55b3b7b5c7ec/apps/mobile/src/connection/environment-cache-store.ts#L103-L177) and [TanStack Query freshness checks](https://github.com/TanStack/query/blob/b09d8e997c220db9939e749403c6e4eacbd6302b/packages/query-core/src/queryClient.ts#L215-L234) | Restore each inbox before refreshing it. Identity includes server, login, bot and filter. Keep the first page in protected device storage and deeper pages in memory. Cancelled and superseded requests cannot publish into a different view. |
| [T3 Code timeline groups](https://github.com/pingdotgg/t3code/blob/a09738fb435120d08707db0142ca55b3b7b5c7ec/apps/web/src/components/chat/TimelineWorkGroupRows.tsx#L85-L135) and [queued run controls](https://github.com/pingdotgg/t3code/blob/a09738fb435120d08707db0142ca55b3b7b5c7ec/apps/web/src/components/chat/QueuedRunsControl.tsx#L62-L130) | Collapse a turn’s tools under a count and show them in order on tap. Route Queue next and Steer now to distinct Hermes operations. Queue uses a submission ID on retry. Steer requires the active execution generation and an affirmative gateway response. |
| [VS Code reconnect protocol](https://github.com/microsoft/vscode/blob/58a9245ffe53ec35991e7d5b08bf2e37f2acedb2/src/vs/base/parts/ipc/common/ipc.net.ts#L974-L1032) and [T3 Code shell stream](https://github.com/pingdotgg/t3code/blob/a09738fb435120d08707db0142ca55b3b7b5c7ec/apps/server/src/orchestration-v2/ShellStream.ts#L41-L105) | Advance the receive cursor through contiguous events. Reconnect on a gap and discard replayed duplicates. A durable restart-safe cursor and an explicit snapshot response on replay expiry are further protocol work. |
| [Hermes gateway internals](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/gateway-internals.md) | Hermes owns admission, steering and execution. Return the actual decision to the phone. This keeps the companion interoperable with turns opened from other clients. |

## Measured on a Windows gateway over Tailscale HTTPS

These are individual observations on one deployment. Times include the Mac-to-bridge network trip. They exclude iOS drawing time.

| Operation | Measurement |
| --- | --- |
| Read the latest 500 rows of a long Telegram chat | 355–400 ms, 1,201,232 bytes after JSON serialization |
| Read the latest 100 rows of the same chat | 71–75 ms, 171,020 bytes under the same serialization |
| List 40 sessions across profiles | One cold request took 3.70 s. Two repeats within the bridge cache window took 42 and 43 ms. |
| Start and stream one ordinary turn | New session 1.63 s. On the new session the start request took 20 ms. First run event at 0.35 s, first text at 7.33 s, completion at 7.61 s after sending. |
| Queue and steer during an active turn | The gateway accepted steering. Retrying the same queued submission returned the same turn. Its event stream completed and the stored transcript contained one queued user message and its answer. |

To reproduce the timings, use an authenticated bridge client on the same tailnet. Time GET requests to `/m/p/<profile>/api/sessions/<id>/messages?order=latest&limit=500` and then `limit=100` on the same chat. Serialize both decoded responses with the same JSON encoder to compare payloads. For the inbox, leave the first-page cache idle for more than six seconds and time three requests to `/m/sessions?limit=40` in succession. For turn controls, use a disposable conversation and time from the start POST to the first run event, text delta and terminal event. Submit the same queued UUID twice and check the receipt and saved chat. Keep tokens and transcript contents out of benchmark logs.

The phone requests 16 summaries initially and 40 on subsequent pages. Returning to a fresh inbox within 12 seconds uses the device cache. The bridge coalesces concurrent reads of the same first page for six seconds and invalidates its cache on successful mutations. A first-ever fleet-wide fetch can still take seconds. Text generation also remains a separate source of latency. The phone reports connection state independently of a bot or connector failure, and Status lists the affected connectors.

OpenRouter credential counts come from Hermes’s per-profile pool. The monetary balance shown by the status service belongs to the credential/account queried. On hosts that use Hermes’s native rotation, the configuration path is `credential_pool_strategies.openrouter` with value `round_robin`. Personal routing changes belong on the operator’s host.

## Engineering sequence

| Order | Change | Acceptance test |
| --- | --- | --- |
| 1 | Persist client-generated submission IDs and an admission receipt across retries. Cap replay retention by bytes and time. Return an explicit history gap when a cursor expires. | Cut connectivity after the gateway accepts a turn and before the phone gets the acknowledgment. Resume on the same admission. Count one submission, one tool action and one final answer across reconnect, app kill and bridge restart. |
| 2 | Benchmark the shipped history paging and protected inbox cache at fleet scale. Add a last-sync timestamp and per-server runtime preferences before supporting multiple simultaneous gateways. | Seed 10,000 sessions and a 2,000-message thread. Open the newest turn, scroll back past 500 without a jump, change servers, and verify profile isolation. Compare cold and warm launch p50/p95 on device. |
| 3 | Add per-device pairing and revocation, capability negotiation and a connection diagnostics screen. Exercise foreground-only status polling under slow provider checks. | Revoke one phone while another streams. The revoked device signs out. The other finishes its existing turn. Simulate reachable bridge with a stopped gateway and a healthy gateway with an unavailable provider. Verify distinct labels. |
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
