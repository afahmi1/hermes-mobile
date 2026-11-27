import Foundation

/// One build's changes. Keyed by build number (CFBundleVersion): every TestFlight build is "1.0".
struct WhatsNewRelease: Identifiable, Equatable {
    let build: Int
    let items: [WhatsNewItem]
    var id: Int { build }
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

    /// Newest first. Add a release at the top for each build that changes something you'd notice.
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(build: 43, items: [
            WhatsNewItem(symbol: "list.bullet.rectangle", text: "What's new is a real changelog, shown once per build"),
            WhatsNewItem(symbol: "circle.hexagongrid", text: "The colorful orb is back: Appearance › Thinking › Color orb"),
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
    static func newest(forBuild build: Int, in releases: [WhatsNewRelease] = releases) -> Int {
        releases.map(\.build).filter { $0 <= build }.max() ?? 0
    }

    /// True once per newer list. Marks it seen right here, not on dismiss, so backing out of a chat
    /// (which re-appears the list) can never bring it back. A fresh install starts caught up.
    static func takeDue(build: Int = currentBuild, defaults: UserDefaults = .standard) -> Bool {
        let newest = newest(forBuild: build)
        guard newest > 0 else { return false }
        guard let seen = defaults.object(forKey: seenKey) as? Int else {
            defaults.set(newest, forKey: seenKey)
            // Signed in already: an upgrade from before the changelog existed gets one look.
            return defaults.string(forKey: "server") != nil
        }
        guard newest > seen else { return false }
        defaults.set(newest, forKey: seenKey)
        return true
    }
}
