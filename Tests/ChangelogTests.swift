import Foundation

/// What's new shows once per newer build, never again on its own, and a fresh install starts caught up.
@main
struct ChangelogTests {
    @MainActor static func main() {
        let d = UserDefaults(suiteName: "whatsnew-test-\(UUID().uuidString)")!
        // Fresh install, not signed in: nothing shows, and it's caught up.
        precondition(!WhatsNew.takeDue(build: 43, defaults: d))
        precondition(!WhatsNew.takeDue(build: 43, defaults: d), "never twice")
        // A newer build with its own list shows exactly once.
        let top = WhatsNew.releases.first!.build
        precondition(WhatsNew.takeDue(build: top + 0, defaults: d) == (top > 43))
        d.set(39, forKey: WhatsNew.seenKey)
        precondition(WhatsNew.takeDue(build: 42, defaults: d), "newer list shows")
        for _ in 0..<5 { precondition(!WhatsNew.takeDue(build: 42, defaults: d), "backing out of a chat must not reopen it") }
        // A build without its own list uses the newest before it, and doesn't reshow it.
        precondition(WhatsNew.newest(forBuild: 99) == top)
        precondition(!WhatsNew.takeDue(build: 42, defaults: d))
        // Upgrading from before the changelog, already signed in: one look.
        let u = UserDefaults(suiteName: "whatsnew-test-\(UUID().uuidString)")!
        u.set("https://mac.example", forKey: "server")
        precondition(WhatsNew.takeDue(build: 43, defaults: u))
        precondition(!WhatsNew.takeDue(build: 43, defaults: u))
        // Releases newest first, one short line each.
        precondition(WhatsNew.releases.map(\.build) == WhatsNew.releases.map(\.build).sorted(by: >))
        precondition(WhatsNew.releases.allSatisfy { $0.items.allSatisfy { $0.text.count <= 64 } }, "keep each line short")
        print("What's new shows once per build, never on back-navigation, changelog ordered and short")
    }
}
