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
    static func imageData(from item: PhotosPickerItem) async throws -> Data {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                throw ChatMedia.Failure.downloadFailed
            }
            return data
        } catch let failure as ChatMedia.Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatMedia.Failure.downloadFailed
        }
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

enum ChatMedia {
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
    static func image(from data: Data) throws -> SendAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = thumbnail(source, pixels: 2048) else { throw Failure.unreadable }
        return try jpeg(UIImage(cgImage: thumbnail), name: "Photo")
    }

    static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: UIImage, name: String) throws -> SendAttachment {
        for quality in [0.82, 0.62, 0.45, 0.3, 0.18] {
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
