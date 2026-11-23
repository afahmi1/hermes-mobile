import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Identifies a chat screen: an existing session, or a draft that becomes one on first send.
struct ChatRef: Hashable, Identifiable {
    let profile: String
    var sessionId: String?
    let draft: UUID

    init(profile: String, sessionId: String?) {
        self.profile = profile
        self.sessionId = sessionId
        self.draft = UUID()
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: String { sessionId.map { "\(profile)/\($0)" } ?? "draft/\(draft.uuidString)" }
}

@MainActor @Observable
final class AppModel {
    var signedIn = API.shared.isSignedIn
    private(set) var gatewaySession = UUID()
    private(set) var savedGateways = API.accounts.servers
    var bots: [Bot] = []
    var health: HealthInfo?
    var checkedConnection = false
    var lastHealthCheck: Date?
    var healthFailure: String?
    var needsLogin = false
    private var healthRequest = UUID()
    /// The Mac's status dashboard data, polled for the app's lifetime (see StatusModel.poll).
    let status = StatusModel()
    var loadError: String?
    @ObservationIgnored var inboxes: [String: InboxSnapshot] = [:]
    var inboxAccount: String? { Self.currentAccount }
    static var currentAccount: String? {
        guard let url = API.shared.baseURL, let token = API.shared.token else { return nil }
        return SHA256.hash(data: Data((url.absoluteString + "|" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func inboxKey(profile: String?, filter: String) -> String? {
        inboxAccount.map { [$0, profile ?? "*", filter].joined(separator: "|") }
    }
    private var catalogs: [String: ModelCatalog] = [:]
    @ObservationIgnored private var chats: [String: ChatModel] = [:]
    @ObservationIgnored private var recentChatKeys: [String] = []
    private let visibleChats = NSMapTable<NSString, ChatModel>.strongToWeakObjects()


    init() {
        #if DEBUG
        // Simulator / automation hook (debug builds only): `-HMServer <url> -HMToken <token>` signs in
        // without a password. Tokens come from `hermes_mobile_bridge.py --issue-token <name>` on the Mac.
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        if let s = env["HMServer"] ?? d.string(forKey: "HMServer"), let url = URL(string: s),
           let t = env["HMToken"] ?? d.string(forKey: "HMToken"), !t.isEmpty {
            if let origin = SavedGateways.origin(url) {
                let login = GatewayLogin(server: origin, token: t)
                #if targetEnvironment(simulator)
                // An unsigned simulator can use its injected launch credentials in memory.
                API.activate(login)
                signedIn = true
                #else
                if API.accounts.remember(login) { API.activate(login); signedIn = true }
                #endif
            }
        }
        #endif
        savedGateways = API.accounts.servers
        DevicePreferences.migrate(account: inboxAccount)
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    func botName(_ id: String) -> String { bot(id)?.name ?? id }

    func refreshBots() async {
        guard let account = inboxAccount else { return }
        do {
            let latest = try await API.shared.bots()
            guard account == inboxAccount, !Task.isCancelled else { return }
            bots = latest
            loadError = nil
        } catch {
            guard account == inboxAccount, !Task.isCancelled else { return }
            loadError = error.localizedDescription
            if case APIError.http(401, _) = error { signOut() }
        }
    }

    func refreshHealth() async {
        let request = UUID()
        healthRequest = request
        do {
            let latest = try await API.shared.health()
            guard !Task.isCancelled, signedIn, request == healthRequest else { return }
            health = latest
            lastHealthCheck = Date()
            healthFailure = nil
            needsLogin = false
        } catch {
            guard !Task.isCancelled, signedIn, request == healthRequest else { return }
            needsLogin = false
            if case APIError.http(401, _) = error { needsLogin = true }
            healthFailure = error.localizedDescription
        }
        checkedConnection = true
    }

    func catalog(for profile: String, refresh: Bool = false) async -> ModelCatalog? {
        if !refresh, let c = catalogs[profile] { return c }
        guard let account = inboxAccount, let c = try? await API.shared.catalog(profile: profile),
              account == inboxAccount else { return nil }
        catalogs[profile] = c
        return c
    }

    /// One live ChatModel per session, so a reply keeps streaming while you look at other chats.
    func chat(for ref: ChatRef) -> ChatModel {
        let key = ref.id
        let chat = chats[key] ?? visibleChats.object(forKey: key as NSString)
            ?? ChatModel(profile: ref.profile, sessionId: ref.sessionId, app: self)
        if recentChatKeys.last != key {
            recentChatKeys.removeAll { $0 == key }
            recentChatKeys.append(key)
        }
        chats[key] = chat
        visibleChats.setObject(chat, forKey: key as NSString)
        if recentChatKeys.count > 12 {
            for old in Array(recentChatKeys.dropLast(12)) {
                guard let candidate = chats[old], !candidate.isRunning, candidate.draft.isEmpty, candidate.draftAttachments.isEmpty else { continue }
                chats.removeValue(forKey: old)
                recentChatKeys.removeAll { $0 == old }
            }
        }
        return chat
    }

    func adopt(_ chat: ChatModel, draftKey: String) {
        guard let sid = chat.sessionId else { return }
        let key = "\(chat.profile)/\(sid)"
        chats[key] = chat
        visibleChats.setObject(chat, forKey: key as NSString)
        if !recentChatKeys.contains(key) { recentChatKeys.append(key) }
        visibleChats.setObject(chat, forKey: draftKey as NSString)
    }

    func resumeLiveRuns() {
        for c in chats.values { c.resumeIfNeeded() }
    }

    func connect(_ login: GatewayLogin) throws {
        let prior = inboxAccount
        let oldURL = API.shared.baseURL
        guard API.accounts.remember(login) else {
            throw APIError.http(0, "Unable to save this device’s sign-in in Keychain.")
        }
        if let prior, oldURL == login.server, API.shared.token != login.token {
            Task { await InboxDisk.shared.forget(prior) }
            DevicePreferences.forget(prior)
        }
        changeGateway(login)
    }

    func switchGateway(_ url: URL) throws {
        guard let login = API.accounts.credential(url) else { throw APIError.notSignedIn }
        UserDefaults.standard.set(login.server.absoluteString, forKey: "server")
        changeGateway(login)
    }

    func signOut() {
        if let server = API.shared.baseURL { _ = API.accounts.forget(server) }
        if let account = inboxAccount {
            Task { await InboxDisk.shared.forget(account) }
            DevicePreferences.forget(account)
        }
        changeGateway(nil)
    }

    private func changeGateway(_ login: GatewayLogin?) {
        for chat in chats.values { chat.cancelLocalFollow() }
        inboxes.removeAll()
        API.activate(login)
        savedGateways = API.accounts.servers
        gatewaySession = UUID()
        loadError = nil
        status.reset()
        health = nil
        checkedConnection = false
        healthRequest = UUID()
        lastHealthCheck = nil
        healthFailure = nil
        needsLogin = false
        bots = []
        signedIn = login != nil
        chats = [:]
        recentChatKeys.removeAll()
        visibleChats.removeAllObjects()
        catalogs = [:]
    }

    // MARK: per-chat runtime choice (device-local mirror of the session lock in state.db)

    func savedChoice(profile: String, session: String) -> RuntimeChoice? {
        guard let key = inboxKey(profile: profile, filter: "runtime/" + session), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RuntimeChoice.self, from: data)
    }

    func saveChoice(_ choice: RuntimeChoice, profile: String, session: String) {
        guard let key = inboxKey(profile: profile, filter: "runtime/" + session) else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: key)
    }
}

// MARK: - Bot look

extension Bot {
    static func color(for id: String) -> Color {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

struct BotAvatar: View {
    let id: String
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Bot.color(for: id).gradient)
            Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let s = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "H" : s.uppercased()
    }
}
