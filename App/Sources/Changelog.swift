import Foundation

/// One build's changes. Keyed by build number (CFBundleVersion): every TestFlight build is "1.0".
struct WhatsNewRelease: Identifiable, Equatable {
    let build: Int
    let items: [WhatsNewItem]
    var id: Int { build }

    /// Stable across process restarts; a changed list in a rebuild gets one new showing.
    var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for item in items {
            for byte in (item.symbol + "\u{1F}" + item.text + "\u{1E}").utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        return "\(build)#" + String(hash, radix: 16)
    }
}

/// A change: an SF Symbol and one short line.
struct WhatsNewItem: Identifiable, Equatable {
    let symbol: String
    let text: String
    var id: String { text }
}

/// The changelog. Shows once, over the chat list, on the first open of a newer build; always reachable from Settings.
enum WhatsNew {
    static let seenKey = "hm.whatsNew.seenBuild"
    private static let fingerprintKey = "hm.whatsNew.seenFingerprint"

    /// Newest first. Add a release at the top for each build that changes something you'd notice.
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(build: 44, items: [
            WhatsNewItem(symbol: "moon.stars", text: "Thermocline Dark gains deeper blues and a soft glow"),
            WhatsNewItem(symbol: "circle.grid.2x2", text: "Colored bot discs and badges are easier to tell apart"),
            WhatsNewItem(symbol: "bell.badge", text: "More reliable reply alerts when your iPhone sleeps"),
        ]),
        WhatsNewRelease(build: 43, items: [
            WhatsNewItem(symbol: "list.bullet.rectangle", text: "What's new is a real changelog, shown once per build"),
            WhatsNewItem(symbol: "circle.hexagongrid", text: "The colorful orb is back: Appearance › Thinking › Color orb"),
            WhatsNewItem(symbol: "bell.slash", text: "\"Still working\" shows once per reply, silently"),
        ]),
        WhatsNewRelease(build: 42, items: [
            WhatsNewItem(symbol: "exclamationmark.triangle", text: "Header says when a fallback model answered"),
            WhatsNewItem(symbol: "arrow.triangle.branch", text: "See each bot's fallback models, tagged Plan, Free or Paid"),
            WhatsNewItem(symbol: "clock", text: "Model sheet shows who wrote the last reply, and when"),
        ]),
        WhatsNewRelease(build: 41, items: [
            WhatsNewItem(symbol: "text.quote", text: "Reply to several messages in one"),
            WhatsNewItem(symbol: "dollarsign.circle", text: "Cost per model: paid vs covered by your plan"),
            WhatsNewItem(symbol: "circle.grid.2x2", text: "Bot icons in each bot's own color"),
            WhatsNewItem(symbol: "bell.badge", text: "Notifications for other chats while the app is open"),
            WhatsNewItem(symbol: "arrowshape.turn.up.left", text: "Reply straight from a notification"),
        ]),
        WhatsNewRelease(build: 40, items: [
            WhatsNewItem(symbol: "arrow.clockwise", text: "Retry a failed reply when limits reset"),
            WhatsNewItem(symbol: "sparkles", text: "Playful thinking lines; tap to read the thinking"),
            WhatsNewItem(symbol: "stopwatch", text: "Timestamps on every tool step"),
            WhatsNewItem(symbol: "moon", text: "Ash dark canvas for Thermocline"),
        ]),
        WhatsNewRelease(build: 39, items: [
            WhatsNewItem(symbol: "photo.on.rectangle", text: "Images show where Hermes mentions them"),
            WhatsNewItem(symbol: "text.cursor", text: "Select text across a whole reply"),
            WhatsNewItem(symbol: "person.2", text: "Tap a subagent to see what it's doing"),
            WhatsNewItem(symbol: "arrow.uturn.backward", text: "Take a message back, images included"),
            WhatsNewItem(symbol: "hand.point.left", text: "Edge swipe goes back, always"),
        ]),
    ]

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// The newest list this build has (a build with no list of its own shows the one before).
    private static func release(forBuild build: Int, in releases: [WhatsNewRelease]) -> WhatsNewRelease? {
        releases.filter { $0.build <= build }.max { $0.build < $1.build }
    }

    static func newest(forBuild build: Int, in releases: [WhatsNewRelease] = releases) -> Int {
        release(forBuild: build, in: releases)?.build ?? 0
    }

    /// Marks seen here, not at dismiss, so returning to Chats can't reopen it.
    static func takeDue(build: Int = currentBuild, defaults: UserDefaults = .standard) -> Bool {
        guard let release = release(forBuild: build, in: releases) else { return false }
        return takeDue(release, defaults: defaults)
    }

    static func takeDue(_ release: WhatsNewRelease, defaults: UserDefaults) -> Bool {
        let seen = defaults.object(forKey: seenKey) as? Int
        if let seen, seen > release.build { return false }
        let fingerprint = release.fingerprint
        if seen == release.build {
            let previous = defaults.string(forKey: fingerprintKey)
            guard fingerprint != previous else { return false }
            defaults.set(fingerprint, forKey: fingerprintKey)
            // A build already seen before fingerprints were stored stays caught up.
            return previous != nil
        }
        defaults.set(release.build, forKey: seenKey)
        defaults.set(fingerprint, forKey: fingerprintKey)
        // A fresh install starts caught up. Signed-in users upgrading from earlier releases get one look.
        return seen != nil || defaults.string(forKey: "server") != nil
    }
}
