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

    var item: ChatItem {
        ChatItem(id: id.uuidString, kind: .control, text: text,
                 footer: mode == "queue" ? "Queued for the next turn" : "Steer received by Hermes",
                 timestamp: at.timeIntervalSince1970)
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
}

actor InboxDisk {
    static let shared = InboxDisk()

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
        try JSONEncoder().encode(send).write(to: url, options: [.atomic, .completeFileProtection])
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
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
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
        try JSONEncoder().encode(Array(rows.suffix(80))).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func save(_ page: InboxSnapshot, key: String) {
        guard !forgotten.contains(account(key)) else { return }
        let url = location(key)
        do {
            if let previous = read(key), previous.savedAt > page.savedAt { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(page)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
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
