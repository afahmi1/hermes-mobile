import Foundation

@main struct SendRecoveryTests {
    @MainActor static func main() async throws {
        let account = UUID().uuidString
        let scope = "default|session/disconnected"
        let key = account + "|outbox/disconnected"
        let disk = ComposerDisk.shared
        defer { disk.forget(account) }
        let submission = UUID(), draft = UUID()
        let file = SendAttachment(mime: "text/plain", filename: "words.txt", base64: "aGk=")
        let paste = PastedText(text: "saved paste")
        let send = PendingSend(id: submission, text: "first", choice: .botDefault, project: nil,
                               attachments: [file], composerText: "first", composerPastes: [paste], returningToComposer: true)
        try await InboxDisk.shared.stage(send, key: key)
        try disk.write(Data("newer unsent message".utf8), part: .text, account: account, scope: scope, id: draft)
        let snapshot = try disk.restoreSend(send, account: account, scope: scope, id: draft)
        precondition(snapshot.text == "newer unsent message")
        precondition(snapshot.pastes.map(\.text) == ["first", "saved paste"] && snapshot.media == [file])
        // Simulate suspension between the transaction and acknowledging the outbox. Edits survive replay.
        try disk.write(Data("edited after return".utf8), part: .text, account: account, scope: scope, id: draft)
        let recovered = try await InboxDisk.shared.pending(key)!
        precondition(recovered.returningToComposer == true)
        let retry = try disk.restoreSend(recovered, account: account, scope: scope, id: draft)
        precondition(retry.text == "edited after return" && retry.pastes == snapshot.pastes && retry.media == [file])
        try await InboxDisk.shared.acknowledge(submission, key: key)
        let pending = try await InboxDisk.shared.pending(key)
        precondition(pending == nil)
        print("Recovered send, newer draft, pasted text and file survive an interrupted return exactly once")
    }
}
