import Foundation
import CryptoKit

/// The grant fingerprint scopes both notification grouping and tap navigation across gateways.
struct ReplyDestination: Equatable {
    let account: String
    let profile: String
    let session: String

    init(account: String, profile: String, session: String) {
        self.account = account
        self.profile = profile
        self.session = session
    }

    /// The chat a notification opens, from its userInfo: local notifications and the bridge's pushes carry the
    /// same three keys. A push without them (the bridge's `--push-test`) opens no chat.
    init?(userInfo: [AnyHashable: Any]) {
        guard let account = userInfo["account"] as? String, let profile = userInfo["profile"] as? String,
              let session = userInfo["session"] as? String, !account.isEmpty, !profile.isEmpty, !session.isEmpty
        else { return nil }
        self.init(account: account, profile: profile, session: session)
    }

    var identifier: String { [account, profile, session].map { "\($0.utf8.count):\($0)" }.joined() }

    /// One notification per chat, whether it arrives locally or through APNs. `apns-collapse-id` allows 64 bytes,
    /// so the bridge and the phone both use a SHA-256 prefix of `identifier`: the local request and the remote
    /// push share it, and the later one replaces the earlier. Mirrors `collapse_id` in Bridge/bridge_push.py.
    var collapseID: String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    var userInfo: [String: String] { ["account": account, "profile": profile, "session": session] }

    @MainActor func open(in app: AppModel) -> Bool {
        if app.inboxAccount != account {
            guard let server = app.savedServer(forAccount: account), (try? app.switchGateway(server)) != nil else { return false }
        }
        guard app.inboxAccount == account else { return false }
        app.inboxPath = [ChatRef(profile: profile, sessionId: session)]
        return true
    }
}

/// What happened in a chat that the person may want to hear about.
enum ReplyEvent {
    case reply, approval, question, failure

    /// The notification's title. The bridge's pushes use the same words (bridge_push.COPY).
    func title(bot: String, worked: TimeInterval? = nil) -> String {
        switch self {
        case .reply:
            let took = worked.flatMap { $0 >= 60 ? " · \(Int($0 / 60)) min" : nil } ?? ""
            return bot + (took.isEmpty ? "" : " finished" + took)
        case .approval: return bot + " needs your approval"
        case .question: return bot + " has a question"
        case .failure: return bot + " could not finish"
        }
    }

    /// The body when there is no one-line excerpt to show.
    var fallback: String {
        switch self {
        case .reply: "Your reply is ready."
        case .approval: "Open the chat to review the request."
        case .question: "Open the chat to answer."
        case .failure: "Open the chat for details."
        }
    }

    /// A question or an approval leaves the run going; the others end it.
    var endsRun: Bool { self == .reply || self == .failure }
}

/// Whether a notification that arrives while the app is open is shown. The chat on screen already shows its own
/// reply; anything else (another chat, a "Try again when limits reset" send, a reply from another device's chat)
/// would otherwise vanish without a trace, because the app suppressed every banner in the foreground.
enum ForegroundPolicy {
    static func shows(_ notification: ReplyDestination?, watching: ReplyDestination?) -> Bool {
        guard let notification, let watching else { return true }
        return notification != watching
    }
}

#if canImport(UIKit)
import UIKit
import UserNotifications
import Observation

/// Tells the person a reply landed, or that Hermes is waiting on an approval or a question, after they left the app.
///
/// Two paths, one notification per chat:
/// - Local, from here: the phone only knows about an event while it is still following the run, and iOS
///   allows roughly thirty seconds of that after the app leaves the foreground. This covers the common
///   case of sending and switching away.
/// - APNs push, from the bridge: it keeps following every run on the Mac and pushes when the phone is no
///   longer watching (see `PushRegistration` and Bridge/bridge_push.py). When this app's background time ends
///   it says so, and the bridge takes over at once. Without an APNs key on the Mac this path is off and a reply
///   that takes longer than the grace window is shown on return.
/// Both use `ReplyDestination.collapseID` as the notification identifier, so they replace each other. Pushes
/// carry generic text: reply excerpts, commands and errors never leave the Mac in a notification.
@MainActor @Observable
final class ReplyNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotifier()
    var destination: ReplyDestination?
    /// The chat on screen. Its notifications aren't shown over it, and opening it clears the ones it had.
    @ObservationIgnored private(set) var watching: ReplyDestination?

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
            // iOS calls this on the main thread just before it suspends the app. The task must end here, and
            // from now on only the Mac can tell the person, so it hears about it first.
            MainActor.assumeIsolated { self?.stopFollowing() }
        }
    }

    func returned() {
        away = false
        endGrace()
    }

    /// Give the background time back as soon as nothing is running.
    func settled(liveRuns: Bool) { if !liveRuns { stopFollowing() } }

    /// The app is about to stop following its runs: a queued follow-up or a run it didn't hear end is the
    /// bridge's to announce now, not in thirty-five seconds.
    private func stopFollowing() {
        guard grace != .invalid else { return }
        if away { PushRegistration.shared.stoppedFollowing() }
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    typealias Event = ReplyEvent

    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil) {
        guard away, let account, let session else { return }
        let chat = ReplyDestination(account: account, profile: profile, session: session)
        let content = UNMutableNotificationContent()
        content.title = event.title(bot: bot, worked: worked)
        // One readable sentence of what happened. iOS hides the body on a locked phone unless the person
        // chose "Show Previews: Always", so excerpts follow their own privacy setting.
        content.body = detail.flatMap { $0.isEmpty ? nil : $0 } ?? event.fallback
        content.sound = .default
        content.threadIdentifier = chat.identifier
        content.userInfo = chat.userInfo

        // One notification per chat: a newer event replaces the older one instead of stacking.
        let request = UNNotificationRequest(identifier: chat.collapseID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A chat came on screen (nil: one without a session yet).
    func watch(_ chat: ReplyDestination?) {
        watching = chat
        if let chat { clearDelivered(chat) }
    }

    /// A chat left the screen. Another may have appeared first, so only its own claim is dropped.
    func unwatch(_ chat: ReplyDestination?) {
        if watching == chat { watching = nil }
    }

    /// Opening a chat answers its notifications: take them out of Notification Center. Local ones use the
    /// collapse id; a push can arrive under another id (older bridges, simulated pushes), so match the chat too.
    private func clearDelivered(_ chat: ReplyDestination) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [chat.collapseID])
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.filter { ReplyDestination(userInfo: $0.request.content.userInfo) == chat }
                .map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chat = ReplyDestination(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.destination = chat }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let chat = ReplyDestination(userInfo: notification.request.content.userInfo)
        let watching = await MainActor.run { self.watching }
        return ForegroundPolicy.shows(chat, watching: watching) ? [.banner, .list, .sound] : []
    }
}
#else
import Foundation

/// The model sources also compile into macOS test executables, where there is nothing to notify.
@MainActor
final class ReplyNotifier {
    static let shared = ReplyNotifier()
    typealias Event = ReplyEvent
    var away = false
    private(set) var watching: ReplyDestination?
    func install() {}
    func askOnce() {}
    func registerIfAuthorized() {}
    func left(liveRuns: Bool) { away = true }
    func returned() { away = false }
    func settled(liveRuns: Bool) {}
    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil) {}
    func watch(_ chat: ReplyDestination?) { watching = chat }
    func unwatch(_ chat: ReplyDestination?) { if watching == chat { watching = nil } }
}
#endif

/// The first sentence of a reply as plain text, for a notification or widget line.
enum Headline {
    static func of(_ markdown: String, limit: Int = 160) -> String? {
        var text = MarkdownBlock.plainText(markdown)
        // Skip code and list noise: take the first line with real words.
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.first { $0.count > 3 && !$0.hasPrefix("```") && !$0.hasPrefix("|") } ?? ""
        guard !text.isEmpty else { return nil }
        if let end = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { text = String(text[..<end.upperBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
