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
        API.activate(GatewayLogin(server: server, token: UUID().uuidString))
        let host = AppModel()
        let retained = ChatModel(profile: "default", sessionId: "same-session", app: host)
        API.activate(GatewayLogin(server: server, token: UUID().uuidString))
        let key = host.inboxKey(profile: "default", filter: "transcript/same-session")!
        let row = try JSONDecoder().decode(StoredMessage.self, from: Data(#"{"id":1,"role":"assistant","content":"other-account-canary"}"#.utf8))
        await InboxDisk.shared.saveTranscript([row], at: Date(), key: key, hasOlder: false)
        let proof = await InboxDisk.shared.transcript(key)
        precondition(proof?.messages.first?.content == "other-account-canary")
        await retained.load(quiet: true, resumeLive: false)
        precondition(retained.cachedAt == nil && !retained.items.contains { $0.text.contains("other-account-canary") })
        await InboxDisk.shared.forget(host.inboxAccount!)
        API.activate(nil)
        let suite = "hermes-notification-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var keys = [String: String]()
        let vault = SavedGateways(defaults: defaults, read: { keys[$0] }, write: { keys[$0] = $1; return true },
                                 remove: { keys.removeValue(forKey: $0); return true })
        let first = GatewayLogin(server: server, token: "first")
        let second = GatewayLogin(server: URL(string: "https://other.invalid")!, token: "second")
        precondition(vault.remember(first) && vault.remember(second))
        API.activate(second)
        let destinationHost = AppModel(accounts: vault)
        let firstTap = ReplyDestination(account: API.accountID(for: first), profile: "default", session: "same")
        let secondTap = ReplyDestination(account: API.accountID(for: second), profile: "default", session: "same")
        precondition(firstTap.identifier != secondTap.identifier)
        precondition(firstTap.open(in: destinationHost) && destinationHost.inboxAccount == firstTap.account)
        precondition(destinationHost.inboxPath == [ChatRef(profile: "default", sessionId: "same")])
        _ = vault.forget(second.server)
        precondition(!secondTap.open(in: destinationHost) && destinationHost.inboxAccount == firstTap.account)
        API.activate(nil)
        print("Notification taps open their original saved gateway and reject a forgotten account")
        print("Late foreign completion cannot replace the active conversation")
    }
}
