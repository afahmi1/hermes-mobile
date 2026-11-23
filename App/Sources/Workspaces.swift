import Foundation
import Observation

// Workspaces: per-project persistent instructions, small UTF-8 reference files, chats started with an
// explicit bot, and artifacts. App-only (not compiled into the share/widget extensions); it depends on
// nothing but Foundation and `Bot`. Nothing is persisted on the phone: the Mac holds it all.

enum WorkspaceLimits {
    static let instructionBytes = 4096
    static let fileBytes = 8192
    static let maxFiles = 4
    static let artifactDownloadBytes = 8 * 1024 * 1024
    static let previewBytes = 64 * 1024
    static let supportedExtensions: Set<String> = ["txt", "md", "csv", "json"]
}

/// Why a Workspaces call failed. Messages are fixed text: server bodies and paths are never shown.
enum WorkspacesFailure: Error, Equatable {
    case disabled, signedOut, rejected, tooLarge, unavailable, malformed, network

    static func fromHTTP(_ status: Int) -> WorkspacesFailure {
        switch status {
        case 404: .disabled
        case 401: .signedOut
        case 400, 409, 413, 415, 422, 507: .rejected
        default: .unavailable
        }
    }

    var message: String {
        switch self {
        case .disabled: "Workspaces aren't turned on for this project (or the Mac bridge is too old). Your project catalog is unaffected."
        case .signedOut: "Your session ended. Sign in to Hermes again."
        case .rejected: "The bridge refused that change (size, type or count limit)."
        case .tooLarge: "That file is larger than the 8 MiB the app will download."
        case .unavailable: "The bridge couldn't complete that right now. Try again in a moment."
        case .malformed: "The bridge sent a response this app couldn't read."
        case .network: "Check your connection and the bridge address, then try again."
        }
    }
}

// MARK: wire types

struct WorkspaceIndex: Equatable {
    let projects: [String]
    let profiles: [String]

    private struct Wire: Decodable { let projects: [String]; let profiles: [String] }
    static func decode(_ data: Data) throws -> WorkspaceIndex {
        guard data.count <= 256 * 1024, let w = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw WorkspacesFailure.malformed
        }
        return WorkspaceIndex(projects: w.projects, profiles: w.profiles)
    }
    func isEnabled(project id: String) -> Bool { projects.contains(id) }
}

struct WorkspaceFile: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let size: Int
}

struct WorkspaceChat: Decodable, Hashable, Identifiable {
    let profile: String
    let sessionId: String
    let title: String?
    var id: String { "\(profile)/\(sessionId)" }
    private enum CodingKeys: String, CodingKey { case profile, title; case sessionId = "session_id" }
}

struct WorkspaceArtifact: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let size: Int
    let projectId: String?
    let profile: String?
    let sessionId: String?
    let mime: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, size, profile, mime
        case projectId = "project_id", sessionId = "session_id"
    }

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^art_[0-9a-f]{32}$"#, options: .regularExpression) != nil
    }

    static func decodeList(_ data: Data) throws -> [WorkspaceArtifact] {
        struct R: Decodable { let artifacts: [WorkspaceArtifact] }
        guard data.count <= 512 * 1024, let r = try? JSONDecoder().decode(R.self, from: data) else {
            throw WorkspacesFailure.malformed
        }
        var seen = Set<String>()
        return r.artifacts.filter { isValidID($0.id) && seen.insert($0.id).inserted }
    }
}

struct WorkspaceDetail: Decodable, Equatable {
    var instructions: String
    var files: [WorkspaceFile]
    var chats: [WorkspaceChat]
    var artifacts: [WorkspaceArtifact]
    var profiles: [String]

    private enum CodingKeys: String, CodingKey { case instructions, files, chats, artifacts, profiles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        files = try c.decodeIfPresent([WorkspaceFile].self, forKey: .files) ?? []
        chats = try c.decodeIfPresent([WorkspaceChat].self, forKey: .chats) ?? []
        artifacts = try c.decodeIfPresent([WorkspaceArtifact].self, forKey: .artifacts) ?? []
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
    }
    init(instructions: String = "", files: [WorkspaceFile] = [], chats: [WorkspaceChat] = [],
         artifacts: [WorkspaceArtifact] = [], profiles: [String] = []) {
        self.instructions = instructions; self.files = files; self.chats = chats
        self.artifacts = artifacts; self.profiles = profiles
    }

    static func decode(_ data: Data) throws -> WorkspaceDetail {
        guard data.count <= 512 * 1024, let d = try? JSONDecoder().decode(WorkspaceDetail.self, from: data) else {
            throw WorkspacesFailure.malformed
        }
        var seen = Set<String>()
        var out = d
        out.artifacts = d.artifacts.filter { WorkspaceArtifact.isValidID($0.id) && seen.insert($0.id).inserted }
        return out
    }
}

// MARK: validation

enum WorkspaceValidation {
    enum Problem: Error, Equatable {
        case instructionsTooLong, unsupportedType, fileTooLarge, notUTF8, badName, tooManyFiles, empty

        var message: String {
            switch self {
            case .instructionsTooLong: "Instructions are limited to 4096 bytes."
            case .unsupportedType: "Only .txt, .md, .csv and .json files can be added."
            case .fileTooLarge: "Reference files are limited to 8192 bytes."
            case .notUTF8: "That file isn't UTF-8 text."
            case .badName: "That file name isn't usable."
            case .tooManyFiles: "A project holds at most 4 reference files."
            case .empty: "That file is empty."
            }
        }
    }

    static func instructionBytes(_ s: String) -> Int { s.utf8.count }

    static func checkInstructions(_ s: String) throws {
        guard s.utf8.count <= WorkspaceLimits.instructionBytes else { throw Problem.instructionsTooLong }
    }

    /// Returns the name to send. The extension is checked, the name is never rewritten.
    static func checkFile(name: String, data: Data, existingCount: Int) throws {
        guard !name.isEmpty, name.utf8.count <= 128, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw Problem.badName }
        let ext = (name as NSString).pathExtension.lowercased()
        guard WorkspaceLimits.supportedExtensions.contains(ext) else { throw Problem.unsupportedType }
        guard existingCount < WorkspaceLimits.maxFiles else { throw Problem.tooManyFiles }
        guard !data.isEmpty else { throw Problem.empty }
        guard data.count <= WorkspaceLimits.fileBytes else { throw Problem.fileTooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw Problem.notUTF8 }
    }

    /// Reads at most `limit` bytes (+1 to detect overflow) from a file the user picked. The caller
    /// opens the security scope. Never loads an unbounded file into memory.
    static func boundedRead(_ url: URL, limit: Int = WorkspaceLimits.fileBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Problem.fileTooLarge }
        return data
    }

    /// Body for POST .../files. Standard base64.
    static func fileBody(name: String, data: Data) -> [String: Any] {
        ["name": name, "data": data.base64EncodedString()]
    }
}

// MARK: bots, per-send project context

enum WorkspaceBots {
    /// Bots a chat may start with: listed by the project's own `profiles`, and present and reachable in
    /// the bot list, matched on the exact ID. Never auto-selected.
    static func selectable(profiles: [String], bots: [Bot]) -> [Bot] {
        let allowed = Set(profiles)
        return bots.filter { allowed.contains($0.id) && $0.reachable }
    }
}

enum ProjectContext {
    /// Adds `project_context` to a send body only for a valid project ID. Used by new sends only;
    /// queue / steer follow-ups have no such parameter.
    static func apply(to body: inout [String: Any], projectID: String?) {
        guard let projectID, !projectID.isEmpty, projectID.utf8.count <= 128,
              !projectID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
        body["project_context"] = projectID
    }

    /// The project to attach for this send: only from a project scope and only when the person switched it on.
    static func chosen(scope: String?, optedIn: Bool) -> String? { optedIn ? scope : nil }

    static let disclosure = "Saved project instructions and UTF-8 reference files are sent to this bot with this message, and may remain in the chat and provider history."

    /// Text for the accepted-context summary from `run.started`; nil if the event carries none.
    static func summary(from raw: [String: Any]) -> String? {
        guard let value = raw["project_context"] else { return nil }
        if let b = value as? Bool { return b ? "Project context accepted" : nil }
        guard let d = value as? [String: Any] else { return nil }
        var parts: [String] = []
        if let i = d["instructions"] as? Bool, i { parts.append("instructions") }
        if let n = d["instructions_bytes"] as? Int, n > 0, parts.isEmpty { parts.append("instructions") }
        if let n = d["files"] as? Int, n > 0 { parts.append("\(n) file\(n == 1 ? "" : "s")") }
        if let a = d["files"] as? [Any], !a.isEmpty { parts.append("\(a.count) file\(a.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Project context accepted" : "Project context accepted: " + parts.joined(separator: " + ")
    }
}

// MARK: artifacts

enum ArtifactPreview: Equatable {
    case text(String)
    case exportOnly

    private static let textTypes: Set<String> = ["text/plain", "text/markdown", "text/csv", "application/json"]

    /// Literal text only, decided by the server's content type; never path- or name-derived, never
    /// rendered as markup. Anything else is exported, not displayed.
    static func make(data: Data, mime: String?) -> ArtifactPreview {
        let base = (mime ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard textTypes.contains(base), data.count <= WorkspaceLimits.previewBytes,
              let s = String(data: data, encoding: .utf8) else { return .exportOnly }
        return .text(s)
    }

    /// File name from a Content-Disposition header, reduced to a safe single component.
    static func filename(disposition: String?, fallback: String) -> String {
        func clean(_ raw: String) -> String? {
            let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            let scalars = last.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            var s = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
            while s.hasPrefix(".") { s.removeFirst() }
            if s.utf8.count > 120 { s = String(s.prefix(120)) }
            return s.isEmpty ? nil : s
        }
        if let h = disposition {
            for part in h.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let lower = part.lowercased()
                if lower.hasPrefix("filename*="), let q = part.range(of: "''") {
                    let v = String(part[q.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let d = v.removingPercentEncoding, let c = clean(d) { return c }
                } else if lower.hasPrefix("filename=") {
                    let v = String(part.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let c = clean(v) { return c }
                }
            }
        }
        return clean(fallback) ?? "artifact"
    }
}

struct WorkspaceDownload {
    let data: Data
    let filename: String
    let mime: String?
}

// MARK: project model

struct WorkspaceClient {
    var detail: () async throws -> WorkspaceDetail
    var saveInstructions: (String) async throws -> Void
    var addFile: (String, Data) async throws -> WorkspaceFile
    var deleteFile: (String) async throws -> Void
    var createChat: (String, String?) async throws -> WorkspaceChat
}

@MainActor @Observable
final class WorkspaceProjectModel {
    enum Phase: Equatable { case idle, loading, loaded, failed(WorkspacesFailure) }

    private(set) var phase: Phase = .idle
    private(set) var detail = WorkspaceDetail()
    var instructionsDraft = ""
    /// Chosen by the person. Never filled in automatically.
    var selectedBot: String?
    var notice: String?
    private(set) var busy = false
    @ObservationIgnored private let client: WorkspaceClient
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var savedInstructions = ""

    init(client: WorkspaceClient) { self.client = client }

    var instructionBytes: Int { instructionsDraft.utf8.count }
    var instructionsOverLimit: Bool { instructionBytes > WorkspaceLimits.instructionBytes }
    var canSaveInstructions: Bool { !busy && !instructionsOverLimit && instructionsDraft != savedInstructions }
    var canAddFile: Bool { !busy && detail.files.count < WorkspaceLimits.maxFiles }

    func selectableBots(_ bots: [Bot]) -> [Bot] { WorkspaceBots.selectable(profiles: detail.profiles, bots: bots) }

    func load() async {
        generation += 1
        let mine = generation
        if phase != .loaded { phase = .loading }
        do {
            let d = try await client.detail()
            guard mine == generation, !Task.isCancelled else { return restore() }
            detail = d
            if instructionsDraft == savedInstructions { instructionsDraft = d.instructions }
            savedInstructions = d.instructions
            if let s = selectedBot, !d.profiles.contains(s) { selectedBot = nil }
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return restore() }
            phase = .failed(error as? WorkspacesFailure ?? .network)
        }
    }

    private func restore() { if phase == .loading { phase = .idle } }

    func saveInstructions() async {
        do { try WorkspaceValidation.checkInstructions(instructionsDraft) }
        catch { notice = (error as? WorkspaceValidation.Problem)?.message; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        let text = instructionsDraft
        do {
            try await client.saveInstructions(text)
            savedInstructions = text
            detail.instructions = text
            notice = "Instructions saved."
        } catch { notice = (error as? WorkspacesFailure ?? .network).message }
    }

    func addFile(name: String, data: Data) async {
        do { try WorkspaceValidation.checkFile(name: name, data: data, existingCount: detail.files.count) }
        catch { notice = (error as? WorkspaceValidation.Problem)?.message; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let f = try await client.addFile(name, data)
            detail.files.removeAll { $0.id == f.id }
            detail.files.append(f)
            notice = "Added \(f.name)."
        } catch { notice = (error as? WorkspacesFailure ?? .network).message }
    }

    func deleteFile(_ file: WorkspaceFile) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await client.deleteFile(file.id)
            detail.files.removeAll { $0.id == file.id }
        } catch { notice = (error as? WorkspacesFailure ?? .network).message }
    }

    /// Starts a real session on the server with the explicitly chosen bot. Nothing happens without a choice.
    func startChat(bots: [Bot], title: String? = nil) async -> WorkspaceChat? {
        guard let bot = selectedBot, selectableBots(bots).contains(where: { $0.id == bot }) else {
            notice = "Choose a bot first."
            return nil
        }
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        let t = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        do {
            let chat = try await client.createChat(bot, t)
            guard chat.profile == bot else { notice = WorkspacesFailure.malformed.message; return nil }
            detail.chats.removeAll { $0.id == chat.id }
            detail.chats.insert(chat, at: 0)
            return chat
        } catch {
            notice = (error as? WorkspacesFailure ?? .network).message
            return nil
        }
    }
}

/// Which projects have Workspaces enabled. A failure here never touches the catalog.
@MainActor @Observable
final class WorkspaceIndexModel {
    private(set) var index: WorkspaceIndex?
    private(set) var failure: WorkspacesFailure?
    @ObservationIgnored private let fetch: () async throws -> WorkspaceIndex
    init(fetch: @escaping () async throws -> WorkspaceIndex) { self.fetch = fetch }

    func load() async {
        do {
            let i = try await fetch()
            guard !Task.isCancelled else { return }
            index = i; failure = nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            index = nil
            failure = error as? WorkspacesFailure ?? .network
        }
    }
    func isEnabled(_ project: String) -> Bool { index?.isEnabled(project: project) ?? false }
    func reset() { index = nil; failure = nil }
}

/// Navigation values for the workspace screens (kept here so views and tests share one definition).
struct WorkspaceScope: Hashable {
    let projectID: String
    let title: String
}
