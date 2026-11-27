import Foundation

/// Covers migration from the legacy version key and presentation of a changed list in the same build.
@main
struct WhatsNewTests {
    static func main() {
        let suite = "hm.whatsNew.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let a = WhatsNewRelease(build: 44, items: [WhatsNewItem(symbol: "a", text: "one")])
        let b = WhatsNewRelease(build: 44, items: a.items + [WhatsNewItem(symbol: "b", text: "two")])

        d.set("https://mac.example", forKey: "server")
        d.set("1.0", forKey: "hm.whatsNew.seen")
        precondition(WhatsNew.takeDue(a, defaults: d), "an upgrade from the old version key shows once")
        precondition(!WhatsNew.takeDue(a, defaults: d), "presentation marks seen before dismissal")
        precondition(WhatsNew.takeDue(b, defaults: d), "a list that gained items shows once more")
        precondition(!WhatsNew.takeDue(b, defaults: d))

        let older = WhatsNewRelease(build: 43, items: a.items)
        precondition(!WhatsNew.takeDue(older, defaults: d), "downgrading doesn't show an older list")
        precondition(!WhatsNew.takeDue(b, defaults: d), "downgrading doesn't reset the fingerprint")
        precondition(a.fingerprint == WhatsNewRelease(build: a.build, items: a.items).fingerprint)
        precondition(a.fingerprint != b.fingerprint)

        d.removePersistentDomain(forName: suite)
        d.set(a.build, forKey: WhatsNew.seenKey)
        precondition(!WhatsNew.takeDue(a, defaults: d), "a build already seen without a fingerprint stays seen")
        precondition(WhatsNew.takeDue(b, defaults: d), "content changes are detected after migrating the seen build")
        print("WhatsNew: ok")
    }
}
