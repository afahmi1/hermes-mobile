import Foundation

/// The phone's upload folder: copies are dated when they arrive, launch cleanup never deletes a file a draft or
/// unsent message needs, and limits and upload failures come from what the Mac said.
@main struct UploadFilesTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // A file last changed years ago (a photo, a PDF from 2019) is dated "now" once copied in.
        let old = scratch.appendingPathComponent("report.pdf")
        try Data("%PDF-1.4 hello".utf8).write(to: old)
        let longAgo = Date(timeIntervalSince1970: 1_500_000_000)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        let copied = try UploadFiles.adopt(old, filename: "report.pdf", mime: "application/pdf", move: false)
        let stamped = try fm.attributesOfItem(atPath: copied.fileURL!.path)[.modificationDate] as! Date
        precondition(abs(stamped.timeIntervalSinceNow) < 60, "copy kept the source's old date: \(stamped)")
        precondition(fm.fileExists(atPath: old.path), "a copy leaves the source alone")

        // Launch cleanup: month-old files go unless something still points at them.
        let kept = try UploadFiles.adopt(old, filename: "draft.pdf", mime: "application/pdf", move: false)
        let stale = try UploadFiles.adopt(old, filename: "stale.pdf", mime: "application/pdf", move: false)
        let fresh = try UploadFiles.adopt(old, filename: "fresh.pdf", mime: "application/pdf", move: false)
        for a in [kept, stale] { try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: a.fileURL!.path) }
        UploadFiles.prune(keep: UploadFiles.names([kept]))
        precondition(fm.fileExists(atPath: kept.fileURL!.path), "deleted a file a draft still needs")
        precondition(!fm.fileExists(atPath: stale.fileURL!.path), "kept a month-old file nobody needs")
        precondition(fm.fileExists(atPath: fresh.fileURL!.path), "deleted a new file")
        precondition(fm.fileExists(atPath: copied.fileURL!.path))

        // A file whose copy is gone is found before anything is sent; inline attachments are never "missing".
        let inline = SendAttachment(mime: "text/plain", filename: "a.txt", base64: "aGk=")
        precondition(UploadFiles.missing([kept, fresh, inline]).isEmpty)
        try fm.removeItem(at: fresh.fileURL!)
        precondition(UploadFiles.missing([kept, fresh, inline]) == [fresh])

        // Removing a chip deletes its copy, unless the same file is still used elsewhere in the chat.
        UploadFiles.discard([kept, copied], keeping: UploadFiles.names([copied]))
        precondition(!fm.fileExists(atPath: kept.fileURL!.path) && fm.fileExists(atPath: copied.fileURL!.path))
        // A damaged record can never point the delete outside the folder.
        let outside = scratch.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: outside)
        UploadFiles.discard([SendAttachment(mime: "", filename: "", base64: "", localFile: "../../keep.txt")])
        precondition(fm.fileExists(atPath: outside.path))
        UploadFiles.discard([copied])

        // Limits follow the bridge: today's bridge (50 MB media, 2 GB uploads) keeps the 8 MB defaults, a small
        // media cap shrinks inline and chunk sizes to fit its request body, and Files videos may be copied up to
        // the upload cap instead of a fixed 256 MB.
        func caps(_ json: String) throws -> MediaCapabilities { try JSONDecoder().decode(MediaCapabilities.self, from: Data(json.utf8)) }
        let today = try caps(#"{"images":true,"files":true,"video":true,"max_video_bytes":52428800,"max_file_bytes":52428800,"max_upload_bytes":2147483648,"max_message_bytes":134217728,"original_images":true}"#)
        precondition(today.uploadLimits == UploadFiles.Limits(inline: 8 << 20, chunk: 8 << 20, copy: 2 << 30), "\(today.uploadLimits)")
        let small = try caps(#"{"images":true,"max_file_bytes":2097152,"max_upload_bytes":104857600}"#)
        precondition(small.uploadLimits.inline == 2 << 20 && small.uploadLimits.chunk == 2 << 20)
        precondition(small.uploadLimits.copy == 256 << 20, "never below the old copy limit")
        let stated = try caps(#"{"max_file_bytes":52428800,"max_image_bytes":4194304,"max_body_bytes":3145728}"#)
        precondition(stated.uploadLimits.inline == 4 << 20)
        precondition(stated.uploadLimits.chunk < 3 << 20, "a chunk must fit the stated body cap")
        let legacy = try caps(#"{"images":true}"#)
        precondition(legacy.uploadLimits.inline == 4 << 20 && legacy.uploadLimits.copy == 256 << 20, "\(legacy.uploadLimits)")

        // Upload answers the person can act on, instead of "Waiting to confirm…" for ever.
        precondition(API.uploadProblem(507, name: "a.mov") == .macFull)
        precondition(API.uploadProblem(503, name: "a.mov") == .macBusy && API.uploadProblem(502, name: "a.mov") == .macBusy)
        precondition(API.uploadProblem(409, name: "a.mov") == .rejected("a.mov"))
        precondition(API.uploadProblem(500, name: "a.mov") == nil)
        precondition(UploadProblem.macBusy.isTransient && !UploadProblem.macFull.isTransient)
        precondition(ActionQueue.isOffline(UploadProblem.macBusy) && !ActionQueue.isOffline(UploadProblem.missingFile("a")))
        precondition(UploadProblem.macFull.localizedDescription.contains("out of disk space"))
        precondition(UploadProblem.missingFile("Report.pdf").localizedDescription.contains("Report.pdf"))
        for problem in [UploadProblem.macFull, .macBusy, .rejected("x"), .missingFile("x")] {
            let text = problem.localizedDescription
            precondition(!text.contains("50") && !text.contains("Error"), "status code or error dump in: \(text)")
        }

        print("Upload folder dating, launch cleanup with drafts kept, chip cleanup, bridge-derived limits and upload errors passed")
    }
}
