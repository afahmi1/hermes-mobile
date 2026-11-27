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
    /// Text typed into a notification's Reply action, consumed by the app when it opens that chat.
    var pendingReply: String? = nil

    private var grace: UIBackgroundTaskIdentifier = .invalid
    private(set) var away = false
    /// Chats already told "still working" for their current run, so leaving the app again doesn't repeat it.
    private var warned: Set<String> = []
    /// Set by PushRegistration: the Mac has an APNs key, so it sends the real reply and no heads-up is needed.
    var macCanPush = false
    private var asked = false
    weak var appRef: AppModel? = nil
    /// The chat on screen right now ("profile|session"). A reply for it is already visible; one for another chat isn't.
    var visibleChat: String? = nil

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Long-press a notification to type a reply. It queues like any other send and goes when the Mac answers.
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                   textInputButtonTitle: "Send", textInputPlaceholder: "Reply…")
        center.setNotificationCategories([UNNotificationCategory(identifier: "reply", actions: [reply], intentIdentifiers: [])])
    }

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
        // A chat whose run finished can be warned again on its next run.
        if let app = appRef {
            let running = Set(app.openChats.filter { $0.1.isRunning }.compactMap { $0.1.sessionId })
            warned = warned.intersection(running)
        }

    }

    /// Give the background time back as soon as nothing is running.
    func settled(liveRuns: Bool) { if !liveRuns { endGrace() } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
        // iOS is about to suspend the app while Hermes still works. Only needed without push (with push the
        // Mac sends the real reply), only once per run, and silent: a heads-up, not an alert.
        guard away, let app = appRef, !macCanPush else { return }
        for (_, chat) in app.openChats where chat.isRunning {
            guard let sid = chat.sessionId, !warned.contains(sid) else { continue }
            warned.insert(sid)
            post(.reply, bot: app.botName(chat.profile), account: app.inboxAccount, profile: chat.profile,
                 session: sid, detail: "Still working. Open the app to see the reply.", quiet: true)
        }
    }

    enum Event { case reply, approval, failure }

    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil, quiet: Bool = false) {
        guard let account, let session else { return }
        // Away: always. In the app: only for a chat you aren't looking at (its reply would otherwise vanish
        // into the list with no sound). The chat on screen shows it itself.
        guard away || visibleChat != profile + "|" + session else { return }
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
        content.sound = quiet ? nil : .default
        if quiet { content.interruptionLevel = .passive }
        content.threadIdentifier = ReplyDestination(account: account, profile: profile, session: session).identifier
        content.categoryIdentifier = "reply"
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
            if response.actionIdentifier == "reply", let text = (response as? UNTextInputNotificationResponse)?.userText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.pendingReply = text
            }
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
    var visibleChat: String? = nil
    var pendingReply: String? = nil
    func install() {}
    func askOnce() {}
    func registerIfAuthorized() {}
    func left(liveRuns: Bool) { away = true }
    func returned() { away = false }
    func settled(liveRuns: Bool) {}
    func post(_ event: Event, bot: String, account: String?, profile: String, session: String?,
              detail: String? = nil, worked: TimeInterval? = nil, quiet: Bool = false) {}
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
