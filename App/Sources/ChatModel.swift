import Foundation
import Observation

struct ChatItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, assistant, tools, notice, control }
    let id: String
    var kind: Kind
    var text: String
    var tools: [String] = []
    var streaming = false
    var footer: String?
    var failed = false
    var timestamp: Double?
    /// Shown under a user message that carried project context (this send only).
    var contextNote: String?
}

struct ApprovalRequest: Identifiable, Hashable {
    let id: String
    let runId: String
    let generation: Int?
    let command: String
    let description: String
    let choices: [String]
    let requestId: String?
}

/// One chat: its transcript (from Hermes), its live run, and its model/provider/effort choice.
@MainActor @Observable
final class ChatModel {
    let profile: String
    private(set) var sessionId: String?
    var items: [ChatItem] = []
    var title: String?
    var isLoading = false
    var isRunning = false
    var status: String?
    var error: String?
    var approval: ApprovalRequest?
    private var waitingApprovals: [ApprovalRequest] = []
    private(set) var answeringApproval = false
    private(set) var approvalError: String?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var textTimer: Task<Void, Never>?
    private(set) var textRevision = 0
    var choice: RuntimeChoice = .botDefault
    private(set) var runtimeNotice: String?
    private(set) var savingRuntime = false
    var served: ServedRuntime?
    /// Bumped on events the UI gives haptic feedback for.
    var completedTick = 0
    var failedTick = 0

    private let api = API.shared
    private weak var app: AppModel?
    private var recovery = StreamRecovery()
    private var confirmedPrimary = false
    private var pendingSend: PendingSend?
    private var sendKey: String? {
        sessionId.flatMap { app?.inboxKey(profile: profile, filter: "outbox/" + $0) }
    }
    private var nextReceiptAttempt = Date.distantPast
    private var receiptBackoff = 1.0

    private var runId: String?
    private var streamTask: Task<Void, Never>?
    private var liveToolGroup: Int?
    private var streamingIndex: Int?
    private var stored: [StoredMessage] = []
    private var receipts: [ControlReceipt] = []
    private var loadedReceipts = false
    private var receiptKey: String? {
        guard let sessionId else { return nil }
        return app?.inboxKey(profile: profile, filter: "control-receipts/" + sessionId)
    }
    private var lastPage: [StoredMessage]?
    private var timelineValidator: String?
    private var lastSnapshotAttempt = false
    private(set) var cachedAt: Date?
    var draft = ""
    var draftAttachments: [SendAttachment] = []
    private var transcriptKey: String? {
        sessionId.flatMap { app?.inboxKey(profile: profile, filter: "transcript/" + $0) }
    }
    private var loadingTranscript = false
    private(set) var hasOlder = false
    private(set) var loadingOlder = false
    /// The user picked a model/effort on this phone for this chat; it rides every turn until another
    /// device changes the session's setting.
    private var picked = false
    private var lastRuntimeRead: Date?
    private var lastPolicy: RuntimeChoice?
    /// Approvals already answered (here or anywhere): a replayed request for one is not shown again.
    private var resolvedApprovals = Set<String>()

    init(profile: String, sessionId: String?, app: AppModel) {
        self.profile = profile
        self.sessionId = sessionId
        self.app = app
        if let sid = sessionId, let saved = app.savedChoice(profile: profile, session: sid) {
            choice = saved
            picked = !saved.isDefault
        }
    }

    // MARK: loading

    func load(quiet: Bool = false, resumeLive: Bool = true) async {
        guard let sid = sessionId, !isRunning, !loadingTranscript, !loadingOlder else { return }
        loadingTranscript = true
        defer { loadingTranscript = false }
        if !quiet { isLoading = items.isEmpty }
        defer { isLoading = false }
        if !loadedReceipts, let key = receiptKey {
            let saved = await InboxDisk.shared.receipts(key)
            guard !Task.isCancelled, key == receiptKey else { return }
            let known = Set(receipts.map(\.id))
            receipts += saved.filter { !known.contains($0.id) }
            loadedReceipts = true
        }
        let key = transcriptKey
        if !lastSnapshotAttempt, let key, stored.isEmpty {
            lastSnapshotAttempt = true
            let cached = await InboxDisk.shared.transcript(key)
            guard !Task.isCancelled, !isRunning, key == transcriptKey else { return }
            if let cached {
                stored = cached.messages
                hasOlder = cached.hasOlder
                items = transcriptWithReceipts()
                cachedAt = cached.savedAt
                isLoading = false
            }
        }
        do {
            let page = try await api.timeline(profile: profile, session: sid, validator: lastPage == nil ? nil : timelineValidator)
            guard !Task.isCancelled, !isRunning, key == transcriptKey else { return }
            timelineValidator = page.validator
            cachedAt = nil
            let msgs = page.rows ?? lastPage ?? []
            if page.rows != nil, lastPage != msgs, let key {
                let date = Date()
                Task { await InboxDisk.shared.saveTranscript(msgs, at: date, key: key, hasOlder: msgs.count == 100) }
            }
            if msgs != lastPage {
                if msgs.count == 100, let anchor = msgs.first?.id,
                   let index = stored.firstIndex(where: { $0.id == anchor }) {
                    stored.replaceSubrange(index..., with: msgs)
                } else {
                    stored = msgs
                    hasOlder = msgs.count == 100
                }
                lastPage = msgs
                items = transcriptWithReceipts()
            }
            if !quiet { error = nil }
        } catch {
            if !quiet { self.error = error.localizedDescription }
        }
        if resumeLive, let key = sendKey {
            do {
                if let pending = try await InboxDisk.shared.pending(key) {
                    guard !isRunning, !Task.isCancelled, key == sendKey else { return }
                    pendingSend = pending
                    if Date() >= nextReceiptAttempt {
                        isRunning = true
                        await deliver(pending, session: sid, key: key, allowLegacy: false)
                    }
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        let runtimeDue = !quiet || lastRuntimeRead.map { Date().timeIntervalSince($0) >= 30 } != false
        async let runtime: Void = runtimeDue ? refreshServed() : ()
        if resumeLive { await reattach() }
        await runtime
    }

    func loadOlder() async {
        guard let sid = sessionId, hasOlder, !loadingOlder, !loadingTranscript, !isRunning else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let offset = stored.count
        do {
            let page = try await api.messages(profile: profile, session: sid, offset: offset)
            guard !isRunning, !Task.isCancelled, stored.count == offset else { return }
            let ids = Set(stored.compactMap(\.id))
            let older = page.filter { row in row.id.map { !ids.contains($0) } ?? true }
            stored.insert(contentsOf: older, at: 0)
            hasOlder = page.count == 100
            items = transcriptWithReceipts()
        } catch { self.error = error.localizedDescription }
    }

    /// A turn started earlier (this app before it was killed, or another phone) may still be running.
    private func reattach() async {
        guard !isRunning, let sid = sessionId,
              let live = try? await api.liveTurns(),
              let t = live.first(where: { $0.sessionId == sid && $0.profile == profile && !$0.done }),
              !isRunning, sessionId == sid else { return }
        recovery = StreamRecovery()
        liveToolGroup = nil
        runId = t.turnId
        isRunning = true
        status = "Hermes is still working…"
        items = items.filter { $0.kind != .assistant || !$0.streaming }
        follow()
    }

    func refreshServed() async {
        guard let sid = sessionId, let s = try? await api.served(profile: profile, session: sid) else { return }
        lastRuntimeRead = Date()
        served = s
        // Hermes's session setting is the truth. Adopt it unless the user just picked something here,
        // and always adopt it when another device (the desktop) changed it since we last looked.
        if let pc = s.policyChoice {
            let changedElsewhere = lastPolicy != nil && pc != lastPolicy && pc != choice
            if changedElsewhere || !picked { choice = pc; picked = false }
            lastPolicy = pc
        }
        if let i = items.lastIndex(where: { $0.kind == .assistant }), items[i].footer == nil {
            items[i].footer = servedCaption
        }
    }

    var servedCaption: String? {
        guard let s = served else { return nil }
        let last = s.modelsUsed?.first
        guard let m = last?.model ?? s.model, !m.isEmpty else { return nil }
        var parts = [m]
        if let p = last?.provider ?? s.provider, !p.isEmpty { parts.append(p) }
        if s.fallbackActive == true { parts.append("fallback") }
        return parts.joined(separator: " · ")
    }

    private func transcriptWithReceipts() -> [ChatItem] {
        var rows = Self.transcript(stored)
        for receipt in receipts.sorted(by: { $0.at < $1.at }) {
            let t = receipt.at.timeIntervalSince1970
            let next = rows.firstIndex { ($0.timestamp ?? 0) > t } ?? rows.endIndex
            rows.insert(receipt.item, at: next)
        }
        return rows
    }

    static func transcript(_ msgs: [StoredMessage]) -> [ChatItem] {
        var out: [ChatItem] = []
        var toolGroup: Int?
        for (i, m) in msgs.enumerated() {
            let key = m.id.map(String.init) ?? "i\(i)"
            let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.role {
            case "user":
                toolGroup = nil
                if !text.isEmpty { out.append(ChatItem(id: key, kind: .user, text: text, timestamp: m.timestamp)) }
            case "assistant":
                let names = (m.toolCalls ?? []).compactMap { $0.function?.name }
                if !names.isEmpty {
                    if let toolGroup {
                        out[toolGroup].tools += names
                    } else {
                        toolGroup = out.count
                        out.append(ChatItem(id: key + "t", kind: .tools, text: "", tools: names, timestamp: m.timestamp))
                    }
                }
                if !text.isEmpty { out.append(ChatItem(id: key, kind: .assistant, text: text, timestamp: m.timestamp)) }
            default:
                continue
            }
        }
        return out
    }

    // MARK: runtime choice

    func apply(_ new: RuntimeChoice) async {
        guard new != choice, !savingRuntime else { return }
        guard let sid = sessionId else { choice = new; picked = !new.isDefault; return }
        savingRuntime = true
        defer { savingRuntime = false }
        let previous = lastPolicy ?? choice
        do {
            let deferred = try await api.lockRuntime(profile: profile, session: sid, choice: new, previous: previous)
            choice = new
            picked = !new.isDefault
            app?.saveChoice(new, profile: profile, session: sid)
            if deferred || isRunning {
                runtimeNotice = "Saved for the next message"
            } else {
                runtimeNotice = nil
                if new.isDefault { lastPolicy = nil }
                await refreshServed()
            }
        } catch {
            self.error = "Hermes couldn’t confirm this model change. \(error.localizedDescription)"
        }
    }

    // MARK: sending

    /// `projectContext` is a project ID only when the person switched context on for this send from a
    /// project scope; follow-ups (queue / steer) never carry it.
    func send(_ raw: String, projectContext: String? = nil, attachments: [SendAttachment] = []) async {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !message.isEmpty || !attachments.isEmpty else { return }
        let text = message.isEmpty ? "Describe the attached media." : message
        if pendingSend != nil {
            draft = raw
            error = "Reconnecting the previous send. Your next message is saved in the composer."
            return
        }
        let account = app?.inboxAccount
        isRunning = true
        error = nil
        status = "Sending…"
        do {
            if picked && sessionId != nil { await refreshServed() }
            guard let account, account == app?.inboxAccount else { throw APIError.notSignedIn }
            if sessionId == nil {
                let sid = try await api.createSession(profile: profile)
                guard account == app?.inboxAccount else { throw APIError.notSignedIn }
                sessionId = sid
                if !choice.isDefault { app?.saveChoice(choice, profile: profile, session: sid) }
            }
            guard let sid = sessionId, let key = sendKey else { throw APIError.notSignedIn }
            let send = PendingSend(id: UUID(), text: text, choice: picked ? choice : .botDefault, project: projectContext, attachments: attachments.isEmpty ? nil : attachments)
            try await InboxDisk.shared.stage(send, key: key)
            guard key == sendKey else { throw APIError.notSignedIn }
            pendingSend = send
            if draftAttachments == attachments { draftAttachments.removeAll() }
            var local = ChatItem(id: send.id.uuidString, kind: .user, text: text)
            if projectContext != nil { local.contextNote = "Project instructions + reference files sent with this message" }
            items.append(local)
            await deliver(send, session: sid, key: key, allowLegacy: true)
        } catch {
            isRunning = false
            status = nil
            if draft.isEmpty { draft = raw }
            fail(error.localizedDescription)
        }
    }

    private func deliver(_ send: PendingSend, session: String, key: String, allowLegacy: Bool) async {
        do {
            let run: String
            do {
                run = try await api.startRun(profile: profile, session: session, text: send.text,
                                                    choice: send.choice, projectContext: send.project, submission: send.id,
                                                    attachments: send.attachments ?? [])
            } catch APIError.http(404, _) where allowLegacy && send.attachments == nil {
                // An old bridge does not implement send-once. Drop the retry record BEFORE the
                // one legacy POST; a lost legacy acknowledgment cannot cause an automatic replay.
                try await InboxDisk.shared.acknowledge(send.id, key: key)
                guard sendKey == key else { throw APIError.notSignedIn }
                pendingSend = nil
                run = try await api.startRun(profile: profile, session: session, text: send.text,
                                                    choice: send.choice, projectContext: send.project)
            }
            guard key == sendKey else { throw APIError.notSignedIn }
            error = nil
            receiptBackoff = 1
            nextReceiptAttempt = .distantPast
            recovery = StreamRecovery()
            liveToolGroup = nil
            runId = run
            status = "Thinking…"
            follow()
        } catch {
            isRunning = false
            status = nil
            guard sendKey == key else { return }
            // Auth failures and a missing route on a recovered send can arrive
            // after delivery. Keep that original UUID until the bridge can confirm it.
            if case APIError.http(let code, _) = error,
               [400, 409, 413, 415, 422].contains(code) || (allowLegacy && [403, 404].contains(code)) {
                try? await InboxDisk.shared.acknowledge(send.id, key: key)
                pendingSend = nil
                if draft.isEmpty { draft = send.text }
                if draftAttachments.isEmpty, let attachments = send.attachments { draftAttachments = attachments }
                items.removeAll { $0.id == send.id.uuidString }
                fail(error.localizedDescription)
            } else if pendingSend != nil {
                nextReceiptAttempt = Date().addingTimeInterval(receiptBackoff)
                receiptBackoff = min(60, receiptBackoff * 2)
                fail("Waiting to confirm your send. Reopening this chat will check the same submission.")
            } else {
                fail("The previous bridge could not confirm delivery. Check the saved chat before sending again.")
            }
        }
    }

    var acceptsFollowUp: Bool { isRunning && runId != nil && !sendingFollowUp && !savingRuntime }
    private(set) var sendingFollowUp = false
    private var lastControlAttempt: (run: String, mode: String, text: String, id: UUID, choice: RuntimeChoice)?

    func followUp(_ raw: String, mode: String) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsFollowUp, let run = runId, !text.isEmpty else { return false }
        sendingFollowUp = true
        defer { sendingFollowUp = false }
        let previous = lastControlAttempt
        let attempt: (run: String, mode: String, text: String, id: UUID, choice: RuntimeChoice)
        if let previous, previous.run == run, previous.mode == mode, previous.text == text {
            // A retry checks the original admission even if the picker has since changed.
            attempt = previous
        } else {
            var next = mode == "queue" && picked ? choice : .botDefault
            if next.model == nil, next.effort != nil, let bot = app?.bot(profile) {
                next.model = bot.model
                next.provider = bot.provider
            }
            attempt = (run, mode, text, UUID(), next)
        }
        let id = attempt.id
        let key = receiptKey
        lastControlAttempt = attempt
        do {
            try await api.followUp(run: run, mode: mode, text: text, submission: id, choice: attempt.choice)
            guard let key, receiptKey == key else { return false }
            let receipt = ControlReceipt(id: id, mode: mode, text: text, at: Date())
            receipts.removeAll { $0.id == id }
            receipts.append(receipt)
            if !items.contains(where: { $0.id == id.uuidString }) { items.append(receipt.item) }
            lastControlAttempt = nil
            error = nil
            do { try await InboxDisk.shared.record(receipt, key: key) }
            catch { self.error = "Hermes received the instruction. This phone could not save its receipt." }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func stop() async {
        guard let run = runId else { return }
        status = "Stopping…"
        do { try await api.stopRun(profile: profile, run: run) }
        catch { status = nil; fail(error.localizedDescription) }
    }

    func answer(_ req: ApprovalRequest, choice: String) async {
        guard !answeringApproval, approval == req, req.runId == runId else { return }
        answeringApproval = true
        approvalError = nil
        defer { answeringApproval = false }
        do {
            try await api.approve(profile: profile, run: req.runId, choice: choice, requestId: req.requestId,
                                         generation: req.generation)
            resolveApproval(req.id)
        } catch {
            if approval == req { approvalError = error.localizedDescription }
        }
    }

    private func resolveApproval(_ id: String) {
        resolvedApprovals.insert(id)
        waitingApprovals.removeAll { $0.id == id }
        if approval?.id == id {
            approval = waitingApprovals.isEmpty ? nil : waitingApprovals.removeFirst()
            approvalError = nil
        }
    }

    private func enqueueApproval(_ request: ApprovalRequest) {
        guard !resolvedApprovals.contains(request.id), approval?.id != request.id,
              !waitingApprovals.contains(where: { $0.id == request.id }) else { return }
        if approval == nil { approval = request } else { waitingApprovals.append(request) }
    }

    private func replaceApprovals(_ requests: [ApprovalRequest]) {
        waitingApprovals.removeAll()
        approvalError = nil
        approval = nil
        for request in requests { enqueueApproval(request) }
    }

    /// Re-attach after the app comes back: the run kept going on the Mac.
    func resumeIfNeeded() {
        if isRunning, runId != nil, streamTask == nil { follow() }
    }

    /// A pruned replay has no reliable prefix for the current assistant bubble. Refresh from
    /// Hermes, retain older loaded pages when they overlap, and wait for a complete response
    /// or a new tool boundary before rendering further text from this particular bubble.
    private func restoreCheckpoint(_ ev: RunEvent, run: String) async throws -> Bool {
        guard let sid = sessionId, runId == run, ev.string("turn_id") == run,
              ev.string("session_id") == sid, let seq = ev.seq, seq >= -1,
              let pending = ev.raw["approvals"] as? [[String: Any]] else { throw APIError.badResponse }
        let approvals = try pending.map { raw -> ApprovalRequest in
            guard let id = raw["request_id"] as? String, !id.isEmpty else { throw APIError.badResponse }
            return ApprovalRequest(id: id, runId: run, generation: raw["execution_generation"] as? Int,
                                   command: raw["command"] as? String ?? "",
                                   description: raw["description"] as? String ?? "Hermes wants to run a command.",
                                   choices: raw["choices"] as? [String] ?? ["once", "deny"], requestId: id)
        }
        replaceApprovals(approvals)
        let page = try await api.messages(profile: profile, session: sid)
        try Task.checkCancellation()
        guard runId == run, sessionId == sid else { throw CancellationError() }
        closeStreamingBubble()
        liveToolGroup = nil
        if let id = page.first?.id, let index = stored.firstIndex(where: { $0.id == id }) {
            stored.replaceSubrange(index..., with: page)
        } else {
            stored = page
            hasOlder = page.count == 100
        }
        lastPage = page
        items = transcriptWithReceipts()
        recovery.restore(checkpoint: seq, epoch: ev.replayEpoch)
        if let terminal = ev.raw["terminal"] as? [String: Any], let name = terminal["event"] as? String {
            return handle(RunEvent(seq: nil, name: name, raw: terminal))
        }
        status = approval == nil ? "Reconnected · waiting for the reply…" : "Waiting for your approval"
        return false
    }

    func cancelLocalFollow() {
        app = nil
        streamTask?.cancel()
        textTimer?.cancel()
        runId = nil
    }

    private func follow() {
        guard let run = runId, streamTask == nil else { return }
        let account = app?.inboxAccount
        streamTask = Task { [weak self] in
            guard let self else { return }
            var finished = false
            var incompleteBubble = false
            while !finished && !Task.isCancelled {
                guard runId == run, account == app?.inboxAccount else { break }
                let network = StreamRoutes.shared.state
                if network.offline {
                    status = "Offline · waiting for connection…"
                    await StreamRoutes.shared.waitForRetry(after: network.revision, seconds: nil)
                    continue
                }
                do {
                    for try await ev in api.events(profile: profile, run: run, after: recovery.lastSequence,
                                                          epoch: recovery.epoch, routeRevision: network.revision) {
                        if ev.name == "stream.checkpoint" {
                            finished = try await restoreCheckpoint(ev, run: run)
                            if finished { break }
                            incompleteBubble = true
                            continue
                        }
                        if recovery.hasGap(before: ev.seq) { break }
                        guard recovery.accept(ev.seq, epoch: ev.replayEpoch) else { continue }
                        if incompleteBubble {
                            if ev.name == "message.delta" || ev.name == "assistant.delta" { continue }
                            if ev.name == "tool.started" || ev.name == "tool.start" { incompleteBubble = false }
                        }
                        if handle(ev) { finished = true; break }
                    }
                } catch is StreamRouteChanged {
                    status = "Reconnecting…"
                    continue
                } catch APIError.http(let code, _) where code == 404 || code == 401 {
                    // The turn is gone from the Mac (finished long ago, or the bridge restarted): Hermes's
                    // transcript has the outcome, so reload it instead of retrying.
                    finished = true
                    if code == 401, let account, app?.inboxAccount == account { app?.signOut() }
                } catch {
                    if Task.isCancelled { break }
                }
                if !finished && !Task.isCancelled {
                    if StreamRoutes.shared.state.offline { continue }
                    guard let delay = recovery.retryDelay() else { break }
                    status = "Reconnecting…"
                    await StreamRoutes.shared.waitForRetry(after: network.revision, seconds: delay)
                }
            }
            streamTask = nil
            if !Task.isCancelled, runId == run, account == app?.inboxAccount {
                await finishRun(gaveUp: !finished)
            }
        }
    }

    /// Returns true when the run is over.
    private func handle(_ ev: RunEvent) -> Bool {
        switch ev.name {
        case "approval.resolved":
            if let id = ev.string("request_id") { resolveApproval(id) }
        case "message.delta", "assistant.delta":
            guard let delta = ev.string("delta"), !delta.isEmpty else { break }
            if streamingIndex != nil {
                pendingText += delta
                if textTimer == nil {
                    textTimer = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(40))
                        guard !Task.isCancelled else { return }
                        self?.flushText()
                    }
                }
            } else {
                items.append(ChatItem(id: "stream-\(UUID().uuidString)", kind: .assistant, text: delta, streaming: true))
                streamingIndex = items.count - 1
                textRevision &+= 1
            }
            if status != nil { status = nil }
        case "tool.started", "tool.start":
            let name = ev.string("tool_name") ?? ev.string("tool") ?? ev.string("name") ?? "tool"
            closeStreamingBubble()
            if let i = liveToolGroup, items.indices.contains(i), items[i].kind == .tools {
                items[i].tools.append(name)
            } else {
                liveToolGroup = items.count
                items.append(ChatItem(id: "tools-\(UUID().uuidString)", kind: .tools, text: "", tools: [name]))
            }
            status = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
        case "run.started":
            // The bridge says what context it accepted; replace the optimistic badge with it.
            if let summary = ProjectContext.summary(from: ev.raw),
               let i = items.lastIndex(where: { $0.kind == .user && $0.contextNote != nil }) {
                items[i].contextNote = summary
            }
        case "reasoning.available", "reasoning.delta":
            if streamingIndex == nil && status != "Thinking…" { status = "Thinking…" }
        case "status":
            if streamingIndex == nil { status = "Thinking…" }
        case "notice":
            items.append(ChatItem(id: "n-\(UUID().uuidString)", kind: .notice, text: ev.string("text") ?? ""))
        case "approval.request":
            let id = ev.string("request_id") ?? UUID().uuidString
            guard !resolvedApprovals.contains(id) else { break }
            enqueueApproval(ApprovalRequest(
                id: id, runId: runId ?? "", generation: ev.raw["execution_generation"] as? Int,
                command: ev.string("command") ?? "", description: ev.string("description") ?? "Hermes wants to run a command.",
                choices: (ev.raw["choices"] as? [String]) ?? ["once", "deny"], requestId: ev.string("request_id")))
            status = "Waiting for your approval"
        case "run.completed":
            confirmedPrimary = true
            if let out = ev.string("output"), !out.isEmpty, streamingIndex == nil {
                items.append(ChatItem(id: "final-\(UUID().uuidString)", kind: .assistant, text: out))
            }
            if let rt = ev.raw["runtime"] as? [String: Any], let m = rt["model"] as? String, !m.isEmpty,
               let i = items.lastIndex(where: { $0.kind == .assistant }) {
                var parts = [m, rt["provider"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                if let requested = ev.string("requested_model"), requested != m {
                    parts = ["Requested " + requested, "Hermes reported " + parts.joined(separator: " · ")]
                }
                if rt["fallback"] as? Bool == true { parts.append("Fallback") }
                items[i].footer = parts.joined(separator: " · ")
            }
            runtimeNotice = nil
            completedTick += 1
            return true
        case "run.failed", "error":
            confirmedPrimary = true
            fail(ev.string("error") ?? ev.string("message") ?? "The run failed.")
            return true
        case "run.cancelled", "run.interrupted":
            confirmedPrimary = true
            items.append(ChatItem(id: "n-\(UUID().uuidString)", kind: .notice, text: "Stopped."))
            return true
        default:
            break
        }
        return false
    }

    private func flushText() {
        textTimer?.cancel()
        textTimer = nil
        if !pendingText.isEmpty, let i = streamingIndex, items.indices.contains(i) {
            items[i].text += pendingText
            textRevision &+= 1
        }
        pendingText = ""
    }

    private func closeStreamingBubble() {
        flushText()
        if let i = streamingIndex, items.indices.contains(i) { items[i].streaming = false }
        streamingIndex = nil
    }

    private func finishRun(gaveUp: Bool) async {
        if confirmedPrimary, let send = pendingSend, let key = sendKey {
            do {
                try await InboxDisk.shared.acknowledge(send.id, key: key)
                pendingSend = nil
            } catch { self.error = "Could not clear this phone’s receipt. The same submission is safe to check again." }
        }
        confirmedPrimary = false
        closeStreamingBubble()
        isRunning = false
        status = nil
        replaceApprovals([])
        runId = nil
        if gaveUp { failedTick += 1 }
        lastPage = nil
        await load(quiet: true, resumeLive: !gaveUp)
        if gaveUp { error = "The live connection was lost. Pull down to reconnect." }
    }

    private func fail(_ message: String) {
        error = message
        failedTick += 1
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
