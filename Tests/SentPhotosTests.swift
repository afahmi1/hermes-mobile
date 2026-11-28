import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Sent photos stay visible: a send's small copies are made, found again by the send, matched to the reloaded
/// message with the same words (oldest send first), and big batches split into even messages Hermes sees whole.
@main
struct SentPhotosTests {
    static func jpeg(_ w: Int, _ h: Int, shade: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @MainActor static func main() async throws {
        // Batches: never over the limit, as even as possible, every photo exactly once.
        precondition(BatchPlan.split(19, perMessage: 10) == [0..<10, 10..<19])
        precondition(BatchPlan.split(21, perMessage: 10) == [0..<7, 7..<14, 14..<21])
        precondition(BatchPlan.split(10, perMessage: 10) == [0..<10])
        precondition(BatchPlan.split(0, perMessage: 10).isEmpty)
        for n in 1...40 {
            let plan = BatchPlan.split(n, perMessage: 10)
            precondition(plan.allSatisfy { $0.count <= 10 } && plan.map(\.count).reduce(0, +) == n, "\(n)")
            precondition(plan.first?.lowerBound == 0 && plan.last?.upperBound == n)
        }
        let first = BatchPlan.text("look at these", range: 0..<10, total: 19, first: true)
        precondition(first.hasPrefix("look at these\n\n(Photos 1 to 10 of 19."), first)
        let later = BatchPlan.text("ignored", range: 10..<19, total: 19, first: false)
        precondition(later == "Photos 11 to 19 of 19, continuing my earlier message.", later)

        // Small copies: one per photo, 600 px on the long side, upright JPEGs; files get none.
        let big = jpeg(4032, 3024, shade: 0.2)
        let photo = SendAttachment(mime: "image/jpeg", filename: "IMG_1.jpg", base64: big.base64EncodedString())
        let doc = SendAttachment(mime: "application/pdf", filename: "a.pdf", base64: Data("%PDF".utf8).base64EncodedString())
        let send = UUID().uuidString
        let urls = SentPreviews.make(send: send, session: "s1", text: "look  at\nthese", attachments: [photo, doc, photo])
        precondition(urls.count == 2, "\(urls.count)")
        let src = CGImageSourceCreateWithURL(urls[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        precondition(max(props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int) == 600)
        precondition(SentPreviews.files(send: send) == urls, "found again by the send")

        // After a reload the message has the Mac's id, not the send's: matched by its words.
        let older = UUID().uuidString
        let olderURLs = SentPreviews.make(send: older, session: "s2", text: "same words", attachments: [photo])
        try await Task.sleep(nanoseconds: 5_000_000)
        let newer = UUID().uuidString
        let newerURLs = SentPreviews.make(send: newer, session: "s2", text: "same words", attachments: [photo, photo])
        var rows = [ChatItem(id: "a", kind: .user, text: "same words"),
                    ChatItem(id: "b", kind: .assistant, text: "same words"),
                    ChatItem(id: "c", kind: .user, text: "other"),
                    ChatItem(id: "d", kind: .user, text: "same   words")]
        SentPreviews.attach(&rows, session: "s2")
        precondition(rows[0].previews == olderURLs, "oldest send to the first matching message")
        precondition(rows[1].previews.isEmpty && rows[2].previews.isEmpty, "only user messages with the same words")
        precondition(rows[3].previews == newerURLs, "the next send to the next match")
        var elsewhere = [ChatItem(id: "x", kind: .user, text: "look at these")]
        SentPreviews.attach(&elsewhere, session: "other-chat")
        precondition(elsewhere[0].previews.isEmpty, "never another chat's photos")
        var mine = [ChatItem(id: "y", kind: .user, text: "look at these")]
        SentPreviews.attach(&mine, session: "s1")
        precondition(mine[0].previews == urls, "whitespace doesn't matter")

        // A copy iOS cleared is skipped, not shown broken; a month-old send is pruned.
        try FileManager.default.removeItem(at: urls[1])
        precondition(SentPreviews.files(send: send) == [urls[0]])
        SentPreviews.prune(now: Date().addingTimeInterval(31 * 86400))
        precondition(SentPreviews.files(send: send).isEmpty && !FileManager.default.fileExists(atPath: urls[0].path))
        print("Sent photos: copies made and matched after reload, batches split evenly, old copies pruned")
    }
}
