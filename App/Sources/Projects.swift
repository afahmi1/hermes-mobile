import Foundation
import Observation

// Read-only Projects, schema V1 from GET /m/projects. Nothing here is persisted: the model lives
// in the Projects view and goes away with it (and with sign-out, which removes the tab).

enum RootKind: String, Hashable {
    case repo, vault, other
}

struct ProjectRoot: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: RootKind

    private enum CodingKeys: String, CodingKey { case id, label, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = RootKind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .other
    }
}

struct ProjectSource: Decodable, Hashable {
    let provider: String
    let source: String
}

struct ProjectFileRef: Decodable, Hashable {
    let root: String
    let path: String
}

struct Project: Decodable, Hashable, Identifiable {
    let id: String
    let title: String
    let summary: String?
    let botIds: [String]
    let sources: [ProjectSource]
    let relatedFiles: [ProjectFileRef]

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, sources
        case botIds = "bot_ids", relatedFiles = "related_files"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        botIds = try c.decodeIfPresent([String].self, forKey: .botIds) ?? []
        sources = try c.decodeIfPresent([ProjectSource].self, forKey: .sources) ?? []
        relatedFiles = try c.decodeIfPresent([ProjectFileRef].self, forKey: .relatedFiles) ?? []
    }
}

/// Why Projects could not load. Messages are fixed text: server error bodies and paths are never shown.
enum ProjectsFailure: Error, Equatable {
    case bridgeTooOld, unsupportedVersion, unavailable, malformed, network, signedOut

    static func fromHTTP(_ status: Int) -> ProjectsFailure {
        switch status {
        case 404: .bridgeTooOld
        case 401: .signedOut
        default: .unavailable
        }
    }

    static func classify(_ error: Error) -> ProjectsFailure {
        switch error {
        case let f as ProjectsFailure: return f
        case is DecodingError: return .malformed
        default: return .network  // URLError and anything unexpected; API.projects() maps APIError first
        }
    }

    /// The Mac's bridge (or this app) is on a different version: friendly upgrade panel.
    var isUpgrade: Bool { self == .bridgeTooOld || self == .unsupportedVersion }

    var title: String {
        switch self {
        case .bridgeTooOld: "Update the Mac bridge"
        case .unsupportedVersion: "Projects version mismatch"
        case .signedOut: "Sign in again"
        case .unavailable: "Projects unavailable"
        case .malformed: "Unreadable response"
        case .network: "Can't reach Hermes"
        }
    }

    var message: String {
        switch self {
        case .bridgeTooOld: "The Hermes bridge on your Mac doesn't support Projects yet. Update it, then try again."
        case .unsupportedVersion: "The bridge and this app use different Projects versions. Update whichever is older, then try again."
        case .signedOut: "Your session ended. Sign in to Hermes again."
        case .unavailable: "The bridge couldn't list projects right now. Try again in a moment."
        case .malformed: "The bridge sent a response this app couldn't read. Try again."
        case .network: "Check your connection and the bridge address, then try again."
        }
    }
}

enum SafeRelativePath {
    /// Match the bridge's relative-reference contract; never rewrite the referenced filename.
    static func normalize(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 512, !raw.hasPrefix("~"),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.rangeOfCharacter(from: CharacterSet(charactersIn: ":\\%#?")) == nil else { return nil }
        guard !raw.unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }), !raw.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".."
        }) else { return nil }
        return raw
    }
}

struct DisplayReference: Hashable, Identifiable {
    let rootID: String
    let rootName: String
    let kind: RootKind
    let path: String
    var copyText: String { "\(rootID): \(path)" }
    var id: String { copyText }
}

struct BotLink: Hashable, Identifiable {
    let id: String
    let displayName: String
    /// Only a known, reachable bot can open BotDetailView.
    let bot: Bot?
    var isLinkable: Bool { bot != nil }
}

struct ProjectsSnapshot: Equatable {
    let configured: Bool
    let roots: [ProjectRoot]
    let projects: [Project]

    private struct Version: Decodable { let schema_version: Int }
    private struct Wire: Decodable {
        let configured: Bool
        let roots: [ProjectRoot]
        let projects: [Project]
    }

    static func decode(_ data: Data) throws -> ProjectsSnapshot {
        let decoder = JSONDecoder()
        guard data.count <= 256 * 1024, let version = try? decoder.decode(Version.self, from: data) else {
            throw ProjectsFailure.malformed
        }
        guard version.schema_version == 1 else { throw ProjectsFailure.unsupportedVersion }
        guard let wire = try? decoder.decode(Wire.self, from: data) else { throw ProjectsFailure.malformed }
        var seen = Set<String>()
        let projects = wire.projects.filter { seen.insert($0.id).inserted }
        return ProjectsSnapshot(configured: wire.configured, roots: wire.roots, projects: projects)
    }

    func references(for project: Project) -> (shown: [DisplayReference], hidden: Int) {
        var shown: [DisplayReference] = []
        var hidden = 0
        var seen = Set<ProjectFileRef>()
        for ref in project.relatedFiles {
            guard seen.insert(ref).inserted, let root = roots.first(where: { $0.id == ref.root }),
                  let path = SafeRelativePath.normalize(ref.path) else {
                hidden += 1
                continue
            }
            shown.append(DisplayReference(rootID: root.id, rootName: root.label, kind: root.kind, path: path))
        }
        return (shown, hidden)
    }

    static func botLinks(ids: [String], bots: [Bot]) -> [BotLink] {
        ids.map { id in
            let bot = bots.first { $0.id == id }
            return BotLink(id: id, displayName: bot?.name ?? id, bot: (bot?.reachable ?? false) ? bot : nil)
        }
    }
    func botLinks(for project: Project, bots: [Bot]) -> [BotLink] { Self.botLinks(ids: project.botIds, bots: bots) }

    func projects(forBot id: String) -> [Project] { projects.filter { $0.botIds.contains(id) } }

    func filtered(_ query: String) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return projects }
        return projects.filter { p in
            ([p.title, p.summary ?? ""] + p.sources.flatMap { [$0.provider, $0.source] })
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }
}

enum ProjectsLoadState: Equatable {
    case idle, loading, notConfigured, empty
    case loaded(ProjectsSnapshot)
    case failed(ProjectsFailure)

    init(snapshot: ProjectsSnapshot) {
        if !snapshot.configured { self = .notConfigured }
        else if snapshot.projects.isEmpty { self = .empty }
        else { self = .loaded(snapshot) }
    }
}

@MainActor @Observable
final class ProjectsModel {
    private(set) var state: ProjectsLoadState = .idle
    var query = ""
    @ObservationIgnored private let fetch: () async throws -> ProjectsSnapshot
    @ObservationIgnored private var generation = 0

    init(fetch: @escaping () async throws -> ProjectsSnapshot) { self.fetch = fetch }

    /// Loads (or reloads). The newest call wins; a cancelled call changes nothing but a spinner.
    func load() async {
        generation += 1
        let mine = generation
        let before = state
        if case .loaded = state {} else { state = .loading }
        do {
            let snapshot = try await fetch()
            guard mine == generation else { return }
            guard !Task.isCancelled else { return restore(before) }
            state = ProjectsLoadState(snapshot: snapshot)
        } catch {
            guard mine == generation else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return restore(before) }
            state = .failed(ProjectsFailure.classify(error))
        }
    }

    private func restore(_ before: ProjectsLoadState) {
        state = before == .loading ? .idle : before
    }

    func reset() {
        generation += 1
        state = .idle
        query = ""
    }
}
