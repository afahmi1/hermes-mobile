import UIKit

/// Keeps the Mac bridge informed of this install's APNs token and of whether the app is in the foreground.
///
/// The bridge pushes a reply, approval, question or failure only when the phone is no longer watching the run,
/// and only if an APNs key is configured on the Mac. Everything here is best effort: a failure leaves local
/// notifications exactly as they were, and a report that didn't arrive is sent again at the next change.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Debug builds are signed with the development push entitlement, everything else with production. (The bridge
    /// also tries the other environment once if APNs calls the token bad, so a mismatched signing still works.)
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// The APNs topic is this app's bundle ID. Sending it means the bridge never has to be told which build
    /// (TestFlight, a local build under another team) is on the phone.
    static var topic: String? { Bundle.main.bundleIdentifier }

    struct Presence: Equatable {
        var away: Bool
        /// Away but still holding background time to follow its runs (the bridge waits out a grace window).
        var following: Bool
        static let here = Presence(away: false, following: true)
    }

    private var token: String?
    private var sent: String?     // "account|token" last accepted by the bridge
    private var sending: String?  // the same, while that request is in flight
    private var wanted = Presence.here
    /// What the bridge last confirmed, per grant. Nil after a launch: the bridge may still hold an "away" from a run
    /// before the app was killed, so the first report always goes out.
    private var confirmed: (account: String, presence: Presence)?
    private var reporting = false

    func received(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        sync()
    }

    /// Registers the token with the gateway that is signed in now. Repeats are free: only a new token or a
    /// different gateway sends a request, and never two at once. Also brings a new grant up to date on presence.
    func sync() {
        defer { report() }
        guard let token, let account = API.shared.accountID else { return }
        let key = account + "|" + token
        guard sent != key, sending != key else { return }
        sending = key
        let api = API.shared
        Task {
            let ok = (try? await api.registerPush(token: token, environment: Self.environment, topic: Self.topic,
                                                  account: account)) != nil
            if sending == key { sending = nil }
            if ok, API.shared === api { sent = key }
        }
    }

    /// The app left the foreground (`following`: it holds background time for live runs) or came back.
    func presence(away: Bool, following: Bool = true) {
        wanted = away ? Presence(away: true, following: following) : .here
        report()
    }

    /// The app's background time is ending (iOS is about to suspend it, or its last run settled): from now on
    /// the bridge announces what happens, without waiting out its grace window.
    func stoppedFollowing() {
        guard wanted.away else { return }
        presence(away: true, following: false)
    }

    /// One report at a time, in order, until the bridge has the latest. A failed one is retried at the next change.
    private func report() {
        guard !reporting, let account = API.shared.accountID else { return }
        let target = wanted
        if let confirmed, confirmed.account == account, confirmed.presence == target { return }
        reporting = true
        let api = API.shared
        let time = BackgroundTime("Push presence")  // the request has to leave before iOS suspends the app
        Task {
            let ok = (try? await api.pushPresence(away: target.away, following: target.following)) != nil
            reporting = false
            if ok, API.shared === api { confirmed = (account, target) }
            time.end()
            if ok { report() }  // the app may have moved on while this was in flight
        }
    }
}

/// A short stretch of background time that ends exactly once, whether the work finishes or iOS runs out first.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { end() }  // iOS calls this on the main thread
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
