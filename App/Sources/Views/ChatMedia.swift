import AVFoundation
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos may supply an iCloud-backed file. Copy it inside the transfer callback before its URL expires.
struct PickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { file in
            try Self(url: MediaStaging.stage(file.file))
        }
    }
}

enum ChatMedia {
    enum Failure: LocalizedError {
        case unreadable, tooLarge, noFrames
        var errorDescription: String? {
            switch self {
            case .unreadable: "This media could not be opened. Try another file."
            case .tooLarge: "This file is too large to send. Choose a smaller photo or a shorter clip."
            case .noFrames: "No frames could be read from this video."
            }
        }
    }

    static func image(at url: URL) throws -> SendAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = thumbnail(source, pixels: 1600) else { throw Failure.unreadable }
        return try jpeg(UIImage(cgImage: thumbnail), name: "Photo")
    }

    static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: UIImage, name: String) throws -> SendAttachment {
        for quality in [0.82, 0.65, 0.48, 0.32] {
            if let bytes = image.jpegData(compressionQuality: quality), bytes.count <= 1024 * 1024 {
                return SendAttachment(mime: "image/jpeg", filename: name + "-" + UUID().uuidString.prefix(6) + ".jpg",
                                      base64: bytes.base64EncodedString())
            }
        }
        throw Failure.tooLarge
    }

    static func clip(from url: URL, maxBytes: Int) async throws -> SendAttachment {
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
                return SendAttachment(mime: "video/mp4", filename: "Video-" + UUID().uuidString.prefix(6) + ".mp4",
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
    let remove: () -> Void
    @State private var thumbnail: UIImage?
    private var label: String {
        if attachment.mime.hasPrefix("video/") { return "Video" }
        let pieces = attachment.filename.split(separator: "-")
        return pieces.count >= 3 && pieces[0] == "Frame" ? "Frame at " + pieces[1] : "Photo"
    }
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 46, height: 38).clipped()
                } else { Image(systemName: "film") }
                if label != "Photo" { Text(label).font(.caption2) }
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityLabel("Remove " + label)
        .task(id: attachment.filename) {
            guard attachment.mime.hasPrefix("image/"), let data = Data(base64Encoded: attachment.base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let pixel = ChatMedia.thumbnail(source, pixels: 96) else { return }
            thumbnail = UIImage(cgImage: pixel)
        }
    }
}
