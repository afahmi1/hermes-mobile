import Foundation

/// Time actual ChatModel updates with an empty draft and with one 4 MiB file staged.
/// The file stays attached for the whole run. Times exclude picking it and sending it.
@main
struct ComposerEdits {
    @MainActor static func main() throws {
        let login = GatewayLogin(server: URL(string: "https://composer-benchmark.invalid")!, token: UUID().uuidString)
        API.activate(login)
        let app = AppModel()
        let account = app.inboxAccount!
        defer { ComposerDisk.shared.forget(account) }
        let plain = app.chat(for: ChatRef(profile: "fixture", sessionId: "plain"))
        let loaded = app.chat(for: ChatRef(profile: "fixture", sessionId: "with-file"))
        let blob = Data(repeating: 65, count: 4 * 1024 * 1024)
        loaded.draftAttachments = [SendAttachment(mime: "application/octet-stream", filename: "fixture.bin", base64: blob.base64EncodedString())]
        var samples = [[Double](), [Double]()]
        for i in 0..<220 {
            let text = "Draft " + String(i)
            for index in (i % 2 == 0 ? [0, 1] : [1, 0]) {
                let chat = index == 0 ? plain : loaded
                let start = DispatchTime.now().uptimeNanoseconds
                chat.draft = text
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if i >= 20 { samples[index].append(elapsed) }
            }
        }
        let restored = try ComposerDisk.shared.read(account, scope: "fixture|session/with-file")
        precondition(restored.text == "Draft 219" && restored.media == loaded.draftAttachments)
        precondition(plain.error == nil && loaded.error == nil)
        for (label, values) in zip(["No file", "4 MiB file"], samples) {
            let sorted = values.sorted()
            print(String(format: "%@: median %.3f ms, p95 %.3f ms (%d edits)", label, sorted[99], sorted[189], sorted.count))
        }
    }
}
