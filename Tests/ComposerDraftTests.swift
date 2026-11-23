import Foundation

@main
struct ComposerDraftTests {
    @MainActor static func main() throws {
        let account = GatewayLogin(server: URL(string: "https://draft-test.invalid")!, token: "temporary-fixture")
        API.activate(account)
        let app = AppModel()
        let disk = ComposerDisk.shared
        let key = app.inboxAccount!
        let existing = ChatRef(profile: "main", sessionId: "chat-123")
        let new = ChatRef(profile: "main", sessionId: nil)
        let image = SendAttachment(mime: "image/jpeg", filename: "swatch.jpg", base64: "YWJj")
        if CommandLine.arguments.contains("--write") {
            disk.forget(key)
            let a = app.chat(for: existing)
            a.draft = "finish this later"
            a.absorbPaste("long block")
            a.draftAttachments = [image]
            a.pastedTexts[0].text = "edited block"
            let pending = app.chat(for: new)
            pending.draft = "unsent first message"
            precondition(app.chat(for: ChatRef(profile: "main", sessionId: nil)) === pending)
            precondition(a.error == nil && pending.error == nil, [a.error, pending.error].compactMap { $0 }.joined(separator: " | "))
            print("Saved composer to protected storage")
            return
        }
        let a = app.chat(for: existing)
        precondition(a.draft == "finish this later" && a.pastedTexts.map(\.text) == ["edited block"] && a.draftAttachments == [image])
        precondition(a.combinedDraft == "finish this later\n\nedited block")
        weak var evictable: ChatModel?
        do {
            let another = app.chat(for: ChatRef(profile: "main", sessionId: "evict-me"))
            another.draft = "saved before eviction"
            evictable = another
        }
        for index in 0..<20 { _ = app.chat(for: ChatRef(profile: "main", sessionId: "cache-\(index)")) }
        precondition(evictable == nil)
        precondition(app.chat(for: ChatRef(profile: "main", sessionId: "evict-me")).draft == "saved before eviction")
        let first = app.chat(for: new)
        precondition(first.draft == "unsent first message")
        precondition(app.chat(for: ChatRef(profile: "other", sessionId: "chat-123")).draft.isEmpty)
        let snapshot = try disk.read(key, scope: "main|new")
        try disk.move(key, from: "main|new", to: "main|session/created", id: snapshot.id!)
        let moved = try disk.read(key, scope: "main|session/created")
        let empty = try disk.read(key, scope: "main|new")
        precondition(moved.text == "unsent first message" && empty.text.isEmpty)
        a.draft = ""
        let remaining = try disk.read(key, scope: "main|session/chat-123")
        precondition(remaining.text.isEmpty && remaining.pastes.count == 1 && remaining.media == [image])
        API.activate(GatewayLogin(server: URL(string: "https://other-draft-test.invalid")!, token: "temporary-fixture"))
        precondition(AppModel().chat(for: existing).combinedDraft.isEmpty)
        a.draft = "stale view"
        let stale = try disk.read(key, scope: "main|session/chat-123")
        precondition(stale.text.isEmpty)
        disk.forget(key)
        let cleared = try disk.read(key, scope: "main|session/chat-123")
        precondition(cleared.pastes.isEmpty && cleared.media.isEmpty)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesComposer")
        let recoveryHost = AppModel()
        let recoveryKey = recoveryHost.inboxAccount!
        let directory = root.appendingPathComponent(recoveryKey)
        disk.forget(recoveryKey)
        // A file in place of our synthetic account directory makes the first write fail.
        try Data().write(to: directory)
        let retry = recoveryHost.chat(for: existing)
        retry.draft = "keep this edit"
        precondition(!retry.canEvictDraft && retry.error != nil)
        try FileManager.default.removeItem(at: directory)
        recoveryHost.retryDraftStorage()
        let recovered = try disk.read(recoveryKey, scope: "main|session/chat-123")
        precondition(retry.canEvictDraft && retry.error == nil && recovered.text == "keep this edit")
        disk.forget(recoveryKey)
        print("Verified cold-process composer restoration, draft adoption, isolation, selective clearing and sign-out cleanup")
    }
}
