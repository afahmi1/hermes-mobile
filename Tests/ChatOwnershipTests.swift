import Foundation

@main
struct ChatOwnershipTests {
    @MainActor static func main() {
        let ref = ChatRef(profile: "default", sessionId: "same-session")
        let oldGateway = AppModel()
        let currentGateway = AppModel()
        let old = oldGateway.chat(for: ref)
        let current = currentGateway.chat(for: ref)
        currentGateway.adopt(old, draftKey: ref.id)
        precondition(currentGateway.chat(for: ref) === current)
        currentGateway.adopt(current, draftKey: ref.id)
        precondition(currentGateway.chat(for: ref) === current)
        print("Late foreign completion cannot replace the active conversation")
    }
}
