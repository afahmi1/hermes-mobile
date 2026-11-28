import Foundation
import Observation

struct ToolActivity: Hashable, Identifiable {
    var id: String
    var name: String
    var preview: String
    var result: String
    var state: String
    /// When the step started and finished (epoch seconds): shown next to each step in the dropdown.
    var started: Double? = nil
    var ended: Double? = nil
}

struct ChatItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, assistant, tools, notice, control, activity }
    let id: String
    var kind: Kind
    var text: String
    var tools: [String] = []
    var activities: [ToolActivity] = []
    var media: [ChatMediaRef] = []
    /// Small copies on this phone of the photos this message carried (`SentPreviews`): shown at once while it
    /// uploads, and kept after a reload until (or instead of, if it's gone) the Mac's copy.
    var previews: [URL] = []
    /// The reply split at its images (bridge `content_parts`), so each image shows where Hermes put it.
    var parts: [ReplyPart]? = nil
    /// Structured background work behind an activity card (empty on older bridges: `detail` is shown).
    var entries: [ActivityEntry] = []
    var detail: String = ""
    var streaming = false
    var footer: String?
    var failed = false
    var timestamp: Double?
    /// Last tool-result time in a tool group, so the row can say how long the burst took.
    var ended: Double?
    /// Shown under a user message that carried project context (this send only).
    var contextNote: String?
    /// A small tag under a user message: sent mid-reply, pasted lines, replying to, model switched.
    var annotation: String?
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


/// One collapsed long paste, shown as a chip in the composer and sent with the next message.
struct PastedText: Identifiable, Equatable, Codable {
    var id = UUID()
    var text: String
    /// A reply quote: shown as a compact "Replying to" chip, sent as a Markdown quote ahead of the message.
    var quote: Bool? = nil
    /// Replying to several messages: your words for this quote (the newest quote's words are the main box).
    /// A quote whose `text` is empty is a plain segment left behind when its pill was removed.
    var answer: String? = nil
    var isQuote: Bool { quote == true }
}

/// Reply quotes in sent text: the leading `> ` lines of a message, shown as a small card above it.
enum ReplyQuote {
    static func split(_ text: String) -> (quote: String?, body: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix { $0.hasPrefix(">") }
        guard !head.isEmpty, head.count < lines.count else { return (nil, text) }
        let quote = head.map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.dropFirst(head.count).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, !body.isEmpty else { return (nil, text) }
        return (quote, body)
    }

    /// Every quote in a sent message with the words under it, in order: [(quote, body)]. A body before the first
    /// quote has quote nil. Lets a reply to three messages show three quote cards, each with its answer.
    static func segments(_ text: String) -> [(quote: String?, body: String)] {
        var out: [(String?, String)] = []
        var quote: [String] = [], body: [String] = []
        var inQuote = false
        func flush() {
            let q = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let b = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty || !b.isEmpty { out.append((q.isEmpty ? nil : q, b)) }
            quote = []; body = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if !inQuote && (!quote.isEmpty || !body.isEmpty) { flush() }
                inQuote = true
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else {
                inQuote = false
                body.append(String(line))
            }
        }
        flush()
        return out
    }

    /// What goes on the wire: a short Markdown quote Hermes reads as "this is what I'm replying to".
    static func markdown(_ excerpt: String) -> String {
        excerpt.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    /// One readable excerpt: plain text, collapsed blank lines, capped.
    static func excerpt(_ raw: String, limit: Int = 320) -> String {
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.count > limit ? String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : joined
    }
}
/// One chat: its transcript (from Hermes), its live run, and its model/provider/effort choice.
@MainActor @Observable
final class ChatModel {
    let profile: String
    private(set) var sessionId: String?
    var items: [ChatItem] = []
    var title: String?
    var isLoading = false
    var isRunning = false { didSet { if isRunning && !oldValue { runStarted = Date(); thinkingText = "" } } }
    /// When this reply started, for notification duration and per-run heads-up deduplication.
    @ObservationIgnored private(set) var runStarted: Date?
    var slashBusy = false
    var slashCommands: [SlashCommand] = SlashCommand.builtIn
    var skillCommands: [String] = []
    var skillDetails: [SkillInfo] = []
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

    private var draftID: UUID
    private let api = API.shared
    private weak var owner: AppModel?
    // Late work must never borrow the new gateway's account, including after A → B → A.
    private var app: AppModel? { API.shared === api ? owner : nil }
    private var recovery = StreamRecovery()
    private var confirmedPrimary = false
    private var outboxRevision = UUID()
    private var returningSend = false
    private var pendingSend: PendingSend?
    private var sendKey: String? {
        sessionId.flatMap { app?.inboxKey(profile: profile, filter: "outbox/" + $0) }
    }
    private var nextReceiptAttempt = Date.distantPast
    private var receiptBackoff = 1.0

    private var localNotes: [ChatItem] = []
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
    private let composerAccount: String?
    private var composerScope: String { Self.scope(profile, sessionId, startIn) }
    /// A Hermes project's new chat keeps its own unsent draft, apart from the bot's plain new chat.
    private static func scope(_ profile: String, _ sessionId: String?, _ startIn: String?) -> String {
        profile + "|" + (sessionId.map { "session/" + $0 } ?? startIn.map { "new/project/" + $0 } ?? "new")
    }
    /// The Hermes project this new chat starts in (its folder on the Mac). Nil for ordinary chats.
    let startIn: String?
    @ObservationIgnored private var restoringComposer = false
    var draft = "" { didSet { if oldValue != draft { persist(.text) } } }
    var draftAttachments: [SendAttachment] = [] { didSet { if oldValue != draftAttachments { persist(.media) } } }
    /// Large pastes (T3-style): kept out of the composer, sent with the next message.
    var pastedTexts: [PastedText] = [] { didSet { if oldValue != pastedTexts { persist(.pastes) } } }

    @ObservationIgnored private var needsDraftRestore = false
    @ObservationIgnored private var draftProblem: String?
    @ObservationIgnored private var failedDraftWrites = Set<ComposerDisk.Part>()
    var canEvictDraft: Bool {
        !needsDraftRestore && failedDraftWrites.isEmpty && (composerAccount != nil || (draft.isEmpty && pastedTexts.isEmpty && draftAttachments.isEmpty))
    }

    private func persist(_ part: ComposerDisk.Part) {
        guard !restoringComposer, let account = composerAccount, account == app?.inboxAccount else { return }
        if needsDraftRestore { failedDraftWrites.insert(part); return }
        do {
            let data: Data?
            switch part {
            case .text: data = draft.isEmpty ? nil : Data(draft.utf8)
            case .pastes: data = pastedTexts.isEmpty ? nil : try JSONEncoder().encode(pastedTexts)
            case .media: data = draftAttachments.isEmpty ? nil : try JSONEncoder().encode(draftAttachments)
            }
            try ComposerDisk.shared.write(data, part: part, account: account, scope: composerScope, id: draftID)
            failedDraftWrites.remove(part)
            clearDraftProblemIfRecovered()
        } catch {
            failedDraftWrites.insert(part)
            reportDraftProblem("This draft could not be saved on this device. " + error.localizedDescription)
        }
    }

    private func reportDraftProblem(_ message: String) {
        draftProblem = message
        error = message
    }

    private func clearDraftProblemIfRecovered() {
        guard !needsDraftRestore, failedDraftWrites.isEmpty, let draftProblem else { return }
        if error == draftProblem { error = nil }
        self.draftProblem = nil
    }

    func retryDraftStorage() {
        guard let account = composerAccount, account == app?.inboxAccount else { return }
        if needsDraftRestore {
            do {
                let saved = try ComposerDisk.shared.read(account, scope: composerScope)
                if let id = saved.id { draftID = id }
                restoringComposer = true
                if !failedDraftWrites.contains(.text) { draft = saved.text }
                if !failedDraftWrites.contains(.pastes) { pastedTexts = saved.pastes }
                if !failedDraftWrites.contains(.media) { draftAttachments = saved.media }
                restoringComposer = false
                needsDraftRestore = false
            } catch {
                reportDraftProblem("Couldn’t open the saved draft. " + error.localizedDescription)
                return
            }
        }
        for part in failedDraftWrites { persist(part) }
        clearDraftProblemIfRecovered()
    }

    /// What the next send actually delivers: the draft plus every pasted chunk.
    var combinedDraft: String {
        let quotes = pastedTexts.filter(\.isQuote)
        let extra = pastedTexts.filter { !$0.isQuote }.map(\.text).joined(separator: "\n\n")
        let body = extra.isEmpty ? draft : draft.isEmpty ? extra : draft + "\n\n" + extra
        guard !quotes.isEmpty else { return body }
        // > quote 1, your words for it, > quote 2, …, the newest quote, then the main box.
        var parts: [String] = []
        for (i, q) in quotes.enumerated() {
            if !q.text.isEmpty { parts.append(ReplyQuote.markdown(q.text)) }
            let words = (i == quotes.count - 1 ? body : (q.answer ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { parts.append(words) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Reply to a message. Replying to another one keeps the first: what you typed becomes your answer to the
    /// previous quote, and the box starts your answer to the new one.
    func setReplyQuote(_ raw: String) {
        let excerpt = ReplyQuote.excerpt(raw)
        guard !excerpt.isEmpty else { return }
        if pastedTexts.contains(where: { $0.isQuote && $0.text == excerpt }) { return }
        if let last = pastedTexts.lastIndex(where: \.isQuote) {
            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                let had = pastedTexts[last].answer ?? ""
                pastedTexts[last].answer = had.isEmpty ? typed : had + "\n\n" + typed
                draft = ""
            }
        }
        let at = (pastedTexts.lastIndex(where: \.isQuote).map { $0 + 1 }) ?? 0
        pastedTexts.insert(PastedText(text: excerpt, quote: true), at: at)
    }

    /// Remove a reply pill. Only the quote goes: the words you wrote for it stay where they were.
    func removeReplyQuote(_ id: UUID) {
        let quotes = pastedTexts.filter(\.isQuote)
        guard let i = quotes.firstIndex(where: { $0.id == id }), let at = pastedTexts.firstIndex(where: { $0.id == id }) else { return }
        let words = (quotes[i].answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if i == quotes.count - 1 {
            // The newest quote: its words are the main box, which now answers the quote before it (or nothing).
            pastedTexts.remove(at: at)
            // The quote that is newest now answers through the box: pull its words (and any plain segments
            // that ended up last) down into the box, in order.
            while let prev = pastedTexts.lastIndex(where: \.isQuote) {
                let carried = (pastedTexts[prev].answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                pastedTexts[prev].answer = nil
                if !carried.isEmpty { draft = draft.isEmpty ? carried : carried + "\n\n" + draft }
                guard pastedTexts[prev].text.isEmpty else { break }
                pastedTexts.remove(at: prev)
            }
        } else if words.isEmpty {
            pastedTexts.remove(at: at)
        } else {
            pastedTexts[at].text = ""  // keep the words as a plain segment in place
        }
    }

    /// "Edit as New Message" on a reply to several messages: every quote back as a pill with its words.
    func restoreReplies(from text: String) -> Bool {
        let segs = ReplyQuote.segments(text)
        guard segs.contains(where: { $0.quote != nil }) else { return false }
        pastedTexts.removeAll(where: \.isQuote)
        var restored: [PastedText] = []
        for (i, seg) in segs.enumerated() {
            let last = i == segs.count - 1
            restored.append(PastedText(text: seg.quote ?? "", quote: true, answer: last || seg.body.isEmpty ? nil : seg.body))
            if last { draft = seg.body }
        }
        pastedTexts.insert(contentsOf: restored, at: 0)
        return true
    }
    private var transcriptKey: String? {
        sessionId.flatMap { app?.inboxKey(profile: profile, filter: "transcript/" + $0) }
    }
    private var loadingTranscript = false
    private(set) var hasOlder = false
    /// Raw-row offset already consumed. Projected rows are fewer, so this is not `stored.count`.
    private var historyOffset = 0
    private(set) var loadingOlder = false
    /// The user picked a model/effort on this phone for this chat; it rides every turn until another
    /// device changes the session's setting.
    private var picked = false
    private var lastRuntimeRead: Date?
    private var lastPolicy: RuntimeChoice?
    /// Approvals already answered (here or anywhere): a replayed request for one is not shown again.
    private var resolvedApprovals = Set<String>()

    init(profile: String, sessionId: String?, app: AppModel, draftID: UUID = UUID(), startIn: String? = nil) {
        let account = app.inboxAccount
        self.composerAccount = account
        self.startIn = sessionId == nil ? startIn : nil
        let scope = Self.scope(profile, sessionId, self.startIn)
        let snapshot: ComposerDisk.Snapshot?
        var restoreError: Error?
        do { snapshot = try account.map { try ComposerDisk.shared.read($0, scope: scope) } }
        catch { snapshot = nil; restoreError = error }
        self.draftID = snapshot?.id ?? draftID
        self.profile = profile
        self.sessionId = sessionId
        self.owner = app
        restoringComposer = true
        if let snapshot {
            draft = snapshot.text
            pastedTexts = snapshot.pastes
            draftAttachments = snapshot.media
        }
        restoringComposer = false
        if let restoreError {
            needsDraftRestore = true
            reportDraftProblem("Couldn’t open the saved draft. " + restoreError.localizedDescription)
        }
        if let sid = sessionId, let saved = app.savedChoice(profile: profile, session: sid) {
            choice = saved
            picked = !saved.isDefault
        }
    }

    // MARK: loading

    func load(quiet: Bool = false, resumeLive: Bool = true) async {
        if outgoingLoadedFor != sendKey { Task { await loadOutgoing() } }
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
                    let paging = HistoryPaging.first(count: msgs.count, hasMore: page.hasMore, nextOffset: page.nextOffset)
                    historyOffset = paging.offset
                    hasOlder = paging.hasOlder
                    fillsScreen = true
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
                let revision = outboxRevision
                if let pending = try await InboxDisk.shared.pending(key) {
                    guard revision == outboxRevision, !returningSend, !isRunning, !Task.isCancelled, key == sendKey else { return }
                    if pending.returningToComposer == true || pendingSend?.returningToComposer == true {
                        pendingSend = pending
                        await returnSend(pending, key: key)
                        return
                    }
                    if pendingSend?.id != pending.id { clearStagedComposer(pending) }
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
        await fillScreen()
        let runtimeDue = !quiet || lastRuntimeRead.map { Date().timeIntervalSince($0) >= 30 } != false
        async let runtime: Void = runtimeDue ? refreshServed() : ()
        if resumeLive { await reattach() }
        await runtime
    }

    /// One long turn can be 100+ tool rows, so a fixed first page may hold a single "Worked 20m" card and no
    /// conversation. After a fresh first page, quietly load earlier pages until there's a screenful of real
    /// messages (yours and Hermes's answers), at most five pages.
    private var fillsScreen = false
    private func fillScreen() async {
        guard fillsScreen else { return }
        fillsScreen = false
        func conversation() -> Int {
            items.filter { $0.kind == .user || ($0.kind == .assistant && !$0.text.isEmpty) }.count
        }
        var pages = 0
        while hasOlder, pages < 5, conversation() < 10 {
            let before = stored.count
            await loadOlder()
            pages += 1
            if stored.count == before { break }
        }
    }

    func loadOlder() async {
        guard let sid = sessionId, hasOlder, !loadingOlder, !loadingTranscript else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let offset = historyOffset
        do {
            let page = try await api.messages(profile: profile, session: sid, offset: offset)
            guard !Task.isCancelled, sessionId == sid else { return }
            let ids = Set(stored.compactMap(\.id))
            let older = page.data.filter { row in row.id.map { !ids.contains($0) } ?? true }
            let paging = HistoryPaging.advance(offset: offset, added: older.count, hasMore: page.hasMore, nextOffset: page.nextOffset)
            historyOffset = paging.offset
            hasOlder = paging.hasOlder
            guard !older.isEmpty else { return }
            // A live reply lives only in `items` (the stream bubble and the running tool group). Rebuilding
            // the transcript from storage must keep that tail, or loading history mid-reply wipes the answer.
            let tailStart = items.firstIndex { $0.streaming || $0.id.hasPrefix("stream-") || $0.activities.contains { $0.id.hasPrefix("live-") } }
            let tail = tailStart.map { Array(items[$0...]) } ?? []
            stored.insert(contentsOf: older, at: 0)
            items = transcriptWithReceipts() + tail
            if let index = items.lastIndex(where: \.streaming) { streamingIndex = index }
            if let index = items.lastIndex(where: { $0.activities.contains { $0.state == "running" } }) { liveToolGroup = index }
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
        Task { await pump() }
        items = items.filter { $0.kind != .assistant || !$0.streaming }
        follow()
    }

    func refreshServed() async {
        guard let sid = sessionId, let s = try? await api.served(profile: profile, session: sid), app != nil else { return }
        lastRuntimeRead = Date()
        served = s
        // Hermes's session setting is the truth. Adopt it unless the user just picked something here,
        // and always adopt it when another device (the desktop) changed it since we last looked.
        if let pc = s.policyChoice {
            let changedElsewhere = lastPolicy != nil && pc != lastPolicy && pc != choice
            if changedElsewhere || !picked { choice = pc; picked = false }
            lastPolicy = pc
        }
    }

    private func transcriptWithReceipts() -> [ChatItem] {
        var rows = Self.transcript(stored)
        SentPreviews.attach(&rows, session: sessionId)
        // A receipt is the phone's note that Hermes took a queued or guiding message. Hermes's own transcript is the
        // truth: once that message is in it (with its "Guided this reply" label), the receipt is a duplicate and goes.
        // A receipt older than the loaded pages waits for its page, instead of piling up at the top with no replies.
        let earliest = rows.compactMap(\.timestamp).min()
        let delivered = Set(rows.filter { $0.kind == .user }.map { Self.receiptMatchKey($0.text) })
        var settled: [UUID] = []
        for receipt in receipts.sorted(by: { $0.at < $1.at }) {
            let t = receipt.at.timeIntervalSince1970
            if delivered.contains(Self.receiptMatchKey(receipt.text)) { settled.append(receipt.id); continue }
            if hasOlder, let earliest, t < earliest { continue }
            let next = rows.firstIndex { ($0.timestamp ?? 0) > t } ?? rows.endIndex
            rows.insert(receipt.item, at: next)
        }
        if !settled.isEmpty { forgetReceipts(settled) }
        rows += localNotes.filter { note in !rows.contains { $0.kind == note.kind && $0.text == note.text } }
        return rows
    }

    static func transcript(_ msgs: [StoredMessage]) -> [ChatItem] {
        var out: [ChatItem] = []
        var toolGroup: Int?
        for (i, m) in msgs.enumerated() {
            if m.displayKind == "hidden" { continue }
            let key = m.id.map(String.init) ?? "i\(i)"
            var text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if m.displayKind == "system_note" {
                toolGroup = nil
                out.append(ChatItem(id: key, kind: .notice, text: m.notice ?? "System note", timestamp: m.timestamp))
                continue
            }
            var annotation = m.note
            if m.role == "user", m.note == nil, !isActivity(m, text: text) {
                switch HarnessText.classify(text) {
                case .notice(let title):
                    toolGroup = nil
                    out.append(ChatItem(id: key, kind: .notice, text: title, timestamp: m.timestamp))
                    continue
                case .user(let words, let note):
                    text = words
                    annotation = note
                }
            }
            if isActivity(m, text: text) {
                toolGroup = nil
                let trimmedNotice = m.notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = trimmedNotice.isEmpty ? activityTitle(text) : trimmedNotice
                let failed = m.ok == false || text.localizedCaseInsensitiveContains("status=failed") || text.contains("✗")
                var row = ChatItem(id: key, kind: .activity, text: title, detail: text == title ? "" : text,
                                   failed: failed, timestamp: m.timestamp)
                row.entries = m.activity ?? []
                out.append(row)
                continue
            }
            switch m.role {
            case "user":
                toolGroup = nil
                if !text.isEmpty || !(m.media ?? []).isEmpty {
                    var row = ChatItem(id: key, kind: .user, text: text, media: m.media ?? [], timestamp: m.timestamp)
                    row.annotation = annotation
                    out.append(row)
                }
            case "assistant":
                let calls = m.toolCalls ?? []
                if !calls.isEmpty {
                    let activities = calls.enumerated().map { offset, call in
                        ToolActivity(id: key + "-\(offset)", name: call.function?.name ?? "tool",
                                     preview: call.preview ?? "", result: "", state: "done", started: m.timestamp)
                    }
                    if let toolGroup {
                        out[toolGroup].activities += activities
                        out[toolGroup].tools += activities.map(\.name)
                    } else {
                        toolGroup = out.count
                        out.append(ChatItem(id: key + "t", kind: .tools, text: "", tools: activities.map(\.name),
                                            activities: activities, timestamp: m.timestamp))
                    }
                }
                if !text.isEmpty || !(m.media ?? []).isEmpty {
                    var row = ChatItem(id: key, kind: .assistant, text: text, media: m.media ?? [], timestamp: m.timestamp)
                    row.parts = m.contentParts
                    out.append(row)
                }
            case "tool":
                guard let toolGroup, let idx = out[toolGroup].activities.firstIndex(where: {
                    $0.result.isEmpty && (m.toolName == nil || m.toolName == $0.name || m.toolName?.isEmpty == true)
                }) else { continue }
                if m.ok == false { out[toolGroup].activities[idx].state = "failed" }
                if let preview = m.preview, !preview.isEmpty { out[toolGroup].activities[idx].result = preview }
                out[toolGroup].activities[idx].ended = m.timestamp
                if let end = m.timestamp { out[toolGroup].ended = end }
            default:
                continue
            }
        }
        return out
    }

    private static func isActivity(_ m: StoredMessage, text: String) -> Bool {
        if m.displayKind == "async_delegation_complete" || m.displayKind == "process_complete" { return true }
        if m.role == "system" { return !text.isEmpty || m.notice?.isEmpty == false }
        let opened = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return opened.hasPrefix("[ASYNC DELEGATION") || opened.hasPrefix("[BACKGROUND PROCESS")
            || opened.hasPrefix("[PROCESS COMPLETE") || opened.hasPrefix("[SUBAGENT")
    }

    private static func activityTitle(_ text: String) -> String {
        if text.hasPrefix("[") { return "Background work finished" }
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Background work finished"
        return line.count > 180 ? String(line.prefix(180)) : line
    }

    // MARK: runtime choice

    /// A guarded model waiting for the person's yes: Hermes's own warning, shown before anything is written.
    struct RuntimeConfirmation: Identifiable, Equatable {
        let id = UUID()
        let choice: RuntimeChoice
        let title: String
        let message: String
    }
    var runtimeConfirmation: RuntimeConfirmation?

    func apply(_ new: RuntimeChoice, confirm: Bool = false) async {
        guard new != choice || confirm, !savingRuntime else { return }
        guard let sid = sessionId else { choice = new; picked = !new.isDefault; return }
        savingRuntime = true
        defer { savingRuntime = false }
        let previous = lastPolicy ?? choice
        do {
            let lock = try await api.lockRuntime(profile: profile, session: sid, choice: new, previous: previous, confirm: confirm)
            if case .needsConfirmation(let title, let message) = lock {
                runtimeConfirmation = RuntimeConfirmation(choice: new, title: title, message: message)
                return
            }
            let deferred = lock == .nextTurn
            guard app != nil else { return }
            choice = new
            picked = !new.isDefault
            app?.saveChoice(new, profile: profile, session: sid)
            RecentModels.record(new, profile: profile)
            if !items.isEmpty {
                // Local marker only: not sent to Hermes, and it may vanish when history reloads.
                let text = new.isDefault ? "Back to bot default" : "Switched to " + [new.model ?? "bot default model", new.effort.flatMap { Effort(rawValue: $0)?.label }].compactMap { $0 }.joined(separator: " · ")
                items.append(ChatItem(id: "n-switch-\(UUID().uuidString)", kind: .notice, text: text))
            }
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
    /// The bot's commands and every skill. Shown at once from the last copy this phone saw, then refreshed;
    /// retried while the Mac is reconnecting, so a chat opened mid-reconnect doesn't stay on the short built-in list.
    func loadPalette() async {
        let cacheKey = "\(api.accountID ?? "-")|\(profile)"
        if skillDetails.isEmpty, let saved = PaletteCache.load(cacheKey) { apply(saved) }
        var wait: UInt64 = 1
        for _ in 0..<6 {
            if let page = try? await api.commandPalette(profile: profile) {
                guard app != nil else { return }
                apply(page)
                PaletteCache.save(page, key: cacheKey)
                return
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 15)
        }
    }

    private func apply(_ page: CommandPalette) {
        if !page.commands.isEmpty { slashCommands = page.commands }
        skillCommands = page.skills
        skillDetails = page.skillDetails ?? page.skills.map { SkillInfo(name: $0) }
    }

    // MARK: pinned messages

    /// Newest pin first. Lives on the bridge, so every device signed in to this gateway sees the same stack.
    private(set) var pins: [MessagePin] = []
    private(set) var pinsAvailable = true
    @ObservationIgnored private var pinWork: Set<Int> = []

    func isPinned(_ item: ChatItem) -> Bool {
        guard let id = MessagePin.messageID(for: item) else { return false }
        return pins.contains { $0.messageId == id }
    }

    func loadPins() async {
        guard let sid = sessionId else { pins = []; return }
        do {
            let latest = try await api.pins(profile: profile, session: sid)
            guard !Task.isCancelled, sessionId == sid else { return }
            pins = latest
            pinsAvailable = true
        } catch APIError.http(404, _) {
            // A bridge from before pinned messages: hide the feature instead of reporting an error.
            pinsAvailable = false
        } catch {
            // Pins are an overlay; a failed refresh keeps what is already shown.
        }
    }

    func togglePin(_ item: ChatItem) async {
        guard let sid = sessionId, let mid = MessagePin.messageID(for: item), !pinWork.contains(mid) else { return }
        pinWork.insert(mid)
        defer { pinWork.remove(mid) }
        do {
            let latest = isPinned(item)
                ? try await api.unpin(profile: profile, session: sid, message: mid)
                : try await api.pin(profile: profile, session: sid, message: mid)
            guard sessionId == sid else { return }
            pins = latest
        } catch where ActionQueue.isOffline(error) {
            guard let account = API.shared.accountID else { return }
            let unpinning = isPinned(item)
            _ = await ActionQueue.shared.perform(QueuedAction(account: account, kind: unpinning ? .unpinMessage : .pinMessage,
                                                              profile: profile, session: sid, message: mid))
            if unpinning { pins.removeAll { $0.messageId == mid } }
            self.error = unpinning ? nil : "Saved. It's pinned as soon as your Mac answers."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unpin(_ pin: MessagePin) async {
        guard let sid = sessionId else { return }
        do {
            let latest = try await api.unpin(profile: profile, session: sid, message: pin.messageId)
            if sessionId == sid { pins = latest }
        } catch where ActionQueue.isOffline(error) {
            guard let account = API.shared.accountID else { return }
            _ = await ActionQueue.shared.perform(QueuedAction(account: account, kind: .unpinMessage, profile: profile,
                                                              session: sid, message: pin.messageId))
            pins.removeAll { $0.messageId == pin.messageId }
        } catch { self.error = error.localizedDescription }
    }

    func unpinAll() async {
        guard let sid = sessionId else { return }
        do {
            try await api.unpinAll(profile: profile, session: sid)
            if sessionId == sid { pins = [] }
        } catch { self.error = error.localizedDescription }
    }

    /// Loads earlier pages until the pinned message is in the transcript. Returns false when Hermes no
    /// longer has it (compressed or deleted); the pin's own snapshot still shows the text.
    /// A message Hermes has stored (its id is the messages.id), so a chat can branch from it.
    func canBranch(from item: ChatItem) -> Bool {
        sessionId != nil && !isRunning && !branching && (item.kind == .user || item.kind == .assistant) && Int(item.id) != nil
    }
    private(set) var branching = false

    /// Branch this chat at a message and open the new chat. Same branch as the desktop's: nested under this
    /// chat everywhere, titled "<this chat> #2" unless Hermes is told otherwise.
    func branch(from item: ChatItem) async {
        guard canBranch(from: item), let sid = sessionId, let message = Int(item.id) else { return }
        branching = true
        defer { branching = false }
        do {
            let made = try await api.branch(profile: profile, session: sid, message: message)
            if made.compressed == true, let app {
                let next = app.chat(for: ChatRef(profile: profile, sessionId: made.sessionId))
                next.error = "That message was in a part of the chat Hermes had compressed, so the branch starts from its summary."
            }
            app?.inboxPath = [ChatRef(profile: profile, sessionId: made.sessionId)]
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reveal(_ pin: MessagePin) async -> Bool { await reveal(itemID: pin.itemID) }

    /// Load earlier pages until this stored message is in `items` (a pin, a search hit). False when it isn't in
    /// the chat's history any more.
    func reveal(itemID: String) async -> Bool {
        var pages = 0
        while !items.contains(where: { $0.id == itemID }) {
            guard hasOlder, pages < 40 else { return false }
            let before = stored.count
            await loadOlder()
            pages += 1
            if stored.count == before { return false }
        }
        return true
    }

    func acceptsSlash(_ raw: String) -> Bool {
        guard draftAttachments.isEmpty, let name = SlashCommand.name(in: raw) else { return false }
        return slashCommands.contains { $0.name == name } || skillCommands.contains(name)
    }

    /// Hermes runs the command. A `send` result becomes the next turn, with the short label in the bubble.
    func runSlash(_ raw: String) async {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !slashBusy, acceptsSlash(command) else { return }
        let account = app?.inboxAccount
        let authored = draft
        let authoredPastes = pastedTexts
        slashBusy = true
        error = nil
        status = "Running /\(SlashCommand.name(in: command) ?? "command")…"
        do {
            guard let account, account == app?.inboxAccount else { throw APIError.notSignedIn }
            if sessionId == nil {
                let sid = try await api.createSession(profile: profile, draftID: draftID, project: startIn)
                guard account == app?.inboxAccount else { throw APIError.notSignedIn }
                try ComposerDisk.shared.move(account, from: composerScope, to: profile + "|session/" + sid, id: draftID)
                sessionId = sid
                if !choice.isDefault { app?.saveChoice(choice, profile: profile, session: sid) }
                // Anything queued during these first seconds can be saved to disk now that the chat has an id.
                Task { await loadOutgoing() }
            }
            guard let sid = sessionId else { throw APIError.notSignedIn }
            draft = ""
            pastedTexts = []
            let result = try await api.slash(profile: profile, session: sid, command: command)
            guard account == app?.inboxAccount else { throw APIError.notSignedIn }
            let title = result.display ?? result.notice ?? command
            if let output = result.output ?? result.warning, !output.isEmpty {
                let note = ChatItem(id: "slash-\(UUID().uuidString)", kind: .activity, text: title, detail: output)
                items.append(note)
                localNotes.append(note)
            } else if result.message == nil {
                items.append(ChatItem(id: "slash-\(UUID().uuidString)", kind: .notice, text: title))
            }
            slashBusy = false
            status = nil
            if let message = result.message, ["send", "skill", "prefill"].contains(result.type ?? "") {
                await send(message, shown: result.display ?? title)
            }
        } catch {
            draft = authored
            pastedTexts = authoredPastes
            slashBusy = false
            status = nil
            self.error = error.localizedDescription
        }
    }

    func send(_ raw: String, projectContext: String? = nil, attachments: [SendAttachment] = [], shown: String? = nil,
              id: UUID = UUID(), fromQueue: Bool = false) async {
        if needsDraftRestore && !fromQueue {
            retryDraftStorage()
            // A restore can merge a previously hidden paste or attachment. Review before sending.
            if needsDraftRestore || raw != combinedDraft || attachments != draftAttachments { return }
        }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !slashBusy, !message.isEmpty || !attachments.isEmpty else { return }
        let text = message.isEmpty ? "Describe the attached media." : message
        if pendingSend != nil {
            error = "Reconnecting the previous send. Your next message is saved in the composer."
            return
        }
        let account = app?.inboxAccount
        // A queued message never came from the composer as it is now: leave the message box alone.
        let authoredText: String? = fromQueue ? nil : draft
        let authoredPastes: [PastedText]? = fromQueue ? nil : pastedTexts
        isRunning = true
        error = nil
        status = "Sending…"
        do {
            if picked && sessionId != nil { await refreshServed() }
            guard let account, account == app?.inboxAccount else { throw APIError.notSignedIn }
            if sessionId == nil {
                let sid = try await api.createSession(profile: profile, draftID: draftID, project: startIn)
                guard account == app?.inboxAccount else { throw APIError.notSignedIn }
                try ComposerDisk.shared.move(account, from: composerScope, to: profile + "|session/" + sid, id: draftID)
                sessionId = sid
                if !choice.isDefault { app?.saveChoice(choice, profile: profile, session: sid) }
                // Anything queued during these first seconds can be saved to disk now that the chat has an id.
                Task { await loadOutgoing() }
            }
            guard let sid = sessionId, let key = sendKey else { throw APIError.notSignedIn }
            let send = PendingSend(id: id, text: text, choice: picked ? choice : .botDefault, project: projectContext, attachments: attachments.isEmpty ? nil : attachments, composerText: authoredText, composerPastes: authoredPastes)
            try await InboxDisk.shared.stage(send, key: key)
            guard key == sendKey else { throw APIError.notSignedIn }
            pendingSend = send
            ReplyNotifier.shared.askOnce()
            clearStagedComposer(send)
            var local = ChatItem(id: send.id.uuidString, kind: .user, text: shown ?? text)
            if projectContext != nil { local.contextNote = "Project instructions + reference files sent with this message" }
            items.append(local)
            if attachments.contains(where: { $0.mime.hasPrefix("image/") }) {
                // Show the photos in the sent message right away, with the upload's progress over them.
                let sendID = send.id.uuidString, words = text
                uploadingItem = sendID
                uploadFraction = 0
                Task {
                    let urls = await Task.detached(priority: .userInitiated) {
                        SentPreviews.make(send: sendID, session: sid, text: words, attachments: attachments)
                    }.value
                    if let i = items.firstIndex(where: { $0.id == sendID }), items[i].previews.isEmpty { items[i].previews = urls }
                }
            }
            await deliver(send, session: sid, key: key, allowLegacy: true)
        } catch {
            isRunning = false
            status = nil
            fail(error.localizedDescription)
        }
    }

    /// True while a staged send is still waiting for the bridge to confirm it.
    var hasUnconfirmedSend: Bool { pendingSend != nil && !isRunning && !returningSend }

    /// Give up on a send the bridge never confirmed and return its text and files to the composer.
    /// The bridge may still have accepted it, so the person is told to check the chat first.
    func cancelUnconfirmedSend() async {
        guard hasUnconfirmedSend, let send = pendingSend, let key = sendKey else { return }
        await returnSend(send, key: key)
    }

    private func returnSend(_ send: PendingSend, key: String, reason: String? = nil) async {
        guard !returningSend, key == sendKey, let account = composerAccount else { return }
        returningSend = true
        outboxRevision = UUID()
        defer { returningSend = false; outboxRevision = UUID() }
        var returning = send
        returning.returningToComposer = true
        pendingSend = returning
        do {
            // Persist the decision before any await that could let the process suspend. Subsequent
            // launches must finish the return instead of attempting delivery again.
            try await InboxDisk.shared.stage(returning, key: key)
            guard key == sendKey else { return }
            retryDraftStorage()
            guard canEvictDraft else { throw CocoaError(.fileWriteUnknown) }
            let snapshot = try ComposerDisk.shared.restoreSend(returning, account: account, scope: composerScope, id: draftID)
            restoringComposer = true
            draft = snapshot.text
            pastedTexts = snapshot.pastes
            draftAttachments = snapshot.media
            restoringComposer = false
            // A file whose phone copy is gone can't be sent again: leave it out instead of failing the next send too.
            let gone = UploadFiles.missing(draftAttachments)
            if !gone.isEmpty { draftAttachments.removeAll { gone.contains($0) } }
            try await InboxDisk.shared.acknowledge(send.id, key: key)
            guard key == sendKey else { return }
            pendingSend = nil
            items.removeAll { $0.id == send.id.uuidString }
            receiptBackoff = 1
            nextReceiptAttempt = .distantPast
            if let reason { fail(reason) }
            else { error = "Moved back to the composer. Refresh the chat to check whether Hermes already received it." }
        } catch {
            self.error = "Couldn’t finish returning this send. Reopen the chat to try again. " + error.localizedDescription
        }
    }

    private func clearStagedComposer(_ send: PendingSend) {
        if let original = send.composerText, draft == original { draft = "" }
        if let pastes = send.composerPastes, pastedTexts == pastes { pastedTexts = [] }
        if send.composerText != nil, draftAttachments == (send.attachments ?? []) { draftAttachments = [] }
    }

    /// The sent message whose photos are uploading now, and how far along (shown over its photos).
    var uploadingItem: String?
    var uploadFraction: Double?

    /// "Uploading 42%…" while a big file goes up. Resumes, so the number never goes backwards much.
    private var uploadProgress: @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self else { return }
                guard fraction < 1 else { self.uploadFraction = nil; return }
                self.uploadFraction = fraction
                self.status = "Uploading \(Int(fraction * 100))%…"
            }
        }
    }

    private func deliver(_ send: PendingSend, session: String, key: String, allowLegacy: Bool) async {
        do {
            let run: String
            do {
                run = try await api.startRun(profile: profile, session: session, text: send.text,
                                                    choice: send.choice, projectContext: send.project, submission: send.id,
                                                    attachments: send.attachments ?? [], recovering: !allowLegacy,
                                                    progress: uploadProgress)
            } catch APIError.http(404, _) where allowLegacy && send.attachments == nil {
                // Legacy sends cannot be repeated safely. Keep the authored data recoverable
                // across a crash, but turn off automatic delivery before the single legacy POST.
                var legacy = send
                legacy.returningToComposer = true
                try await InboxDisk.shared.stage(legacy, key: key)
                guard sendKey == key else { throw APIError.notSignedIn }
                pendingSend = legacy
                run = try await api.startRun(profile: profile, session: session, text: send.text,
                                                    choice: send.choice, projectContext: send.project)
            }
            guard key == sendKey else { throw APIError.notSignedIn }
            uploadingItem = nil
            uploadFraction = nil
            error = nil
            receiptBackoff = 1
            nextReceiptAttempt = .distantPast
            recovery = StreamRecovery()
            liveToolGroup = nil
            runId = run
            status = "Thinking…"
            follow()
            Task { await pump() }
        } catch {
            isRunning = false
            status = nil
            uploadingItem = nil
            uploadFraction = nil
            // Queued follow-ups stay saved; they go once this send is confirmed or returned.
            guard sendKey == key else { return }
            if outgoing.contains(where: { $0.id == send.id }) {
                // This was a queued message going out as the next message. It still lives in the outbox, so it is
                // never thrown back into the composer (that would make a second copy). Busy: wait. Refused: mark it.
                try? await InboxDisk.shared.acknowledge(send.id, key: key)
                pendingSend = nil
                if case APIError.http(let code, let message) = error, [400, 413, 415, 422].contains(code) {
                    update(send.id) { $0.problem = message.isEmpty ? "Hermes refused this message." : message }
                    await persistOutgoing()
                } else if let problem = error as? UploadProblem, !problem.isTransient {
                    update(send.id) { $0.problem = problem.localizedDescription }
                    await persistOutgoing()
                } else {
                    Task { await reattach(); await pump() }
                }
                return
            }
            // Auth failures and a missing route on a recovered send can arrive
            // after delivery. Keep that original UUID until the bridge can confirm it.
            if case APIError.http(let code, _) = error,
               [400, 409, 413, 415, 422].contains(code) || (allowLegacy && [403, 404].contains(code)) {
                await returnSend(send, key: key, reason: error.localizedDescription)
            } else if let problem = error as? UploadProblem, !problem.isTransient {
                // A file that is gone, a full Mac, a file the Mac keeps refusing: waiting won't fix any of them.
                await returnSend(send, key: key, reason: problem.localizedDescription
                                 + (problem == .macFull ? "" : " Your message is back in the message box."))
            } else if pendingSend?.returningToComposer != true {
                nextReceiptAttempt = Date().addingTimeInterval(receiptBackoff)
                // The first failure is news. Later silent retries must not buzz the phone once a minute.
                let first = receiptBackoff <= 1
                receiptBackoff = min(60, receiptBackoff * 2)
                let busy = (error as? UploadProblem) == .macBusy
                    || { if case APIError.http(let code, _) = error { return [502, 503, 504].contains(code) }; return false }()
                let waiting = busy ? "Your Mac is busy. Your message is saved and sends when it’s ready."
                    : "Waiting to confirm your send. Reopening this chat will check the same submission."
                if first { fail(waiting) } else { self.error = waiting }
            } else {
                await returnSend(send, key: key, reason: "The bridge could not confirm delivery. Check the saved chat before sending again.")
            }
        }
    }

    var acceptsFollowUp: Bool { isRunning && runId != nil && !sendingFollowUp && !savingRuntime }

    // MARK: Run phase

    /// What this chat is doing, derived from the flags that used to be checked in ad-hoc combinations.
    enum RunPhase: Equatable {
        case idle                // nothing running; a new message can start
        case starting            // a reply is starting or a send awaits confirmation: no run id yet
        case replying(String)    // a reply is running under this run id
        case busy                // a slash command or a returning send owns the chat
    }

    var runPhase: RunPhase {
        if slashBusy || returningSend { return .busy }
        if isRunning, let runId { return .replying(runId) }
        if isRunning || pendingSend != nil { return .starting }
        return .idle
    }

    // MARK: Outbox: Send next and Guide, durable on this phone until Hermes has them

    /// Messages waiting to go, oldest first. Saved to disk before any network call.
    private(set) var outgoing: [Outgoing] = []
    /// The chat's queue as Hermes holds it on the Mac. Nil until read, or from an older bridge.
    private(set) var queue: QueueState?
    private(set) var queueControls = true
    private var outgoingLoadedFor: String?
    private var pumping = false
    private var pumpAgain = false
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Double = 2

    /// Compatibility for the composer: true while anything is waiting to go.
    var hasOutgoing: Bool { !outgoing.isEmpty }

    private func loadOutgoing() async {
        guard let key = sendKey, outgoingLoadedFor != key else { return }
        let saved = await InboxDisk.shared.outgoing(key)
        guard key == sendKey else { return }
        outgoingLoadedFor = key
        // Anything typed before the chat had an id (the first seconds of a new chat) joins the saved list.
        let fresh = outgoing.filter { o in !saved.contains { $0.id == o.id } }
        outgoing = saved + fresh
        outgoingFiles = UploadFiles.names(saved.flatMap { $0.attachments ?? [] })
        if !fresh.isEmpty { await persistOutgoing() }
        if !outgoing.isEmpty { await pump() }
    }

    private func persistOutgoing() async {
        guard let key = sendKey else { return }   // a brand-new chat: saved as soon as it has an id
        let saving = outgoing
        do {
            try await InboxDisk.shared.saveOutgoing(saving, key: key)
            // Files of messages that left the tray (started, guided, removed) are no longer needed on the phone.
            let now = UploadFiles.names(saving.flatMap { $0.attachments ?? [] })
            let left = outgoingFiles.subtracting(now)
            outgoingFiles = now
            if !left.isEmpty { releaseUploads(names: left) }
        }
        catch { self.error = "Couldn't save your queued message on this phone. Keep the app open until it sends." }
    }

    /// Upload files the saved tray last pointed at.
    @ObservationIgnored private var outgoingFiles = Set<String>()

    /// Delete the phone's upload copies of these attachments unless this chat still uses them: in the draft,
    /// a send waiting for confirmation, or the tray.
    func releaseUploads(_ attachments: [SendAttachment]) { releaseUploads(names: UploadFiles.names(attachments)) }

    private func releaseUploads(names: Set<String>) {
        let inUse = UploadFiles.names(draftAttachments + (pendingSend?.attachments ?? []) + outgoing.flatMap { $0.attachments ?? [] })
        let unused = names.subtracting(inUse)
        guard !unused.isEmpty else { return }
        UploadFiles.discard(unused.map { SendAttachment(mime: "", filename: "", base64: "", localFile: $0) })
    }

    /// The person removed an attachment chip: it leaves the draft and, unless something else here uses it,
    /// its copy leaves the phone.
    func removeDraftAttachment(at index: Int) {
        guard draftAttachments.indices.contains(index) else { return }
        let removed = draftAttachments.remove(at: index)
        releaseUploads([removed])
    }

    private func update(_ id: UUID, _ change: (inout Outgoing) -> Void) {
        guard let i = outgoing.firstIndex(where: { $0.id == id }) else { return }
        change(&outgoing[i])
    }

    /// Send while Hermes is replying: queue it. Works from the first second of a run and with no connection.
    func queueNext(_ raw: String, attachments: [SendAttachment]) async -> Bool {
        await enqueue(raw, mode: "queue", attachments: attachments)
    }

    // MARK: failed replies

    /// Messages the Mac will send later in this chat (bridge `schedule_v1`).
    var scheduled: [API.ScheduledSend] = []

    static func isFailedTurn(_ text: String) -> Bool {
        text.hasPrefix("Your request was not processed") || text.hasPrefix("This turn did not complete")
    }

    /// The person's message a failed reply was answering.
    func askBefore(_ itemID: String) -> String? {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return items[..<i].last(where: { $0.kind == .user && !$0.text.isEmpty })?.text
    }

    func retryNow(_ itemID: String) async {
        guard let ask = askBefore(itemID) else { error = "Couldn't find the message to resend."; return }
        if isRunning { _ = await enqueue(ask, mode: "queue", attachments: []) } else { await send(ask) }
    }

    func retryLater(_ itemID: String, at date: Date, reason: String) async {
        guard let ask = askBefore(itemID), let sid = sessionId else { error = "Couldn't find the message to resend."; return }
        do {
            scheduled = try await api.schedule(profile: profile, session: sid, action: "schedule",
                                               body: ["text": ask, "at": date.timeIntervalSince1970, "reason": reason])
        } catch APIError.http(404, _) {
            error = "Update the bridge on your Mac to schedule a retry."
        } catch {
            self.error = "Couldn't reach your Mac to schedule it. Try again in a moment."
        }
    }

    func cancelScheduled(_ id: String) async {
        guard let sid = sessionId else { return }
        scheduled.removeAll { $0.id == id }
        scheduled = (try? await api.schedule(profile: profile, session: sid, action: "unschedule", body: ["id": id])) ?? scheduled
    }

    func refreshScheduled() async {
        guard let sid = sessionId else { return }  // an older bridge answers 404; nothing shows
        if let rows = try? await api.schedule(profile: profile, session: sid, action: "scheduled") { scheduled = rows }
    }

    // MARK: thinking

    /// Hermes's reasoning for the current reply (streamed), and a counter that moves on every new step.
    var thinkingText = ""
    var activityTick = 0
    private func appendThinking(_ s: String) {
        thinkingText += s
        if thinkingText.count > 24_000 { thinkingText = String(thinkingText.suffix(20_000)) }
    }

    // MARK: Hermes's questions

    /// Questions Hermes is waiting on (its clarify tool asks 1 to 5 at once), oldest first.
    var questions: [ClarifyRequest] = []
    var question: ClarifyRequest? { questions.first }
    @ObservationIgnored private var answeredQuestions = Set<String>()
    private(set) var answering = false

    /// Answer the oldest open question (a message typed while Hermes waits).
    func answerQuestion(_ raw: String) async -> Bool {
        guard let q = question else { return false }
        return await answer([q.id: raw])
    }

    /// Send answers for several questions at once (the question panel's Submit). Each goes as Hermes's own
    /// clarify answer; whatever went through is shown as your message, whatever failed stays open.
    func answer(_ answers: [String: String]) async -> Bool {
        guard !answering else { return false }
        answering = true
        defer { answering = false }
        var sent: [(ClarifyRequest, String)] = []
        for q in questions {
            guard let raw = answers[q.id] else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            do {
                try await api.answerQuestion(run: q.runId.isEmpty ? (runId ?? "") : q.runId, requestId: q.id,
                                             answer: text, generation: q.generation)
                answeredQuestions.insert(q.id)
                sent.append((q, text))
            } catch {
                self.error = "Couldn't send your answer: " + error.localizedDescription
            }
        }
        guard !sent.isEmpty else { return false }
        questions.removeAll { q in sent.contains { $0.0.id == q.id } }
        var bubble = ChatItem(id: "answer-\(sent[0].0.id)", kind: .user,
                              text: sent.count == 1 ? sent[0].1 : sent.map { "\($0.0.question)\n→ \($0.1)" }.joined(separator: "\n\n"))
        bubble.contextNote = sent.count == 1 ? "Answered: " + String(sent[0].0.question.prefix(80)) : "Answered \(sent.count) questions"
        if !items.contains(where: { $0.id == bubble.id }) { items.append(bubble) }
        if questions.isEmpty { status = "Working…" }
        return sent.count == answers.count
    }

    /// Queue (Send next) or steer (Guide this reply). Returns true once it is safely on disk.
    func enqueue(_ raw: String, mode: String, attachments: [SendAttachment]) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        // Hermes is waiting on a question: what you send is the answer, as in any conversation.
        if question != nil, attachments.isEmpty, !text.isEmpty { return await answerQuestion(text) }
        var pick = mode == "queue" && picked ? choice : RuntimeChoice.botDefault
        if pick.model == nil, pick.effort != nil, let bot = app?.bot(profile) { pick.model = bot.model; pick.provider = bot.provider }
        let item = Outgoing(id: UUID(), mode: mode, text: text, attachments: attachments.isEmpty ? nil : attachments,
                            choice: pick, created: Date(), files: attachments.count)
        outgoing.append(item)
        await persistOutgoing()
        if attachments.contains(where: { $0.mime.hasPrefix("image/") }) {
            let id = item.id.uuidString, session = sessionId
            Task.detached(priority: .utility) { SentPreviews.make(send: id, session: session, text: text, attachments: attachments) }
        }
        if draftAttachments == attachments { draftAttachments = [] }
        ReplyNotifier.shared.askOnce()
        Task { await pump() }
        return true
    }

    /// Deliver what can go now, in order. Single-flight; safe to call from anywhere, any time.
    func pump() async {
        if pumping { pumpAgain = true; return }
        pumping = true
        defer { pumping = false }
        repeat {
            pumpAgain = false
            await pumpOnce()
        } while pumpAgain
        scheduleRetry()
    }

    private func pumpOnce() async {
        guard sendKey != nil else { return }
        for item in outgoing {
            guard let current = outgoing.first(where: { $0.id == item.id }) else { continue }
            switch current.phase {
            case .needsYou:
                return                                      // keep order: the person decides on this one first
            case .onMac:
                continue
            case .editPending(let text) where current.onMac:
                await applyEdit(current, text: text)
                continue
            case .onPhone, .retrying, .editPending:
                break
            }
            switch runPhase {
            case .replying(let run) where !savingRuntime:
                guard await deliverFollowUp(current, run: run) else { return }
            case .idle:
                // Nothing running: a queued message is simply the next message, and a steer whose reply already
                // ended goes the same way. Same UUID, so a copy that already landed is not repeated.
                var next = current.demotedToQueue(note: "The reply it was meant to guide had finished, so it went as a new message.")
                if let edit = next.edit { next.text = edit }
                await sendQueued(next)
                return                                      // the rest wait for this new reply
            case .replying, .starting, .busy:
                return                                      // wait for a run id or for the chat to be free
            }
        }
    }

    /// One follow-up to the running reply. False stops the pump (offline, or the person must decide).
    private func deliverFollowUp(_ item: Outgoing, run: String) async -> Bool {
        update(item.id) { $0 = $0.attempted() }
        let text = item.edit ?? item.text
        do {
            // The original words with the original ID: if a lost acknowledgment means the Mac already has it,
            // Hermes answers with that same admission instead of filing a second copy. Edits apply after.
            let (accepted, admission) = try await api.followUpReceipt(run: run, mode: item.mode, text: item.text,
                                                                      submission: item.id, choice: item.choice ?? .botDefault,
                                                                      attachments: item.attachments ?? [], progress: uploadProgress)
            retryDelay = 2
            if error?.hasPrefix("Waiting to send") == true { error = nil }
            if item.mode == "steer" {
                outgoing.removeAll { $0.id == item.id }
                await recordReceipt(ControlReceipt(id: item.id, mode: "steer", text: item.text, at: Date(), files: accepted))
            } else {
                // Hermes has it now (state.db). Files are no longer needed on the phone.
                update(item.id) { $0 = $0.accepted(admission: admission ?? "turn:" + run, files: accepted) }
                if item.edit != nil, let now = outgoing.first(where: { $0.id == item.id }) { await applyEdit(now, text: text) }
            }
            await persistOutgoing()
            Task { await refreshQueue() }
            return true
        } catch APIError.http(let code, let message) where code == 404 || code == 409 {
            // The reply ended (or this bridge restarted) between the tap and the request. Never an error to
            // the person: the message waits for the next safe moment and goes as the next message.
            if code == 409, !message.contains("no longer") && !message.contains("not started") && !message.contains("Refresh") {
                return refuse(item, message)
            }
            update(item.id) { $0 = $0.demotedToQueue(note: "The reply had finished, so this goes as the next message.") }
            await persistOutgoing()
            if isRunning, runId == run { runId = nil; isRunning = false; status = nil }
            pumpAgain = true
            return false
        } catch APIError.http(let code, let message) where [400, 413, 415, 422].contains(code) {
            return refuse(item, message)
        } catch let problem as UploadProblem where !problem.isTransient {
            return refuse(item, problem.localizedDescription)
        } catch {
            // Offline, timed out, the Mac asleep. It stays saved here and goes when the connection is back.
            if (outgoing.first { $0.id == item.id }?.attempts ?? 0) <= 1 {
                self.error = "Waiting to send. Your message is saved on this phone and goes out when \(app?.botName(profile) ?? "Hermes") is reachable."
            }
            await persistOutgoing()
            return false
        }
    }

    private func refuse(_ item: Outgoing, _ message: String) -> Bool {
        update(item.id) { $0 = $0.refused(message) }
        Task { await persistOutgoing() }
        return false
    }

    /// Matching ignores spacing and case: Hermes trims what it stores, and steers arrive wrapped.
    static func receiptMatchKey(_ text: String) -> String {
        String(text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    /// Drop receipts Hermes's transcript now shows, here and on disk.
    private func forgetReceipts(_ ids: [UUID]) {
        let gone = Set(ids)
        receipts.removeAll { gone.contains($0.id) }
        guard let key = receiptKey else { return }
        let keep = receipts
        Task { try? await InboxDisk.shared.replaceReceipts(keep, key: key) }
    }

    /// A guide or queued message moved on (read by Hermes, or up next). Updates the row in place, no reload.
    private func markReceipt(wireID: String, stage: String, at: Date?) async {
        guard let i = receipts.firstIndex(where: { $0.wireID == wireID }), receipts[i].stage != stage else { return }
        receipts[i].stage = stage
        if let at { receipts[i].readAt = at }
        let updated = receipts[i]
        if let row = items.firstIndex(where: { $0.id == updated.id.uuidString }) { items[row] = updated.item }
        if let key = receiptKey { try? await InboxDisk.shared.record(updated, key: key) }
    }

    /// The reply ended: queued messages are next in line now.
    private func promoteQueuedReceipts() {
        for r in receipts where r.mode == "queue" && r.stage == nil {
            Task { await markReceipt(wireID: r.wireID, stage: "next", at: nil) }
        }
    }

    private func recordReceipt(_ receipt: ControlReceipt) async {
        guard let key = receiptKey else { return }
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
        if !items.contains(where: { $0.id == receipt.id.uuidString }) { items.append(receipt.item) }
        try? await InboxDisk.shared.record(receipt, key: key)
    }

    /// Hands a queued message to the ordinary send path (durable PendingSend) and only then drops it here.
    private func sendQueued(_ item: Outgoing) async {
        // The Mac may already be running something for this chat (this app was away when it started).
        // Follow that first; the queued message goes after it.
        if let sid = sessionId, let live = try? await api.liveTurns(),
           live.contains(where: { $0.sessionId == sid && $0.profile == profile && !$0.done }) {
            await reattach()
            return
        }
        guard !isRunning, pendingSend == nil else { return }
        await send(item.text, attachments: item.attachments ?? [], shown: nil, id: item.id, fromQueue: true)
        if pendingSend?.id == item.id || isRunning {
            outgoing.removeAll { $0.id == item.id }
            await persistOutgoing()
        }
    }

    /// Retries with a gentle backoff while something is waiting: 2 s, 4 s … 30 s. Silent after the first try.
    private func scheduleRetry() {
        retryTask?.cancel()
        guard outgoing.contains(where: { !$0.onMac && $0.problem == nil }) || outgoing.contains(where: { $0.onMac }) else {
            retryDelay = 2
            return
        }
        let delay = outgoing.contains(where: { !$0.onMac && $0.problem == nil }) ? retryDelay : 15
        retryDelay = min(30, retryDelay * 2)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.outgoing.contains(where: { $0.onMac }) { await self.refreshQueue() }
            await self.pump()
        }
    }

    /// Called when the app comes back, the connection returns, or a reply ends.
    func outboxWake() {
        retryDelay = 2
        Task { await refreshQueue(); await pump() }
    }

    /// Reads Hermes's queue and drops messages that have started (they are in the transcript now).
    func refreshQueue() async {
        guard let sid = sessionId else { return }
        guard queueControls else {
            // Older bridge: a queued message has started once no reply is running.
            if !isRunning { outgoing.removeAll { $0.onMac && $0.problem == nil }; await persistOutgoing() }
            return
        }
        do {
            guard let state = try await api.queueState(profile: profile, session: sid) else {
                queueControls = false
                return await refreshQueue()
            }
            guard sid == sessionId else { return }
            queue = state
            let before = outgoing.count
            outgoing.removeAll { o in
                guard let adm = o.admission, !adm.hasPrefix("turn:"), o.edit == nil else { return false }
                return state.row(adm).map { $0.status != "queued" } ?? true
            }
            // An admission id from an older bridge ("turn:…") is reconciled once no reply runs.
            if !isRunning, state.rows.allSatisfy({ $0.status != "queued" }) {
                outgoing.removeAll { $0.admission?.hasPrefix("turn:") == true }
            }
            if outgoing.count != before {
                await persistOutgoing()
                if !isRunning { await load(quiet: true) }
            }
        } catch {}
    }

    // MARK: Changing a queued message

    /// What a waiting message can still do. On the phone everything is local. Once it's in Hermes's
    /// queue, Hermes decides: it only edits or guides text-only messages, so one carrying files can
    /// only be removed. Before the queue has been read, files alone decide it.
    func allows(_ control: QueueControl, _ item: Outgoing) -> Bool {
        guard item.onMac, let adm = item.admission, !adm.hasPrefix("turn:") else { return true }
        if let row = queue?.row(adm) {
            switch control {
            case .edit: return row.canEdit
            case .steer: return row.canSteer
            }
        }
        return item.files == 0
    }

    enum QueueControl { case edit, steer }


    /// Edit a message that is still waiting. On the phone it is a local change; on the Mac it uses
    /// Hermes's replace_queued (a new admission at the back of the queue). Too late once it started.
    func editOutgoing(_ id: UUID, text raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item = outgoing.first(where: { $0.id == id }) else { return }
        if item.onMac {
            guard allows(.edit, item) else {
                error = Self.filesLocked
                return
            }
            await applyEdit(item, text: text)
            return
        }
        // On the phone it's instant; if it may already be on the Mac, the edit waits for the original's place.
        update(id) { $0 = $0.edited(text) }
        await persistOutgoing()
        await pump()
    }

    private func applyEdit(_ item: Outgoing, text: String) async {
        guard let sid = sessionId, let adm = item.admission, !adm.hasPrefix("turn:"), queueControls else {
            update(item.id) { $0.edit = nil }
            error = "This Mac's bridge can't edit queued messages yet. Update the bridge, or remove it and send again."
            await persistOutgoing()
            return
        }
        do {
            let (newAdmission, state) = try await api.queueAction(profile: profile, session: sid, admission: adm,
                                                                  action: "edit", text: text, submission: UUID())
            update(item.id) { var o = $0; o.edit = text; $0 = o.editApplied(admission: newAdmission ?? adm) }
            if let state { queue = state }
            await persistOutgoing()
        } catch APIError.http(409, let message) where message.contains("already started") {
            outgoing.removeAll { $0.id == item.id }
            await persistOutgoing()
            error = "Hermes had already started that message, so the edit didn't apply. Your edit is in the message box."
            draft = draft.isEmpty ? text : text + "\n\n" + draft
        } catch APIError.http(404, _) {
            outgoing.removeAll { $0.id == item.id }
            await persistOutgoing()
            error = "That message already left the queue. Your edit is in the message box."
            draft = draft.isEmpty ? text : text + "\n\n" + draft
        } catch APIError.http(let code, let message) where (400..<500).contains(code) {
            // Hermes answered and said no. Retrying won't change that, so drop the pending edit.
            update(item.id) { $0.edit = nil }
            await persistOutgoing()
            error = message.isEmpty ? Self.filesLocked : message
            await refreshQueue()
        } catch {
            update(item.id) { $0.edit = text }   // offline: applied when the connection is back
            await persistOutgoing()
        }
    }

    /// Remove a waiting message. `toComposer` puts its words back in the message box.
    /// Move back / Remove: instant on the phone. If the message may already be on the Mac, a durable "take it back"
    /// follows (same retry path as archives: sent now, or as soon as the Mac answers, even after an app restart).
    func removeOutgoing(_ id: UUID, toComposer: Bool) async {
        guard let item = outgoing.first(where: { $0.id == id }) else { return }
        outgoing.removeAll { $0.id == id }
        if toComposer { returnToComposer(item) }
        await persistOutgoing()
        let mayBeOnMac = item.admission != nil || item.attempts > 0
        if mayBeOnMac, let sid = sessionId, let account = api.accountID {
            let admission = item.admission.flatMap { $0.hasPrefix("turn:") ? nil : $0 }
            let action = QueuedAction(account: account, kind: .withdraw, profile: profile, session: sid,
                                      admission: admission, submission: item.id.uuidString)
            Task {
                if case .failed(let e) = await ActionQueue.shared.perform(action) { self.error = e.localizedDescription }
                await self.refreshQueue()
            }
        }
    }

    private func returnToComposer(_ item: Outgoing) {
        let words = item.edit ?? item.text
        draft = draft.isEmpty ? words : words + "\n\n" + draft
        if let files = item.attachments { draftAttachments = files + draftAttachments }
    }

    /// Hand a queued message to the running reply now, as guidance (Hermes's steer_queued).
    func guideNow(_ id: UUID) async {
        guard let item = outgoing.first(where: { $0.id == id }) else { return }
        if item.onMac, let adm = item.admission, !adm.hasPrefix("turn:"), let sid = sessionId {
            guard allows(.steer, item) else {
                // Hermes won't convert this admission (files, or its controls say no): take it back off the Mac's
                // queue and send the same words and files as a guide. Shown as "Guiding…" right away.
                do {
                    _ = try await api.queueAction(profile: profile, session: sid, admission: adm, action: "cancel")
                } catch APIError.http(409, _) {
                    error = "Hermes already started that message, so it can't become guidance now."
                    await refreshQueue()
                    return
                } catch APIError.http(404, _) {
                } catch {
                    self.error = "Couldn't reach your Mac to move it. Try again in a moment."
                    return
                }
                // A fresh submission id: Hermes keys repeats by it, so the old id would be answered with the
                // admission just cancelled (and the message silently dropped) if the guide is refused and it
                // falls back to the queue. 2026-11-28: two phone messages, one with a photo, were lost exactly so.
                let fresh = UUID()
                update(id) { $0.id = fresh; $0.mode = "steer"; $0.note = nil; $0.admission = nil; $0.attempts = 0 }
                SentPreviews.rekey(from: id.uuidString, to: fresh.uuidString)
                await persistOutgoing()
                await pump()
                return
            }
            do {
                _ = try await api.queueAction(profile: profile, session: sid, admission: adm, action: "steer")
                outgoing.removeAll { $0.id == id }
                await persistOutgoing()
                await recordReceipt(ControlReceipt(id: item.id, mode: "steer", text: item.text, at: Date(), files: item.files))
            } catch {
                self.error = error.localizedDescription
                await refreshQueue()
            }
        } else if !item.onMac {
            update(id) { $0.mode = "steer"; $0.note = nil }
            await persistOutgoing()
            await pump()
        }
    }

    /// After Hermes restarted mid-reply: acknowledge the cut-off reply so the queue behind it runs.
    func continueQueue() async {
        guard let sid = sessionId, let lost = queue?.lost else { return }
        do {
            let (_, state) = try await api.queueAction(profile: profile, session: sid, admission: lost.id, action: "resolve")
            queue = state
            await load(quiet: true)
        } catch { self.error = error.localizedDescription }
    }

    static let filesLocked = "Hermes can't edit or guide this message: only text-only messages in a live chat can be. It runs as sent. Remove it to change it."

    private(set) var sendingFollowUp = false
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
    /// Called when the app comes back and when the network changes. A stream that hasn't heard even a heartbeat
    /// in 20 s is a socket iOS froze while the app was away: replace it now instead of waiting out its timeout.
    func resumeIfNeeded() {
        guard isRunning, runId != nil else { return }
        if let task = streamTask, Date().timeIntervalSince(streamHeard) > 20 {
            task.cancel()
            streamTask = nil
        }
        if streamTask == nil { follow() }
        // A short switch can still leave a frozen socket. Check once more after one heartbeat window.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(21))
            guard !Task.isCancelled, let self, self.isRunning, let task = self.streamTask,
                  Date().timeIntervalSince(self.streamHeard) > 20 else { return }
            task.cancel()
            self.streamTask = nil
            self.follow()
        }
    }
    @ObservationIgnored private var watchdog: Task<Void, Never>?

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
        let rows = page.data
        if let id = rows.first?.id, let index = stored.firstIndex(where: { $0.id == id }) {
            stored.replaceSubrange(index..., with: rows)
        } else {
            stored = rows
            let paging = HistoryPaging.first(count: rows.count, hasMore: page.hasMore, nextOffset: page.nextOffset)
            historyOffset = paging.offset
            hasOlder = paging.hasOlder
        }
        lastPage = rows
        items = transcriptWithReceipts()
        recovery.restore(checkpoint: seq, epoch: ev.replayEpoch)
        if let terminal = ev.raw["terminal"] as? [String: Any], let name = terminal["event"] as? String {
            return handle(RunEvent(seq: nil, name: name, raw: terminal))
        }
        status = approval == nil ? "Reconnected · waiting for the reply…" : "Waiting for your approval"
        return false
    }

    func cancelLocalFollow() {
        owner = nil
        streamTask?.cancel()
        textTimer?.cancel()
        runId = nil
    }

    /// When the live stream last heard from the bridge (an event or its ~15 s heartbeat).
    @ObservationIgnored private var streamHeard = Date.distantPast
    @ObservationIgnored private var streamGeneration = 0
    /// What the reply was doing before a reconnect, so the status line can go back to it.
    @ObservationIgnored private var workingStatus: String?

    private func follow() {
        guard let run = runId, streamTask == nil else { return }
        let account = app?.inboxAccount
        streamGeneration &+= 1
        let generation = streamGeneration
        streamHeard = Date()
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
                        guard !Task.isCancelled, runId == run, account == app?.inboxAccount else { break }
                        streamHeard = Date()
                        if ev.name == "stream.open" || ev.name == "stream.alive" {
                            // Connected again: say what the reply is doing, not "Reconnecting…" until text arrives.
                            if ev.name == "stream.open" { recovery.connected() }
                            if status == "Reconnecting…" || status?.hasPrefix("Offline") == true {
                                status = workingStatus ?? "Working…"
                            }
                            continue
                        }
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
                    if status != "Reconnecting…" { workingStatus = status }
                    status = "Reconnecting…"
                    continue
                } catch APIError.http(404, _) {
                    // The turn is gone from the Mac (finished long ago, or the bridge restarted): Hermes's
                    // transcript has the outcome, so reload it instead of retrying.
                    finished = true
                } catch APIError.http(401, _) {
                    // Possibly a momentary 401 from a busy bridge. The app re-checks the sign-in before forgetting
                    // it; meanwhile this keeps retrying like any dropped connection (a real sign-out cancels it).
                    if let account, app?.inboxAccount == account { app?.sessionExpired() }
                } catch {
                    if Task.isCancelled { break }
                }
                if !finished && !Task.isCancelled {
                    if StreamRoutes.shared.state.offline { continue }
                    guard let delay = recovery.retryDelay() else { break }
                    if status != "Reconnecting…" { workingStatus = status }
                    status = "Reconnecting…"
                    await StreamRoutes.shared.waitForRetry(after: network.revision, seconds: delay)
                }
            }
            // A replaced stream must not clear its replacement.
            if streamGeneration == generation { streamTask = nil }
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
            let activity = ToolActivity(id: "live-\(UUID().uuidString)", name: name, preview: ev.string("preview") ?? "",
                                        result: "", state: "running", started: Date().timeIntervalSince1970)
            closeStreamingBubble()
            if let i = liveToolGroup, items.indices.contains(i), items[i].kind == .tools {
                items[i].tools.append(name)
                items[i].activities.append(activity)
            } else {
                liveToolGroup = items.count
                items.append(ChatItem(id: "tools-\(UUID().uuidString)", kind: .tools, text: "", tools: [name], activities: [activity]))
            }
            status = "Using \(name.replacingOccurrences(of: "_", with: " "))…"
            activityTick &+= 1
        case "tool.completed":
            let name = ev.string("tool_name") ?? ev.string("name") ?? ""
            let ok = ev.raw["ok"] as? Bool ?? true
            if let i = liveToolGroup, items.indices.contains(i),
               let idx = items[i].activities.lastIndex(where: { $0.state == "running" && (name.isEmpty || $0.name == name) }) {
                items[i].activities[idx].state = ok ? "done" : "failed"
                items[i].activities[idx].ended = Date().timeIntervalSince1970
                if let preview = ev.string("preview"), !preview.isEmpty, items[i].activities[idx].result.isEmpty {
                    items[i].activities[idx].result = preview
                }
                if items[i].activities.contains(where: { $0.state == "running" }) {
                    status = "Using \(items[i].activities.last { $0.state == "running" }?.name.replacingOccurrences(of: "_", with: " ") ?? "a tool")…"
                } else {
                    status = ok ? nil : "A tool failed"
                }
            }
        case "subagent":
            let title = ev.string("title") ?? "Background task"
            status = ev.string("state") == "done" ? "Background task finished · \(title)" : "Waiting on \(title)…"
        case "run.started":
            // The bridge says what context it accepted; replace the optimistic badge with it.
            if let summary = ProjectContext.summary(from: ev.raw),
               let i = items.lastIndex(where: { $0.kind == .user && $0.contextNote != nil }) {
                items[i].contextNote = summary
            }
        case "reasoning.available", "reasoning.delta":
            if let d = ev.string("delta"), !d.isEmpty { appendThinking(d) }
            if streamingIndex == nil && status != "Thinking…" { status = "Thinking…"; activityTick &+= 1 }
        case "status":
            if let text = ev.string("text"), !text.isEmpty {
                // Status events are complete labels, not reasoning deltas. Keep each on its own line.
                appendThinking((thinkingText.isEmpty || thinkingText.last?.isNewline == true ? "" : "\n") + text + "\n")
                if streamingIndex == nil { status = text }
            } else if streamingIndex == nil {
                status = "Thinking…"
            }
        case "notice":
            items.append(ChatItem(id: "n-\(UUID().uuidString)", kind: .notice, text: ev.string("text") ?? ""))
        case "clarify.request":
            guard let id = ev.string("request_id"), !questions.contains(where: { $0.id == id }),
                  !answeredQuestions.contains(id) else { break }
            questions.append(ClarifyRequest(id: id, runId: runId ?? "", generation: ev.raw["execution_generation"] as? Int,
                                      question: ev.string("question") ?? "Hermes has a question.",
                                      choices: (ev.raw["choices"] as? [String]) ?? [],
                                      multiSelect: ev.raw["multi_select"] as? Bool ?? false))
            status = "Waiting for your answer"
            notify(.question, detail: Headline.of(ev.string("question") ?? ""))
        case "steer.picked_up", "steer.carried":
            guard let sid = ev.string("submission_id") else { break }
            let read = ev.name == "steer.picked_up"
            let at = (ev.raw["at"] as? Double).map(Date.init(timeIntervalSince1970:))
            Task { await markReceipt(wireID: sid, stage: read ? "read" : "next", at: at) }
        case "clarify.resolved":
            if let id = ev.string("request_id"), questions.contains(where: { $0.id == id }) {
                answeredQuestions.insert(id)
                questions.removeAll { $0.id == id }
                if questions.isEmpty, status == "Waiting for your answer" { status = "Working…" }
            }
        case "approval.request":
            let id = ev.string("request_id") ?? UUID().uuidString
            guard !resolvedApprovals.contains(id), approval?.id != id, !waitingApprovals.contains(where: { $0.id == id }) else { break }
            enqueueApproval(ApprovalRequest(
                id: id, runId: runId ?? "", generation: ev.raw["execution_generation"] as? Int,
                command: ev.string("command") ?? "", description: ev.string("description") ?? "Hermes wants to run a command.",
                choices: (ev.raw["choices"] as? [String]) ?? ["once", "deny"], requestId: ev.string("request_id")))
            status = "Waiting for your approval"
            notify(.approval, detail: (ev.string("description")).flatMap { Headline.of($0) })
        case "run.completed":
            confirmedPrimary = true
            var answeredItem = streamingIndex
            if let out = ev.string("output"), !out.isEmpty, streamingIndex == nil {
                items.append(ChatItem(id: "final-\(UUID().uuidString)", kind: .assistant, text: out))
                answeredItem = items.indices.last
            }
            if let rt = ev.raw["runtime"] as? [String: Any], let m = rt["model"] as? String, !m.isEmpty,
               let i = answeredItem, items.indices.contains(i) {
                var parts = [m, rt["provider"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                if let requested = ev.string("requested_model"), requested != m {
                    parts = ["Requested " + requested, "Hermes reported " + parts.joined(separator: " · ")]
                }
                if rt["fallback"] as? Bool == true { parts.append("Fallback") }
                parts[0] = ModelName.short(parts[0])
                if let label = CostSummary(rt["cost"])?.replyLabel { parts.append(label) }
                items[i].footer = parts.joined(separator: " · ")
            }
            runtimeNotice = nil
            completedTick += 1
            let replyText = answeredItem.flatMap { items.indices.contains($0) ? items[$0].text : nil } ?? ""
            notify(.reply, detail: Headline.of(replyText))
            return true
        case "run.failed", "error":
            confirmedPrimary = true
            let reason = ev.string("error") ?? ev.string("message") ?? "The run failed."
            fail(reason)
            notify(.failure, detail: Headline.of(reason))
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
                // Hermes has the files now: the phone's upload copies can go.
                releaseUploads(send.attachments ?? [])
            } catch { self.error = "Could not clear this phone’s receipt. The same submission is safe to check again." }
        }
        confirmedPrimary = false
        questions = []
        promoteQueuedReceipts()
        closeStreamingBubble()
        isRunning = false
        status = nil
        replaceApprovals([])
        runId = nil
        if gaveUp { failedTick += 1 }
        lastPage = nil
        await load(quiet: true, resumeLive: !gaveUp)
        if gaveUp { error = "The live connection was lost. Tap Reload chat to reconnect." }
        // Queued messages are never thrown back at the person: they stay saved and go at the next safe moment.
        outboxWake()
    }

    func absorbPaste(_ text: String) {
        pastedTexts.append(PastedText(text: text))
    }

    func removePastedText(_ id: UUID) {
        pastedTexts.removeAll { $0.id == id }
    }



    private func notify(_ event: ReplyNotifier.Event, detail: String? = nil) {
        guard let app else { return }
        let worked = runStarted.map { Date().timeIntervalSince($0) }
        ReplyNotifier.shared.post(event, bot: app.botName(profile), account: app.inboxAccount, profile: profile,
                                  session: sessionId, detail: detail, worked: event.endsRun ? worked : nil)
        if event.endsRun {
            // This run is over; if it was the last one, hand the background time back.
            let others = app.hasLiveRuns(excluding: self)
            ReplyNotifier.shared.settled(liveRuns: others)
        }
    }

    /// This chat's identity in notifications (nil until it has a session on the Mac).
    var notificationDestination: ReplyDestination? {
        guard let account = app?.inboxAccount, let sessionId else { return nil }
        return ReplyDestination(account: account, profile: profile, session: sessionId)
    }

    private func fail(_ message: String) {
        error = message
        failedTick += 1
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
