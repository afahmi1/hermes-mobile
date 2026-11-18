import Foundation
import Observation

struct ChatItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, assistant, tools, notice }
    let id: String
    var kind: Kind
    var text: String
    var tools: [String] = []
    var streaming = false
    var footer: String?
    var failed = false
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
    private var runId: String?
    private var lastSeq: Int?
    private var streamTask: Task<Void, Never>?
    private var streamingIndex: Int?
    private var lastLoadedCount = 0
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

    func load(quiet: Bool = false) async {
        guard let sid = sessionId else { return }
        if !quiet { isLoading = items.isEmpty }
        defer { isLoading = false }
        do {
            let msgs = try await API.shared.messages(profile: profile, session: sid)
            if isRunning { return }  // the live stream owns the tail; reload when it ends
            if !(quiet && msgs.count == lastLoadedCount) {
                lastLoadedCount = msgs.count
                items = Self.transcript(msgs)
                error = nil
            }
        } catch {
            if !quiet { self.error = error.localizedDescription }
        }
        await refreshServed()
        await reattach()
    }

    /// A turn started earlier (this app before it was killed, or another phone) may still be running.
    private func reattach() async {
        guard !isRunning, let sid = sessionId,
              let live = try? await API.shared.liveTurns(),
              let t = live.first(where: { $0.sessionId == sid && $0.profile == profile && !$0.done }) else { return }
        runId = t.turnId
        lastSeq = nil
        isRunning = true
        status = "Still working on your Mac…"
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

    static func transcript(_ msgs: [StoredMessage]) -> [ChatItem] {
        var out: [ChatItem] = []
        for (i, m) in msgs.enumerated() {
            let key = m.id.map(String.init) ?? "i\(i)"
            let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.role {
            case "user":
                if !text.isEmpty { out.append(ChatItem(id: key, kind: .user, text: text)) }
            case "assistant":
                let names = (m.toolCalls ?? []).compactMap { $0.function?.name }
                if !names.isEmpty {
                    if let last = out.last, last.kind == .tools {
                        out[out.count - 1].tools += names
                    } else {
                        out.append(ChatItem(id: key + "t", kind: .tools, text: "", tools: names))
                    }
                }
                if !text.isEmpty { out.append(ChatItem(id: key, kind: .assistant, text: text)) }
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

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        error = nil
        items.append(ChatItem(id: "local-\(UUID().uuidString)", kind: .user, text: text))
        isRunning = true
        status = "Sending…"
        if sessionId != nil { await refreshServed() }  // a switch made on the desktop wins over a stale pick
        do {
            if sessionId == nil {
                let sid = try await API.shared.createSession(profile: profile)
                sessionId = sid
                if !choice.isDefault { AppModel.saveChoice(choice, profile: profile, session: sid) }
            }
            let run = try await API.shared.startRun(profile: profile, session: sessionId!, text: text,
                                                    choice: picked ? choice : .botDefault)
            runId = run
            lastSeq = nil
            status = "Thinking…"
            follow()
        } catch {
            isRunning = false
            status = nil
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard let run = runId else { return }
        status = "Stopping…"
        try? await API.shared.stopRun(profile: profile, run: run)
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
        guard let run = runId else { return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var finished = false
            var attempts = 0
            while !finished && !Task.isCancelled && attempts < 6 {
                do {
                    for try await ev in API.shared.events(profile: profile, run: run, after: lastSeq) {
                        if let s = ev.seq { lastSeq = s }
                        attempts = 0  // progress: only consecutive failures count toward giving up
                        if handle(ev) { finished = true; break }
                    }
                    if !finished { attempts += 1; try? await Task.sleep(for: .seconds(1)) }
                } catch APIError.http(let code, _) where code == 404 || code == 401 {
                    // The turn is gone from the Mac (finished long ago, or the bridge restarted): Hermes's
                    // transcript has the outcome, so reload it instead of retrying.
                    finished = true
                    if code == 401 { app?.signOut() }
                } catch {
                    if Task.isCancelled { break }
                    attempts += 1
                    status = "Reconnecting…"
                    try? await Task.sleep(for: .seconds(Double(min(attempts * 2, 8))))
                }
            }
            streamTask = nil
            if finished || attempts >= 6 { await finishRun(gaveUp: !finished) }
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
            if let last = items.last, last.kind == .tools {
                items[items.count - 1].tools.append(name)
            } else {
                items.append(ChatItem(id: "tools-\(UUID().uuidString)", kind: .tools, text: "", tools: [name]))
            }
            status = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
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
        if gaveUp { fail("Lost the connection. The reply may still finish on your Mac; pull down to refresh.") }
        lastLoadedCount = 0
        await load(quiet: true)  // Hermes's transcript is the source of truth
        await refreshServed()
    }

    private func fail(_ message: String) {
        error = message
        failedTick += 1
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
