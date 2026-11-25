import Foundation

/// The grant fingerprint scopes both notification grouping and tap navigation across gateways.
struct ReplyDestination: Equatable {
    let account: String
    let profile: String
    let session: String

    var identifier: String { [account, profile, session].map { "\($0.utf8.count):\($0)" }.joined() }

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
/// There is no push server: the phone only knows about an event while it is still following the run.
/// iOS allows roughly thirty seconds of that after the app leaves the foreground, so this covers the
/// common case of sending and switching away. A reply that takes longer is shown on return.
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
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
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

    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil) {
        guard away, let account, let session else { return }
        let content = UNMutableNotificationContent()
        let took = worked.flatMap { $0 >= 60 ? " · \(Int($0 / 60)) min" : nil } ?? ""
        switch event {
        case .reply: content.title = bot + (took.isEmpty ? "" : " finished" + took)
        case .approval: content.title = bot + " needs your approval"
        case .failure: content.title = bot + " could not finish"
        }
        // One readable sentence of what happened. iOS hides the body on a locked phone unless the person
        // chose "Show Previews: Always", so excerpts follow their own privacy setting.
        let fallback: String
        switch event {
        case .reply: fallback = "Your reply is ready."
        case .approval: fallback = "Open the chat to review the request."
        case .failure: fallback = "Open the chat for details."
        }
        content.body = detail.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        content.sound = .default
        content.threadIdentifier = ReplyDestination(account: account, profile: profile, session: session).identifier
        content.userInfo = ["account": account, "profile": profile, "session": session]

        // One notification per chat: a newer event replaces the older one instead of stacking.
        let request = UNNotificationRequest(identifier: content.threadIdentifier, content: content, trigger: nil)
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
    func left(liveRuns: Bool) { away = true }
    func returned() { away = false }
    func settled(liveRuns: Bool) {}
    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil) {}
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
