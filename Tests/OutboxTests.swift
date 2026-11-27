import Foundation
import CryptoKit

/// The outbox message state machine, and that it survives on disk exactly as written.
@main struct OutboxTests {
    static func main() async throws {
        var o = Outgoing(id: UUID(), mode: "queue", text: "first", attachments: [SendAttachment(mime: "text/plain", filename: "a.txt", base64: "aGk=")],
                         choice: .botDefault, created: Date(), files: 1)
        precondition(o.phase == .onPhone)
        // Never tried: an edit is instant and local.
        o = o.edited("first, fixed")
        precondition(o.text == "first, fixed" && o.edit == nil && o.phase == .onPhone)
        // Tried with no answer: it may be on the Mac, so the edit waits instead of changing the original.
        o = o.attempted()
        precondition(o.phase == .retrying)
        let held = o.edited("second edit")
        precondition(held.text == "first, fixed" && held.phase == .editPending("second edit"))
        // The Mac confirms it: files stay with it until it leaves the tray, so "Move back to message box" brings them back.
        o = o.accepted(admission: "adm_1", files: 1)
        precondition(o.phase == .onMac("adm_1") && o.attachments?.count == 1 && o.files == 1)
        // An edit on the Mac applies under the new admission.
        o = o.edited("on mac edit")
        precondition(o.phase == .editPending("on mac edit"))
        o = o.editApplied(admission: "adm_2")
        precondition(o.text == "on mac edit" && o.edit == nil && o.phase == .onMac("adm_2"))
        // Refusal is sticky until edited.
        var r = Outgoing(id: UUID(), mode: "steer", text: "x", choice: nil, created: Date())
        r = r.refused("too big")
        precondition(r.phase == .needsYou("too big"))
        r = r.edited("smaller")
        precondition(r.phase == .onPhone && r.text == "smaller")
        // A steer whose reply ended becomes the next message and says so; a queue item is untouched.
        let s = r.demotedToQueue(note: "late")
        precondition(s.mode == "queue" && s.note == "late")
        precondition(o.demotedToQueue(note: "late").note == nil)
        // Disk: written list reads back identically; an empty list removes the file.
        let key = UUID().uuidString + "|outbox/test"
        try await InboxDisk.shared.saveOutgoing([o, s], key: key)
        let back = await InboxDisk.shared.outgoing(key)
        precondition(back == [o, s])
        try await InboxDisk.shared.saveOutgoing([], key: key)
        let cleared = await InboxDisk.shared.outgoing(key)
        precondition(cleared.isEmpty)
        // Big files: kept as a file, fingerprinted without loading whole, stable upload id, small JSON.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let file = try UploadFiles.adopt(source, filename: "rec.mov", mime: "video/quicktime", move: true)
        precondition(file.isUpload && file.byteCount == bytes.count && file.base64.isEmpty)
        precondition(file.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let onDisk = try Data(contentsOf: file.fileURL!)
        precondition(onDisk == bytes)
        precondition(UploadFiles.uploadID(file) == UploadFiles.uploadID(file) && UploadFiles.uploadID(file).count == 32)
        let json = try JSONEncoder().encode(file)
        precondition(json.count < 600, "the outbox stores a name, not the bytes")
        let decoded = try JSONDecoder().decode(SendAttachment.self, from: json)
        precondition(decoded == file)
        try? FileManager.default.removeItem(at: file.fileURL!)
        // Reply quotes: excerpt, wire format, and splitting a sent message back into quote + body.
        let ex = ReplyQuote.excerpt("Line one\n\n\n  Line two  \n" + String(repeating: "x", count: 400))
        precondition(ex.hasPrefix("Line one\nLine two\n") && ex.hasSuffix("…") && ex.count <= 321)
        let wire = ReplyQuote.markdown("a\nb") + "\n\nmy answer"
        precondition(wire == "> a\n> b\n\nmy answer")
        let parts = ReplyQuote.split(wire)
        precondition(parts.quote == "a\nb" && parts.body == "my answer")
        precondition(ReplyQuote.split("> only a quote").quote == nil)
        precondition(ReplyQuote.split("no quote here").quote == nil)
        let legacy = try JSONDecoder().decode(PastedText.self, from: Data(#"{"id":"\#(UUID().uuidString)","text":"t"}"#.utf8))
        precondition(!legacy.isQuote, "drafts saved by older builds still load")
        print("Outbox phases, edits, refusals, steer demotion, disk round trip, big-file attachments and reply quotes passed")
    }
}
