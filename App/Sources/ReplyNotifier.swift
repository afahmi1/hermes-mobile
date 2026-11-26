import Foundation
import CryptoKit

/// The grant fingerprint scopes both notification grouping and tap navigation across gateways.
struct ReplyDestination: Equatable {
    let account: String
    let profile: String
    let session: String

    var identifier: String { [account, profile, session].map { "\($0.utf8.count):\($0)" }.joined() }

    /// One notification per chat, whether it arrives locally or through APNs. `apns-collapse-id` allows 64 bytes,
    /// so the bridge and the phone both use a SHA-256 prefix of `identifier`: the local request and the remote
    /// push share it, and the later one replaces the earlier. Mirrors `collapse_id` in Bridge/bridge_push.py.
    var collapseID: String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    @MainActor func open(in app: AppModel) -> Bool {
        if app.inboxAccount != account {
            guard let server = app.savedServer(forAccount: account), (try? app.switchGateway(server)) != nil else { return false }
        }
        guard app.inboxAccount == account else { return false }
        app.inboxPath = [ChatRef(profile: profile, sessionId: session)]
        return true
    }
}

#if canImport(UIKit)
import UIKit
import UserNotifications
import Observation

/// Tells the person a reply landed, or that Hermes is waiting on an approval, after they left the app.
///
/// Two paths, one notification per chat:
/// - Local, from here: the phone only knows about an event while it is still following the run, and iOS
///   allows roughly thirty seconds of that after the app leaves the foreground. This covers the common
///   case of sending and switching away.
/// - APNs push, from the bridge: it keeps following every run on the Mac and pushes when the phone is no
///   longer watching (see `PushRegistration` and Bridge/bridge_push.py). Without an APNs key on the Mac
///   this path is off and a reply that takes longer than the grace window is shown on return.
/// Both use `ReplyDestination.collapseID` as the notification identifier, so they replace each other, and
/// the same generic text: reply excerpts, commands and errors never leave the Mac in a notification.
@MainActor @Observable
final class ReplyNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotifier()
    var destination: ReplyDestination?

    private var grace: UIBackgroundTaskIdentifier = .invalid
    private(set) var away = false
    private var asked = false

    func install() { UNUserNotificationCenter.current().delegate = self }

    /// Ask at the first send, when the reason is obvious, and never again.
    func askOnce() {
        guard !asked else { return }
        asked = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Already allowed on an earlier launch: ask APNs for this install's token again (it can change).
    func registerIfAuthorized() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func left(liveRuns: Bool) {
        away = true
        guard liveRuns, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "Follow reply") { [weak self] in
            Task { @MainActor in self?.endGrace() }
        }
    }

    func returned() {
        away = false
        endGrace()

    }

    /// Give the background time back as soon as nothing is running.
    func settled(liveRuns: Bool) { if !liveRuns { endGrace() } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    enum Event { case reply, approval, failure }

    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?) {
        guard away, let account, let session else { return }
        let content = UNMutableNotificationContent()
        switch event {
        case .reply: content.title = bot
        case .approval: content.title = bot + " needs your approval"
        case .failure: content.title = bot + " could not finish"
        }
        // Commands, errors and reply excerpts can hold private data on a locked device.
        switch event {
        case .reply: content.body = "Your reply is ready."
        case .approval: content.body = "Open the chat to review the request."
        case .failure: content.body = "Open the chat for details."
        }
        content.sound = .default
        content.threadIdentifier = ReplyDestination(account: account, profile: profile, session: session).identifier
        content.userInfo = ["account": account, "profile": profile, "session": session]

        // One notification per chat: a newer event replaces the older one instead of stacking.
        let request = UNNotificationRequest(identifier: ReplyDestination(account: account, profile: profile, session: session).collapseID,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["account"] as? String, let profile = info["profile"] as? String,
              let session = info["session"] as? String else { return }
        await MainActor.run {
            self.destination = ReplyDestination(account: account, profile: profile, session: session)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []  // the chat on screen already shows it
    }
}
#else
import Foundation

/// The model sources also compile into macOS test executables, where there is nothing to notify.
@MainActor
final class ReplyNotifier {
    static let shared = ReplyNotifier()
    enum Event { case reply, approval, failure }
    var away = false
    func install() {}
    func askOnce() {}
    func registerIfAuthorized() {}
    func left(liveRuns: Bool) { away = true }
    func returned() { away = false }
    func settled(liveRuns: Bool) {}
    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?) {}
}
#endif
