import Foundation

@main
struct ChatOwnershipTests {
    @MainActor static func main() async throws {
        let ref = ChatRef(profile: "default", sessionId: "same-session")
        let oldGateway = AppModel()
        let currentGateway = AppModel()
        let old = oldGateway.chat(for: ref)
        let current = currentGateway.chat(for: ref)
        currentGateway.adopt(old, draftKey: ref.id)
        precondition(currentGateway.chat(for: ref) === current)
        currentGateway.adopt(current, draftKey: ref.id)
        precondition(currentGateway.chat(for: ref) === current)
        let server = URL(string: "https://example.invalid")!
        API.activate(GatewayLogin(server: server, token: "fixture-one"))
        let host = AppModel()
        let retained = ChatModel(profile: "default", sessionId: "same-session", app: host)
        API.activate(GatewayLogin(server: server, token: "fixture-two"))
        let key = host.inboxKey(profile: "default", filter: "transcript/same-session")!
        let row = try JSONDecoder().decode(StoredMessage.self, from: Data(#"{"id":1,"role":"assistant","content":"other-account-canary"}"#.utf8))
        await InboxDisk.shared.saveTranscript([row], at: Date(), key: key, hasOlder: false)
        let proof = await InboxDisk.shared.transcript(key)
        precondition(proof?.messages.first?.content == "other-account-canary")
        await retained.load(quiet: true, resumeLive: false)
        precondition(retained.cachedAt == nil && !retained.items.contains { $0.text.contains("other-account-canary") })
        await InboxDisk.shared.forget(host.inboxAccount!)
        API.activate(nil)
        print("Late foreign completion cannot replace the active conversation")
    }
}
