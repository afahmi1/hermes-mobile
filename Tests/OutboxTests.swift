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
        // The Mac confirms it: files leave the phone.
        o = o.accepted(admission: "adm_1", files: 1)
        precondition(o.phase == .onMac("adm_1") && o.attachments == nil && o.files == 1)
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
        precondition(try Data(contentsOf: file.fileURL!) == bytes)
        precondition(UploadFiles.uploadID(file) == UploadFiles.uploadID(file) && UploadFiles.uploadID(file).count == 32)
        let json = try JSONEncoder().encode(file)
        precondition(json.count < 600, "the outbox stores a name, not the bytes")
        precondition(try JSONDecoder().decode(SendAttachment.self, from: json) == file)
        try? FileManager.default.removeItem(at: file.fileURL!)
        print("Outbox phases, edits, refusals, steer demotion, disk round trip and big-file attachments passed")
    }
}
