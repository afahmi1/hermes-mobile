import Foundation
import Observation

// Owner management of projects and bots (build 5, slice B). Pure logic + models with injected closures;
// the network calls live in ManagementAPI.swift. The deletion PIN exists only inside ArchiveModel.pin while
// the sheet is open: it is cleared right after each request and on dismiss, never logged, never
// persisted, never put in a URL, and sent only as the JSON body {"pin": ...}.

extension Notification.Name {
    /// Posted after a project/bot was created, edited, archived or restored, so lists reload.
    static let manageChanged = Notification.Name("hermes.manage.changed")
}

// MARK: - Validation

enum ManageLimits {
    static let titleMax = 80
    static let summaryMax = 500
    static let botNameMax = 60
    static let personaBytes = 4096
    static let idMax = 48
    static let pinLength = 4
}

enum ManageSlug {
    /// What the bridge would be asked to use as an id: lowercase ASCII letters/digits separated by single dashes.
    static func preview(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var pendingDash = false
        for u in folded.unicodeScalars {
            if (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(u)
            } else {
                pendingDash = true
            }
        }
        if out.count > ManageLimits.idMax { out = String(out.prefix(ManageLimits.idMax)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= ManageLimits.idMax, !id.hasPrefix("-"), !id.hasSuffix("-"),
              !id.contains("--") else { return false }
        return id.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-" }
    }
}

enum ManageField: Hashable { case title, summary, id, name, persona, host }

struct ManageIssue: Equatable { let field: ManageField; let message: String }

enum ManageValidation {
    static func project(title: String, summary: String, id: String) -> [ManageIssue] {
        var issues: [ManageIssue] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { issues.append(.init(field: .title, message: "Add a title.")) }
        else if t.count > ManageLimits.titleMax { issues.append(.init(field: .title, message: "Keep the title under \(ManageLimits.titleMax + 1) characters.")) }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).count > ManageLimits.summaryMax {
            issues.append(.init(field: .summary, message: "Keep the summary under \(ManageLimits.summaryMax + 1) characters."))
        }
        let rawID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawID.isEmpty, !ManageSlug.isValid(rawID) {
            issues.append(.init(field: .id, message: "Use lowercase letters, digits and single dashes (up to \(ManageLimits.idMax))."))
        } else if rawID.isEmpty, !t.isEmpty, ManageSlug.preview(t).isEmpty {
            issues.append(.init(field: .id, message: "Add an ID with letters or digits."))
        }
        return issues
    }

    static func personaBytes(_ text: String) -> Int { text.utf8.count }

    static func bot(name: String, persona: String, host: String?) -> [ManageIssue] {
        var issues: [ManageIssue] = []
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { issues.append(.init(field: .name, message: "Add a name.")) }
        else if n.count > ManageLimits.botNameMax { issues.append(.init(field: .name, message: "Keep the name under \(ManageLimits.botNameMax + 1) characters.")) }
        let p = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { issues.append(.init(field: .persona, message: "Describe how this bot should behave.")) }
        else if personaBytes(persona) > ManageLimits.personaBytes {
            issues.append(.init(field: .persona, message: "Too long: \(personaBytes(persona)) of \(ManageLimits.personaBytes) bytes."))
        } else if persona.unicodeScalars.contains("\u{0}") {
            issues.append(.init(field: .persona, message: "The persona can't contain a null character."))
        }
        if host == nil || host?.isEmpty == true { issues.append(.init(field: .host, message: "Choose a bot to run on.")) }
        return issues
    }
}

enum PINField {
    /// Digits only (ASCII), at most four. Everything else, including pasted text, is dropped.
    static func filter(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.prefix(ManageLimits.pinLength).map(Character.init))
    }
    static func isComplete(_ text: String) -> Bool { text.count == ManageLimits.pinLength && filter(text) == text }
}

/// Settings -> Deletion PIN. First set needs the new PIN twice; a change also needs the current PIN.
/// Fixed local text only; the PINs never leave the sheet except in one JSON body.
enum PINSetup {
    static func problem(new: String, confirm: String, current: String, configured: Bool) -> String? {
        if configured && !PINField.isComplete(current) { return "Enter your current 4-digit PIN." }
        if !PINField.isComplete(new) { return "Choose a 4-digit PIN." }
        if new != confirm { return "The two new PINs don't match." }
        return nil
    }
    static func body(new: String, confirm: String, current: String, configured: Bool) -> [String: String] {
        var b = ["pin": new, "confirm": confirm]
        if configured { b["current"] = current }
        return b
    }
}

// MARK: - Failures

/// Fixed local text per code/status. Server `error` text is never shown.
enum ManageFailure: Error, Equatable {
    case pinWrong, pinLocked(minutes: Int), pinUnset, ownerRequired, readOnly
    case duplicate, invalid, notFound, notManageable, signedOut, network, server, malformed

    static func from(status: Int, data: Data) -> ManageFailure {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["code"] as? String ?? ""
        let retry = (obj?["retry_after"] as? Int) ?? (obj?["retry_after"] as? Double).map(Int.init) ?? 0
        return from(status: status, code: code, retryAfter: retry)
    }

    static func from(status: Int, code: String, retryAfter: Int = 0) -> ManageFailure {
        switch code {
        case "pin_wrong": return .pinWrong
        case "pin_locked": return .pinLocked(minutes: max(1, (max(retryAfter, 0) + 59) / 60))
        case "pin_unset": return .pinUnset
        case "owner_required": return .ownerRequired
        case "read_only": return .readOnly
        case "duplicate", "id_taken", "exists", "conflict": return .duplicate
        case "not_manageable", "protected": return .notManageable
        default: break
        }
        switch status {
        case 401: return .signedOut
        case 404: return .notFound
        case 409: return .duplicate
        case 400, 413, 422: return .invalid
        case 429: return .pinLocked(minutes: max(1, (max(retryAfter, 0) + 59) / 60))
        case 503: return .pinUnset
        case 500...599: return .server
        default: return .server
        }
    }

    static func classify(_ error: Error) -> ManageFailure {
        switch error {
        case let f as ManageFailure: return f
        case is DecodingError: return .malformed
        default: return .network
        }
    }

    var message: String {
        switch self {
        case .pinWrong: "That PIN isn't right."
        case .pinLocked(let m): "Too many tries. Try again in \(m) minute\(m == 1 ? "" : "s")."
        case .pinUnset: "Set a deletion PIN on the Mac first."
        case .ownerRequired: "Sign in again on this phone to manage projects and bots."
        case .readOnly: "This project comes from the Mac's catalog and can't be edited here."
        case .duplicate: "That ID or name is already in use. Pick a different one."
        case .invalid: "The Mac didn't accept those details. Check them and try again."
        case .notFound: "That item no longer exists. Pull to refresh."
        case .notManageable: "This bot is managed on the Mac."
        case .signedOut: "Your session ended. Sign in to Hermes again."
        case .network: "Can't reach your Mac. Check Tailscale and try again."
        case .server: "The Mac couldn't do that right now. Try again in a moment."
        case .malformed: "The Mac sent something this app couldn't read."
        }
    }
}

// MARK: - Wire models

private func firstString(_ c: KeyedDecodingContainer<ManageDynamicKey>, _ keys: [String]) -> String? {
    for k in keys { if let v = try? c.decodeIfPresent(String.self, forKey: ManageDynamicKey(k)), !v.isEmpty { return v } }
    return nil
}

struct ManageDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// An app-made bot: a persona that runs on an existing host bot.
struct ManagedPersona: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let persona: String
    let host: String

    init(id: String, name: String, persona: String = "", host: String = "") {
        self.id = id; self.name = name; self.persona = persona; self.host = host
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ManageDynamicKey.self)
        guard let id = firstString(c, ["id"]) else { throw DecodingError.dataCorruptedError(forKey: ManageDynamicKey("id"), in: c, debugDescription: "id") }
        self.id = id
        name = firstString(c, ["name", "title"]) ?? id
        persona = firstString(c, ["persona"]) ?? ""
        host = firstString(c, ["host"]) ?? ""
    }
}

struct ManageHost: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    init(id: String, name: String) { self.id = id; self.name = name }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { id = s; name = s; return }
        let c = try decoder.container(keyedBy: ManageDynamicKey.self)
        guard let id = firstString(c, ["id"]) else { throw DecodingError.dataCorruptedError(forKey: ManageDynamicKey("id"), in: c, debugDescription: "id") }
        self.id = id
        name = firstString(c, ["name", "title"]) ?? id
    }
}

/// GET /m/manage/bots
struct ManageBotsInfo: Equatable {
    let personas: [ManagedPersona]
    let hosts: [ManageHost]
    let manageable: [String]

    private struct Wire: Decodable {
        let personas: [ManagedPersona]?
        let hosts: [ManageHost]?
        let manageable: [String]?
    }
    static func decode(_ data: Data) throws -> ManageBotsInfo {
        guard data.count <= 256 * 1024, let w = try? JSONDecoder().decode(Wire.self, from: data) else { throw ManageFailure.malformed }
        return ManageBotsInfo(personas: w.personas ?? [], hosts: w.hosts ?? [], manageable: w.manageable ?? [])
    }
    /// The default bot is never archivable from the phone, whatever the bridge lists.
    func canArchive(_ botID: String) -> Bool { botID != "default" && manageable.contains(botID) }
}

extension ManagedPersona: Equatable {}
extension ManageHost: Equatable {}

struct ArchivedEntry: Decodable, Hashable, Identifiable {
    let id: String
    let title: String
    init(id: String, title: String) { self.id = id; self.title = title }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { id = s; title = s; return }
        let c = try decoder.container(keyedBy: ManageDynamicKey.self)
        guard let id = firstString(c, ["id"]) else { throw DecodingError.dataCorruptedError(forKey: ManageDynamicKey("id"), in: c, debugDescription: "id") }
        self.id = id
        title = firstString(c, ["title", "name"]) ?? id
    }
}

/// GET /m/manage/archived
struct ArchivedInfo: Equatable {
    let projects: [ArchivedEntry]
    let bots: [ArchivedEntry]
    var isEmpty: Bool { projects.isEmpty && bots.isEmpty }

    private struct Wire: Decodable { let projects: [ArchivedEntry]?; let bots: [ArchivedEntry]? }
    static func decode(_ data: Data) throws -> ArchivedInfo {
        guard data.count <= 256 * 1024, let w = try? JSONDecoder().decode(Wire.self, from: data) else { throw ManageFailure.malformed }
        return ArchivedInfo(projects: w.projects ?? [], bots: w.bots ?? [])
    }
}

/// Unwraps `{project: {...}}`, `{bot: {...}}`, `{persona: {...}}` or the bare object.
enum ManageEnvelope {
    static func unwrap(_ data: Data, keys: [String]) -> Data {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        for k in keys { if let inner = o[k] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: inner) { return d } }
        return data
    }
    static func project(_ data: Data) throws -> Project {
        guard let p = try? JSONDecoder().decode(Project.self, from: unwrap(data, keys: ["project"])) else { throw ManageFailure.malformed }
        return p
    }
    static func persona(_ data: Data) throws -> ManagedPersona {
        guard let p = try? JSONDecoder().decode(ManagedPersona.self, from: unwrap(data, keys: ["bot", "persona"])) else { throw ManageFailure.malformed }
        return p
    }
}

struct ProjectDraft: Equatable {
    var title: String
    var summary: String
    var id: String?
    /// JSON body: trimmed values; `id` only when the owner typed one (the bridge makes the slug otherwise).
    var body: [String: Any] {
        var b: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines)]
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { b["summary"] = s }
        if let id, !id.isEmpty { b["id"] = id }
        return b
    }
}

// MARK: - Models

@MainActor @Observable
final class AddProjectModel {
    var title = ""
    var summary = ""
    var idText = ""
    private(set) var isSaving = false
    private(set) var failure: ManageFailure?
    private(set) var created: Project?
    @ObservationIgnored private let create: (ProjectDraft) async throws -> Project

    init(create: @escaping (ProjectDraft) async throws -> Project) { self.create = create }

    /// The ID the bridge is asked to use: the typed one, else the slug of the title.
    var effectiveID: String {
        let typed = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? ManageSlug.preview(title) : typed
    }
    var issues: [ManageIssue] { ManageValidation.project(title: title, summary: summary, id: idText) }
    var canSave: Bool { issues.isEmpty && !isSaving }
    func issue(_ f: ManageField) -> String? { issues.first { $0.field == f }?.message }

    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        let typed = idText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            created = try await create(ProjectDraft(title: title, summary: summary, id: typed.isEmpty ? nil : typed))
            return true
        } catch {
            failure = ManageFailure.classify(error)
            return false
        }
    }
}

@MainActor @Observable
final class EditProjectModel {
    var title: String
    var summary: String
    private(set) var isSaving = false
    private(set) var failure: ManageFailure?
    @ObservationIgnored private let update: (String, String) async throws -> Void

    init(title: String, summary: String?, update: @escaping (String, String) async throws -> Void) {
        self.title = title
        self.summary = summary ?? ""
        self.update = update
    }
    var issues: [ManageIssue] { ManageValidation.project(title: title, summary: summary, id: "").filter { $0.field != .id } }
    var canSave: Bool { issues.isEmpty && !isSaving }
    func issue(_ f: ManageField) -> String? { issues.first { $0.field == f }?.message }

    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            try await update(title.trimmingCharacters(in: .whitespacesAndNewlines),
                             summary.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch {
            failure = ManageFailure.classify(error)
            return false
        }
    }
}

enum ManageBotsState: Equatable {
    case idle, loading
    case loaded(ManageBotsInfo)
    case failed(ManageFailure)
}

/// GET /m/manage/bots for the add-bot form, the persona list and the live-bot archive row.
@MainActor @Observable
final class ManageBotsModel {
    private(set) var state: ManageBotsState = .idle
    @ObservationIgnored private let fetch: () async throws -> ManageBotsInfo
    @ObservationIgnored private var generation = 0

    init(fetch: @escaping () async throws -> ManageBotsInfo) { self.fetch = fetch }

    var info: ManageBotsInfo? { if case .loaded(let i) = state { i } else { nil } }

    func load() async {
        generation += 1
        let mine = generation
        if info == nil { state = .loading }
        do {
            let i = try await fetch()
            guard mine == generation else { return }
            state = .loaded(i)
        } catch {
            guard mine == generation else { return }
            if Task.isCancelled || error is CancellationError { if info == nil { state = .idle }; return }
            state = .failed(ManageFailure.classify(error))
        }
    }

    /// Fail closed: only an explicit `manageable` listing enables an archive action.
    func canArchive(_ botID: String) -> Bool { info?.canArchive(botID) ?? false }
}

@MainActor @Observable
final class AddBotModel {
    var name = ""
    var persona = ""
    var hostID: String?
    private(set) var isSaving = false
    private(set) var failure: ManageFailure?
    private(set) var created: ManagedPersona?
    private(set) var hosts: [ManageHost] = []
    private(set) var hostsLoaded = false
    private(set) var hostsFailure: ManageFailure?
    @ObservationIgnored private let loadHosts: () async throws -> [ManageHost]
    @ObservationIgnored private let create: (_ name: String, _ persona: String, _ host: String) async throws -> ManagedPersona

    init(loadHosts: @escaping () async throws -> [ManageHost],
         create: @escaping (String, String, String) async throws -> ManagedPersona) {
        self.loadHosts = loadHosts
        self.create = create
    }

    var noHosts: Bool { hostsLoaded && hosts.isEmpty }
    var personaBytes: Int { ManageValidation.personaBytes(persona) }
    var issues: [ManageIssue] { ManageValidation.bot(name: name, persona: persona, host: hostID) }
    func issue(_ f: ManageField) -> String? { issues.first { $0.field == f }?.message }
    var canSave: Bool { hostsLoaded && !hosts.isEmpty && issues.isEmpty && !isSaving }

    func load() async {
        do {
            hosts = try await loadHosts()
            hostsFailure = nil
            hostsLoaded = true
            if hostID == nil || !hosts.contains(where: { $0.id == hostID }) { hostID = hosts.first?.id }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            hostsFailure = ManageFailure.classify(error)
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave, let host = hostID else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            created = try await create(name.trimmingCharacters(in: .whitespacesAndNewlines), persona, host)
            return true
        } catch {
            failure = ManageFailure.classify(error)
            return false
        }
    }
}

/// Archive confirmation. The PIN lives in `pin` only while the sheet is open.
@MainActor @Observable
final class ArchiveModel {
    private(set) var isWorking = false
    private(set) var failure: ManageFailure?
    private(set) var done = false
    private(set) var pin = ""
    @ObservationIgnored private let archive: (String) async throws -> Void

    init(archive: @escaping (String) async throws -> Void) { self.archive = archive }

    /// Bound to the secure field; digits only, max four.
    var pinInput: String {
        get { pin }
        set { pin = PINField.filter(newValue) }
    }
    var canSubmit: Bool { PINField.isComplete(pin) && !isWorking && !done }

    /// Sends the PIN (JSON body only) and clears it afterwards, success or failure.
    @discardableResult
    func submit() async -> Bool {
        guard canSubmit else { return false }
        let sent = pin
        isWorking = true
        failure = nil
        defer { pin = ""; isWorking = false }
        do {
            try await archive(sent)
            done = true
            return true
        } catch {
            failure = ManageFailure.classify(error)
            return false
        }
    }

    func clear() { pin = "" }
}

@MainActor @Observable
final class ArchivedModel {
    enum State: Equatable { case idle, loading, loaded(ArchivedInfo), failed(ManageFailure) }
    private(set) var state: State = .idle
    private(set) var restoring: Set<String> = []
    private(set) var restoreFailure: ManageFailure?
    @ObservationIgnored private let fetch: () async throws -> ArchivedInfo
    @ObservationIgnored private let restoreProject: (String) async throws -> Void
    @ObservationIgnored private let restoreBot: (String) async throws -> Void

    init(fetch: @escaping () async throws -> ArchivedInfo,
         restoreProject: @escaping (String) async throws -> Void,
         restoreBot: @escaping (String) async throws -> Void) {
        self.fetch = fetch
        self.restoreProject = restoreProject
        self.restoreBot = restoreBot
    }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        do { state = .loaded(try await fetch()) }
        catch {
            if Task.isCancelled || error is CancellationError { if case .loading = state { state = .idle }; return }
            state = .failed(ManageFailure.classify(error))
        }
    }

    /// Restoring needs no PIN. Returns true when the item is back.
    @discardableResult
    func restore(project: Bool, id: String) async -> Bool {
        let key = (project ? "p:" : "b:") + id
        guard !restoring.contains(key) else { return false }
        restoring.insert(key)
        restoreFailure = nil
        defer { restoring.remove(key) }
        do {
            if project { try await restoreProject(id) } else { try await restoreBot(id) }
            if case .loaded(let info) = state {
                state = .loaded(ArchivedInfo(projects: project ? info.projects.filter { $0.id != id } : info.projects,
                                             bots: project ? info.bots : info.bots.filter { $0.id != id }))
            }
            return true
        } catch {
            restoreFailure = ManageFailure.classify(error)
            return false
        }
    }
    func isRestoring(project: Bool, id: String) -> Bool { restoring.contains((project ? "p:" : "b:") + id) }
}
