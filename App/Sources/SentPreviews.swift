import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The photos you sent, as small copies kept on this phone, so a sent message shows its pictures at once
/// (while it uploads) and keeps showing them after the chat reloads, even when the Mac's copy is gone.
/// Like T3's blob-URL hand-off: the local copy shows first; the Mac's image takes over once it loads.
///
/// Files: Caches/SentPreviews/<send id>-<n>.jpg, 600 px on the long side. An index maps each send to its chat and
/// words, so a reloaded message (which has the Mac's id, not the send's) finds its photos. Kept 30 days.
/// Caches, not Application Support: iOS may clear them under storage pressure, and that only costs the preview.
enum SentPreviews {
    struct Entry: Codable, Equatable {
        var send: String
        var session: String?
        var text: String
        var files: [String]
        var created: Date
    }

    static let pixels = 600
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [Entry]?

    static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var indexURL: URL { folder.appendingPathComponent("index.json") }

    /// The words a message is matched by: what Hermes stores is the same text, give or take whitespace.
    static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Make the small copies for one send. Images only; files keep their chips. Safe off the main thread.
    @discardableResult
    static func make(send: String, session: String?, text: String, attachments: [SendAttachment]) -> [URL] {
        var urls: [URL] = []
        for (n, a) in attachments.enumerated() where a.mime.hasPrefix("image/") {
            let out = folder.appendingPathComponent("\(safe(send))-\(n).jpg")
            if FileManager.default.fileExists(atPath: out.path) || write(a, to: out) { urls.append(out) }
        }
        guard !urls.isEmpty else { return [] }
        update { entries in
            entries.removeAll { $0.send == send }
            entries.append(Entry(send: send, session: session, text: key(text), files: urls.map(\.lastPathComponent),
                                 created: Date()))
        }
        return urls
    }

    /// The copies for one send (an optimistic or queued message carries the send's id).
    static func files(send: String) -> [URL] {
        guard let entry = entries().first(where: { $0.send == send }) else { return [] }
        return existing(entry)
    }

    /// A send made before its chat had an id: file it under the chat once it has one.
    static func adopt(send: String, session: String) {
        update { entries in
            for i in entries.indices where entries[i].send == send && entries[i].session == nil { entries[i].session = session }
        }
    }

    /// Give reloaded user messages their photos: each send's copies go to the first message in this chat with the
    /// same words that doesn't have them yet, oldest send first. A message with no match is left alone.
    static func attach(_ items: inout [ChatItem], session: String?) {
        guard let session else { return }
        var waiting = entries().filter { $0.session == session }.sorted { $0.created < $1.created }
        guard !waiting.isEmpty else { return }
        for i in items.indices where items[i].kind == .user && items[i].previews.isEmpty {
            let words = key(items[i].text)
            guard let at = waiting.firstIndex(where: { $0.text == words }) else { continue }
            items[i].previews = existing(waiting.remove(at: at))
            if waiting.isEmpty { break }
        }
    }

    /// Drop copies older than 30 days.
    static func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        update { entries in
            for old in entries where old.created < cutoff {
                for name in old.files { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            }
            entries.removeAll { $0.created < cutoff }
        }
    }

    // MARK: Private

    private static func existing(_ entry: Entry) -> [URL] {
        entry.files.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func safe(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)) }

    private static func write(_ a: SendAttachment, to out: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        if let url = a.fileURL { source = CGImageSourceCreateWithURL(url as CFURL, options) }
        else if let data = Data(base64Encoded: a.base64) { source = CGImageSourceCreateWithData(data as CFData, options) }
        else { source = nil }
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        loaded = read
        return read
    }

    private static func update(_ change: (inout [Entry]) -> Void) {
        var current = entries()
        change(&current)
        lock.lock(); defer { lock.unlock() }
        loaded = current
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: indexURL, options: .atomic) }
    }
}

/// How a photo batch bigger than Hermes's per-message limit is split, and what each message says.
enum BatchPlan {
    /// Even-sized messages, none over the limit: 19 at 10 a message is 10 + 9, 21 is 7 + 7 + 7.
    static func split(_ count: Int, perMessage: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let limit = max(1, perMessage)
        let messages = (count + limit - 1) / limit
        let base = count / messages, extra = count % messages
        var out: [Range<Int>] = [], start = 0
        for n in 0..<messages {
            let size = base + (n < extra ? 1 : 0)
            out.append(start..<(start + size))
            start += size
        }
        return out
    }

    static func text(_ words: String, range: Range<Int>, total: Int, first: Bool) -> String {
        let label = "Photos \(range.lowerBound + 1) to \(range.upperBound) of \(total)"
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if first {
            let note = "(\(label). The rest come in the next messages; take them all in before answering in full.)"
            return trimmed.isEmpty ? note : trimmed + "\n\n" + note
        }
        return "\(label), continuing my earlier message."
    }
}
