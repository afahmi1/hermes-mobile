import Foundation
import CryptoKit
import Observation

/// One Hermes profile ("bot"). `id` is the profile name; "default" is the front door.
struct Bot: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let model: String
    let provider: String
    let reachable: Bool
    let front: Bool
    var skills: [String] = []
    /// Newer bridges: what Hermes tries, in order, when this bot's model can't answer. Nil = not reported.
    var fallbacks: [Fallback]? = nil

    struct Fallback: Codable, Hashable {
        let provider: String
        let model: String
        /// "plan" (a subscription covers it), "free" or "paid" (billed per call).
        let kind: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, blurb, model, provider, reachable, front, skills, fallbacks
    }

    init(id: String, name: String, blurb: String, model: String, provider: String, reachable: Bool, front: Bool,
         skills: [String] = []) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.model = model
        self.provider = provider
        self.reachable = reachable
        self.front = front
        self.skills = skills
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        blurb = try c.decode(String.self, forKey: .blurb)
        model = try c.decode(String.self, forKey: .model)
        provider = try c.decode(String.self, forKey: .provider)
        reachable = try c.decode(Bool.self, forKey: .reachable)
        front = try c.decode(Bool.self, forKey: .front)
        skills = (try? c.decode([String].self, forKey: .skills)) ?? []
        fallbacks = try? c.decodeIfPresent([Fallback].self, forKey: .fallbacks)
    }
}

/// One gateway slash command the composer can offer. Typing it still runs on the Mac.
struct SlashCommand: Codable, Identifiable, Hashable {
    let name: String
    let description: String
    let hint: String
    let category: String
    var id: String { name }

    /// The command word in `/learn something`, while the rest of the line is the argument.
    static func name(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let token = text.dropFirst().prefix { $0 != " " && $0 != "\n" }
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return String(token)
    }

    /// What the person has typed after `/`, while they are still picking a command.
    static func filter(in raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains(" "), !raw.contains("\n") else { return nil }
        let token = raw.dropFirst()
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return String(token)
    }

    static let builtIn: [SlashCommand] = [
        .init(name: "learn", description: "Learn a reusable skill from what you describe, a URL, or this chat", hint: "<what to learn from>", category: "Tools & Skills"),
        .init(name: "reload-skills", description: "Rescan skill folders", hint: "", category: "Tools & Skills"),
        .init(name: "status", description: "Session and gateway status", hint: "", category: "Status"),
        .init(name: "agents", description: "Background tasks for this chat", hint: "", category: "Status"),
        .init(name: "usage", description: "Token use for this chat", hint: "", category: "Status"),
        .init(name: "compress", description: "Summarize earlier turns to free context", hint: "", category: "Session"),
        .init(name: "goal", description: "Set or show the goal for this chat", hint: "<goal>", category: "Session"),
        .init(name: "btw", description: "A side question that does not steer the chat", hint: "<question>", category: "Session"),
        .init(name: "title", description: "Rename this chat", hint: "<title>", category: "Session"),
        .init(name: "help", description: "Commands Hermes can run from this chat", hint: "", category: "Help"),
    ]
}

/// The last command/skill list per account and bot, in Caches (rebuildable; never backed up).
enum PaletteCache {
    private static func url(_ key: String) -> URL {
        let name = SHA256Hex.of(key).prefix(24)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("palette-\(name).json")
    }
    static func load(_ key: String) -> CommandPalette? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(CommandPalette.self, from: data)
    }
    static func save(_ page: CommandPalette, key: String) {
        guard let data = try? JSONEncoder().encode(page) else { return }
        try? data.write(to: url(key), options: .atomic)
    }
}

enum SHA256Hex {
    static func of(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CommandPalette: Codable {
    let commands: [SlashCommand]
    let skills: [String]
    /// Name, category folder and one-line description. Absent on older bridges (names only).
    let skillDetails: [SkillInfo]?

    enum CodingKeys: String, CodingKey { case commands, skills, skillDetails = "skill_details" }
}

struct SkillInfo: Codable, Hashable, Identifiable {
    let name: String
    let category: String
    let description: String
    var id: String { name }

    init(name: String, category: String = "", description: String = "") {
        self.name = name; self.category = category; self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }

    /// Ranked search: name prefix, then name contains, then category or description contains. Each word
    /// of the query must match somewhere, so "web pentest" finds "web-pentest" and "authorized web pentest".
    static func search(_ skills: [SkillInfo], _ raw: String) -> [SkillInfo] {
        let words = raw.lowercased().split { $0 == " " || $0 == "/" }.map(String.init)
        guard !words.isEmpty else { return skills }
        let joined = words.joined(separator: "-")
        var scored: [(Int, SkillInfo)] = []
        for skill in skills {
            let name = skill.name.lowercased()
            let hay = name + " " + skill.category.lowercased() + " " + skill.description.lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { continue }
            let score = name.hasPrefix(joined) ? 0 : name.contains(joined) ? 1
                : words.allSatisfy({ name.contains($0) }) ? 2 : skill.category.lowercased().contains(words[0]) ? 3 : 4
            scored.append((score, skill))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name < $1.1.name }.map(\.1)
    }
}

struct SlashResult {
    var output: String?
    var warning: String?
    var type: String?
    var message: String?
    var display: String?
    var notice: String?
}

struct ChatMediaRef: Codable, Hashable {
    let name: String
    let digest: String
    let kind: String
}

/// A session row as the gateway lists it (plus `profile`, added by the bridge).
struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let profile: String
    let source: String?
    var createdVia: String? = nil
    let model: String?
    var title: String?
    let preview: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    var pinned: Bool?
    var archived: Bool?
    let endedAt: Double?
    /// Pinned messages inside this chat (bridge-side). Absent on older bridges and on chats without pins.
    var pinCount: Int?
    /// What Hermes recorded this chat cost, classified like the chat header. Absent when nothing is priced.
    var cost: CostSummary?

    enum CodingKeys: String, CodingKey {
        case id, profile, source, model, title, preview, pinned, archived, createdVia = "created_via"
        case startedAt = "started_at", lastActive = "last_active", messageCount = "message_count", endedAt = "ended_at"
        case pinCount = "pin_count", cost
    }

    var pinnedMessages: Int { max(0, pinCount ?? 0) }

    var key: String { "\(profile)/\(id)" }
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return String(p.prefix(80)) }
        return "Untitled chat"
    }
    var date: Date { Date(timeIntervalSince1970: lastActive ?? startedAt ?? 0) }

    /// Preserve the gateway source. Only a recorded mobile creation identifies the client.
    var sourceLabel: String {
        if createdVia == "mobile_bridge" { return "Mobile" }
        switch source ?? "" {
        case "local": return "Desktop app"  // Hermes records the desktop app's own chats as "local"
        case "desktop": return "Desktop"
        case "gui": return "Hermes app"
        case "api_server": return "API"
        case "hermes_browser": return "Browser"
        case "bluebubbles": return "iMessage"
        case "tui", "cli": return "Terminal"
        case "telegram": return "Telegram"
        case "cron": return "Scheduled"
        case "oneshot": return "One-shot"
        case "subagent": return "Subagent"
        case "tool": return "Tool run"
        case let s where s.isEmpty: return ""
        case let s: return s.capitalized
        }
    }
    var isAutomation: Bool { ["cron", "oneshot", "subagent", "tool"].contains(source ?? "") }
}

struct SessionPage: Codable {
    let errors: [String: String]?
    let reset: Bool?
    var partialWarning: String? {
        guard let errors, !errors.isEmpty else { return nil }
        return "Couldn’t refresh " + errors.keys.sorted().joined(separator: ", ") + ". Pull down to retry."
    }
    let data: [SessionSummary]
    let next: String?
}

struct SessionFlagResult {
    let updated: [String]
    let errors: [String: String]
    /// Chats the bridge refused to archive because they hold pinned messages: {session id: pin count}.
    var heldForPins: [String: Int] = [:]
    /// Chats not changed because Hermes was restarting. The phone keeps these and sends them again.
    var unreachable: [String] = []
}

/// One pinned message in a chat. The bridge snapshots the text from Hermes when it is pinned, so the pin
/// still reads correctly after the live transcript is compressed or trimmed.
struct MessagePin: Codable, Identifiable, Hashable {
    let messageId: Int
    let role: String
    let text: String
    let messageAt: Double?
    let pinnedAt: Double

    var id: Int { messageId }
    /// The transcript row id this pin points at (`ChatItem.id` for stored messages).
    var itemID: String { String(messageId) }
    var isMine: Bool { role == "user" }
    var excerpt: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    enum CodingKeys: String, CodingKey {
        case role, text
        case messageId = "message_id", messageAt = "message_at", pinnedAt = "pinned_at"
    }

    /// A ChatItem can be pinned only when it is a stored user/assistant message (numeric Hermes id).
    static func messageID(for item: ChatItem) -> Int? {
        guard item.kind == .user || item.kind == .assistant, !item.streaming,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Int(item.id)
    }
}

/// Harness text that lands in user-role rows. The bridge classifies it (bridge_transcript.classify_user_text);
/// this is the phone's fallback for older bridges, so a system nudge never shows as something the person said.
enum HarnessText {
    enum Verdict: Equatable { case user(String, note: String?), notice(String) }

    static func classify(_ raw: String) -> Verdict {
        var body = raw
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let notices: [(String, String)] = [
            ("You've reached the maximum number of tool-calling iterations", "Hermes hit its tool-call limit for this turn and wrapped up"),
            ("[CONTEXT COMPACTION", "Earlier turns were compacted into a summary"),
            ("[Your active task list was preserved", "Task list carried over after compaction"),
            ("[STILL IN PROGRESS", "Your earlier request carried over after compaction"),
            ("[System note: Your previous turn was interrupted", "Resumed after an interruption"),
            ("[IMPORTANT: MCP servers have been reloaded", "Tool servers reloaded"),
            ("[System:", "System note for Hermes"), ("[SYSTEM:", "System note for Hermes"), ("[System note:", "System note for Hermes"),
        ]
        if let hit = notices.first(where: { trimmed.hasPrefix($0.0) }) { return .notice(hit.1) }
        var note: String?
        if trimmed.hasPrefix("[OUT-OF-BAND USER MESSAGE") {
            if let close = body.range(of: "]") { body = String(body[close.upperBound...]) }
            body = body.replacingOccurrences(of: "[/OUT-OF-BAND USER MESSAGE]", with: "")
            note = "Sent while Hermes was working"
        }
        return .user(body.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
    }
}

/// One background command or subagent task in an activity card.
struct ActivityEntry: Codable, Hashable {
    /// "process" or "task".
    let type: String
    /// "ok", "failed", "stopped" or "warning".
    let status: String
    let label: String
    var exitCode: Int?
    var cwd: String?
    var command: String?
    var output: String?
    var duration: String?
    var apiCalls: Int?
    var model: String?
    var state: String?
    /// A finished subagent's token use, from Hermes's delegation record. Absent on older bridges.
    var tokensIn: Int?
    var tokensOut: Int?

    enum CodingKeys: String, CodingKey {
        case type, status, label, cwd, command, output, duration, model, state
        case exitCode = "exit_code", apiCalls = "api_calls", tokensIn = "tokens_in", tokensOut = "tokens_out"
    }

    /// "3.7M tokens in · 25k out", or nil when Hermes recorded nothing.
    var tokens: String? {
        switch (tokensIn, tokensOut) {
        case let (i?, o?): return Self.compact(i) + " tokens in · " + Self.compact(o) + " out"
        case let (i?, nil): return Self.compact(i) + " tokens in"
        case let (nil, o?): return Self.compact(o) + " tokens out"
        default: return nil
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000:
            let k = Double(n) / 1_000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        default:
            let m = Double(n) / 1_000_000
            return m < 10 ? String(format: "%.1fM", m) : "\(Int(m.rounded()))M"
        }
    }

    var isProcess: Bool { type == "process" }
    var failed: Bool { status == "failed" }

    /// "in plate B · exit 0" or "gpt-6.2-astra · 14 calls · 7m25s".
    var meta: String {
        var parts: [String] = []
        if isProcess {
            if let cwd, !cwd.isEmpty { parts.append("in " + cwd) }
            if status == "stopped" { parts.append("stopped") }
            else if let exitCode, exitCode != 0 { parts.append("exit \(exitCode)") }
        } else {
            if let state, !state.isEmpty, state != "completed" { parts.append(state) }
            if let model, !model.isEmpty { parts.append(model) }
            if let apiCalls { parts.append(apiCalls == 1 ? "1 call" : "\(apiCalls) calls") }
            if let tokens { parts.append(tokens) }
        }
        if let duration, !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

struct PinList: Decodable {
    let pins: [MessagePin]
    let limit: Int?
}

struct SearchPage: Codable { let data: [SessionSummary] }

/// A stored transcript row.
struct StoredMessage: Codable, Identifiable, Hashable {
    let id: Int?
    let role: String
    let content: String?
    let toolName: String?
    let toolCalls: [ToolCall]?
    let timestamp: Double?
    let reasoning: String?
    let displayKind: String?
    let notice: String?
    let preview: String?
    let ok: Bool?
    let media: [ChatMediaRef]?
    /// Background commands and subagent tasks behind an activity card (bridge-parsed). Absent on older bridges.
    let activity: [ActivityEntry]?
    /// A short tag under a user bubble ("Sent while Hermes was working · Pasted 6 lines").
    let note: String?
    /// Newer bridges: the reply split at its images ([{text}, {media: 0}, …]).
    var contentParts: [ReplyPart]? = nil

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning, notice, preview, ok, media, activity, note
        case toolName = "tool_name", toolCalls = "tool_calls", displayKind = "display_kind", contentParts = "content_parts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(Int.self, forKey: .id)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        content = Self.flatten(c, .content)
        toolName = try? c.decode(String.self, forKey: .toolName)
        toolCalls = try? c.decode([ToolCall].self, forKey: .toolCalls)
        timestamp = try? c.decode(Double.self, forKey: .timestamp)
        reasoning = try? c.decode(String.self, forKey: .reasoning)
        displayKind = try? c.decode(String.self, forKey: .displayKind)
        notice = try? c.decode(String.self, forKey: .notice)
        preview = try? c.decode(String.self, forKey: .preview)
        ok = try? c.decode(Bool.self, forKey: .ok)
        media = try? c.decode([ChatMediaRef].self, forKey: .media)
        activity = try? c.decode([ActivityEntry].self, forKey: .activity)
        note = try? c.decode(String.self, forKey: .note)
        contentParts = try? c.decode([ReplyPart].self, forKey: .contentParts)
    }

    /// Content may be a string or a list of OpenAI-style parts.
    private static func flatten(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: k) { return s }
        if let parts = try? c.decode([ContentPart].self, forKey: k) {
            return parts.compactMap { $0.text }.joined(separator: "\n")
        }
        return nil
    }

    struct ContentPart: Codable, Hashable { let type: String?; let text: String? }
    struct ToolCall: Codable, Hashable {
        let id: String?
        let function: Fn?
        let preview: String?
        struct Fn: Codable, Hashable { let name: String?; let arguments: String? }
    }
}

/// One piece of a reply: some text, or the index of an image in its `media`.
struct ReplyPart: Codable, Hashable {
    var text: String?
    var media: Int?
}

struct MessagesPage: Codable {
    let data: [StoredMessage]
    /// Present when the bridge knows whether another raw page exists. Absent on older bridges.
    let hasMore: Bool?
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}

/// How far back the transcript can still go. A projected page is often shorter than the 100 raw
/// rows the bridge fetched (hidden tool rows are dropped), so a short page is not the end.
enum HistoryPaging {
    static func first(count: Int, limit: Int = 100, hasMore: Bool?, nextOffset: Int?) -> (offset: Int, hasOlder: Bool) {
        if let hasMore { return (nextOffset ?? limit, hasMore) }
        return (limit, count == limit)
    }

    static func advance(offset: Int, limit: Int = 100, added: Int, hasMore: Bool?, nextOffset: Int?) -> (offset: Int, hasOlder: Bool) {
        if let hasMore { return (nextOffset ?? offset + limit, hasMore) }
        return (offset + limit, added > 0)
    }
}

// MARK: - Model catalog

struct ModelCatalog: Decodable {
    let providers: [Provider]
    let model: String?
    let provider: String?

    struct Provider: Decodable, Identifiable, Hashable {
        let slug: String
        let name: String
        let models: [String]
        let authenticated: Bool
        let isCurrent: Bool
        let reasoning: [String: Bool]
        var id: String { slug }

        /// Signed in with an account plan (OAuth / CLI login): calls are covered, not billed per token.
        var isSubscription: Bool {
            let s = slug.lowercased()
            return s.hasSuffix("-oauth") || s.contains("subscription") || s == "openai-codex" || s == "claude-code"
                || s == "copilot" || s == "github-copilot" || s.hasPrefix("copilot-")
        }

        enum CodingKeys: String, CodingKey { case slug, name, models, authenticated, capabilities, isCurrent = "is_current" }
        struct Cap: Decodable { let reasoning: Bool? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slug = try c.decode(String.self, forKey: .slug)
            name = (try? c.decode(String.self, forKey: .name)) ?? slug
            models = (try? c.decode([String].self, forKey: .models)) ?? []
            authenticated = (try? c.decode(Bool.self, forKey: .authenticated)) ?? false
            isCurrent = (try? c.decode(Bool.self, forKey: .isCurrent)) ?? false
            let caps = (try? c.decode([String: Cap].self, forKey: .capabilities)) ?? [:]
            reasoning = caps.compactMapValues { $0.reasoning }
        }

        func supportsReasoning(_ model: String) -> Bool { reasoning[model] ?? true }
    }

    /// Subscriptions first (already paid for), then pay-per-use APIs.
    var usable: [Provider] {
        let ready = providers.filter { $0.authenticated && !$0.models.isEmpty }
        return ready.filter(\.isSubscription) + ready.filter { !$0.isSubscription }
    }

    /// The same model on a subscription you're signed in to (Grok on OpenRouter -> your xAI subscription).
    func subscriptionTwin(of model: String, on provider: String) -> (provider: Provider, model: String)? {
        guard let from = self.provider(slug: provider), !from.isSubscription else { return nil }
        let bare = model.split(separator: "/").last.map(String.init)?.lowercased() ?? model.lowercased()
        for p in usable where p.isSubscription {
            if let m = p.models.first(where: { $0.lowercased() == bare || $0.split(separator: "/").last.map(String.init)?.lowercased() == bare }) {
                return (p, m)
            }
        }
        return nil
    }
    /// Exact slug match: `openai-codex` and `openai-api` are different providers.
    func provider(slug: String) -> Provider? { providers.first { $0.slug == slug } }
}

// MARK: - Live model catalog

/// `.cached` is a normal read (Hermes may serve its own disk cache); `.refresh` asks Hermes to re-probe providers.
enum CatalogFetch: Sendable {
    case cached, refresh
    func path(escapedProfile: String) -> String {
        "/m/p/\(escapedProfile)/api/model/options" + (self == .refresh ? "?refresh=1" : "")
    }
}

/// The account id already hashes server origin + token, so it keeps gateways and sign-ins apart.
struct CatalogScope: Hashable, Sendable { let account: String; let profile: String }

struct CatalogState {
    var catalog: ModelCatalog?
    var fetchedAt: Date?
    var lastRefreshAt: Date?       // last successful live (`refresh=1`) read
    var lastAttemptAt: Date?       // last live attempt, success or not (bounds cadence)
    var lastError: String?
    var isRefreshing = false

    func isStale(now: Date, ttl: TimeInterval = ModelCatalogStore.ttl) -> Bool {
        lastError != nil || fetchedAt.map { now.timeIntervalSince($0) > ttl } ?? true
    }

    /// Footer text for pickers and provider detail.
    func caption(now: Date) -> String {
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        func ago(_ d: Date) -> String { now.timeIntervalSince(d) < 45 ? "just now" : rel.localizedString(for: d, relativeTo: now) }
        if isRefreshing { return "Refreshing…" }
        guard let at = fetchedAt else { return lastError ?? "Not loaded yet" }
        if lastError != nil { return "Couldn’t refresh — showing the list from \(ago(at))" }
        return "Checked \(ago(at))"
    }
}

@MainActor @Observable
final class ModelCatalogStore {
    nonisolated static let ttl: TimeInterval = 300
    nonisolated static let minRefreshInterval: TimeInterval = 60
    nonisolated static let failureText = "Couldn’t reach Hermes’s model catalog."

    typealias Fetcher = @Sendable (CatalogScope, CatalogFetch) async throws -> ModelCatalog

    private(set) var entries: [CatalogScope: CatalogState] = [:]
    @ObservationIgnored private var inFlight: [CatalogScope: (kind: CatalogFetch, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let currentAccount: () -> String?
    @ObservationIgnored private let fetcher: Fetcher

    init(now: @escaping () -> Date = Date.init, currentAccount: @escaping () -> String?, fetcher: @escaping Fetcher) {
        self.now = now
        self.currentAccount = currentAccount
        self.fetcher = fetcher
    }

    func state(_ scope: CatalogScope) -> CatalogState { entries[scope] ?? CatalogState() }

    /// Account/server switch or sign-out: drop everything; late responses are discarded.
    func reset() {
        generation += 1
        for (_, f) in inFlight { f.task.cancel() }
        inFlight = [:]
        entries = [:]
    }

    /// Fresh entries are served without network; otherwise one coalesced plain read.
    @discardableResult
    func load(_ scope: CatalogScope) async -> ModelCatalog? {
        if let e = entries[scope], e.catalog != nil, !e.isStale(now: now()) { return e.catalog }
        if let f = inFlight[scope] { await f.task.value } else { await start(scope, .cached).value }
        return entries[scope]?.catalog
    }

    /// Live re-probe, at most once per `minRefreshInterval` per scope; extra calls join or return the cached list.
    @discardableResult
    func refresh(_ scope: CatalogScope) async -> ModelCatalog? {
        if let f = inFlight[scope] {
            await f.task.value
            if f.kind == .refresh { return entries[scope]?.catalog }
        }
        if let at = entries[scope]?.lastAttemptAt, now().timeIntervalSince(at) < Self.minRefreshInterval {
            return entries[scope]?.catalog
        }
        if let f = inFlight[scope] { await f.task.value } else { await start(scope, .refresh).value }
        return entries[scope]?.catalog
    }

    /// On open: publish the cached/plain read right away, then one live check if the last one is old or missing.
    func openCheck(_ scope: CatalogScope) async {
        await load(scope)
        if let at = entries[scope]?.lastRefreshAt, now().timeIntervalSince(at) <= Self.ttl { return }
        await refresh(scope)
    }

    private func start(_ scope: CatalogScope, _ kind: CatalogFetch) -> Task<Void, Never> {
        let gen = generation
        var e = state(scope)
        e.isRefreshing = true
        if kind == .refresh { e.lastAttemptAt = now() }
        entries[scope] = e
        let task = Task { @MainActor [weak self, fetcher] in
            let result: Result<ModelCatalog, Error>
            do { result = .success(try await fetcher(scope, kind)) } catch { result = .failure(error) }
            guard let self, gen == self.generation else { return }
            self.inFlight[scope] = nil
            var e = self.state(scope)
            e.isRefreshing = false
            if self.currentAccount() == scope.account {
                switch result {
                case .success(let c):
                    e.catalog = c; e.fetchedAt = self.now(); e.lastError = nil
                    if kind == .refresh { e.lastRefreshAt = e.fetchedAt }
                case .failure:
                    e.lastError = Self.failureText   // keep the last-good list
                }
                self.entries[scope] = e
            } else { self.entries[scope] = nil }
        }
        inFlight[scope] = (kind, task)
        return task
    }
}

/// What the user picked for a chat. All nil = the bot's own default.
struct RuntimeChoice: Codable, Hashable {
    var provider: String?
    var model: String?
    var effort: String?

    static let botDefault = RuntimeChoice()
    var isDefault: Bool { provider == nil && model == nil && effort == nil }
}

enum Effort: String, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Off"
        case .xhigh: "X-High"
        default: rawValue.capitalized
        }
    }
}

/// What Hermes has on record for a chat, read by the bridge from state.db: the session's own
/// model/provider/effort setting (`policy`) and which models actually answered (`modelsUsed`).
struct ServedRuntime: Codable, Hashable {
    let model: String?
    let provider: String?
    let reasoningTokens: Int?
    let fallbackActive: Bool?
    let policy: Policy?
    let modelsUsed: [Used]?
    let cost: CostSummary?
    /// Newer bridges: the model that wrote the last real reply, and when (epoch seconds).
    var lastAnswer: LastAnswer? = nil

    struct Policy: Codable, Hashable { let model: String?; let provider: String?; let effort: String? }
    struct LastAnswer: Codable, Hashable { let model: String; let provider: String?; let at: Double? }
    struct Used: Codable, Hashable {
        let model: String
        let provider: String?
        let calls: Int?
        let reasoningTokens: Int?
        /// Newer bridges: what this model cost. kind = "priced" (usd paid), "included" (a plan; api_usd is the
        /// API-price equivalent) or "unknown".
        var usd: Double? = nil
        var apiUsd: Double? = nil
        var kind: String? = nil
        enum CodingKeys: String, CodingKey { case model, provider, calls, usd, kind, reasoningTokens = "reasoning_tokens", apiUsd = "api_usd" }
    }
    enum CodingKeys: String, CodingKey {
        case model, provider, policy, cost
        case reasoningTokens = "reasoning_tokens", fallbackActive = "fallback_active", modelsUsed = "models_used"
        case lastAnswer = "last_answer"
    }

    /// The last reply came from a different model than the one picked (a fallback when a plan ran out, or
    /// an older answer from before you switched). Nil when they match or there's nothing to compare.
    func stand(in picked: String?) -> LastAnswer? {
        guard let last = lastAnswer, let picked, !picked.isEmpty else { return nil }
        return ModelName.same(last.model, picked) ? nil : last
    }

    /// The session's persisted setting as a picker choice (nil fields = not set on the session).
    var policyChoice: RuntimeChoice? {
        guard let p = policy, let m = p.model, !m.isEmpty else { return nil }
        return RuntimeChoice(provider: p.provider.flatMap { $0.isEmpty ? nil : $0 }, model: m,
                             effort: p.effort.flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct LiveTurn: Codable, Hashable {
    let turnId: String
    let profile: String
    let sessionId: String
    let done: Bool
    /// Newer bridges: when it started and finished, and whether Hermes is waiting on you ("question"/"approval").
    var startedAt: Double? = nil
    var endedAt: Double? = nil
    var waiting: String? = nil
    enum CodingKeys: String, CodingKey {
        case profile, done, waiting, turnId = "turn_id", sessionId = "session_id", startedAt = "started_at", endedAt = "ended_at"
    }
}

/// What a chat is doing, for its row in the list (like T3: Input · 3m 12s · Done).
enum ChatActivity: Equatable {
    case input, working(since: Date), done
}

struct HealthInfo: Codable {
    struct Transition: Codable { let phase: String; let at: Double }
    let phase: String?
    let recent: [Transition]?
    let reason: String?
    let imageAttachments: Bool?
    let fileAttachments: Bool?
    let maxFileBytes: Int?
    let inboxFallback: String?
    let ok: Bool
    let gatewayState: String?
    let version: String?
    enum CodingKeys: String, CodingKey { case ok, version, phase, recent, reason, imageAttachments = "image_attachments",
                                              fileAttachments = "file_attachments", maxFileBytes = "max_file_bytes",
                                              inboxFallback = "inbox_fallback", gatewayState = "gateway_state" }
}

// MARK: - Live run events

struct RunEvent {
    let seq: Int?
    let name: String
    let raw: [String: Any]
    var replayEpoch: String? = nil

    func string(_ k: String) -> String? { raw[k] as? String }
}

struct BridgeCapabilities: Decodable {
    let features: [String]
    let deviceID: String
    let manageDevices: Bool
    /// Owner phones may restart Hermes and the bridge (`POST /m/restart`). Older bridges don't send it.
    var canRestart: Bool? = nil
    var restartable: Bool { features.contains("restart_v1") && canRestart == true }
    enum CodingKeys: String, CodingKey {
        case features, deviceID = "device_id", manageDevices = "manage_devices", canRestart = "can_restart"
    }
}

/// What the bridge said it will do after a restart request.
struct RestartResult: Decodable {
    let mode: String?
    let message: String?
}

struct DeviceGrant: Decodable, Identifiable {
    let id: String
    let name: String
    let method: String
    let expires: Double
}

struct DevicePairCode: Decodable {
    let code: String
    let expires: Double
}


/// Legacy preferences belonged to the account already signed in when this version was installed.
enum DevicePreferences {
    static func migrate(account: String?, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "scopedDevicePreferences") else { return }
        for (key, value) in defaults.dictionaryRepresentation() {
            if key == "status.seenEvents" {
                if let account { defaults.set(value, forKey: "device." + account + "." + key) }
            } else if key.hasPrefix("runtime.") {
                let parts = key.dropFirst("runtime.".count).split(separator: "/", maxSplits: 1)
                if let account, parts.count == 2 {
                    defaults.set(value, forKey: [account, String(parts[0]), "runtime/" + String(parts[1])].joined(separator: "|"))
                }
            } else {
                continue
            }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "scopedDevicePreferences")
    }

    static func forget(_ account: String, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("device." + account + ".") || key.hasPrefix(account + "|") {
            defaults.removeObject(forKey: key)
        }
    }
}

struct GatewayLogin: Equatable {
    let server: URL
    let token: String
}

/// Stores server addresses in defaults and calls the injected credential store for each origin.
struct SavedGateways {
    let defaults: UserDefaults
    let read: (String) -> String?
    let write: (String, String) -> Bool
    let remove: (String) -> Bool

    static func origin(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(), !host.isEmpty,
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { return nil }
        c.scheme = scheme
        c.host = host
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        c.path = ""
        return c.url
    }

    /// Only expand a single DNS label on the active gateway's known Tailscale domain.
    static func peerOrigin(_ input: String, relativeTo active: URL?) -> URL? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let active, active.scheme == "https", let host = active.host?.lowercased(),
              host.hasSuffix(".ts.net"), host.split(separator: ".").count == 4,
              name.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil,
              name != "localhost", !name.allSatisfy(\.isNumber),
              var parts = URLComponents(url: active, resolvingAgainstBaseURL: false),
              let dot = host.firstIndex(of: ".") else { return nil }
        parts.host = name + String(host[dot...])
        return parts.url.flatMap(origin)
    }

    static func displayName(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if host.hasSuffix(".ts.net"), let first = host.split(separator: ".").first { return String(first) }
        return host
    }

    var servers: [URL] {
        (defaults.stringArray(forKey: "savedGatewayOrigins") ?? []).compactMap(URL.init(string:))
    }

    func credential(_ server: URL) -> GatewayLogin? {
        guard let url = Self.origin(server), servers.contains(url),
              let token = read("gateway." + url.absoluteString) else { return nil }
        return GatewayLogin(server: url, token: token)
    }

    func remember(_ login: GatewayLogin) -> Bool {
        guard let server = Self.origin(login.server), !login.token.isEmpty,
              write("gateway." + server.absoluteString, login.token) else { return false }
        var items = servers
        if !items.contains(server) { items.append(server) }
        defaults.set(items.map(\.absoluteString), forKey: "savedGatewayOrigins")
        defaults.set(server.absoluteString, forKey: "server")
        defaults.set(true, forKey: "migratedGatewayCredentials")
        return true
    }

    func restore() -> GatewayLogin? {
        guard let raw = defaults.string(forKey: "server"), let url = URL(string: raw),
              let origin = Self.origin(url) else { return nil }
        if let prior = credential(origin) { return prior }
        // Bind a pre-upgrade single token exactly once to its existing server.
        guard !defaults.bool(forKey: "migratedGatewayCredentials"), let old = read("token") else { return nil }
        let login = GatewayLogin(server: origin, token: old)
        guard remember(login) else { return nil }
        _ = remove("token")
        return login
    }

    func forget(_ server: URL) -> Bool {
        guard let origin = Self.origin(server) else { return false }
        let deleted = remove("gateway." + origin.absoluteString)
        defaults.set(true, forKey: "migratedGatewayCredentials")
        // An earlier upgrade may have completed just before legacy cleanup was interrupted.
        if let raw = defaults.string(forKey: "server"), let active = URL(string: raw),
           Self.origin(active) == origin { _ = remove("token") }
        defaults.set(servers.filter { $0 != origin }.map(\.absoluteString), forKey: "savedGatewayOrigins")
        return deleted
    }
}

// MARK: - Message format (rendered by MarkdownText)

/// One block of a Markdown message, as the phone renders it. See docs/message-format.md for the contract.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case list([ListItem])
    case quote(String)
    case code(language: String, body: String, closed: Bool, file: String? = nil)
    /// GitHub alert syntax: `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`.
    case callout(kind: String, text: String)
    case table([[String]])
    case rule

    struct ListItem: Equatable {
        var depth: Int
        /// "•", "1.", "☐" or "☑".
        var marker: String
        var text: String
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !quote.isEmpty {
                if let kind = calloutKind(quote[0]) {
                    var lines = Array(quote.dropFirst())
                    let rest = quote[0].replacingOccurrences(of: "[!\(kind.uppercased())]", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { lines.insert(rest, at: 0) }
                    out.append(.callout(kind: kind, text: lines.joined(separator: "\n")))
                } else {
                    out.append(.quote(quote.joined(separator: "\n")))
                }
                quote = []
            }
            if !table.isEmpty {
                let rows = table.filter { !isTableRule($0) }.map(cells)
                if table.count >= 2, table.contains(where: isTableRule) { out.append(.table(rows)) }
                else { out.append(.paragraph(table.joined(separator: "\n"))) }
                table = []
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code: ``` or ~~~, with an optional language. An unclosed fence (a reply still streaming)
            // runs to the end and is shown as code straight away.
            if let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flush()
                let (language, file) = fenceInfo(String(trimmed.dropFirst(fence.count)))
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { closed = true; break }
                    body.append(lines[i])
                    i += 1
                }
                out.append(.code(language: language, body: body.joined(separator: "\n"), closed: closed, file: file))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let heading = headingLevel(trimmed) {
                flush()
                out.append(.heading(heading.level, heading.text))
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && trimmed.count >= 3 {
                flush()
                out.append(.rule)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !list.isEmpty || !table.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
                if !paragraph.isEmpty || !list.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
            } else if let item = listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                list.append(item)
            } else if !list.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                // A wrapped continuation of the previous list item.
                list[list.count - 1].text += " " + trimmed
            } else {
                if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return out
    }

    /// "python title=build.py", "ts src/app.ts" or "build.py": the language and an optional file name.
    static func fenceInfo(_ raw: String) -> (language: String, file: String?) {
        let tokens = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        var language = tokens.first ?? ""
        var file: String?
        for token in tokens {
            for key in ["title=", "file=", "filename="] where token.lowercased().hasPrefix(key) {
                file = String(token.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        if file == nil, let first = tokens.first, first.contains("."), !first.hasPrefix("."), !first.contains("=") {
            file = first
            language = (first as NSString).pathExtension
        } else if file == nil, tokens.count > 1, tokens[1].contains("."), !tokens[1].contains("=") {
            file = tokens[1]
        }
        if language.contains("=") { language = "" }
        return (language, file?.isEmpty == true ? nil : file)
    }

    /// "bash" reads "Bash", "cpp" reads "C++": the label a code block's header shows.
    static func languageName(_ raw: String) -> String {
        let names = ["sh": "Shell", "bash": "Bash", "zsh": "Zsh", "shell": "Shell", "console": "Console", "fish": "Fish",
                     "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
                     "tsx": "TSX", "jsx": "JSX", "py": "Python", "python": "Python", "swift": "Swift", "rb": "Ruby",
                     "ruby": "Ruby", "go": "Go", "rs": "Rust", "rust": "Rust", "c": "C", "h": "C", "cpp": "C++", "c++": "C++",
                     "cs": "C#", "csharp": "C#", "java": "Java", "kt": "Kotlin", "kotlin": "Kotlin", "json": "JSON",
                     "jsonc": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML", "html": "HTML",
                     "css": "CSS", "scss": "SCSS", "sql": "SQL", "md": "Markdown", "markdown": "Markdown", "diff": "Diff",
                     "patch": "Diff", "dockerfile": "Dockerfile", "docker": "Dockerfile", "ps1": "PowerShell",
                     "powershell": "PowerShell", "text": "Text", "txt": "Text", "plaintext": "Text", "graphql": "GraphQL",
                     "php": "PHP", "lua": "Lua", "r": "R", "ini": "INI", "env": "Env", "nginx": "Nginx",
                     "makefile": "Makefile", "make": "Makefile", "proto": "Protobuf", "regex": "Regex", "applescript": "AppleScript",
                     "gcode": "G-code", "smiles": "SMILES", "fasta": "FASTA"]
        if raw.isEmpty { return "Code" }
        return names[raw.lowercased()] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// The message as plain text: Markdown markers gone, code kept verbatim. "Copy" uses this.
    static func plainText(_ text: String) -> String {
        func flat(_ s: String) -> String {
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return (try? AttributedString(markdown: s, options: opts)).map { String($0.characters) } ?? s
        }
        return parse(text).map { block -> String in
            switch block {
            case .paragraph(let s), .quote(let s): return flat(s)
            case .heading(_, let s): return flat(s)
            case .callout(_, let s): return flat(s)
            case .list(let items):
                return items.map { String(repeating: "  ", count: $0.depth) + ($0.marker == "•" ? "-" : $0.marker) + " " + flat($0.text) }
                    .joined(separator: "\n")
            case .code(_, let body, _, _): return body
            case .table(let rows): return rows.map { $0.map(flat).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: return "---"
            }
        }.joined(separator: "\n\n")
    }

    private static func calloutKind(_ line: String) -> String? {
        let lower = line.lowercased()
        return ["note", "tip", "important", "warning", "caution"].first { lower.hasPrefix("[!\($0)]") }
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var marker: String
        var rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            marker = "•"
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 4 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            rest = after.dropFirst(2)
        }
        if marker == "•" {
            if rest.hasPrefix("[ ] ") { marker = "☐"; rest = rest.dropFirst(4) }
            else if rest.lowercased().hasPrefix("[x] ") { marker = "☑"; rest = rest.dropFirst(4) }
        }
        return ListItem(depth: min(indent / 2, 4), marker: marker, text: String(rest))
    }

    private static func isTableRule(_ line: String) -> Bool {
        let core = line.replacingOccurrences(of: " ", with: "")
        return !core.isEmpty && core.allSatisfy { "|-:".contains($0) } && core.contains("-")
    }

    private static func cells(_ line: String) -> [String] {
        var core = line.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("|") { core.removeFirst() }
        if core.hasSuffix("|") { core.removeLast() }
        return core.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Model ids as people say them: "claude-opus-5-5[1m]" reads "Opus 5.5 · 1M", "deepseek-v4-pro" reads
/// "DeepSeek V4 Pro", "accounts/fireworks/models/glm-5p1" reads "GLM 5.1". Display only; the id is kept everywhere else.
enum ModelName {
    /// Same model, ignoring provider prefixes and context tags: "x-ai/grok-4.7" = "grok-4.7", "claude-opus-5-5[1m]" = "claude-opus-5-5".
    static func same(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var k = s.lowercased()
            if let slash = k.lastIndex(of: "/") { k = String(k[k.index(after: slash)...]) }
            if let br = k.firstIndex(of: "[") { k = String(k[..<br]) }
            return k.replacingOccurrences(of: ".", with: "-").trimmingCharacters(in: .whitespaces)
        }
        return key(a) == key(b)
    }

    private static let upper: Set<String> = ["gpt", "glm", "llm", "ai", "oss", "vl", "moe", "r1", "o1", "o3", "o4"]
    private static let brands: [String: String] = ["deepseek": "DeepSeek", "openai": "OpenAI", "xai": "xAI",
                                                   "qwen": "Qwen", "kimi": "Kimi", "minimax": "MiniMax", "grok": "Grok"]

    static func short(_ raw: String) -> String {
        var id = raw.split(separator: "/").last.map(String.init) ?? raw
        var context = ""
        if let open = id.firstIndex(of: "["), id.hasSuffix("]") {
            context = String(id[id.index(after: open)..<id.index(before: id.endIndex)]).uppercased()
            id = String(id[..<open])
        }
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        // Dated snapshots ("-20250514") say nothing a person needs.
        id = id.replacingOccurrences(of: #"-20\d{6}$"#, with: "", options: .regularExpression)
        var words: [String] = []
        for token in id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" }).map(String.init) {
            let fixed = token.replacingOccurrences(of: #"^(\d+)p(\d+)$"#, with: "$1.$2", options: .regularExpression)
            if let last = words.last, fixed.allSatisfy(\.isNumber), last.allSatisfy({ $0.isNumber || $0 == "." }), !last.contains(".") {
                words[words.count - 1] = last + "." + fixed
                continue
            }
            let lower = fixed.lowercased()
            if let brand = brands[lower] { words.append(brand) }
            else if upper.contains(lower) { words.append(lower.uppercased()) }
            else if lower.first?.isLetter == true, lower.count > 1, lower.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                words.append(lower.uppercased())  // v4, k2
            } else { words.append(fixed.prefix(1).uppercased() + fixed.dropFirst()) }
        }
        let name = words.joined(separator: " ")
        return context.isEmpty ? name : name + " · " + context
    }
}

/// What a chat or a reply cost, from Hermes's own ledger. `usd` is real money (API-priced routes);
/// subscription routes are `included`, with what they would have cost at API prices kept separately.
struct CostSummary: Codable, Hashable {
    let usd: Double
    let includedApiUsd: Double
    let included: Bool
    let unknown: Bool
    enum CodingKeys: String, CodingKey { case usd, included, unknown, includedApiUsd = "included_api_usd" }

    init(usd: Double, includedApiUsd: Double = 0, included: Bool = false, unknown: Bool = false) {
        self.usd = usd; self.includedApiUsd = includedApiUsd; self.included = included; self.unknown = unknown
    }

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any] else { return nil }
        self.init(usd: (d["usd"] as? NSNumber)?.doubleValue ?? 0,
                  includedApiUsd: (d["included_api_usd"] as? NSNumber)?.doubleValue ?? 0,
                  included: d["included"] as? Bool ?? false, unknown: d["unknown"] as? Bool ?? false)
    }

    static func money(_ usd: Double) -> String {
        if usd < 0.005 { return "<$0.01" }
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 1 ? 3 : 2)))
    }

    /// On a chat row: "$1.24", "Plan", "$0.40 + plan". Nil when nothing is priced or included.
    var rowLabel: String? {
        let paid = usd >= 0.0005
        if paid && included { return Self.money(usd) + " + plan" }
        if paid { return Self.money(usd) }
        if included { return "Plan" }
        return nil
    }

    var spokenLabel: String? {
        let paid = usd >= 0.0005
        if paid && included { return "Cost \(Self.money(usd)), plus usage included in a plan" }
        if paid { return "Cost \(Self.money(usd))" }
        if included { return "Included in a plan" }
        return nil
    }

    /// Under one reply: "$0.042", "Included in plan", "$0.03 + plan". Nil when nothing is priced or included.
    var replyLabel: String? {
        let paid = usd >= 0.0005
        if paid && included { return Self.money(usd) + " + plan" }
        if paid { return Self.money(usd) }
        if included { return "Included in plan" }
        return nil
    }
}

/// One chat's queue on the Mac (Hermes's session_admissions), oldest first.
struct QueueState: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String          // admission id
        let status: String      // queued | started | steering | unknown
        let text: String
        let canEdit: Bool
        let canSteer: Bool
        let canCancel: Bool
    }
    let rows: [Row]
    /// Hermes restarted mid-reply and holds the queue until that loss is acknowledged.
    let paused: Bool
    let lost: Row?

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any], let list = d["pending"] as? [[String: Any]] else { return nil }
        func row(_ r: [String: Any]) -> Row? {
            guard let id = r["admission_id"] as? String else { return nil }
            return Row(id: id, status: r["status"] as? String ?? "queued", text: r["text"] as? String ?? "",
                       canEdit: r["can_edit"] as? Bool ?? false, canSteer: r["can_steer"] as? Bool ?? false,
                       canCancel: r["can_cancel"] as? Bool ?? false)
        }
        rows = list.compactMap(row)
        paused = d["paused"] as? Bool ?? false
        lost = (d["lost"] as? [String: Any]).flatMap(row)
    }

    func row(_ admission: String) -> Row? { rows.first { $0.id == admission } }
    /// Still waiting its turn (not started, not finished).
    func isWaiting(_ admission: String) -> Bool { row(admission)?.status == "queued" }
}

/// A question Hermes asked mid-reply. Answered from the phone: tap a choice, or just reply.
struct ClarifyRequest: Identifiable, Equatable {
    let id: String
    let runId: String
    let generation: Int?
    let question: String
    let choices: [String]
    let multiSelect: Bool
}


/// One match from searching a chat (bridge `GET /m/chat/<bot>/<chat>/search`).
struct ChatSearchHit: Decodable, Identifiable, Hashable {
    let messageId: Int
    let role: String
    let timestamp: Double?
    let snippet: String
    /// Where the match sits in `snippet` (characters), to bold it.
    let offset: Int
    let length: Int
    var id: Int { messageId }
    var itemID: String { String(messageId) }
    enum CodingKeys: String, CodingKey { case role, timestamp, snippet, offset, length; case messageId = "message_id" }

    /// The snippet with the match in bold.
    var attributed: AttributedString {
        var out = AttributedString(snippet)
        let chars = Array(snippet)
        guard offset >= 0, length > 0, offset + length <= chars.count else { return out }
        let lower = out.index(out.startIndex, offsetByCharacters: offset)
        let upper = out.index(lower, offsetByCharacters: length)
        out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        return out
    }
}

struct ChatSearchResult: Decodable {
    let query: String
    let results: [ChatSearchHit]
    let total: Int
    let truncated: Bool
}

extension Array {
    /// The element at `index`, or nil past either end.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
