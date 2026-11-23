import Darwin
import Foundation

enum MediaStaging {
    enum Failure: LocalizedError {
        case unreadable, copyTooLarge, lowSpace
        var errorDescription: String? {
            switch self {
            case .unreadable: "This file could not be imported. Try selecting it again."
            case .copyTooLarge: "Trim this video or choose a smaller file. This source requires a full temporary copy."
            case .lowSpace: "There isn’t enough space to prepare this attachment. Free some space or select a smaller file."
            }
        }
    }

    static func stage(_ source: URL, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var info = stat()
        guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw Failure.unreadable
        }
        let size = Int(info.st_size)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        do {
            // An APFS clone keeps a private snapshot without writing the original a second time.
            if clonefile(source.path, target.path, 0) != 0 {
                let reason = errno
                guard [ENOTSUP, EXDEV, EPERM, EACCES, EINVAL].contains(reason) else {
                    if reason == ENOSPC { throw Failure.lowSpace }
                    throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
                }
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
                try checkCopy(size: size, available: capacity)
                try FileManager.default.copyItem(at: source, to: target)
            }
            try Task.checkCancellation()
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    static func checkCopy(size: Int, available: Int?) throws {
        guard size <= 256 * 1024 * 1024 else { throw Failure.copyTooLarge }
        guard let available, available >= size + 64 * 1024 * 1024 else { throw Failure.lowSpace }
    }
}
