import Foundation

/// Hermes add-ons the owner phone can browse and install: Skills Hub skills, plugins and MCP servers.
/// The bridge calls Hermes's own functions (the same ones its dashboard uses), so the security scan, capability
/// consent and declared-settings checks are Hermes's, not this app's. Contract: Bridge/bridge_addons.py.
enum AddonKind: String, CaseIterable, Identifiable, Codable {
    case skills, plugins, mcp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .mcp: "MCP"
        }
    }
    var symbol: String {
        switch self {
        case .skills: "book.closed"
        case .plugins: "puzzlepiece.extension"
        case .mcp: "server.rack"
        }
    }
    /// What the tab is, in one line, under its title.
    var blurb: String {
        switch self {
        case .skills: "Know-how Hermes loads when a task needs it."
        case .plugins: "New tools and powers for Hermes."
        case .mcp: "Connect Hermes to apps and services."
        }
    }
}

struct AddonItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let source: String
    let trust: String
    let repo: String?
    let tags: [String]
    let installed: Bool
    let enabled: Bool?
    let updateAvailable: Bool
    let needsSetup: Bool
    let version: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, source, trust, repo, tags, installed, enabled, version
        case updateAvailable = "update_available", needsSetup = "needs_setup"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        trust = try c.decodeIfPresent(String.self, forKey: .trust) ?? "community"
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        needsSetup = try c.decodeIfPresent(Bool.self, forKey: .needsSetup) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
    }

    /// How much to trust where it comes from, in words a person can act on.
    var trustLabel: String {
        switch trust {
        case "builtin": "Built in"
        case "trusted": "Trusted"
        case "curated": "Curated"
        default: "Community"
        }
    }
    var isCommunity: Bool { trust == "community" }
    var sourceLabel: String {
        switch source.lowercased() {
        case "": ""
        case "github": "GitHub"
        case "clawhub": "ClawHub"
        case "official": "Official"
        default: source.prefix(1).uppercased() + source.dropFirst()
        }
    }
}

struct AddonCatalog: Decodable {
    let kind: String
    let items: [AddonItem]
    var featured: [String] = []
    var timedOut: [String] = []
    var note: String? = nil
    enum CodingKeys: String, CodingKey { case kind, items, featured, note; case timedOut = "timed_out" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        items = try c.decodeIfPresent([AddonItem].self, forKey: .items) ?? []
        featured = try c.decodeIfPresent([String].self, forKey: .featured) ?? []
        timedOut = try c.decodeIfPresent([String].self, forKey: .timedOut) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

struct AddonSetting: Decodable, Hashable {
    let name: String
    let description: String?
    let secret: Bool
    let required: Bool
}

struct AddonDetail: Decodable {
    let item: AddonItem
    var readme: String? = nil
    var files: [String] = []
    var env: [AddonSetting] = []
    var capabilities: [String] = []
    var suggest: [String] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(AddonItem.self, forKey: .item)
        readme = try c.decodeIfPresent(String.self, forKey: .readme)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        env = try c.decodeIfPresent([AddonSetting].self, forKey: .env) ?? []
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        suggest = try c.decodeIfPresent([String].self, forKey: .suggest) ?? []
    }
    enum CodingKeys: String, CodingKey { case item, readme, files, env, capabilities, suggest }
}

struct AddonScan: Decodable {
    struct Finding: Decodable, Hashable { let severity: String; let title: String; let file: String? }
    let verdict: String
    let policy: String
    let reason: String?
    let severityCounts: [String: Int]
    let findings: [Finding]
    let scanID: String
    enum CodingKeys: String, CodingKey {
        case verdict, policy, reason, findings
        case severityCounts = "severity_counts", scanID = "scan_id"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? "not_scanned"
        policy = try c.decodeIfPresent(String.self, forKey: .policy) ?? "ask"
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        severityCounts = try c.decodeIfPresent([String: Int].self, forKey: .severityCounts) ?? [:]
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        scanID = try c.decode(String.self, forKey: .scanID)
    }
    var blocked: Bool { policy == "block" }
    /// Ask = Hermes wants a human to look before it goes in.
    var needsCare: Bool { policy == "ask" }
}

/// What an install, update, removal or toggle did. `restart` says when it takes effect.
struct AddonChange: Decodable {
    let status: String
    var action: String? = nil
    var message: String = ""
    var restart: String = "none"
    var capabilities: [String] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "done"
        action = try c.decodeIfPresent(String.self, forKey: .action)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        restart = try c.decodeIfPresent(String.self, forKey: .restart) ?? "none"
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
    enum CodingKeys: String, CodingKey { case status, action, message, restart, capabilities }

    static func restartNote(_ restart: String) -> String? {
        switch restart {
        case "next_session": "Takes effect in the next chat."
        case "restart_hermes": "Takes effect after Hermes restarts."
        default: nil
        }
    }
}

struct AddonAction: Decodable {
    let state: String
    var logTail: String = ""
    var message: String = ""
    var restart: String = "none"
    enum CodingKeys: String, CodingKey { case state, message, restart; case logTail = "log_tail" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        logTail = try c.decodeIfPresent(String.self, forKey: .logTail) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        restart = try c.decodeIfPresent(String.self, forKey: .restart) ?? "none"
    }
}

extension API {
    private func addonQuery(_ pairs: [(String, String?)]) -> String {
        var parts = URLComponents()
        parts.queryItems = pairs.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        return parts.percentEncodedQuery.map { "?" + $0 } ?? ""
    }

    func addonCatalog(_ kind: AddonKind, query: String?, profile: String) async throws -> AddonCatalog {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await getJSON("/m/addons/catalog" + addonQuery([("kind", kind.rawValue), ("q", q?.isEmpty == false ? q : nil),
                                                                   ("profile", profile)]), as: AddonCatalog.self)
    }

    func addonDetail(_ kind: AddonKind, id: String, profile: String) async throws -> AddonDetail {
        try await getJSON("/m/addons/detail" + addonQuery([("kind", kind.rawValue), ("id", id), ("profile", profile)]), as: AddonDetail.self)
    }

    func addonScan(_ kind: AddonKind, id: String, profile: String) async throws -> AddonScan {
        try await getJSON("/m/addons/scan" + addonQuery([("kind", kind.rawValue), ("id", id), ("profile", profile)]), as: AddonScan.self)
    }

    func addonInstall(_ kind: AddonKind, id: String, profile: String, scanID: String?, env: [String: String] = [:],
                      consent: Bool = false) async throws -> AddonChange {
        var body: [String: Any] = ["kind": kind.rawValue, "id": id, "profile": profile, "consent": consent]
        if let scanID { body["scan_id"] = scanID }
        if !env.isEmpty { body["env"] = env }
        return try await postJSON("/m/addons/install", body: body, as: AddonChange.self)
    }

    func addonUpdate(_ kind: AddonKind, id: String, profile: String, consent: Bool = false) async throws -> AddonChange {
        try await postJSON("/m/addons/update", body: ["kind": kind.rawValue, "id": id, "profile": profile, "consent": consent],
                           as: AddonChange.self)
    }

    func addonUninstall(_ kind: AddonKind, id: String, profile: String) async throws -> AddonChange {
        try await postJSON("/m/addons/uninstall", body: ["kind": kind.rawValue, "id": id, "profile": profile], as: AddonChange.self)
    }

    func addonEnable(_ kind: AddonKind, id: String, profile: String, enabled: Bool) async throws -> AddonChange {
        try await postJSON("/m/addons/enable", body: ["kind": kind.rawValue, "id": id, "profile": profile, "enabled": enabled],
                           as: AddonChange.self)
    }

    func addonAction(_ action: String) async throws -> AddonAction {
        try await getJSON("/m/addons/action/" + API.escapePath(action), as: AddonAction.self)
    }
}
