# Notifications and multi-quote replies: research and recommendations (2026-11-27)

Scope: why a friend reports "notifications are broken" in Prometheus (iOS client for Hermes), what well-built open-source chat/agent apps do, and a concrete design for us. This was read-only research. Clones are in `~/.hermes/cache/scratch/research-clones/` (t3code @ 2026-11-27 HEAD, Signal-iOS, element-x-ios, mattermost-mobile, ntfy-ios; the last three are sparse).

Our code read: `App/Sources/ReplyNotifier.swift`, `App/Sources/PushRegistration.swift`, `App/Sources/HermesMobileApp.swift`, `App/Sources/ChatModel.swift` (`handle(_:)`, `notify(_:)`, quote functions), `App/Sources/Views/ChatView.swift` (`draftShelf`), `Bridge/bridge_push.py`, `Bridge/bridge_devices.py`, `Bridge/bridge_turns.py`. Note: `ChatModel.swift`, `ChatView.swift` and others had **uncommitted edits in progress** during this research (multi-quote work). ChatModel line numbers moved while I was reading, so treat them as approximate and use the function names.

---

## 1. Likely bugs in our code (file:line, why, fix)

Ordered by how likely each one is to explain "notifications are broken".

**B1. No notification at all once a reply takes more than about 30 s after you leave, unless APNs is configured** (the main cause)
- `ReplyNotifier.swift:76-82` `left(liveRuns:)` holds a `beginBackgroundTask` for the grace period. iOS gives about 30 s, sometimes less (it is not guaranteed). After that the app is suspended, and `post()` never runs. `Bridge/bridge_push.py:219` returns early when `Config.from_env()` is None, which is today's state because there is no .p8. Agent turns often run for minutes, so most real replies produce **nothing**.
- The expiration handler (`:79-81`) only ends the task. It does not tell the user anything.
- Fix: (a) get push working (see §3 P1; a relay avoids putting a .p8 on every Mac). (b) Until then, when the grace task expires with runs still live, post one honest local notification ("Hermes is still working on '<chat>'. Open to see the reply") and schedule a `BGAppRefreshTask` (Signal pattern, §2). (c) Say in Settings that push is off when the bridge reports no APNs config. `/m/health` could expose `push: false`.

**B2. Nothing is shown in-app for *other* chats**
- `ReplyNotifier.swift:103` `guard away` means the local path never posts while the app is foreground. `:139-142` `willPresent` returns `[]` for **every** notification ("the chat on screen already shows it"). That is only true for the chat on screen. If you are reading chat A while chat B finishes or needs an approval, you get no banner, no sound and no list entry.
- Fix: track the visible destination (`ReplyNotifier.visible: ReplyDestination?`, set from ChatView `onAppear`/`onDisappear` plus scenePhase). Then post locally even in the foreground, and in `willPresent` return `[.banner, .list, .sound]` unless `userInfo` matches the visible destination. This is exactly what Signal (`shouldPresentNotification` + `NotificationSuppressionRule.messagesInThread`), Element X (`shouldDisplayInAppNotification`), Mattermost (`condition1/2/3`) and T3 (`foregroundNotificationBehavior`) do (§2).

**B3. Runs the phone isn't streaming never notify locally**
- Only a live `ChatModel` calls `notify` (`ChatModel.swift` `handle` → `notify`). Cron jobs, runs started on the Mac or Desktop, a chat whose model was never opened, and streams torn down by a Tailscale/network change (`finishRun(gaveUp:)` path) produce no local alert. `AppModel.hasLiveRuns` (`AppModel.swift:238`) only counts open chats, and `resumeLiveRuns` (`:248`) skips `newChats`.
- Fix: the bridge is the only component that sees every turn, so it must be the notifier of record (push or relay). In the app, the chat list's `watchActivity()` could raise local notifications for non-visible chats while the app is foreground.

**B4. Stale `away_since` on the bridge causes double alerts and wrong suppression**
- `PushRegistration.swift:43-45` `presence(away:)` short-circuits on `guard away != now`. Its in-memory `away` starts `false` on every launch. If the app was killed while away (the bridge still holds `away_since`), the next `.active` sends `presence(away:false)`, but the guard drops it because local `away` is already false. `bridge_push.py:186-189` `presence` uses `self.away.setdefault(device, now)`, so the **old** timestamp survives. On the next background with a live run, `should_push` already sees more than 35 s, so the bridge pushes immediately **and** the app posts locally inside its grace window. That is two alerts. They share a collapse id, so one replaces the other, but iOS re-alerts with sound.
- Also `:44` flips `away` before the request succeeds (`:53` `try?`), so a failed POST is never retried.
- Also `HermesMobileApp.swift:99` only sends `presence(away:true)` `if app.hasLiveRuns`. A queued outbox message or a scheduled run that starts after backgrounding leaves the bridge thinking the phone is foreground while the socket stays open. `should_push` then returns False, so the event is **missed** after suspension.
- Fix: always send presence on every phase change, without the dedupe guard, and retry on failure. On the bridge, `presence(away=True)` should overwrite the timestamp, not `setdefault`. Expire `away` entries when the device's sockets close.

**B5. Events inside the 35 s grace window are lost when the app is suspended early**
- `bridge_push.py:221-227` marks `turn.alerted`/`turn.notified` **before** computing targets. If the phone is attached and inside `AWAY_GRACE` (`:34`, 35 s), `targets()` is empty, the event is consumed, and nothing re-checks it later. The app's grace task can end earlier than 35 s (iOS decides), or the socket can die, so neither side notifies.
- Fix: track which events each device has received. When the bridge skips a device because of grace, schedule a re-check at `away_since + AWAY_GRACE`. Then push unless the app ACKed the event (the app can POST `/m/push/ack {run, event}` after it posts its local notification; Mattermost does this with `AckNotification.swift`).

**B6. Badge is never set or cleared, and delivered notifications are never removed**
- `ReplyNotifier.swift:63` requests `[.alert, .sound]` without `.badge`. Nothing calls `setBadgeCount` or `removeDeliveredNotifications`. Reading a chat in the app, on the phone or on the Mac, leaves its notification in Notification Center forever.
- Fix: on opening a chat (ChatView appear) and on `.active`, remove delivered notifications whose `userInfo` matches (Mattermost `NotificationManager.removeChannelNotifications`, Element X `removeDeliveredNotificationsForFullyReadRooms`). Add `.badge` and set the badge to the number of chats with unseen replies or pending approvals (Signal `AppIconBadgeUpdater`, Element X `setBadgeCount`). Send the badge in the APNs payload too.

**B7. No actions: no inline reply, approve/deny, stop or mark read**
- No `UNNotificationCategory` is registered and `categoryIdentifier` is never set (`ReplyNotifier.swift:104-122`). Approvals are the most time-critical event, yet they force a full app open.
- Fix: see §3 P3.

**B8. Content is ambiguous and inconsistent between paths**
- The local title is only `bot` (`:107`). Several chats with the same bot show identical titles, and the chat title is missing. The APNs copy is generic (`bridge_push.py:39-43`) while the local copy includes a headline excerpt and the raw failure `reason` (`ChatModel` `notify(.failure, detail: Headline.of(reason))`). Error text can contain paths or commands. That contradicts the header comment at `ReplyNotifier.swift:43-44` ("the same generic text … never leave the Mac"). When the push replaces the local notification, the text visibly downgrades.
- Fix: title = chat title, subtitle = bot name (or the reverse), body = first sentence. Never show raw errors; map them to a short category. Use the same builder for both paths (the NSE fetches the excerpt, §3 P1). Set `content.summaryArgument` and a `hiddenPreviewsBodyPlaceholder` on the category.

**B9. Possible duplicate on re-handled terminal events**
- `notify(.reply)` in `handle` has no per-run dedupe. `StreamRecovery.accept` filters by sequence, but a fresh `ChatModel` that re-attaches, or a replay epoch change, could re-handle `run.completed`. Approvals without a `request_id` get a random UUID (`approval.request` case) and so always re-notify.
- Fix: keep `notifiedRuns: Set<runId+event>` in `ReplyNotifier`, persisted for about 1 day. Use a stable key such as `runId+seq` when `request_id` is missing.

**B10. Tap routing drops the destination on failure, and launch handling is fragile**
- `HermesMobileApp.swift:88-92` sets `destination = nil` even when `open(in:)` fails (signed out, gateway not loaded yet). Tapping then does nothing.
- Fix: keep it pending until sign-in or gateway restore finishes (T3 `notificationResponseConsumer.ts` reads, routes, then clears last response only after routing succeeds).

**B11. Minor issues**
- `askOnce()` (`:57`) never explains a denial. Add a Settings row that deep-links to `UIApplication.openNotificationSettingsURLString`.
- No `interruptionLevel`. Approvals should be `.timeSensitive`, which needs the `com.apple.developer.usernotifications.time-sensitive` entitlement.
- No `relevanceScore`.
- `bridge_push.py:31` `DEFAULT_TOPIC = com.example.hermesmobile`. `install.sh:118-120` derives the topic from Signing.xcconfig, but a friend's Mac without that file falls back to the example ID, which causes silent `DeviceTokenNotForTopic` → token dropped.
- A friend using **our** TestFlight build needs **our** team's .p8 on **their** Mac. That is a credential-sharing problem, and it is the strongest argument for a relay (§3 P1).

---

## 2. Patterns worth stealing (source repo + path + summary)

### T3 Code (pingdotgg/t3code). Closest analogue: agent threads + mobile app + self-hosted environments
- **Central relay holding the APNs key.** Self-hosted environments publish *activity state* to it. `infra/relay/src/agentActivity/*` covers `ApnsClient.ts`, `ApnsDeliveries.ts`, `ApnsDeliveryQueue.ts`, `apnsJwt.ts`, `Devices.ts`, `MobileRegistrations.ts`, and FCM for Android. This is how one app build works against many users' machines without shipping the key to each machine.
- **Transition-based alerting, not event-based** (`agentActivityAlerts.ts`). An alert fires only when a thread row *enters* `waiting_for_approval`/`waiting_for_input` or newly becomes `completed`/`failed`, compared against the previous aggregate. "A missing baseline is a replay, not a transition that should buzz the phone." Terminal alerts are dropped if older than 2 min (`TERMINAL_NOTIFICATION_FRESHNESS_MS`). Per-phase user prefs: `notifyOnApproval/Input/Completion/Failure`. Several simultaneous rows coalesce into one alert: "3 agents finished: A, B, C".
- **Payload**: title = thread title, body = `"<status>: <project>"`, `thread-id = "<environmentId>/<threadId>"` (fallback `t3-agent-alerts`), `userInfo.body.deepLink`. Text is truncated to 120 chars, deep link sanitized to a relative path (`agentActivityPayloads.ts`).
- **Live Activities for running agents** (`ApnsClient.ts` `buildLiveActivityRequest`). `apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`. Updates use priority 5 unless they carry an alert, with `stale-date` now+10 min. `end` uses `dismissal-date` +5 min. Updates are throttled to ≥15 s unless a phase changed or a row needs attention (`ApnsDeliveries.ts` `shouldUpdateLiveActivity`, `MIN_LIVE_ACTIVITY_UPDATE_INTERVAL_MS`). Payload rows shrink to fit the 4 KB limit. A single aggregate activity shows up to 5 rows (Dynamic Island shows 3). Running rows expire after 2 h so a dead environment can't pin the island. **Lesson: activities are only started in the foreground** ("push-to-start wakes proved too unreliable to hand the token over", `apps/mobile/src/features/agent-awareness/remoteRegistration.ts:~1088`). A freshly armed activity gets a 2 min grace before an empty aggregate ends it.
- **Foreground suppression only for the thread on screen**: `apps/mobile/src/features/agent-awareness/foregroundNotificationBehavior.ts` compares the notification's deep link with `deepLinkOnScreen`.
- **Cold-start tap routing**: `notificationResponseConsumer.ts` reads the last response, routes, and clears it only after routing succeeds.
- A lock-screen/home widget mirrors the activity (`apps/mobile/src/widgets/AgentActivityWidget.tsx`). Settings live in `SettingsNotificationsRouteScreen.tsx`.

### Signal-iOS (signalapp/Signal-iOS)
- `SignalServiceKit/Notifications/UserNotificationsPresenter.swift`: categories with `UNTextInputNotificationAction` reply, `markAsRead`, a thumbs-up reaction, and SF-symbol icons (`UNNotificationActionIcon`). `shouldPresentNotification` suppresses message categories when `NotificationSuppressionRule.messagesInThread(id)` matches the visible thread, while system or error categories always show. When suppressed it still plays the sound with no body.
- `NotificationPresenterImpl.swift:~1878-1913`: foreground **sound throttle**, at most 2 sounds per 5 s. Useful when several agents finish at once.
- Communication notifications: an `INSendMessageIntent` is donated, then `content.updating(from: intent)` gives an avatar and a "sender" look (`:1618`).
- `Signal/Notifications/NotificationActionHandler.swift`: `reply` sends from the background and quotes the original. On failure it posts "failed to send" and marks the thread read.
- `Signal/Notifications/MessageFetchBGRefreshTask.swift`: a `BGAppRefreshTaskRequest` with `earliestBeginDate`, a 27 s cooperative timeout, and a reschedule after each run. It is the fallback for missed pushes.
- `clearNotificationsForAppActivate`, plus `cancelNotifications(threadId:)` when a thread is read. `Signal/Notifications/AppIconBadgeUpdater.swift` and `BadgeManager.swift` derive the badge from the unread DB count and observe DB changes.

### Element X iOS (element-hq/element-x-ios)
- `ElementX/Sources/Services/Notification/Manager/NotificationManager.swift:55-70`: `UNTextInputNotificationAction` quick reply on the message category. `willPresent` returns `[.badge,.sound,.list,.banner]` unless `delegate.shouldDisplayInAppNotification(content)` says the room is on screen. `setBadgeCount` is used.
- `Service/NotificationService.swift:63-85`: `removeDeliveredMessageNotifications(for: roomID)` on open. `removeDeliveredNotificationsForFullyReadRooms` compares each notification's event date with the room's `lastMessageDate`, which keeps notification state in sync when the user read elsewhere.
- `NSE/Sources/NotificationHandler.swift:~140`: the NSE handles a *redaction* by removing the matching delivered notification and decrementing the badge. Pattern for "the run was cancelled or answered elsewhere: retract the alert". `NotificationContentBuilder.swift` builds rich content inside the NSE.

### Mattermost mobile (mattermost/mattermost-mobile)
- **ID-only push plus NSE fetch**: `ios/NotificationService/NotificationService.swift` calls `PushNotification.fetchAndStoreDataForPushNotification`, with `serviceExtensionTimeWillExpire` falling back to generic text. The server sends ids, and the extension pulls the message over HTTPS. Content never transits Apple.
- **ACK** (`ios/Gekidou/.../AckNotification.swift`): the device confirms receipt, so the server knows delivery happened.
- **"clear" push type**: the server tells the device to retract notifications for a channel read elsewhere. The handler is `app/init/push_notifications.ts` `handleClearNotification`, and removal is `libraries/@mattermost/rnutils/ios/Managers/NotificationManager.swift` `removeChannelNotifications`/`removeThreadNotifications`.
- In-app banner rules (`push_notifications.ts:155-186`): show unless the user is on the same channel or thread. Tablet layout is considered.
- Reply category with background text input (`createReplyCategory`, `:95-102`). The badge is requested.

### ntfy (binwiederhier/ntfy + ntfy-ios). Self-hosted push without your own APNs key
- How it works (https://docs.ntfy.sh/config/#ios-instant-notifications): a self-hosted server forwards a `poll_request` containing **only** the message id plus a SHA-256 of the topic URL to `ntfy.sh` (`upstream-base-url`). ntfy.sh sends it through APNs to the *ntfy app*. That app's NSE (`ntfyNSE/NotificationService.swift:71-95` `handlePollRequest`) fetches the real message from the self-hosted server and falls back to "New message" if the server is unreachable.
- `ntfy/Utils/NotificationContent.swift:41-68`: `threadIdentifier = topicUrl`. Priority maps to `interruptionLevel` (`.passive` for 1-2, `.timeSensitive` for 4, `.critical` for 5 when allowed). Categories are built per message from server-supplied actions (`:178`).
- **Limit for us:** the relay only works for the **ntfy app's** bundle id. To use it, a user installs ntfy, subscribes to a per-device secret topic, and the bridge POSTs `Click: prometheus://chat/<id>` (plus `Actions: view, Open, prometheus://...`). Tapping opens our app. It works with no Apple key, but the notifications come from "ntfy" and we get no inline reply into our app. It is a good zero-cost fallback for friends; it is not the product answer.

### General iOS limits (Apple docs, relevant to the "no APNs" question)
- A local notification needs the app to be running. Background time after leaving is ~30 s and not guaranteed.
- `BGAppRefreshTask` runs at the system's discretion: often hours apart, never on a schedule, and rarely if the user doesn't open the app. It is a backstop, not a notifier.
- Silent pushes (`content-available`) are throttled (Apple suggests ≤2-3/hour) and still need APNs.
- Live Activity push updates need APNs (`liveactivity` push type). Without push, a Live Activity can only be updated by the app while it runs, so it freezes after suspension.
- Conclusion: **timely alerts for multi-minute agent turns require APNs** (ours or a relay's), or a third-party app's APNs (ntfy, Pushover, Bark).

---

## 3. Recommended notification design for us (priority ordered, concrete)

**P0. Fix the in-app logic. No new infra; ship first.**
1. Add `ReplyNotifier.visible: ReplyDestination?`, set by ChatView appear/disappear and cleared on `.background`.
2. Replace `guard away` with `guard destination != visible || !foreground` in `post()`. In `willPresent`, return `[.banner,.list,.sound]` unless the notification's destination equals `visible` (T3/Signal/Element pattern). This fixes B2.
3. On ChatView appear and on `.active`, call `removeDeliveredNotifications` for that chat's collapse id, and recompute the badge (B6). Add `.badge` to the authorization options.
4. Persisted `notifiedKeys` dedupe (B9). Keep `destination` pending until routing succeeds (B10).
5. Presence fixes (B4): always send, retry, and make the bridge overwrite the timestamp. Bridge grace re-check plus app ACK (B5).
6. When the grace task expires with live runs, post one "still working" local notification (same collapse id, `.passive`) so the user knows to come back. Show "Push off: replies after ~30 s won't alert you" in Settings when the bridge has no APNs.

**P1. Reliable remote delivery: build a relay, do not ship a .p8 to every Mac.**
- Run a tiny relay (Cloudflare Worker or Fly app) that holds *our* APNs key, modeled on T3 `infra/relay`. Each bridge registers with a per-bridge secret (pairing via the existing device grant). The bridge sends `{device_token_ref, collapse_id, thread_id, event, run_id, seq}` only. **No text.**
- Set `mutable-content: 1` and add a **Notification Service Extension**, as Mattermost and ntfy do. The NSE calls the bridge (`GET /m/push/content?run=…`, short timeout, shared keychain group for the device grant) to fetch the title and first sentence, and falls back to the generic copy if the Mac or Tailscale is unreachable. Content never touches Apple or the relay, and the B8 inconsistency goes away.
- Keep the direct-APNs path in `bridge_push.py` for owners who have their own key (already written). The relay becomes the default.
- Zero-key fallback: optional **ntfy** sink. The bridge POSTs to `https://ntfy.sh/<secret-topic>` (or the user's server) with `Title`, `Click: prometheus://chat/<session>`, `Priority: 4` for approvals. Document it as "works today, notifications come from the ntfy app".

**P2. Event model: when to notify** (port T3's transition logic into `bridge_push.py`)
- Notify on these transitions: run → `waiting_for_approval`/`clarify` (always, `.timeSensitive`), run → `completed` (`.active`), run → `failed` (`.active`, generic text). Do **not** notify on `cancelled` by the user, on streaming deltas, or on tool steps.
- Freshness: drop terminal alerts older than 2 min (replays after bridge restart; already partly handled at `bridge_turns.py:957`).
- Coalesce: if ≥2 chats transition within ~3 s, send one alert ("2 chats finished: X, Y") with `thread-id` per chat when they are separate. Apply a foreground sound throttle of 2 per 5 s (Signal).
- Retract: when an approval is answered elsewhere (Mac, another phone) or a run is stopped, remove the stale "needs approval" alert. Use a background push (`content-available` + `apns-collapse-id` replacement with `.passive` text "Approved on Mac"), or let the app clean up on `.active` (Element/Mattermost "clear" pattern).

**P3. Actions (categories)**
- `hermes.reply` (completed): `UNTextInputNotificationAction` "Reply" (no `.foreground`; send via the bridge from the background with `beginBackgroundTask`, as Signal `NotificationActionHandler.reply` does), plus "Mark read". If the send fails, post "Couldn't send: tap to retry" (Signal) and keep the text in the chat's outbox; we already have `ActionQueue`.
- `hermes.approval`: "Approve once" (`.authenticationRequired` so a locked phone needs Face ID), "Deny" (`.destructive`), "Open". Choices come from `ApprovalRequest.choices`. Use per-variant categories, since iOS categories are static.
- `hermes.clarify`: a text input "Answer". If `choices.count ≤ 3`, one action per choice.
- `hermes.running` (the "still working" one): "Stop" (`.destructive`, `.authenticationRequired`).
- Register categories at launch in `install()`. Set `categoryIdentifier` locally and `aps.category` remotely. Add `hiddenPreviewsBodyPlaceholder` ("%u new replies") and `categorySummaryFormat`.

**P4. Grouping and content**
- `threadIdentifier` per chat (already done, good) and `summaryArgument = chat title`.
- Title = chat title, subtitle = bot name plus "· 4 min" if long, body = `Headline.of(reply)` (first sentence ≤160 chars). Approvals use body = description headline, never the raw command. Failures use a mapped category ("Rate limited", "Model error"), never the raw error.
- Optionally communication notifications: donate an `INSendMessageIntent` with the bot avatar (Signal `:1618`). Bots then look like senders, and Focus "allowed people" can whitelist them. This needs the Communication Notifications capability.
- `relevanceScore`: approvals 1.0, replies 0.5, "still working" 0.1.

**P5. Live Activity for long turns**
- Start in the foreground when a send begins and keep one aggregate activity for all running chats (T3 learned this; skip push-to-start). Show the step status ("Using terminal…"), elapsed time and a pending-approval state.
- Updates: in-app while alive, then via relay `liveactivity` pushes (priority 5, throttled ≥15 s, immediate on phase change, `stale-date` +10 min). End with `dismissal-date` +5 min, and use a 2 h TTL for orphaned runs. Without push, the activity freezes after suspension, so make it show an honest "last update hh:mm".
- Add a Stop button via App Intents (`LiveActivityIntent`). An approval in the Dynamic Island should get Approve/Deny App Intent buttons.

**P6. Badges, quiet hours, summaries**
- Badge = chats with unseen replies plus pending approvals. The bridge includes `badge` in pushes and the app recomputes on `.active`.
- Quiet hours: rely on iOS Focus and Scheduled Summary. Use `.passive` for completions if the user picks "Deliver quietly", and keep approvals `.timeSensitive` (they break through Summary/Focus only if the user allows time-sensitive). Add per-event toggles (T3 `notifyOnApproval/Input/Completion/Failure`) synced to the bridge.
- `BGAppRefreshTask` (Signal): refresh the inbox cache and badge, and post missed-reply notifications. It is a backstop only.

---

## 4. Multi-quote composer patterns

**What other apps do**
- **Slack / Discord / Signal / WhatsApp**: one reply reference per message. Discord and Signal render a quoted card above the composer with an × to remove it. Selecting another message replaces the reference. Multi-quote is done by hand with Markdown `>` (Slack, Discord), or with Discord's "Forward" for separate messages. Signal's quoted reply carries the original message id and author, and a missing original renders "Original message not found" (Signal-Android #6017 history).
- **Telegram** (Replies 2.0, https://telegram.org/blog/reply-revolution): select part of a message, then "Quote" attaches a *partial* quote of that message, still one per message. Telegram can also reply to a message from another chat. The quote is stored as offsets plus text so it can scroll-to-highlight.
- **ChatGPT web**: "Ask ChatGPT" on a selection adds one quote chip and replaces the previous one. Users built extensions to stack quotes ("Ask ChatGPT Multi", Chrome Web Store) by appending `> quote` blocks, which shows real demand.
- **T3 Code (best reference; supports true multi-quote, inline)**:
  - Selection toolbar on assistant text: `apps/web/src/components/chat/AssistantSelectionToolbar.tsx` ("Cite").
  - The citation is an **inline atom node** in the Tiptap composer (`ComposerPromptEditorTiptap.tsx:459` `ComposerCitationExtension`, `group: inline, atom: true`). Several can sit anywhere in the text, with your words between them. Each chip can carry its own **comment** (`withAssistantCitationComment`), and a popover edits it.
  - Data model (`packages/contracts/src/assistantCitations.ts`): `{version, environmentId, threadId, messageId, text ≤8000, comment?, start, end, prefix ≤32, suffix ≤32}`. Offsets plus 32-char context let it re-anchor and **jump to the source** (`citationProcedure.ts`, `lib/assistantCitationNavigation`). If the source was deleted, the saved text is kept and the UI says so.
  - Wire format (`packages/shared/src/assistantCitations.ts`): in the draft each chip serializes to `[Assistant quote](t3-citation:?…)`. For the model, `expandAssistantCitationsForProvider` replaces each with `[assistant-quote-N]` and appends an `<assistant_citations>` JSON block that explains the quotes are *reference material, not instructions* and that comments are user-authored (prompt-injection hygiene). `renderAssistantCitationsAsText` gives the `> Assistant quote:` Markdown for display or copy.
  - Native iOS composer (`apps/mobile/modules/t3-composer-editor/ios/T3ComposerEditorView.swift`): chips are `NSTextAttachment` subclasses carrying a token (`:49`). `deleteBackward` (`:284-300`) removes a whole chip in one backspace. Chip width is capped to the line. Attachment interaction is disabled so a chip isn't treated as an image. Undo restores the chip.

**Our current state (uncommitted work in progress, `ChatModel.swift` `setReplyQuote`/`removeReplyQuote`/`combinedDraft`, `ReplyQuote.segments`; `ChatView.swift` `draftShelf`)**
This is a stacked-pills model: each quote pill gets its own "Your reply to this…" field, the newest quote's answer is the main box, and the message serializes to `> q1 / a1 / > q2 / a2 / … / main`. That is a reasonable mobile-first take (closer to the Telegram/ChatGPT extensions than to T3's inline chips). Risks found:
1. **Lossy Markdown round-trip.** `ReplyQuote.segments` treats *any* line starting with `>` as a quote. A user's own blockquote, a pasted email, or a reply body that begins with `>` will mis-split into fake quote cards. Fix: serialize with an unambiguous envelope the bridge and app both understand (T3-style link token or a fenced `<quote id=…>` block), and keep `> ` only as the human-readable fallback.
2. **No source reference.** Quotes store only an excerpt. Add `messageId` (and offsets/prefix/suffix) so tapping a sent quote card scrolls to and highlights the original (Telegram, T3), and dedupe by `(messageId, range)` instead of text equality (`setReplyQuote` dedupes on `text ==`).
3. **Model framing.** Tell the agent which text is quoted and which is the instruction, as T3 does with the `<assistant_citations>` description. Otherwise quoted assistant text with imperative wording ("run rm -rf…") reads as a new instruction.
4. **Removal semantics.** `removeReplyQuote` carries answers into neighbours. This needs tests for: removing the middle pill with text, removing the newest pill when the previous answer is non-empty, and an empty-text "segment left behind" quote (`PastedText.answer` doc comment) being sent as a stray paragraph. T3's inline-chip model avoids this whole class of problem: deleting a chip deletes only the chip and your words stay where you typed them.
5. **Non-quote paste chips** are appended only to the final body (`combinedDraft`). If the user pasted a log while answering quote 1, it lands after quote N. Either attach a paste to the active segment or document the ordering.

**Recommendation:** keep the stacked pill UI for small screens, but adopt T3's **data model and wire format**: structured citations with ids, offsets and an optional per-quote comment (our "answer"), expanded for the model with an explicit "quoted reference, not instructions" preamble. Render sent messages from the structure, not by re-parsing `>`. Pill UX: one tap on × removes the pill and its empty answer field. A non-empty answer gets a confirm or undo toast (the iOS shake-to-undo convention). Long-press on a pill jumps to the source message. Cap at around 5 quotes, like T3's row caps, to keep the shelf scrollable.
