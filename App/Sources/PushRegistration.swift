import UIKit

/// Keeps the Mac bridge informed of this install's APNs token and of whether the app is in the foreground.
///
/// The bridge pushes a reply, approval or failure only when the phone is no longer watching the run, and only
/// if an APNs key is configured on the Mac. Everything here is best effort: a failure leaves local
/// notifications exactly as they were.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Debug builds are signed with the development push entitlement, everything else with production.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private(set) var token: String?
    /// The Mac said it can send pushes (it has an APNs key). Until then, replies after the app sleeps can't reach you.
    private(set) var macCanPush = false
    private var sent: String?  // "account|token" last accepted by the bridge
    private var away = false

    func received(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        sync()
    }

    /// Registers the token with the gateway that is signed in now. Repeats are free: only a new token or a
    /// different gateway sends a request.
    func sync() {
        guard let token, let account = API.shared.accountID, sent != account + "|" + token else { return }
        let api = API.shared
        Task {
            do {
                let enabled = try await api.registerPush(token: token, environment: Self.environment, account: account)
                if API.shared === api { sent = account + "|" + token; macCanPush = enabled; ReplyNotifier.shared.macCanPush = enabled }
            } catch {}
        }
    }

    func presence(away now: Bool) {
        guard API.shared.isSignedIn else { return }
        away = now
        let api = API.shared
        // The request has to leave before iOS suspends the app. Sent every time: a launch's in-memory flag
        // starts false even when the bridge still thinks this phone is away, and a failed send must be retried.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Push presence") {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task {
            do { try await api.pushPresence(away: now) } catch { await MainActor.run { self.away = !now } }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
