import Foundation

/// One Hermes profile ("bot"). `id` is the profile name; "default" is the front door.
struct Bot: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let model: String
    let provider: String
    let reachable: Bool
    let front: Bool
}

/// A session row as the gateway lists it (plus `profile`, added by the bridge).
struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let profile: String
    let source: String?
    let model: String?
    let title: String?
    let preview: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    let pinned: Bool?
    let archived: Bool?
    let endedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, profile, source, model, title, preview, pinned, archived
        case startedAt = "started_at", lastActive = "last_active", messageCount = "message_count", endedAt = "ended_at"
    }

    var key: String { "\(profile)/\(id)" }
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return String(p.prefix(80)) }
        return "Untitled chat"
    }
    var date: Date { Date(timeIntervalSince1970: lastActive ?? startedAt ?? 0) }

    /// Where the chat came from, in plain words.
    var sourceLabel: String {
        switch source ?? "" {
        case "local", "desktop": return "Desktop"
        case "gui": return "Desktop / mobile"
        case "hermes_browser", "api_server": return "Phone/API"
        case "bluebubbles": return "iMessage"
        case "tui", "cli": return "Terminal"
        case "cron": return "Scheduled"
        case "oneshot": return "One-shot"
        case "subagent": return "Subagent"
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

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case toolName = "tool_name", toolCalls = "tool_calls", displayKind = "display_kind"
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
        struct Fn: Codable, Hashable { let name: String?; let arguments: String? }
    }
}

struct MessagesPage: Codable { let data: [StoredMessage] }

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

    var usable: [Provider] { providers.filter { $0.authenticated && !$0.models.isEmpty } }
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

    struct Policy: Codable, Hashable { let model: String?; let provider: String?; let effort: String? }
    struct Used: Codable, Hashable {
        let model: String
        let provider: String?
        let calls: Int?
        let reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case model, provider, calls, reasoningTokens = "reasoning_tokens" }
    }
    enum CodingKeys: String, CodingKey {
        case model, provider, policy
        case reasoningTokens = "reasoning_tokens", fallbackActive = "fallback_active", modelsUsed = "models_used"
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
    enum CodingKeys: String, CodingKey { case profile, done, turnId = "turn_id", sessionId = "session_id" }
}

struct HealthInfo: Codable {
    struct Transition: Codable { let phase: String; let at: Double }
    let phase: String?
    let recent: [Transition]?
    let reason: String?
    let imageAttachments: Bool?
    let inboxFallback: String?
    let ok: Bool
    let gatewayState: String?
    let version: String?
    enum CodingKeys: String, CodingKey { case ok, version, phase, recent, reason, imageAttachments = "image_attachments", inboxFallback = "inbox_fallback", gatewayState = "gateway_state" }
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
    enum CodingKeys: String, CodingKey {
        case features, deviceID = "device_id", manageDevices = "manage_devices"
    }
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
