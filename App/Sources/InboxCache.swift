import CryptoKit
import Foundation

/// Protected first-page snapshots, isolated by server and login. Pagination and
/// live-run state stay in memory. iOS can evict the disk copy at any time.
struct InboxSnapshot: Codable {
    let sessions: [SessionSummary]
    let cursor: String?
    let savedAt: Date
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
