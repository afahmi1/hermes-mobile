import Foundation

/// What's new shows once per list: never on a first run, once after an update, and again only when the list changes.
@main
struct WhatsNewTests {
    static func main() {
        let suite = "hm.whatsNew.tests"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let a = WhatsNewRelease(version: "1.0", items: [WhatsNewItem(symbol: "a", title: "A", detail: "one")])
        let b = WhatsNewRelease(version: "1.0", items: a.items + [WhatsNewItem(symbol: "b", title: "B", detail: "two")])

        // First run (no server yet): marked seen, not shown.
        precondition(WhatsNew.due(a, defaults: d) == nil, "first run shows nothing")
        precondition(WhatsNew.due(a, defaults: d) == nil, "and stays hidden")

        // Signed-in user who never saw it (the old bug left the key unset or at the bare version): shown once.
        d.removePersistentDomain(forName: suite)
        d.set("https://mac.example", forKey: "server")
        d.set("1.0", forKey: WhatsNew.seenKey)  // what older builds stored
        guard let shown = WhatsNew.due(a, defaults: d) else { preconditionFailure("an unseen list shows") }
        WhatsNew.markSeen(shown, defaults: d)
        precondition(WhatsNew.due(a, defaults: d) == nil, "after showing it never comes back")
        precondition(WhatsNew.due(a, defaults: d) == nil, "not on the next launch either")

        // Same marketing version, new items: shown once more, then quiet.
        precondition(WhatsNew.due(b, defaults: d) != nil, "a list that gained items shows again")
        WhatsNew.markSeen(b, defaults: d)
        precondition(WhatsNew.due(b, defaults: d) == nil)

        // The fingerprint is stable across launches (FNV, not hashValue) and content-sensitive.
        precondition(a.fingerprint == WhatsNewRelease(version: "1.0", items: a.items).fingerprint)
        precondition(a.fingerprint != b.fingerprint)
        d.removePersistentDomain(forName: suite)
        print("WhatsNew: ok")
    }
}
