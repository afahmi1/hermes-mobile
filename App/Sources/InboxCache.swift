#if canImport(UIKit)
import UIKit
#endif
import SQLite3
import CryptoKit
import Foundation

/// Protected first-page snapshots, isolated by server and login. Pagination and
/// live-run state stay in memory. iOS can evict the disk copy at any time.
struct InboxSnapshot: Codable {
    let sessions: [SessionSummary]
    let cursor: String?
    let savedAt: Date
}

struct TranscriptSnapshot: Codable {
    let messages: [StoredMessage]
    let savedAt: Date
    let hasOlder: Bool
}

struct ControlReceipt: Codable, Identifiable {
    let id: UUID
    let mode: String
    let text: String
    let at: Date
    /// Files that rode along with this follow-up. Absent in receipts saved by older builds.
    var files: Int? = nil

    var item: ChatItem {
        let base = mode == "queue" ? "Sends after this reply" : "Guided this reply"
        let attached = files.map { $0 == 1 ? " · 1 file" : " · \($0) files" } ?? ""
        return ChatItem(id: id.uuidString, kind: .control, text: text.isEmpty ? "Attachments" : text,
                        footer: base + ((files ?? 0) > 0 ? attached : ""), timestamp: at.timeIntervalSince1970)
    }
}

struct SendAttachment: Codable, Hashable {
    let mime: String
    let filename: String
    let base64: String
    var sourceFormat: String? = nil
    var byteCount: Int { base64.utf8.count / 4 * 3 - (base64.hasSuffix("==") ? 2 : base64.hasSuffix("=") ? 1 : 0) }
}

struct PendingSend: Codable {
    let id: UUID
    let text: String
    let choice: RuntimeChoice
    let project: String?
    let attachments: [SendAttachment]?
    var composerText: String?
    var composerPastes: [PastedText]?
    var returningToComposer: Bool?
}

/// A message written while Hermes was busy (Send next) or meant to steer the running reply. It is saved
/// to disk before any network call, so closing the app, a crash or a dead connection never loses it, and
/// it goes out with the same submission ID on every retry, so a lost acknowledgment never duplicates it.
///
/// Life of one: on this phone (`admission == nil`) → on the Mac, held in Hermes's own queue in state.db
/// (`admission` set; survives bridge and gateway restarts) → started, at which point it leaves this list
/// and appears in the transcript. `problem` means the bridge refused it and the person must decide.
struct Outgoing: Codable, Identifiable, Equatable {
    var id: UUID
    var mode: String                 // "queue" or "steer"
    var text: String
    var attachments: [SendAttachment]?
    var choice: RuntimeChoice?
    var created: Date
    var attempts: Int = 0
    var admission: String? = nil
    var files: Int = 0
    var note: String? = nil
    var problem: String? = nil
    /// An edit typed after the original may already have reached the Mac: applied once that's confirmed.
    var edit: String? = nil

    var onMac: Bool { admission != nil }
    var label: String { text.isEmpty ? "\(files) attachment\(files == 1 ? "" : "s")" : text }

    /// The one place that says what state a waiting message is in. Every screen and decision reads this,
    /// never the raw fields, so a new field can't create a state nobody handles.
    enum Phase: Equatable {
        case onPhone            // saved here, never tried
        case retrying           // tried, no answer yet: may or may not be on the Mac
        case needsYou(String)   // the bridge refused it; the person decides
        case onMac(String)      // in Hermes's queue under this admission
        case editPending(String) // an edit waits until the original's place is confirmed
    }

    var phase: Phase {
        if let problem { return .needsYou(problem) }
        if let edit, attempts > 0 || admission != nil { return .editPending(edit) }
        if let admission { return .onMac(admission) }
        return attempts > 0 ? .retrying : .onPhone
    }

    /// Transitions. Each returns the next value; nothing else mutates these fields.
    func attempted() -> Outgoing { var o = self; o.attempts += 1; return o }
    func accepted(admission: String, files: Int) -> Outgoing {
        var o = self; o.admission = admission; o.attachments = nil; o.files = files; o.problem = nil; return o
    }
    func refused(_ reason: String) -> Outgoing { var o = self; o.problem = reason.isEmpty ? "Hermes refused this message." : reason; return o }
    /// An edit: instant while it never left the phone, otherwise held until the Mac confirms where it is.
    func edited(_ text: String) -> Outgoing {
        var o = self
        switch phase {
        case .onPhone, .needsYou:
            o.text = text; o.problem = nil; o.edit = nil
        case .retrying, .onMac, .editPending:
            o.edit = text
        }
        return o
    }
    func editApplied(admission: String) -> Outgoing {
        var o = self; o.text = edit ?? text; o.edit = nil; o.admission = admission; return o
    }
    /// A steer whose reply ended becomes the next message, and says so.
    func demotedToQueue(note: String) -> Outgoing {
        var o = self
        if o.mode == "steer" { o.mode = "queue"; o.note = note }
        return o
    }
}

actor InboxDisk {
    static let shared = InboxDisk()
    #if os(macOS)
    // Standalone macOS model tests cannot request iOS Data Protection classes.
    private static let protectedWrite: Data.WritingOptions = .atomic
    #else
    private static let protectedWrite: Data.WritingOptions = [.atomic, .completeFileProtection]
    #endif

    private var forgotten = Set<String>()
    private var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HermesInbox")
    }
    private func account(_ key: String) -> String { String(key.prefix(64)) }
    func forget(_ account: String) {
        forgotten.insert(account)
        try? FileManager.default.removeItem(at: outbox.appendingPathComponent(account))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account))
    }

    private func location(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(account(key)).appendingPathComponent(digest)
    }

    func read(_ key: String) -> InboxSnapshot? {
        guard !forgotten.contains(account(key)), let data = try? Data(contentsOf: location(key)) else { return nil }
        return try? JSONDecoder().decode(InboxSnapshot.self, from: data)
    }

    // Outstanding submissions must survive OS cache eviction. They are device protected,
    // excluded from backups and removed once the final outcome has been received.
    private var outbox: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesOutbox")
    }

    private func pendingURL(_ key: String) -> URL {
        outbox.appendingPathComponent(account(key)).appendingPathComponent(location(key).lastPathComponent)
    }

    func pending(_ key: String) throws -> PendingSend? {
        guard !forgotten.contains(account(key)) else { throw APIError.notSignedIn }
        do { return try JSONDecoder().decode(PendingSend.self, from: Data(contentsOf: pendingURL(key))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func stage(_ send: PendingSend, key: String) throws {
        if let original = try pending(key), original.id != send.id {
            throw APIError.http(409, "This chat has a send awaiting confirmation. Open it again to reconnect.")
        }
        let url = pendingURL(key)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(send).write(to: url, options: Self.protectedWrite)
    }

    // Follow-ups have their own small file next to the first-send record. Files ride along only until the
    // Mac has them; after that the record is a few hundred bytes of text and IDs.
    private func outgoingURL(_ key: String) -> URL {
        pendingURL(key).appendingPathExtension("followups")
    }

    func outgoing(_ key: String) -> [Outgoing] {
        guard !forgotten.contains(account(key)), let data = try? Data(contentsOf: outgoingURL(key)) else { return [] }
        return (try? JSONDecoder().decode([Outgoing].self, from: data)) ?? []
    }

    func saveOutgoing(_ list: [Outgoing], key: String) throws {
        guard !forgotten.contains(account(key)) else { throw APIError.notSignedIn }
        let url = outgoingURL(key)
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        try JSONEncoder().encode(list).write(to: url, options: Self.protectedWrite)
    }

    func acknowledge(_ id: UUID, key: String) throws {
        if try pending(key)?.id == id { try FileManager.default.removeItem(at: pendingURL(key)) }
    }

    private func transcriptURL(_ key: String) -> URL {
        let url = location(key)
        return url.deletingLastPathComponent().appendingPathComponent("transcripts").appendingPathComponent(url.lastPathComponent)
    }

    func transcript(_ key: String) -> TranscriptSnapshot? {
        guard !forgotten.contains(account(key)) else { return nil }
        let url = transcriptURL(key)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TranscriptSnapshot.self, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return snapshot
    }

    func saveTranscript(_ messages: [StoredMessage], at date: Date, key: String, hasOlder: Bool) {
        guard !forgotten.contains(account(key)) else { return }
        let url = transcriptURL(key)
        let directory = url.deletingLastPathComponent()
        let fs = FileManager.default
        do {
            try fs.createDirectory(at: directory, withIntermediateDirectories: true)
            var rows = messages[...]
            while true {
                let snapshot = TranscriptSnapshot(messages: Array(rows), savedAt: date, hasOlder: hasOlder || rows.count < messages.count)
                let data = try JSONEncoder().encode(snapshot)
                if data.count <= 1024 * 1024 {
                    try data.write(to: url, options: Self.protectedWrite)
                    break
                }
                guard rows.count > 1 else {
                    try? fs.removeItem(at: url)
                    return
                }
                rows = rows.suffix(rows.count / 2)
            }
            let files = try fs.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            if files.count > 12 {
                let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(12) { try? fs.removeItem(at: old) }
            }
        } catch { /* The next online read can refill an evicted or locked cache. */ }
    }

    func receipts(_ key: String) -> [ControlReceipt] {
        guard !forgotten.contains(account(key)), let data = try? Data(contentsOf: location(key)) else { return [] }
        return (try? JSONDecoder().decode([ControlReceipt].self, from: data)) ?? []
    }

    func record(_ receipt: ControlReceipt, key: String) throws {
        guard !forgotten.contains(account(key)) else { return }
        let url = location(key)
        let rows = receipts(key).filter { $0.id != receipt.id } + [receipt]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(rows.suffix(80))).write(to: url, options: Self.protectedWrite)
    }

    func save(_ page: InboxSnapshot, key: String) {
        guard !forgotten.contains(account(key)) else { return }
        let url = location(key)
        do {
            if let previous = read(key), previous.savedAt > page.savedAt { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(page)
            try data.write(to: url, options: Self.protectedWrite)
        } catch { /* An evicted or locked cache is recoverable from the bridge. */ }
    }
}

// Drafts are user-authored data. Each committed edit replaces one protected row;
// typing never re-encodes or rewrites the files attached to the same draft.
@MainActor
final class ComposerDisk {
    static let shared = ComposerDisk()
    enum Part: String { case text, pastes, media }
    struct Snapshot {
        var id: UUID?
        var text = ""
        var pastes: [PastedText] = []
        var media: [SendAttachment] = []
    }
    private var databases: [String: OpaquePointer] = [:]
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HermesComposer")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func open(_ account: String, create: Bool) throws -> OpaquePointer? {
        #if os(iOS)
        guard UIApplication.shared.isProtectedDataAvailable else { throw CocoaError(.fileReadNoPermission) }
        #endif
        if let db = databases[account] { return db }
        var folder = root.appendingPathComponent(account)
        let file = folder.appendingPathComponent("drafts.sqlite")
        if !create && !FileManager.default.fileExists(atPath: file.path) { return nil }
        #if os(macOS)
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #else
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #endif
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else { sqlite3_close(handle); throw CocoaError(.fileWriteUnknown) }
        let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS returned_sends(scope TEXT PRIMARY KEY, submission TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS drafts(scope TEXT, part TEXT, id TEXT NOT NULL, value BLOB NOT NULL,
                PRIMARY KEY(scope, part)) WITHOUT ROWID;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        databases[account] = db
        return db
    }

    private func withStatement<T>(_ db: OpaquePointer, _ sql: String, _ strings: [String],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in strings.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        return try body(stmt)
    }

    func read(_ account: String, scope: String) throws -> Snapshot {
        var snapshot = Snapshot()
        guard let db = try open(account, create: false) else { return snapshot }
        return try withStatement(db, "SELECT part,id,value FROM drafts WHERE scope=?", [scope]) { stmt in
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let part = String(cString: sqlite3_column_text(stmt, 0))
                snapshot.id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1)))
                let data = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
                switch Part(rawValue: part) {
                case .text: snapshot.text = String(decoding: data, as: UTF8.self)
                case .pastes: snapshot.pastes = try JSONDecoder().decode([PastedText].self, from: data)
                case .media: snapshot.media = try JSONDecoder().decode([SendAttachment].self, from: data)
                case nil: break
                }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
            return snapshot
        }
    }

    func write(_ data: Data?, part: Part, account: String, scope: String, id: UUID) throws {
        guard let db = try open(account, create: data != nil) else { return }
        let sql = data == nil ? "DELETE FROM drafts WHERE scope=? AND part=?" :
            "INSERT OR REPLACE INTO drafts(scope,part,id,value) VALUES(?,?,?,?)"
        try withStatement(db, sql, [scope, part.rawValue] + (data == nil ? [] : [id.uuidString])) { stmt in
            if let data {
                let status = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
                guard status == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// The return receipt commits in the same transaction as the restored draft. If the phone
    /// quits before it removes the outbox record, replay preserves any newer composer edits.
    func restoreSend(_ send: PendingSend, account: String, scope: String, id: UUID) throws -> Snapshot {
        guard let db = try open(account, create: true),
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var snapshot = try read(account, scope: scope)
        let duplicate = try withStatement(db, "SELECT 1 FROM returned_sends WHERE scope=? AND submission=?",
                                          [scope, send.id.uuidString]) { stmt in
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw CocoaError(.fileReadUnknown)
            }
        }
        if !duplicate {
            let text = send.composerText ?? send.text
            let pastes = send.composerPastes ?? []
            if snapshot.text.isEmpty { snapshot.text = text }
            else if snapshot.text != text, !text.isEmpty { snapshot.pastes.insert(PastedText(id: send.id, text: text), at: 0) }
            let existingIDs = Set(snapshot.pastes.map(\.id))
            snapshot.pastes += pastes.filter { !existingIDs.contains($0.id) }
            if let files = send.attachments {
                snapshot.media = files + snapshot.media.filter { !files.contains($0) }
            }
            let draft = snapshot.id ?? id
            try write(snapshot.text.isEmpty ? nil : Data(snapshot.text.utf8), part: .text, account: account, scope: scope, id: draft)
            try write(snapshot.pastes.isEmpty ? nil : JSONEncoder().encode(snapshot.pastes), part: .pastes, account: account, scope: scope, id: draft)
            try write(snapshot.media.isEmpty ? nil : JSONEncoder().encode(snapshot.media), part: .media, account: account, scope: scope, id: draft)
            try withStatement(db, "INSERT OR REPLACE INTO returned_sends(scope,submission) VALUES(?,?)", [scope, send.id.uuidString]) {
                guard sqlite3_step($0) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return snapshot
    }

    /// Every scope ("bot|session/id") holding unsent text, pastes or files, for the inbox marker.
    func scopes(_ account: String) -> Set<String> {
        guard let db = try? open(account, create: false) else { return [] }
        let found = try? withStatement(db, "SELECT DISTINCT scope FROM drafts", []) { stmt -> Set<String> in
            var scopes = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW { scopes.insert(String(cString: sqlite3_column_text(stmt, 0))) }
            return scopes
        }
        return found ?? []
    }

    func move(_ account: String, from: String, to: String, id: UUID) throws {
        guard let db = try open(account, create: false) else { return }
        try withStatement(db, "UPDATE drafts SET scope=? WHERE scope=? AND id=?", [to, from, id.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    func forget(_ account: String) {
        if let db = databases.removeValue(forKey: account) { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account))
    }
}

// MARK: - Queued actions

/// A chat action taken while the Mac couldn't be reached: archive, pin, flags, pinned messages. Every one sets a
/// final state ("archived = true"), so sending it twice changes nothing, and they can be replayed safely in order.
struct QueuedAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case flags, pinMessage, unpinMessage }
    var id = UUID()
    let account: String
    let kind: Kind
    let profile: String
    var ids: [String] = []
    var fields: [String: Bool] = [:]
    var confirmPins = false
    var session: String? = nil
    var message: Int? = nil
    var created = Date()
    var attempts = 0
    var problem: String? = nil

    var summary: String {
        switch kind {
        case .flags:
            let what = fields.map { key, on in
                switch key {
                case "archived": return on ? "Archive" : "Unarchive"
                case "pinned": return on ? "Pin" : "Unpin"
                default: return (on ? "Set " : "Clear ") + key
                }
            }.sorted().joined(separator: ", ")
            return ids.count == 1 ? what + " chat" : what + " \(ids.count) chats"
        case .pinMessage: return "Pin a message"
        case .unpinMessage: return "Unpin a message"
        }
    }
}

/// Saved to disk the moment an action is queued; replayed oldest first whenever the Mac answers again.
@MainActor @Observable
final class ActionQueue {
    static let shared = ActionQueue()
    private(set) var pending: [QueuedAction] = []
    private var running = false
    private var retry: Task<Void, Never>?
    private var delay: Double = 2

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesOutbox").appendingPathComponent("actions.json")
    }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([QueuedAction].self, from: data) {
            pending = saved
        }
    }

    /// Waiting actions for the signed-in gateway (another gateway's actions stay put for when you switch back).
    var mine: [QueuedAction] { pending.filter { $0.account == API.shared.accountID } }

    private func save() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        if pending.isEmpty { try? FileManager.default.removeItem(at: file); return }
        #if os(macOS)
        try? JSONEncoder().encode(pending).write(to: file, options: .atomic)
        #else
        try? JSONEncoder().encode(pending).write(to: file, options: [.atomic, .completeFileProtection])
        #endif
    }

    /// True when the error means "couldn't reach the Mac", as opposed to the Mac saying no.
    static func isOffline(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case APIError.http(let code, _) = error { return code == 0 || code == 502 || code == 503 || code == 504 }
        return false
    }

    /// Run an action now; if the Mac can't be reached, save it and return `.queued`.
    enum Outcome { case done, queued, failed(Error) }
    func perform(_ action: QueuedAction) async -> Outcome {
        do {
            try await Self.send(action)
            return .done
        } catch where Self.isOffline(error) {
            pending.append(action)
            save()
            schedule()
            return .queued
        } catch {
            return .failed(error)
        }
    }

    static func send(_ action: QueuedAction) async throws {
        let api = API.shared
        guard api.accountID == action.account else { throw APIError.notSignedIn }
        switch action.kind {
        case .flags:
            do {
                let result = try await api.updateSessions(profile: action.profile, ids: action.ids, fields: action.fields,
                                                          confirmPins: action.confirmPins)
                if let first = result.errors.values.first, result.updated.isEmpty { throw APIError.http(409, first) }
            } catch APIError.http(404, _) {
                for id in action.ids { try await api.updateSession(profile: action.profile, session: id, fields: action.fields) }
            }
        case .pinMessage:
            _ = try await api.pin(profile: action.profile, session: action.session ?? "", message: action.message ?? 0)
        case .unpinMessage:
            _ = try await api.unpin(profile: action.profile, session: action.session ?? "", message: action.message ?? 0)
        }
    }

    /// Replay everything waiting for this gateway, oldest first. Stops at the first one the Mac can't take yet.
    func flush() async {
        guard !running else { return }
        running = true
        defer { running = false; schedule() }
        for action in mine where action.problem == nil {
            do {
                try await Self.send(action)
                pending.removeAll { $0.id == action.id }
                save()
                delay = 2
            } catch where Self.isOffline(error) {
                if let i = pending.firstIndex(where: { $0.id == action.id }) { pending[i].attempts += 1 }
                save()
                return
            } catch {
                if let i = pending.firstIndex(where: { $0.id == action.id }) { pending[i].problem = error.localizedDescription }
                save()
            }
        }
    }

    func discard(_ id: UUID) { pending.removeAll { $0.id == id }; save() }

    /// Wake now (app foreground, network back); otherwise back off quietly up to 30 s.
    func wake() { delay = 2; Task { await flush() } }

    private func schedule() {
        retry?.cancel()
        guard mine.contains(where: { $0.problem == nil }) else { return }
        let wait = delay
        delay = min(30, delay * 2)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}
