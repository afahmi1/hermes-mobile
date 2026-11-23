import Foundation

@main
struct MediaStagingTests {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try MediaStaging.stage(source, in: dir)
        try Data([4]).write(to: source)
        let frozen = try Data(contentsOf: snapshot)
        precondition(frozen == Data([1, 2, 3]))
        let link = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try MediaStaging.stage(link, in: dir); fatalError("accepted symlink") }
        catch MediaStaging.Failure.unreadable {}
        try Data().write(to: source)
        do { _ = try MediaStaging.stage(source, in: dir); fatalError("accepted empty input") }
        catch MediaStaging.Failure.unreadable {}
        let limit = 256 * 1024 * 1024
        let reserve = 64 * 1024 * 1024
        try MediaStaging.checkCopy(size: limit, available: limit + reserve)
        do { try MediaStaging.checkCopy(size: limit + 1, available: Int.max); fatalError("accepted large copy") }
        catch MediaStaging.Failure.copyTooLarge {}
        for capacity in [nil, limit + reserve - 1] {
            do { try MediaStaging.checkCopy(size: limit, available: capacity); fatalError("accepted insufficient space") }
            catch MediaStaging.Failure.lowSpace {}
        }
        print("Media staging snapshot, source validation, and storage boundaries passed")
    }
}
