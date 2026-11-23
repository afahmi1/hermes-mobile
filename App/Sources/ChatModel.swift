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
    var choice: RuntimeChoice = .botDefault
    var served: ServedRuntime?
    /// Bumped on events the UI gives haptic feedback for.
    var completedTick = 0
    var failedTick = 0

    private weak var app: AppModel?
    private var recovery = StreamRecovery()
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
    private var loadingTranscript = false
    private(set) var hasOlder = false
    private(set) var loadingOlder = false
    /// The user picked a model/effort on this phone for this chat; it rides every turn until another
    /// device changes the session's setting.
    private var picked = false
    private var lastPolicy: RuntimeChoice?
    /// Approvals already answered (here or anywhere): a replayed request for one is not shown again.
    private var resolvedApprovals = Set<String>()

    init(profile: String, sessionId: String?, app: AppModel) {
        self.profile = profile
        self.sessionId = sessionId
        self.app = app
        if let sid = sessionId, let saved = AppModel.savedChoice(profile: profile, session: sid) { choice = saved }
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
        do {
            let msgs = try await API.shared.messages(profile: profile, session: sid)
            if isRunning { return }  // the live stream owns the tail; reload when it ends
            if !quiet || msgs != lastPage {
                if msgs.count == 100, let anchor = msgs.first?.id,
                   let index = stored.firstIndex(where: { $0.id == anchor }) {
                    stored.replaceSubrange(index..., with: msgs)
                } else {
                    stored = msgs
                    hasOlder = msgs.count == 100
                }
                lastPage = msgs
                items = transcriptWithReceipts()
                error = nil
            }
        } catch {
            if !quiet { self.error = error.localizedDescription }
        }
        async let runtime: Void = refreshServed()
        if resumeLive { await reattach() }
        await runtime
    }

    func loadOlder() async {
        guard let sid = sessionId, hasOlder, !loadingOlder, !loadingTranscript, !isRunning else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let offset = stored.count
        do {
            let page = try await API.shared.messages(profile: profile, session: sid, offset: offset)
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
              let live = try? await API.shared.liveTurns(),
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
        guard let sid = sessionId, let s = try? await API.shared.served(profile: profile, session: sid) else { return }
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
        let previous = lastPolicy ?? choice
        choice = new
        picked = !new.isDefault
        guard let sid = sessionId else { return }
        AppModel.saveChoice(new, profile: profile, session: sid)
        do {
            try await API.shared.lockRuntime(profile: profile, session: sid, choice: new, previous: previous)
            if new.isDefault { picked = false; lastPolicy = nil }  // adopt whatever the bot's default is now
            await refreshServed()
        } catch {
            self.error = "Hermes didn't take the change: \(error.localizedDescription). It will be sent with your next message."
        }
    }

    // MARK: sending

    /// `projectContext` is a project ID only when the person switched context on for this send from a
    /// project scope; follow-ups (queue / steer) never carry it.
    func send(_ raw: String, projectContext: String? = nil) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        error = nil
        var local = ChatItem(id: "local-\(UUID().uuidString)", kind: .user, text: text)
        if projectContext != nil { local.contextNote = "Project instructions + reference files sent with this message" }
        items.append(local)
        isRunning = true
        status = "Sending…"
        if picked && sessionId != nil { await refreshServed() }  // a switch made on the desktop wins over a stale pick
        do {
            if sessionId == nil {
                let sid = try await API.shared.createSession(profile: profile)
                sessionId = sid
                if !choice.isDefault { AppModel.saveChoice(choice, profile: profile, session: sid) }
            }
            let run = try await API.shared.startRun(profile: profile, session: sessionId!, text: text,
                                                    choice: picked ? choice : .botDefault, projectContext: projectContext)
            recovery = StreamRecovery()
            liveToolGroup = nil
            runId = run
            status = "Thinking…"
            follow()
        } catch {
            isRunning = false
            status = nil
            fail(error.localizedDescription)
        }
    }

    var acceptsFollowUp: Bool { isRunning && runId != nil && !sendingFollowUp }
    private(set) var sendingFollowUp = false
    private var lastControlAttempt: (run: String, mode: String, text: String, id: UUID)?

    func followUp(_ raw: String, mode: String) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsFollowUp, let run = runId, !text.isEmpty else { return false }
        sendingFollowUp = true
        defer { sendingFollowUp = false }
        let previous = lastControlAttempt
        let id: UUID
        if let previous, previous.run == run, previous.mode == mode, previous.text == text { id = previous.id }
        else { id = UUID() }
        let key = receiptKey
        lastControlAttempt = (run, mode, text, id)
        do {
            try await API.shared.followUp(run: run, mode: mode, text: text, submission: id)
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
        do { try await API.shared.stopRun(profile: profile, run: run) }
        catch { status = nil; fail(error.localizedDescription) }
    }

    func answer(_ req: ApprovalRequest, choice: String) async {
        approval = nil
        do {
            resolvedApprovals.insert(req.id)
            try await API.shared.approve(profile: profile, run: req.runId, choice: choice, requestId: req.requestId,
                                         generation: req.generation)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Re-attach after the app comes back: the run kept going on the Mac.
    func resumeIfNeeded() {
        if isRunning, runId != nil, streamTask == nil { follow() }
    }

    private func follow() {
        guard let run = runId, streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var finished = false
            while !finished && !Task.isCancelled {
                do {
                    for try await ev in API.shared.events(profile: profile, run: run, after: recovery.lastSequence) {
                        if recovery.hasGap(before: ev.seq) { break }
                        guard recovery.accept(ev.seq) else { continue }
                        if handle(ev) { finished = true; break }
                    }
                } catch APIError.http(let code, _) where code == 404 || code == 401 {
                    // The turn is gone from the Mac (finished long ago, or the bridge restarted): Hermes's
                    // transcript has the outcome, so reload it instead of retrying.
                    finished = true
                    if code == 401 { app?.signOut() }
                } catch {
                    if Task.isCancelled { break }
                }
                if !finished && !Task.isCancelled {
                    guard let delay = recovery.retryDelay() else { break }
                    status = "Reconnecting…"
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            streamTask = nil
            if !Task.isCancelled { await finishRun(gaveUp: !finished) }
        }
    }

    /// Returns true when the run is over.
    private func handle(_ ev: RunEvent) -> Bool {
        // Anything the turn does after asking means the question was answered (here, on the desktop,
        // or by a timeout): a replayed or stale approval must not stay on screen.
        if approval != nil, ["message.delta", "tool.started", "tool.completed", "run.completed",
                             "run.failed", "run.cancelled"].contains(ev.name) {
            if let a = approval { resolvedApprovals.insert(a.id) }
            approval = nil
        }
        switch ev.name {
        case "approval.resolved":
            if let id = ev.string("request_id") { resolvedApprovals.insert(id) }
            if approval?.id == ev.string("request_id") { approval = nil }
        case "message.delta", "assistant.delta":
            let d = ev.string("delta") ?? ""
            if let i = streamingIndex, items.indices.contains(i) {
                items[i].text += d
            } else {
                items.append(ChatItem(id: "stream-\(UUID().uuidString)", kind: .assistant, text: d, streaming: true))
                streamingIndex = items.count - 1
            }
            status = nil
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
            status = "Thinking…"
        case "status":
            if streamingIndex == nil { status = "Thinking…" }
        case "notice":
            items.append(ChatItem(id: "n-\(UUID().uuidString)", kind: .notice, text: ev.string("text") ?? ""))
        case "approval.request":
            let id = ev.string("request_id") ?? UUID().uuidString
            guard !resolvedApprovals.contains(id) else { break }
            approval = ApprovalRequest(
                id: id, runId: runId ?? "", generation: ev.raw["execution_generation"] as? Int,
                command: ev.string("command") ?? "", description: ev.string("description") ?? "Hermes wants to run a command.",
                choices: (ev.raw["choices"] as? [String]) ?? ["once", "deny"], requestId: ev.string("request_id"))
            status = "Waiting for your approval"
        case "run.completed":
            if let out = ev.string("output"), !out.isEmpty, streamingIndex == nil {
                items.append(ChatItem(id: "final-\(UUID().uuidString)", kind: .assistant, text: out))
            }
            if let rt = ev.raw["runtime"] as? [String: Any], let m = rt["model"] as? String, !m.isEmpty,
               let i = items.lastIndex(where: { $0.kind == .assistant }) {
                items[i].footer = [m, rt["provider"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            completedTick += 1
            return true
        case "run.failed", "error":
            fail(ev.string("error") ?? ev.string("message") ?? "The run failed.")
            return true
        case "run.cancelled", "run.interrupted":
            items.append(ChatItem(id: "n-\(UUID().uuidString)", kind: .notice, text: "Stopped."))
            return true
        default:
            break
        }
        return false
    }

    private func closeStreamingBubble() {
        if let i = streamingIndex, items.indices.contains(i) { items[i].streaming = false }
        streamingIndex = nil
    }

    private func finishRun(gaveUp: Bool) async {
        closeStreamingBubble()
        isRunning = false
        status = nil
        approval = nil
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
