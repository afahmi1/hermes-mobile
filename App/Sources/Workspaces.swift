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
    /// 409 stale: someone else (or the Mac) changed it first.
    case conflict
    /// 409 duplicate: another file of the project already has this exact content.
    case duplicate
    /// 403 codes (build 5). The app shows fixed text for each, never the server's.
    case notEligible, ownerRequired, operatorManaged

    static func fromHTTP(_ status: Int) -> WorkspacesFailure {
        fromResponse(status: status, code: nil)
    }

    /// `code` is the bridge's machine code from the JSON error body, when there was one.
    static func fromResponse(status: Int, code: String?) -> WorkspacesFailure {
        switch (status, code) {
        case (403, "not_eligible"): return .notEligible
        case (403, "owner_required"): return .ownerRequired
        case (403, "operator_managed"): return .operatorManaged
        case (409, "duplicate"): return .duplicate
        case (409, _): return .conflict
        default: break
        }
        switch status {
        case 404: return .disabled
        case 401: return .signedOut
        case 400, 413, 415, 422, 507: return .rejected
        default: return .unavailable
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
        case .conflict: "This changed on another device or on the Mac since you opened it."
        case .duplicate: "Another file in this project already has exactly that content."
        case .notEligible: "One of those bots isn't eligible for this project. Eligible bots are set on the Mac."
        case .ownerRequired: "Only the owner sign-in can change this. Sign in as the owner on this server."
        case .operatorManaged: "Bot access for this project is set on the Mac."
        }
    }
}

// MARK: wire types

struct WorkspaceIndexEntry: Decodable, Equatable {
    let id: String
    let assigned: [String]
    let eligible: [String]
    private enum CodingKeys: String, CodingKey { case id, assigned, eligible }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        assigned = (try? c.decodeIfPresent([String].self, forKey: .assigned)) ?? []
        eligible = (try? c.decodeIfPresent([String].self, forKey: .eligible)) ?? []
    }
    init(id: String, assigned: [String] = [], eligible: [String] = []) {
        self.id = id; self.assigned = assigned; self.eligible = eligible
    }
}

struct WorkspaceIndex: Equatable {
    let projects: [String]
    let profiles: [String]
    /// "owner" | "operator"; nil on a build-4 bridge (read-only assignment).
    let mode: String?
    let workspaces: [WorkspaceIndexEntry]

    private struct Wire: Decodable {
        let projects: [String]
        let profiles: [String]
        let mode: String?
        let workspaces: [WorkspaceIndexEntry]
        private enum CodingKeys: String, CodingKey { case projects, profiles, mode, workspaces }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projects = try c.decode([String].self, forKey: .projects)
            profiles = (try? c.decodeIfPresent([String].self, forKey: .profiles)) ?? []
            mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
            workspaces = (try? c.decodeIfPresent([WorkspaceIndexEntry].self, forKey: .workspaces)) ?? []
        }
    }
    static func decode(_ data: Data) throws -> WorkspaceIndex {
        guard data.count <= 256 * 1024, let w = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw WorkspacesFailure.malformed
        }
        return WorkspaceIndex(projects: w.projects, profiles: w.profiles, mode: w.mode, workspaces: w.workspaces)
    }
    init(projects: [String], profiles: [String], mode: String? = nil, workspaces: [WorkspaceIndexEntry] = []) {
        self.projects = projects; self.profiles = profiles; self.mode = mode; self.workspaces = workspaces
    }
    /// Visibility depends only on the project being listed, never on how many bots it has.
    func isEnabled(project id: String) -> Bool { projects.contains(id) }
    var isOwnerManaged: Bool { mode == "owner" }
}

struct WorkspaceFile: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let size: Int
    /// Build 5: content hash and whether the bridge will serve/accept content. Absent on build 4.
    var sha: String? = nil
    var editable: Bool? = nil
}

/// GET /m/workspaces/<p>/files/<id>
struct WorkspaceFileContent: Decodable, Equatable {
    let id: String
    let name: String
    let size: Int
    let sha: String
    let content: String
}

/// PUT file result.
struct WorkspaceFileMeta: Decodable, Equatable {
    let id: String
    let name: String
    let size: Int
    let sha: String
}

struct WorkspaceAssignment: Decodable, Equatable {
    var editable: Bool
    var revision: Int
    var assigned: [String]
    var inactive: [String]
    var eligible: [String]

    private enum CodingKeys: String, CodingKey { case editable, revision, assigned, inactive, eligible }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editable = (try? c.decodeIfPresent(Bool.self, forKey: .editable)) ?? false
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
        assigned = (try? c.decodeIfPresent([String].self, forKey: .assigned)) ?? []
        inactive = (try? c.decodeIfPresent([String].self, forKey: .inactive)) ?? []
        eligible = (try? c.decodeIfPresent([String].self, forKey: .eligible)) ?? []
    }
    init(editable: Bool = false, revision: Int = 0, assigned: [String] = [], inactive: [String] = [], eligible: [String] = []) {
        self.editable = editable; self.revision = revision; self.assigned = assigned
        self.inactive = inactive; self.eligible = eligible
    }

    static func decodeEnvelope(_ data: Data) throws -> WorkspaceAssignment {
        struct R: Decodable { let assignment: WorkspaceAssignment }
        guard data.count <= 64 * 1024, let r = try? JSONDecoder().decode(R.self, from: data) else {
            throw WorkspacesFailure.malformed
        }
        return r.assignment
    }
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
    /// Build 5. nil / 0 on a build-4 payload.
    var mode: String? = nil
    var instructionsRevision: String? = nil
    var assignment: WorkspaceAssignment? = nil
    var hiddenChats: Int = 0

    private enum CodingKeys: String, CodingKey {
        case instructions, files, chats, artifacts, profiles, mode, assignment
        case instructionsRevision = "instructions_revision", hiddenChats = "hidden_chats"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        files = try c.decodeIfPresent([WorkspaceFile].self, forKey: .files) ?? []
        chats = try c.decodeIfPresent([WorkspaceChat].self, forKey: .chats) ?? []
        artifacts = try c.decodeIfPresent([WorkspaceArtifact].self, forKey: .artifacts) ?? []
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        instructionsRevision = (try? c.decodeIfPresent(String.self, forKey: .instructionsRevision)) ?? nil
        assignment = (try? c.decodeIfPresent(WorkspaceAssignment.self, forKey: .assignment)) ?? nil
        hiddenChats = max(0, (try? c.decodeIfPresent(Int.self, forKey: .hiddenChats)) ?? 0)
    }
    init(instructions: String = "", files: [WorkspaceFile] = [], chats: [WorkspaceChat] = [],
         artifacts: [WorkspaceArtifact] = [], profiles: [String] = [], mode: String? = nil,
         instructionsRevision: String? = nil, assignment: WorkspaceAssignment? = nil, hiddenChats: Int = 0) {
        self.instructions = instructions; self.files = files; self.chats = chats
        self.artifacts = artifacts; self.profiles = profiles; self.mode = mode
        self.instructionsRevision = instructionsRevision; self.assignment = assignment; self.hiddenChats = hiddenChats
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
    /// (text, expected revision or nil on a build-4 bridge) -> new revision
    var saveInstructions: (String, String?) async throws -> String?
    var addFile: (String, Data) async throws -> WorkspaceFile
    var deleteFile: (String) async throws -> Void
    var createChat: (String, String?) async throws -> WorkspaceChat
    // Build 5
    var saveAssignment: ([String], Int) async throws -> WorkspaceAssignment = { _, _ in throw WorkspacesFailure.disabled }
    var fileContent: (String) async throws -> WorkspaceFileContent = { _ in throw WorkspacesFailure.disabled }
    /// (file id, content, expected sha)
    var saveFile: (String, String, String) async throws -> WorkspaceFileMeta = { _, _, _ in throw WorkspacesFailure.disabled }
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
    private(set) var instructionsEditing = false
    /// True after a 409: the draft is kept, nothing was overwritten.
    private(set) var instructionsConflict = false
    @ObservationIgnored private let client: WorkspaceClient
    @ObservationIgnored private var instructionsRevision: String?
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
            if !instructionsConflict { instructionsRevision = d.instructionsRevision }
            if let s = selectedBot, !d.profiles.contains(s) { selectedBot = nil }
            phase = .loaded
        } catch {
            guard mine == generation else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return restore() }
            phase = .failed(error as? WorkspacesFailure ?? .network)
        }
    }

    private func restore() { if phase == .loading { phase = .idle } }

    func beginEditInstructions() { instructionsEditing = true }

    func cancelEditInstructions() {
        instructionsDraft = savedInstructions
        instructionsEditing = false
        instructionsConflict = false
    }

    func saveInstructions() async {
        do { try WorkspaceValidation.checkInstructions(instructionsDraft) }
        catch { notice = (error as? WorkspaceValidation.Problem)?.message; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        let text = instructionsDraft
        do {
            let rev = try await client.saveInstructions(text, instructionsRevision)
            savedInstructions = text
            instructionsRevision = rev ?? instructionsRevision
            detail.instructions = text
            detail.instructionsRevision = instructionsRevision
            instructionsEditing = false
            instructionsConflict = false
            notice = "Instructions saved."
        } catch WorkspacesFailure.conflict {
            instructionsConflict = true   // keep the draft; the person decides
        } catch { notice = (error as? WorkspacesFailure ?? .network).message }
    }

    /// Replaces the draft with the Mac's current instructions. Only ever called by an explicit tap.
    func reloadLatestInstructions() async {
        do {
            let d = try await client.detail()
            detail = d
            savedInstructions = d.instructions
            instructionsRevision = d.instructionsRevision
            instructionsDraft = d.instructions
            instructionsConflict = false
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

// MARK: bot assignment

@MainActor @Observable
final class WorkspaceAssignmentModel {
    enum Phase: Equatable { case idle, loading, loaded, failed(WorkspacesFailure) }

    private(set) var phase: Phase = .idle
    private(set) var assignment: WorkspaceAssignment?
    private(set) var mode: String?
    private(set) var hiddenChats = 0
    private(set) var busy = false
    private(set) var saved = false
    var selection: Set<String> = []
    /// Fixed text only.
    var message: String?
    @ObservationIgnored private let client: WorkspaceClient

    init(client: WorkspaceClient) { self.client = client }

    /// Owner mode and the bridge says it's editable. Everything else is read-only.
    var isEditable: Bool { mode == "owner" && assignment?.editable == true }
    var eligible: [String] { assignment?.eligible ?? [] }
    var inactive: [String] { assignment?.inactive ?? [] }
    var canSave: Bool {
        guard isEditable, !busy, let a = assignment else { return false }
        return selection != Set(a.assigned)
    }
    var hiddenChatsNote: String? {
        hiddenChats > 0 ? "\(hiddenChats) chat\(hiddenChats == 1 ? "" : "s") from unassigned bots are kept and come back if you reassign the bot." : nil
    }

    func summary(name: (String) -> String) -> String {
        guard phase == .loaded, let a = assignment else {
            if case .failed = phase { return "Unavailable" }
            return "Loading…"
        }
        return a.assigned.isEmpty ? "No bots assigned" : a.assigned.map(name).joined(separator: ", ")
    }

    func load() async {
        if phase != .loaded { phase = .loading }
        do {
            let d = try await client.detail()
            guard !Task.isCancelled else { if phase == .loading { phase = .idle }; return }
            apply(d)
            phase = .loaded
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if phase == .loading { phase = .idle }
                return
            }
            phase = .failed(error as? WorkspacesFailure ?? .network)
        }
    }

    private func apply(_ d: WorkspaceDetail) {
        // A build-4 bridge has no assignment block: show its read-only `profiles` as the assigned list.
        assignment = d.assignment ?? WorkspaceAssignment(editable: false, assigned: d.profiles)
        mode = d.mode
        hiddenChats = d.hiddenChats
        selection = Set(assignment?.assigned ?? [])
    }

    func toggle(_ id: String) {
        guard isEditable else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        message = nil; saved = false
    }

    /// Cancel: forget unsaved choices.
    func discard() {
        selection = Set(assignment?.assigned ?? [])
        message = nil
    }

    func save() async {
        guard canSave, let a = assignment else { return }
        busy = true; defer { busy = false }
        message = nil
        // Stored-but-inactive bots are kept (keeping is not granting) so they return with the bot.
        let ids = Array(selection.union(a.inactive)).sorted()
        do {
            let r = try await client.saveAssignment(ids, a.revision)
            assignment = r
            selection = Set(r.assigned)
            saved = true
            message = "Saved."
        } catch WorkspacesFailure.conflict {
            await load()
            message = "Bot access changed on another device or the Mac. Reloaded the latest list; review it and save again."
        } catch {
            message = (error as? WorkspacesFailure ?? .network).message
        }
    }
}

// MARK: file editor

@MainActor @Observable
final class WorkspaceFileEditorModel {
    enum Mode: Equatable { case existing(WorkspaceFile), new }
    enum Phase: Equatable { case idle, loading, loaded, failed(WorkspacesFailure) }
    enum Conflict: Equatable { case stale, duplicate }

    let mode: Mode
    private(set) var phase: Phase
    var name: String
    var draft: String
    private(set) var isEditing: Bool
    private(set) var conflict: Conflict?
    private(set) var busy = false
    private(set) var created: WorkspaceFile?
    private(set) var saveCount = 0
    var notice: String?
    @ObservationIgnored private let client: WorkspaceClient
    @ObservationIgnored private let existingCount: Int
    @ObservationIgnored private var original = ""
    @ObservationIgnored private var sha: String?

    init(client: WorkspaceClient, mode: Mode, existingCount: Int = 0, name: String = "") {
        self.client = client; self.mode = mode; self.existingCount = existingCount
        switch mode {
        case .existing(let f): self.name = f.name; phase = .idle; isEditing = false; draft = ""
        case .new: self.name = name; phase = .loaded; isEditing = true; draft = ""
        }
    }

    var bytes: Int { draft.utf8.count }
    var overLimit: Bool { bytes > WorkspaceLimits.fileBytes }
    var isNew: Bool { mode == .new }

    /// Why the draft can't be saved (nil if fine or merely empty).
    var problem: String? {
        if draft.contains("\0") { return "Text files can't contain null characters." }
        if overLimit { return WorkspaceValidation.Problem.fileTooLarge.message }
        if isNew, !name.isEmpty {
            do { try WorkspaceValidation.checkFile(name: name, data: Data(" ".utf8), existingCount: existingCount) }
            catch { return (error as? WorkspaceValidation.Problem)?.message }
        }
        if (name as NSString).pathExtension.lowercased() == "json", !draft.isEmpty,
           (try? JSONSerialization.jsonObject(with: Data(draft.utf8), options: [.fragmentsAllowed])) == nil {
            return "That isn't valid JSON."
        }
        return nil
    }

    var canSave: Bool {
        guard !busy, isEditing, !draft.isEmpty, problem == nil else { return false }
        if isNew { return !name.isEmpty }
        return phase == .loaded && draft != original && sha != nil
    }

    func load() async {
        guard case .existing(let f) = mode else { return }
        phase = .loading
        do {
            let c = try await client.fileContent(f.id)
            original = c.content; draft = c.content; sha = c.sha
            phase = .loaded
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { phase = .idle; return }
            phase = .failed(error as? WorkspacesFailure ?? .network)
        }
    }

    func beginEdit() { if phase == .loaded { isEditing = true } }

    /// Cancel discards the draft (back to what the Mac last sent).
    func cancel() {
        draft = original; isEditing = isNew; conflict = nil; notice = nil
    }

    /// Returns true when the Mac accepted the change.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        busy = true; defer { busy = false }
        let text = draft
        do {
            switch mode {
            case .new:
                created = try await client.addFile(name, Data(text.utf8))
            case .existing(let f):
                guard let sha else { return false }
                let m = try await client.saveFile(f.id, text, sha)
                original = text; self.sha = m.sha
                isEditing = false
            }
            conflict = nil; saveCount += 1
            return true
        } catch WorkspacesFailure.conflict { conflict = .stale }
        catch WorkspacesFailure.duplicate { conflict = .duplicate }
        catch { notice = (error as? WorkspacesFailure ?? .network).message }
        return false
    }

    /// Explicit tap only: replaces the draft with what's on the Mac now.
    func reloadLatest() async {
        guard case .existing(let f) = mode else { return }
        do {
            let c = try await client.fileContent(f.id)
            original = c.content; draft = c.content; sha = c.sha
            conflict = nil
        } catch { notice = (error as? WorkspacesFailure ?? .network).message }
    }

    func delete() async -> Bool {
        guard case .existing(let f) = mode, !busy else { return false }
        busy = true; defer { busy = false }
        do { try await client.deleteFile(f.id); return true }
        catch { notice = (error as? WorkspacesFailure ?? .network).message; return false }
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
