import AVFoundation
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The picked video as a private file snapshot. Declaring the movie content type matches the
/// picker's actual representations; the old single generic `.item` file import, used for photos
/// and videos alike, intermittently matched nothing and failed with "no compatible representations".
struct PickedVideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { file in
            try Self(url: MediaStaging.stage(file.file))
        }
    }
}

enum MediaImport {
    /// The photo's bytes. `Data` is the native transferable for library assets: the system picks
    /// the asset's real representation and downloads the iCloud original when needed, instead of
    /// negotiating a generic file representation that large or not-yet-local items fail to provide.
    /// Tries three times: a photo kept only in iCloud ("Optimize iPhone Storage") often fails its first download.
    static func imageData(from item: PhotosPickerItem) async throws -> Data {
        var lastError: Error = ChatMedia.Failure.downloadFailed
        for attempt in 0..<3 {
            do {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(600 * attempt)) }
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    throw ChatMedia.Failure.downloadFailed
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw (lastError as? ChatMedia.Failure) ?? ChatMedia.Failure.downloadFailed
    }

    static func videoFile(from item: PhotosPickerItem) async throws -> URL {
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideoFile.self) else {
                throw ChatMedia.Failure.downloadFailed
            }
            return picked.url
        } catch let failure as ChatMedia.Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatMedia.Failure.downloadFailed
        }
    }
}

/// A file chosen from Files. Unlike a photo or video, this keeps the original bytes and media
/// type: Hermes's agent gets a private local path and decides which tool reads it. The bridge
/// stages the bytes; nothing is transcoded, so an MP3 stays an MP3.
enum FileImport {
    enum Failure: LocalizedError {
        case unreadable, empty, tooLarge(Int), notDownloaded
        var errorDescription: String? {
            switch self {
            case .unreadable: "This file could not be opened. Try choosing it again."
            case .empty: "This file is empty."
            case .tooLarge(let max):
                "This file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(max), countStyle: .file)). Choose a smaller file."
            case .notDownloaded: "This file couldn’t be downloaded from its cloud storage. Check your connection and try again."
            }
        }
    }

    /// Read a Files-app item through a file coordinator, then turn it into an attachment. The coordinator
    /// downloads an iCloud Drive or File Provider placeholder first, and hands a package (a Pages, Keynote or
    /// Numbers document, an .rtfd) or a folder over as one .zip, so it can travel like any other file.
    /// The coordinated URL only lives inside the block, so the attachment is built there.
    static func coordinated<T>(_ url: URL, _ body: (_ local: URL, _ filename: String, _ zipped: Bool) throws -> T) throws -> T {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        var outcome: Result<T, Error> = .failure(Failure.unreadable)
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordination) { local in
            outcome = Result {
                let original = try safeName(url)
                // Packages and folders arrive zipped; say so in the name so the Mac knows what it holds.
                let zipped = isFolder || (local.pathExtension.lowercased() == "zip" && url.pathExtension.lowercased() != "zip")
                return try body(local, zipped ? try safeName(original + ".zip") : original, zipped)
            }
        }
        if let coordination {
            if coordination.domain == NSCocoaErrorDomain && coordination.code == NSUserCancelledError { throw CancellationError() }
            throw Failure.notDownloaded
        }
        return try outcome.get()
    }

    /// Read a security-scoped file and turn it into the one attachment the bridge accepts.
    /// Images keep the existing camera/library pipeline (decoded and bounded as JPEG); every
    /// other regular file rides as its original bytes and MIME type.
    /// `uploadMax`: the bridge takes big files through resumable uploads, up to this size. Anything over the
    /// inline limit is then kept as a file on the phone and uploaded in chunks, never read into memory.
    /// `filename`: the name to send (a coordinated copy can have a temporary name). Defaults to the URL's own.
    static func attachment(from url: URL, filename: String? = nil, maxBytes: Int, uploadMax: Int? = nil,
                           originals: Bool = false, inlineLimit: Int = UploadFiles.inlineLimit) throws -> SendAttachment {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw Failure.unreadable }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw Failure.empty }
        var name = try filename ?? safeName(url)
        var type = values.contentType ?? UTType(filenameExtension: (name as NSString).pathExtension)
            ?? UTType(filenameExtension: url.pathExtension)
        // The extension can lie (a HEIC saved as .jpg) or name a format ImageIO knows better (DNG, AVIF, TIFF).
        // For anything that claims to be an image, the bytes decide the type and the extension follows.
        if type?.conforms(to: .image) ?? false, let real = ChatMedia.imageType(at: url), real != type {
            type = real
            name = ChatMedia.renamed(name, to: real)
        }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        // A Mac that takes originals gets every file as it is, images included: no conversion, no size cap but its own.
        if originals, let uploadMax {
            guard size <= uploadMax else { throw Failure.tooLarge(uploadMax) }
            return try UploadFiles.adopt(url, filename: name, mime: mime, move: false)
        }
        if let uploadMax, size > inlineLimit, !(type?.conforms(to: .image) ?? false) {
            guard size <= uploadMax else { throw Failure.tooLarge(uploadMax) }
            return try UploadFiles.adopt(url, filename: name, mime: mime, move: false)
        }
        if let type, type.conforms(to: .image) {
            // Downsample the file at its URL. A large original can produce a small valid upload.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let preview = ChatMedia.thumbnail(source, pixels: 2048) else { throw ChatMedia.Failure.unreadable }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            let attachment = try ChatMedia.jpeg(UIImage(cgImage: preview), name: "Photo",
                                                sourceType: ChatMedia.originalTypeName(header) ?? ChatMedia.formatName(type),
                                                originalName: name)
            guard attachment.byteCount <= maxBytes else { throw Failure.tooLarge(maxBytes) }
            return attachment
        }
        guard size <= maxBytes else { throw Failure.tooLarge(maxBytes) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maxBytes else { throw Failure.tooLarge(maxBytes) }
        if let type, type.conforms(to: .movie) {
            throw Failure.unreadable  // the app routes clips through Photos, where consent is explained
        }
        return SendAttachment(mime: mime, filename: name, base64: data.base64EncodedString())
    }

    /// A bridge- and filesystem-safe display/staging name: last path component, printable,
    /// no separators or quotes, at most 120 Unicode scalars with the extension kept.
    static func safeName(_ url: URL) throws -> String { try safeName(url.lastPathComponent) }

    static func safeName(_ raw: String) throws -> String {
        let banned = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:\""))
        // macOS screenshots put a narrow no-break space (U+202F) before "PM"; other names carry U+00A0. Every
        // kind of space becomes a plain one, and the name is NFC so "é" is one character on both sides.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars where !banned.contains(scalar) {
            scalars.append(scalar.properties.generalCategory == .spaceSeparator ? " " : scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = capped(cleaned, scalars: 120)
        guard !name.isEmpty, name != ".", name != ".." else { throw Failure.unreadable }
        return name
    }

    /// At most `limit` Unicode scalars, cutting the name before its extension (never mid-character) so
    /// "Quarterly report ... final.pdf" stays a .pdf.
    static func capped(_ name: String, scalars limit: Int) -> String {
        guard name.unicodeScalars.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.unicodeScalars.count <= 16
        let stem = keepExt ? (name as NSString).deletingPathExtension : name
        let suffix = keepExt ? "." + ext : ""
        let room = limit - suffix.unicodeScalars.count
        var out = ""
        var used = 0
        for character in stem {
            let n = character.unicodeScalars.count
            guard used + n <= room else { break }
            out.append(character)
            used += n
        }
        return out.trimmingCharacters(in: .whitespaces) + suffix
    }
}

/// What the pasteboard holds when it isn't text or a picture: a copied file (a PDF from Files, a document).
enum PastedFile {
    /// The type to read, or nil when nothing on the pasteboard is a file.
    static func type(in identifiers: [String]) -> UTType? {
        for identifier in identifiers {
            guard !identifier.hasPrefix("dyn."), let type = UTType(identifier) else { continue }
            if type.conforms(to: .text) || type.conforms(to: .url) || type.conforms(to: .image) { continue }
            if type.conforms(to: .data) || type.conforms(to: .package) { return type }
        }
        return nil
    }

    /// Copy the pasted file into a private temporary folder (the provider's URL only lives inside its callback).
    static func load(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<URL, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { return done.resume(throwing: error ?? FileImport.Failure.unreadable) }
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var name = suggested.flatMap { try? FileImport.safeName($0) } ?? url.lastPathComponent
                    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
                    let target = folder.appendingPathComponent((try? FileImport.safeName(name)) ?? "Pasted file")
                    try FileManager.default.copyItem(at: url, to: target)
                    done.resume(returning: target)
                } catch {
                    done.resume(throwing: FileImport.Failure.unreadable)
                }
            }
        }
    }
}

/// Shared by all import sources and the final Send check, including drafts restored from disk.
enum AttachmentSelection {
    static func issue(_ assets: [SendAttachment], fileLimit: Int, videoLimit: Int, uploadLimit: Int? = nil,
                      messageLimit: Int? = nil) -> String? {
        // Hermes's per-message cap is for the photos it hands the model natively. Other files are staged on the
        // Mac one by one and only have the upload limit below.
        let photoBytes = assets.filter { $0.mime.hasPrefix("image/") }.reduce(0) { $0 + $1.byteCount }
        if let messageLimit, photoBytes > messageLimit {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(messageLimit), countStyle: .file)
            return "These photos are over the \(limit) your Mac takes in one message. Send them in two messages."
        }
        if assets.count > ChatMedia.maxAttachments { return "Choose up to \(ChatMedia.maxAttachments) attachments for one message." }
        let hasVideo = assets.contains { $0.mime == "video/mp4" }
        if hasVideo && assets.count != 1 { return "Send a video on its own, or choose still frames." }
        // Uploaded files each have their own (much larger) limit; only inline bytes share the message budget.
        if assets.contains(where: \.isUpload) && uploadLimit == nil {
            return "This Mac's bridge can't take big files. Update it, or remove the large attachment."
        }
        if let uploadLimit, assets.contains(where: { $0.isUpload && $0.byteCount > uploadLimit }) {
            return "A file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(uploadLimit), countStyle: .file)), the most this Mac takes."
        }
        let limit = hasVideo ? videoLimit : fileLimit
        if assets.filter({ !$0.isUpload }).reduce(0, { $0 + $1.byteCount }) > limit {
            return "The attachments exceed this bot’s limit. Remove an attachment and try again."
        }
        return nil
    }
}

enum ChatMedia {
    /// Per message, matching the bridge (bridge_media.MAX_ITEMS) and a Telegram album.
    static let maxAttachments = 20

    enum Failure: LocalizedError {
        case unreadable, tooLarge, noFrames, downloadFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "This media could not be opened. Try another file."
            case .tooLarge: "This file is too large to send. Choose a smaller photo or a shorter clip."
            case .noFrames: "No frames could be read from this video."
            case .downloadFailed: "This photo or video couldn't be downloaded from iCloud. Check your connection and try again."
            }
        }
    }

    /// Decode the picked photo's bytes: PNG screenshots, HEIC camera originals and animated GIFs
    /// (first frame) all pass through ImageIO, whatever the library hands over.
    /// A photo at its full resolution, for the Mac's resumable upload: decoded once, turned upright, saved as a
    /// high-quality JPEG (models can't read HEIC) into the upload folder. Location and camera metadata are not
    /// copied. Nothing is downscaled; Hermes shrinks a copy itself if a model needs it.
    /// `budget` is this photo's share of the message: full resolution first, stepping JPEG quality down, then the
    /// size (6000, 4032, 3024, 2048 px) until it fits. A photo sent smaller always beats a photo left out.
    static let maxPixels = 50_000_000  // matches the bridge (bridge_media.MAX_PIXELS)

    static func fullImage(from data: Data, uploadMax: Int, budget: Int = .max, name: String = "Photo") throws -> SendAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadable }
        let limit = min(uploadMax, budget)
        let full = max(w, h)
        let fit = w * h > maxPixels ? Int(Double(full) * (Double(maxPixels) / Double(w * h)).squareRoot()) : full
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: target) }
        var size = 0
        search: for edge in [fit, 6000, 4032, 3024, 2048] where edge <= fit {
            guard let upright = thumbnail(source, pixels: edge) else { throw Failure.unreadable }
            for quality in [0.92, 0.85, 0.75, 0.65] {
                guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw Failure.unreadable }
                CGImageDestinationAddImage(dest, upright, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable }
                // Read from disk every time: URL caches resource values, so a re-check would see the first size.
                size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.intValue ?? 0
                if size > 0 && size <= limit { break search }
            }
        }
        guard size > 0 else { throw Failure.unreadable }
        guard size <= limit else { throw Failure.tooLarge }
        var out = try UploadFiles.adopt(target, filename: name + "-" + UUID().uuidString.prefix(6) + ".jpg", mime: "image/jpeg", move: true)
        out.sourceFormat = originalTypeName(data) ?? imageType(of: data).flatMap(formatName)
        return out
    }

    /// The photo exactly as the iPhone stored it (HEIC stays HEIC, with its metadata), for a Mac that takes originals.
    /// Over the batch's share of the message, or over the bridge's 50 MP, it falls back to a full-resolution JPEG
    /// sized to fit. The type comes from the bytes (DNG, AVIF, TIFF, BMP keep their own), never guessed as JPEG.
    static func original(from data: Data, uploadMax: Int, budget: Int, name: String? = nil, prefix: String = "Photo") throws -> SendAttachment {
        guard data.count <= min(uploadMax, budget) else { return try fullImage(from: data, uploadMax: uploadMax, budget: budget, name: prefix) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { throw Failure.unreadable }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w * h > maxPixels {
            return try fullImage(from: data, uploadMax: uploadMax, budget: budget, name: prefix)
        }
        let mime = type.preferredMIMEType ?? "image/jpeg"
        let ext = type.preferredFilenameExtension.map { $0 == "jpeg" ? "jpg" : $0 } ?? "jpg"
        let stem = name.map { ($0 as NSString).deletingPathExtension } ?? (prefix + "-" + UUID().uuidString.prefix(6))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var out = try UploadFiles.adopt(tmp, filename: FileImport.capped(stem + "." + ext, scalars: 120), mime: mime, move: false)
        out.sourceFormat = originalTypeName(data) ?? (type == .jpeg ? nil : formatName(type))
        return out
    }

    /// The image format ImageIO reads in these bytes or this file, whatever the name says.
    static func imageType(of data: Data) -> UTType? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
    }

    static func imageType(at url: URL) -> UTType? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
    }

    /// "IMG_0042.jpg" holding HEIC bytes becomes "IMG_0042.heic".
    static func renamed(_ name: String, to type: UTType) -> String {
        guard var ext = type.preferredFilenameExtension else { return name }
        if ext == "jpeg" { ext = "jpg" }
        let current = (name as NSString).pathExtension.lowercased()
        if current == ext || (type == .jpeg && current == "jpeg") { return name }
        return FileImport.capped((name as NSString).deletingPathExtension + "." + ext, scalars: 120)
    }

    /// A short badge name for a format: "DNG", "TIFF", "AVIF". Nil for plain JPEG.
    static func formatName(_ type: UTType) -> String? {
        if type == .jpeg { return nil }
        return (type.preferredFilenameExtension ?? type.localizedDescription)?.uppercased()
    }

    static func image(from data: Data) throws -> SendAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = thumbnail(source, pixels: 2048) else { throw Failure.unreadable }
        return try jpeg(UIImage(cgImage: thumbnail), name: "Photo", sourceType: originalTypeName(data))
    }

    /// An image pasted into the composer (already decoded by UIKit) rides as a JPEG under a
    /// "Pasted image" filename. The caller downsamples first; this only encodes within the 1 MiB budget.
    static func pasted(_ image: UIImage) throws -> SendAttachment {
        try jpeg(image, name: "Pasted image")
    }

    /// The original format behind picked bytes, for an honest badge on the chip. nil = plain JPEG.
    /// The bytes sent are always JPEG (first frame); the badge says where they came from.
    static func originalTypeName(_ data: Data) -> String? {
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "GIF" }          // GIF87a / GIF89a
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if data.count >= 12, data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "WebP" }
        if data.count >= 12, let head = String(bytes: data[4..<12], encoding: .ascii), head.hasPrefix("ftyp"),
           head.dropFirst(4).hasPrefix("he") || head.dropFirst(4).hasPrefix("mi") || head.dropFirst(4).hasPrefix("ms") { return "HEIC" }
        return nil
    }

    /// A picture of an image attachment, whether its bytes ride inline or wait in the upload folder.
    /// Downsampled, so a 48 MP original never decodes at full size just to be looked at.
    static func previewImage(_ attachment: SendAttachment, pixels: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        if let url = attachment.fileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, options)
        } else if let data = Data(base64Encoded: attachment.base64) {
            source = CGImageSourceCreateWithData(data as CFData, options)
        } else {
            source = nil
        }
        return source.flatMap { thumbnail($0, pixels: pixels) }.map { UIImage(cgImage: $0) }
    }

    static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG bytes within the 1 MiB send budget; the uploaded filename matches its bytes.
    static func jpeg(_ image: UIImage, name: String, sourceType: String? = nil, originalName: String? = nil) throws -> SendAttachment {
        let stem = originalName.map { ($0 as NSString).deletingPathExtension } ?? (name + "-" + UUID().uuidString.prefix(6))
        let filename = FileImport.capped(stem + ".jpg", scalars: 120)
        for quality in [0.82, 0.62, 0.45, 0.3, 0.18] {
            if let bytes = image.jpegData(compressionQuality: quality), bytes.count <= 1024 * 1024 {
                return SendAttachment(mime: "image/jpeg", filename: filename,
                                      base64: bytes.base64EncodedString(), sourceFormat: sourceType)
            }
        }
        throw Failure.tooLarge
    }

    /// The video exactly as recorded (a screen recording, a .mov), as a file for the resumable upload. No
    /// re-encoding: Hermes gets every frame and the audio, and can process it with its own tools.
    static func original(from url: URL, uploadMax: Int, move: Bool = false) throws -> SendAttachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw Failure.unreadable }
        guard size <= uploadMax else { throw Failure.tooLarge }
        let type = UTType(filenameExtension: url.pathExtension)
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        return try UploadFiles.adopt(url, filename: "Video \(stamp).\(ext)",
                                     mime: type?.preferredMIMEType ?? "video/quicktime", move: move)
    }

    static func clip(from url: URL, maxBytes: Int, uploadMax: Int? = nil) async throws -> SendAttachment {
        let maxBytes = max(maxBytes, uploadMax ?? 0)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.unreadable }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: target) }
        for preset in [AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset),
                  export.supportedFileTypes.contains(.mp4) else { continue }
            export.outputURL = target
            export.outputFileType = .mp4
            export.fileLengthLimit = Int64(maxBytes)
            export.metadata = []
            export.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: target)
            if #available(iOS 18, *) {
                do { try await export.export(to: target, as: .mp4) }
                catch { try Task.checkCancellation(); continue }
            } else {
                await export.export()
            }
            try Task.checkCancellation()
            guard export.status == .completed else { continue }
            let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > 0 && size <= maxBytes {
                let exportedDuration = try await AVURLAsset(url: target).load(.duration).seconds
                guard exportedDuration.isFinite, abs(exportedDuration - duration) <= min(0.25, duration * 0.02) else { continue }
                let filename = "Video-" + UUID().uuidString.prefix(6) + ".mp4"
                if uploadMax != nil, size > UploadFiles.inlineLimit {
                    return try UploadFiles.adopt(target, filename: filename, mime: "video/mp4", move: true)
                }
                return SendAttachment(mime: "video/mp4", filename: filename,
                                      base64: try Data(contentsOf: target).base64EncodedString())
            }
        }
        throw Failure.tooLarge
    }

    static func frames(from url: URL, count: Int) async throws -> [SendAttachment] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, count > 0 else { throw Failure.noFrames }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = generator.requestedTimeToleranceAfter
        let fractions = count == 1 ? [0.5] : (count == 2 ? [0.2, 0.8] : [0.1, 0.5, 0.9])
        var frames: [SendAttachment] = []
        var previousTime: CMTime?
        for fraction in fractions {
            try Task.checkCancellation()
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            let sample = try await generator.image(at: time)
            guard sample.actualTime != previousTime else { continue }
            previousTime = sample.actualTime
            let name = "Frame-" + String(format: "%.2fs", sample.actualTime.seconds)
            frames.append(try jpeg(UIImage(cgImage: sample.image), name: name))
        }
        guard !frames.isEmpty else { throw Failure.noFrames }
        return frames
    }
}


/// T3-style long pastes: a paste this big leaves the composer and rides as a removable chip,
/// sent with the next message instead of flooding the text field.
enum PasteSplit {
    static func collapse(_ pasted: String) -> Bool { pasted.count >= 2_000 }
}

struct CameraPhoto: UIViewControllerRepresentable {
    let picked: (UIImage?) -> Void
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let picked: (UIImage?) -> Void
        init(_ picked: @escaping (UIImage?) -> Void) { self.picked = picked }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picked(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picked(info[.originalImage] as? UIImage)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(picked) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.mediaTypes = [UTType.image.identifier]
        camera.delegate = context.coordinator
        return camera
    }
    func updateUIViewController(_ view: UIImagePickerController, context: Context) {}
}

struct AttachmentChip: View {
    let attachment: SendAttachment
    /// Opens the full image for review. Only images get a preview; other types ignore it.
    let preview: () -> Void
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    private var isImage: Bool { attachment.mime.hasPrefix("image/") }
    private var isVideo: Bool { attachment.mime.hasPrefix("video/") }
    private var isAudio: Bool { attachment.mime.hasPrefix("audio/") }

    private var label: String {
        if isVideo { return "Video" }
        if isAudio { return "Audio" }
        if !isImage { return "File" }
        if attachment.filename.hasPrefix("Pasted image") { return "Pasted image" }
        let pieces = attachment.filename.split(separator: "-")
        return pieces.count >= 3 && pieces[0] == "Frame" ? "Frame at " + pieces[1] : "Photo"
    }

    private var detail: String {
        attachment.filename + " · " + ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
    }

    private var icon: String {
        if isVideo { return "film" }
        if isAudio { return "waveform" }
        return "doc"
    }

    /// The source format when the sent bytes are a converted JPEG (a GIF's first frame, a HEIC
    /// original): named in the corner of the preview so the type is never a surprise.
    private var typeBadge: String? {
        guard attachment.mime == "image/jpeg" else { return nil }
        switch (attachment.sourceFormat ?? (attachment.filename as NSString).pathExtension).lowercased() {
        case "gif": return "GIF · 1st frame"
        case "png": return "PNG"
        case "webp": return "WebP"
        case "heic": return "HEIC"
        case "", "jpg", "jpeg": return nil
        case let other: return other.uppercased()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isImage {
                Button(action: preview) { content }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview " + attachment.filename)
            } else {
                content.accessibilityElement(children: .combine)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(HMDesign.text2)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove " + attachment.filename)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .task(id: attachment) {
            thumbnail = nil
            guard isImage else { return }
            let attachment = attachment
            thumbnail = await Task.detached(priority: .utility) { ChatMedia.previewImage(attachment, pixels: 96) }.value
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 46, height: 40).clipped()
                    .overlay(alignment: .bottomLeading) {
                        if let typeBadge {
                            Text(typeBadge).font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
            } else {
                Image(systemName: icon).frame(width: 46, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(HMDesign.text2).lineLimit(1)
            }
            .padding(.trailing, 2)
        }
        .contentShape(Rectangle())
    }
}

/// A dismissible full-screen look at one decoded image. Tap the image or the close button.
struct FullImagePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Attached photo")
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(.white.opacity(0.9)).padding(16)
            }
            .accessibilityLabel("Close preview")
        }
        .onTapGesture { dismiss() }
    }
}
