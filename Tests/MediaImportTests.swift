import UIKit
import UniformTypeIdentifiers

@main
enum MediaImportTests {
    static func main() throws {
        // A screenshot-sized, many-colour PNG — the shape that failed to import on-device —
        // must decode through ImageIO and land inside the 1 MiB send budget.
        let screenshot = try render(CGSize(width: 1179, height: 2556))
        precondition(screenshot.count > 2 * 1024 * 1024, "fixture is not a large image")
        let asset = try ChatMedia.image(from: screenshot)
        precondition(asset.mime == "image/jpeg")
        precondition(asset.filename.hasPrefix("Photo-"), asset.filename)
        let bytes = Data(base64Encoded: asset.base64) ?? Data()
        precondition(!bytes.isEmpty && bytes.count <= 1024 * 1024,
                     "decoded image is \(bytes.count) bytes, over budget")

        // The compressed result is a readable JPEG, not garbage bytes.
        precondition(CGImageSourceCreateWithData(bytes as CFData, nil) != nil, "attachment is not a JPEG")

        // Junk bytes are refused as unreadable, never attached.
        do { _ = try ChatMedia.image(from: Data([0x89, 0x50, 0x4E, 0x47, 0x00])); fatalError("decoded junk as an image") }
        catch ChatMedia.Failure.unreadable {}
        do { _ = try ChatMedia.image(from: Data()); fatalError("decoded empty data") }
        catch ChatMedia.Failure.unreadable {}

        // A HEIC original decodes through the same path (ImageIO reads it on-device).

        // Pasted-text collapse: a huge paste is isolated exactly; small edits stay inline.
        let big = String(repeating: "paste ", count: 600)  // 3,600 characters
        guard let run = PasteSplit.insertion(old: "keep tail", new: "keep " + big + "tail") else {
            fatalError("a 3,600-char paste was not isolated")
        }
        precondition(run == big, "isolated run differs from the pasted text")
        precondition(PasteSplit.insertion(old: big, new: big + "tail") == nil, "short insertion collapsed")
        precondition(PasteSplit.insertion(old: "a", new: "ab") == nil, "tiny insertion collapsed")

        // Source-type sniffing names the original format; JPEGs stay unbadged.
        precondition(ChatMedia.originalTypeName(Data("GIF89a".utf8)) == "GIF")
        precondition(ChatMedia.originalTypeName(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == "PNG")
        precondition(ChatMedia.originalTypeName(Data([0, 0, 0, 0]) + Data("ftypheic".utf8)) == "HEIC")
        precondition(ChatMedia.originalTypeName(Data("RIFF____WEBP".utf8)) == "WebP")
        precondition(ChatMedia.originalTypeName(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 20)) == nil)
        precondition(ChatMedia.originalTypeName(Data()) == nil)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let dot = renderer.image { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let gifAsset = try ChatMedia.jpeg(dot, name: "Photo", sourceType: "GIF")
        precondition((gifAsset.filename as NSString).pathExtension == "gif", gifAsset.filename)
        precondition(gifAsset.mime == "image/jpeg", "a GIF's first frame still rides as JPEG bytes")

        // A HEIC original decodes through the same path (ImageIO reads it on-device).
        if let heic = try? heicFixture(1200) {
            let h = try ChatMedia.image(from: heic)
            precondition(h.mime == "image/jpeg")
        }

        print("Media import decode, paste split, source types and budget boundaries passed")
    }
    /// A large, per-pixel-noise PNG: uncompressible, like a real photo or dense screenshot.
    static func render(_ size: CGSize) throws -> Data {
        let w = Int(size.width), h = Int(size.height)
        var noise = Data(capacity: w * h * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<(w * h) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise.append(UInt8(truncatingIfNeeded: seed >> 16))
            noise.append(UInt8(truncatingIfNeeded: seed >> 40))
            noise.append(UInt8(truncatingIfNeeded: seed >> 8))
            noise.append(0xFF)
        }
        guard let provider = CGDataProvider(data: noise as CFData) else { throw ChatMedia.Failure.unreadable }
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        guard let cg, let png = UIImage(cgImage: cg).pngData() else { throw ChatMedia.Failure.unreadable }
        return png
    }

    /// A small solid-colour HEIC, or nil when the platform cannot encode HEIC (older simulator).
    static func heicFixture(_ pixels: Int) throws -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: pixels, height: pixels)))
        }
        guard let cg = image.cgImage else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
