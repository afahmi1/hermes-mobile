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

## Public pull-request review, November 22, 2026

The GitHub GraphQL repository connection returned 26,409 distinct T3 Code PR numbers through [#41107](https://github.com/pingdotgg/t3code/pull/41107). Its reported total was also 26,409. At collection, 12,737 were merged, 11,220 were closed without merging and 2,452 were open. All titles and states were screened. A case-insensitive title filter for reconnects, offline use, health probes, cold loads, usage, quota, rate limits, sidebars, snapshots, replay, idempotency, first text and session lists matched 2,169 records. The table records a selection whose descriptions and changed files were read. Other repositories were searched by topic. The counts describe T3 coverage only.

| Behavior | Evidence from code and design | Application to Hermes Mobile |
| --- | --- | --- |
| First inbox page | T3 selects the eligible IDs before reading their full shell rows. Hermes projects compact session rows in SQLite and has an explicit index for its correlated preview and activity lookups. All three changes merged. [T3 #27106](https://github.com/pingdotgg/t3code/pull/27106/files), [Hermes #60883](https://github.com/NousResearch/hermes-agent/pull/60883/files), [Hermes #127883](https://github.com/NousResearch/hermes-agent/pull/127883/files) | Bound work by the visible page, include pins and logical session lineage, and compare IDs, ordering and previews against the upstream response. Time a cold database read separately from a warm bridge reply. |
| History and search | Hermes added server-side search and a continuation cursor to the stored session RPC. T3 bounds folded history queries by finding the latest segment boundaries that contain the requested visible tail. [Hermes #152645](https://github.com/NousResearch/hermes-agent/pull/152645/files), [T3 #33305](https://github.com/pingdotgg/t3code/pull/33305/files) | Apply the selected source and bot before limiting search results. Preserve enough of a tool group at a page boundary to render it in order. Confirm behavior on the installed gateway version. |
| Usage and limits | On mobile, T3 split recorded spend and token use for a selected period from subscription limits with independent reset dates. Slow providers can refresh individually while the prior readings remain visible. A later fix suppressed unchanged cached Codex limits that could overwrite a newer account check. [T3 #9775](https://github.com/pingdotgg/t3code/pull/9775/files), [#17147](https://github.com/pingdotgg/t3code/pull/17147/files), [#26331](https://github.com/pingdotgg/t3code/pull/26331/files) | Label local recorded usage, account balance and key-specific quota separately. Show source time and coverage. Missing usage, failed checks and a measured zero each need their own presentation. |
| Contention during refresh | T3 introduced concurrent WAL read workers for independent requests and batched offline usage scans with a yield between batches. [T3 #27097](https://github.com/pingdotgg/t3code/pull/27097/files), [#19446](https://github.com/pingdotgg/t3code/pull/19446/files) | Exercise connection checks and sends while a usage refresh runs. Measure their slowest responses under load before increasing worker counts. |
| Reachability and capability | OpenClaw reloads iOS composer permissions after a real health recovery, since a cached session can appear before its authenticated route is ready. In another merged patch it suppresses provider setup advice while health is unknown. [OpenClaw #195314](https://github.com/openclaw/openclaw/pull/195314/files), [#199349](https://github.com/openclaw/openclaw/pull/199349/files) | Distinguish reachable bridge, accepting gateway, and degraded connectors. Recheck actions after reconnect and preserve drafts through a failed attempt. Two **open proposals** supply additional regression cases for cached row actions and the age of the original health observation. [T3 #26205](https://github.com/pingdotgg/t3code/pull/26205/files), [OpenClaw #181390](https://github.com/openclaw/openclaw/pull/181390/files) |
| At-a-glance status | The Hex notebook product pairs color with a named kernel state and nearby actions. The separate open-source Hex dictation app reuses the underlying listener error in its CLI status and consolidated competing labels during transcription. [Hex project kernels](https://learn.hex.tech/docs/explore-data/projects/environment-configuration/project-kernels), [Hex #1313](https://github.com/anomalyco/hex/pull/1313/files), [#2038](https://github.com/anomalyco/hex/pull/2038/files) | Give Chats a short state label, visible color and a tap target for the reason and last check. Use the same underlying observation in Settings and Status. Verify meaning with color filters and VoiceOver. |
| Two gateways | Hermes Desktop keeps each registered gateway connected and lets the user switch without discarding the session list. [Hermes #147681](https://github.com/NousResearch/hermes-agent/pull/147681/files) | A second active host needs its own authenticated client, health observation, cache and capability state. Test by taking one host offline while a turn on the other continues. |

To reproduce the T3 index and inspect any selected patch, use the commands below. The public repository continues to receive PRs. Filter the TSV by the recorded upper PR number to reproduce the title cohort. PR states can change later.

```sh
gh api graphql --paginate -f query='query($endCursor:String) {
  repository(owner:"pingdotgg",name:"t3code") {
    pullRequests(first:100,after:$endCursor,orderBy:{field:CREATED_AT,direction:ASC}) {
      nodes { number state title } pageInfo { hasNextPage endCursor }
    }
  }
}' --jq '.data.repository.pullRequests.nodes[] | [.number,.state,.title] | @tsv' > t3-prs.tsv
awk -F '\t' '$1 <= 41107' t3-prs.tsv | cut -f1 | sort -u | wc -l
awk -F '\t' '$1 <= 41107' t3-prs.tsv | cut -f3- | rg -ic 'reconnect|offline|connectivity|health check|health probe|cold (scan|start|load)|usage|quota|rate.limit|sidebar|shell snapshot|replay|idempoten|first token|first text|session list'
gh pr view 27106 --repo pingdotgg/t3code --json title,state,body,mergeCommit
gh api --paginate 'repos/pingdotgg/t3code/pulls/27106/files?per_page=100'
```

### Research translated into acceptance checks

- **Keep a useful screen interactive during a slow read.** Wu et al. tested asynchronous interaction snapshots for exploratory tasks under latency. In a companion, the analogous test is to delay one filter by five seconds, switch between Chats and Telegram, then return to the first filter. Check that each tab shows its own most recent data immediately and a late reply only updates the correct tab. Their user study evaluated analytic tasks. Phone navigation needs its own timing. [Facilitating Exploration with Interaction Snapshots under High Latency](https://arxiv.org/abs/1806.01499)
- **Measure freshness at the source.** Age-of-information research defines the age of the latest delivered observation from its generation time. A cached quota refreshed at 09:00 and served at 09:05 should still say 09:00. Let an unsuccessful later probe show both its failure time and the earlier successful reading. Test with a fixed clock and out-of-order responses. [Age of Information](https://arxiv.org/abs/2007.08564)
- **Separate waiting for a reply from reading one.** DistServe distinguishes model-side time to first token and time per output token. Through this bridge, instrument acceptance, first status, first visible text and subsequent display gaps independently. A text delta may contain several tokens, so display gaps measure a different interval from model token latency. Compare warm and cold runs with the same model and prompt and report the sample count. [DistServe](https://arxiv.org/abs/2401.09670)
- **Validate any larger cache against real navigation.** TinyLFU studies admission based on recent frequency under skewed access. Replay a sequence that revisits two chats while paging through hundreds of one-off threads. Compare hit rate, bytes held and reopening latency against a small bounded recency cache before adding complexity. [TinyLFU](https://arxiv.org/abs/1512.00727)

## Follow-up acceptance on November 22

On one five-profile Windows installation, the previous Chats path fetched pages of automation and filtered them on the bridge. Five alternating uncached calls with the iOS filter and a limit of 16 took 4,518, 3,832, 3,642, 3,348 and 3,794 ms, returning five rows each time. The compact reader took 682, 79, 79, 76 and 247 ms and returned 16 rows each time. The medians were 3,794 and 79 ms. These are elapsed times in the bridge with the result cache bypassed. They include host filesystem cache effects. One real HTTPS request took 376 ms and its repeat took 26 ms. These measurements cover listing chats only.

Reproduce by calling `all_sessions(16, None, exclude=("cron", "oneshot", "subagent", "tool"), compact=...)` for both values of `compact`, alternating which runs first, in the installed Hermes environment. Count results and errors. Also verify consecutive pages have disjoint profile/session keys. The optimized reader calls Hermes’s read-only `list_sessions_rich` with its visibility and conversation-lineage rules, filters before pagination, retrieves pins and returns a mobile field allowlist. An older bridge or runtime can use gateway history.

During a supervised, idle gateway restart, the mobile endpoint remained reachable while the gateway drained, briefly stopped, started, and returned to running at about 67 seconds. Newer bridge code gives a recently observed drain up to 45 seconds of “Waiting” before declaring the gateway unavailable. An explicit fresh restart signal shows “Restarting.” The phone checks transitioning states every three seconds while active. It retains the last successful observation after a failed request and distinguishes expired login. Each bridge process keeps the last eight observed transitions. Storage under 512 MiB is called out in gateway diagnostics because a full volume can prevent transcript writes.

In a disposable turn, submitting the same steering UUID twice while a tool was working returned the same generation-bound receipt. The unique instruction marker then appeared in the streamed reply and the stored assistant response. That proves application in this test. A successful steer response on its own means the gateway accepted the instruction. The phone now renders the exact instruction and timestamp, persists the latest 80 receipts per conversation in protected device cache, and clears the draft only on acknowledgment. Simulator tests confirmed both queue and steer receipts were visible after process relaunch.

Provider details now separate the default profile’s configured credentials, provider-reported quota or key spend, and lifetime activity in readable bot ledgers. OpenRouter’s per-key counters come from the official key endpoint; the balance comes from the environment key’s billing account. Each amount includes the number of keys that supplied it. A live check read 12 of 12 unique keys and five of five profile ledgers. The model configuration parser now reads the primary provider even when nested fallback definitions precede it. Generic historical routes remain unattributed to individual proxies where the ledger supplies no exact identity. [OpenRouter key information](https://openrouter.ai/docs/api/reference/limits)

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
swiftc App/Sources/Projects.swift App/Sources/Models.swift Tests/ProjectsTests.swift -parse-as-library -o /tmp/hermes-projects-tests
swiftc App/Sources/Workspaces.swift App/Sources/Models.swift Tests/WorkspaceModelTests.swift -parse-as-library -o /tmp/hermes-workspace-tests
swiftc App/Sources/Management.swift App/Sources/Projects.swift App/Sources/Workspaces.swift App/Sources/Models.swift Tests/ManagementTests.swift -parse-as-library -o /tmp/hermes-management-tests
/tmp/hermes-projects-tests
/tmp/hermes-workspace-tests
/tmp/hermes-management-tests
/tmp/hermes-recovery-tests
xcodebuild -project App/HermesMobile.xcodeproj -scheme HermesMobile -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a Windows host using the per-user Hermes installer, copy the Bridge, Status and Windows directories into one persistent folder. Run Windows/Install-HermesMobile.ps1 as the logged-in Hermes user. Confirm loopback ports 9131 and 9230 are listening, then follow the Tailscale Serve step in the main README. Test unauthenticated rejection, authenticated health, bot discovery, Telegram pagination, transcript read, a new turn and the persisted reply. Each tester enters their own host and bridge credentials. Google sign-in to Tailscale establishes network access. Hermes's dashboard credentials sign into the application.

For TestFlight, record the upload date, processed build number and actual expiration in App Store Connect. Test cold sign-in on a fresh install, because a development installation may already have a token. Upload a replacement before the current beta expires. Apple permits testing a build for up to 90 days. [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

## Build 12 on top of Build 5

An initial prompt now has one identity on the phone, in the bridge journal and at Hermes admission. Text and opted-in media travel together. On a missed acknowledgment the phone asks about that same prompt. The bridge resumes a journaled admission and reads the terminal receipt after a process restart. Workspace context is frozen at submission. A model change made while busy applies at the next eligible turn; the reply can show when the observed model differs.

The phone keeps protected recent transcript tails, shows their observation time while offline, and checks for changes on return. The optional timeline representation keeps text, tool names, IDs and timestamps. Hidden tool results, tool arguments and reasoning are omitted from this mobile representation. Its validator changes when visible content changes even when row count stays the same. A conditional re-read with an unchanged validator returns an empty 304 after the gateway read.

The live client paints first text immediately and groups subsequent text updates over 40 ms. Scrolling up suspends automatic following. **Latest** returns to the end. Reader backpressure, expired history, changed replay epochs and restored routes all have explicit recovery paths. Current approvals survive unrelated events; multiple pending decisions are ordered and a failed approval stays available to retry.

The media composer follows the T3 pattern of making staged attachments visible and removable. An image goes through Hermes native attachment admission. A video can become a small set of reviewable frames. A full clip is offered only when the selected gateway profile reports a usable video backend. A text-only primary chat model can benefit from Hermes auxiliary analysis. Admission alone cannot prove provider-side analysis. Cua's reconnect and retry UI distinguishes transient failures from states that need an operator action; here the phone distinguishes a missed acknowledgment from a rejected send. [T3 composer uploads](https://github.com/pingdotgg/t3code/blob/76de50bc0d3fdd9fc2c5816de4142fbda1ce8364/apps/mobile/src/state/composer-attachment-uploads.test.ts) · [Cua retry presentation](https://github.com/trycua/cua/blob/186e7cfd8a1707720aabe350c3784f6019bd955c/apps/cua-spaces-web/src/bridge/create-retry.ts)

The inference literature separates first output latency from steady-state delivery and studies chunk size versus scheduling overhead. We applied those questions at the UI and transport layers. Sampling shared replay buffers and tail catch-up tests are companion experiments, not evidence of a faster language model. [DistServe](https://arxiv.org/abs/2401.09670) · [Sarathi-Serve](https://arxiv.org/abs/2403.02310) · [PagedAttention](https://arxiv.org/abs/2309.06180) · [SGLang](https://arxiv.org/abs/2312.07104) · [Interaction snapshots](https://arxiv.org/abs/1806.01499)

| Controlled experiment | Result on the development Mac |
| --- | --- |
| 50 simultaneous HTTP readers, 2,000 previously published events each | Three-trial median delivery time fell from 1,210 ms to 108 ms. The test checked every sequence number for every reader. |
| Latest 100 rows of a synthetic tool-heavy 2,000-row chat in a 10,000-chat fixture | 601,760 bytes rich, 6,260 bytes projected, zero response body on an unchanged conditional read. Ratios depend on actual tool output and text. |
| Rust transport prototype, 50 readers resuming halfway through 2,000 deltas | Five-trial median 23.2 ms for the batch compared with 38.2 ms in the bounded Python reader. Resident memory was 5.6 versus 34.7 MiB. The prototype lacks production protocol parity and is excluded from the app and bridge deployment. |

Reproduce with `python3 Benchmarks/replay_fanout.py --http`, `python3 Benchmarks/timeline.py`, and the experiment in [Experiments/replay-transport](../Experiments/replay-transport/README.md). These runs cover transport and serialization. A cold or overloaded provider still determines how long it takes to generate the first word.

For Windows installations with a nearly full system volume, set the user environment variable `HERMES_MOBILE_ADMISSIONS_DIR` to a new private directory on a fixed data volume before installing the bridge. Keep that path stable across upgrades. Durable receipt keys and payloads must stay readable only by the operator and system administrators. The Windows installer restricts the companion state folder and initializes permissions when creating an alternate receipt folder.

Public design references also prompted three concrete checks. The state-machine discussion motivated enumerating all 46,656 six-step combinations of progress, duplicates, gaps, stalls and epoch changes against the real Swift consumer. T3's multi-machine connection settings inspired checking that two deliberately different gateways each accept only their own bearer. Hermes's auxiliary-model configuration and the distinction between still frames and a full audiovisual clip informed the capability and consent checks. A photo-capable chat route is insufficient evidence that a video will be understood. [State-machine testing prompt](https://x.com/poteto/status/2119521036660314339) · [T3 connections](https://x.com/maria_rcks/status/2096747115791765520) · [Hermes auxiliary models](https://x.com/Teknium/status/2099168594731106767) · [Video versus still frames](https://x.com/udiWertheimer/status/2096204771984122275)
