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
    private let accounts: SavedGateways
    private(set) var savedGateways: [URL]
    var inboxPath: [ChatRef] = []
    var bots: [Bot] = []
    private(set) var botsLoaded = false
    @ObservationIgnored private var botRequest = UUID()
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
    static var currentAccount: String? { API.shared.accountID }

    func inboxKey(profile: String?, filter: String) -> String? {
        inboxAccount.map { [$0, profile ?? "*", filter].joined(separator: "|") }
    }
    /// Live provider model catalog, per account + profile (TTL, coalesced, cadence-bounded refresh).
    let catalogStore = ModelCatalogStore(currentAccount: { AppModel.currentAccount }) { scope, fetch in
        try await API.shared.catalog(profile: scope.profile, fetch: fetch)
    }
    func catalogScope(_ profile: String) -> CatalogScope? { inboxAccount.map { CatalogScope(account: $0, profile: profile) } }
    @ObservationIgnored private var chats: [String: ChatModel] = [:]
    @ObservationIgnored private var recentChatKeys: [String] = []
    @ObservationIgnored private var newChats: [String: ChatModel] = [:]
    private let visibleChats = NSMapTable<NSString, ChatModel>.strongToWeakObjects()


    init(accounts: SavedGateways = API.accounts) {
        self.accounts = accounts
        savedGateways = accounts.servers
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
                if accounts.remember(login) { API.activate(login); signedIn = true }
                #endif
            }
        }
        // `-HMOpenChat <bot>/<session id>` opens that chat at launch, for screenshot QA with no taps.
        if signedIn, let open = env["HMOpenChat"] ?? d.string(forKey: "HMOpenChat"),
           let slash = open.firstIndex(of: "/") {
            inboxPath = [ChatRef(profile: String(open[..<slash]), sessionId: String(open[open.index(after: slash)...]))]
        }
        #endif
        savedGateways = accounts.servers
        DevicePreferences.migrate(account: inboxAccount)
    }

    /// `prometheus://` links, so dictation keyboards (Hex, Zone) can bounce back here after recording and
    /// Shortcuts / the Action Button can start a chat:
    /// - `prometheus://` (or `/open`) only brings the app forward, keeping the chat and draft you were in.
    /// - `prometheus://chat/<bot>/<session>` opens that chat.
    /// - `prometheus://new/<bot>?text=…` opens a new chat with the text in its draft (nothing is sent).
    func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "prometheus", signedIn else { return false }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        switch parts.first?.lowercased() {
        case nil, "open":
            return true
        case "chat" where parts.count >= 3:
            inboxPath = [ChatRef(profile: parts[1], sessionId: parts[2...].joined(separator: "/"))]
            return true
        case "new":
            let profile = parts.count >= 2 ? parts[1] : (bots.first?.id ?? "default")
            let ref = ChatRef(profile: profile, sessionId: nil)
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value ?? ""
            if !text.isEmpty {
                let chat = chat(for: ref)
                chat.draft = chat.draft.isEmpty ? text : chat.draft + "\n\n" + text
            }
            inboxPath = [ref]
            return true
        default:
            return false
        }
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    func botName(_ id: String) -> String { bot(id)?.name ?? id }

    func refreshBots() async {
        guard inboxAccount != nil else { return }
        let request = UUID()
        botRequest = request
        do {
            let latest = try await API.shared.bots()
            guard request == botRequest, !Task.isCancelled else { return }
            botsLoaded = true
            bots = latest
            loadError = nil
        } catch {
            guard request == botRequest, !Task.isCancelled else { return }
            loadError = error.localizedDescription
            if case APIError.http(401, _) = error { sessionExpired() }
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
            if let reason = error as? URLError, API.shared.baseURL?.host?.hasSuffix(".ts.net") == true {
                switch reason.code {
                case .cannotFindHost, .dnsLookupFailed:
                    healthFailure = "The phone couldn’t resolve this gateway’s Tailscale name. Check the saved address and tailnet connection."
                case .timedOut, .cannotConnectToHost:
                    healthFailure = "The private HTTPS endpoint didn’t answer. Check that the host is awake and its bridge is published on the saved port. An exit node is optional."
                default: healthFailure = error.localizedDescription
                }
            } else { healthFailure = error.localizedDescription }
        }
        checkedConnection = true
    }

    func catalog(for profile: String, refresh: Bool = false) async -> ModelCatalog? {
        guard let scope = catalogScope(profile) else { return nil }
        return refresh ? await catalogStore.refresh(scope) : await catalogStore.load(scope)
    }

    /// One live ChatModel per session, so a reply keeps streaming while you look at other chats.
    func chat(for ref: ChatRef) -> ChatModel {
        let key = ref.id
        let unfinished = newChats[ref.profile]
        let chat = chats[key] ?? visibleChats.object(forKey: key as NSString)
            ?? (ref.sessionId == nil && unfinished?.sessionId == nil ? unfinished : nil)
            ?? ChatModel(profile: ref.profile, sessionId: ref.sessionId, app: self, draftID: ref.draft)
        if recentChatKeys.last != key {
            recentChatKeys.removeAll { $0 == key }
            recentChatKeys.append(key)
        }
        chats[key] = chat
        if ref.sessionId == nil && chat.sessionId == nil { newChats[ref.profile] = chat }
        visibleChats.setObject(chat, forKey: key as NSString)
        if recentChatKeys.count > 12 {
            for old in Array(recentChatKeys.dropLast(12)) {
                guard let candidate = chats[old], !candidate.isRunning, candidate.canEvictDraft else { continue }
                chats.removeValue(forKey: old)
                recentChatKeys.removeAll { $0 == old }
            }
        }
        return chat
    }

    func adopt(_ chat: ChatModel, draftKey: String) {
        guard visibleChats.object(forKey: draftKey as NSString) === chat, let sid = chat.sessionId else { return }
        if newChats[chat.profile] === chat { newChats.removeValue(forKey: chat.profile) }
        let key = "\(chat.profile)/\(sid)"
        chats[key] = chat
        visibleChats.setObject(chat, forKey: key as NSString)
        if !recentChatKeys.contains(key) { recentChatKeys.append(key) }
        visibleChats.setObject(chat, forKey: draftKey as NSString)
    }

    func retryDraftStorage() {
        for chat in chats.values { chat.retryDraftStorage() }
    }

    var hasLiveRuns: Bool { chats.values.contains { $0.isRunning } || newChats.values.contains { $0.isRunning } }
    /// A queued or guide message that hasn't reached the Mac yet, in any open chat.
    var hasUnsentMessages: Bool {
        (Array(chats.values) + Array(newChats.values)).contains { $0.outgoing.contains { !$0.onMac && $0.problem == nil } }
    }

    func hasLiveRuns(excluding chat: ChatModel) -> Bool {
        chats.values.contains { $0 !== chat && $0.isRunning } || newChats.values.contains { $0 !== chat && $0.isRunning }
    }

    func resumeLiveRuns() {
        for c in chats.values { c.resumeIfNeeded() }
    }

    func connect(_ login: GatewayLogin) throws {
        guard let origin = SavedGateways.origin(login.server) else { throw APIError.badResponse }
        let canonical = GatewayLogin(server: origin, token: login.token)
        guard accounts.remember(canonical) else {
            throw APIError.http(0, "Unable to save this device’s sign-in in Keychain.")
        }
        // The bridge issues opaque device grants. Only the identical origin and grant may
        // reopen saved drafts or unconfirmed sends, even when two grants use the same URL.
        changeGateway(canonical)
    }

    func sessionExpired() {
        guard let server = API.shared.baseURL else { return }
        if accounts.credential(server)?.token == API.shared.token { _ = accounts.forget(server) }
        accounts.defaults.set(server.absoluteString, forKey: "server")
        // Keep device-protected writing in its original grant scope after involuntary sign-out.
        changeGateway(nil)
    }

    func savedServer(forAccount id: String) -> URL? {
        savedGateways.first { accounts.credential($0).map(API.accountID(for:)) == id }
    }

    func switchGateway(_ url: URL) throws {
        guard let login = accounts.credential(url) else { throw APIError.notSignedIn }
        accounts.defaults.set(login.server.absoluteString, forKey: "server")
        changeGateway(login)
    }

    func openDestinationChat(_ chat: SessionSummary, on login: GatewayLogin) throws {
        guard accounts.credential(login.server) == login else { throw APIError.notSignedIn }
        if API.shared.baseURL != login.server || API.shared.token != login.token { try switchGateway(login.server) }
        inboxPath = [ChatRef(profile: chat.profile, sessionId: chat.id)]
    }

    /// Remove the local entry before waiting for a best-effort revoke, so it cannot become
    /// the active destination during that request. Send the captured grant to its own host.
    func forgetGateway(_ url: URL) async {
        guard let login = accounts.credential(url), login.server != API.shared.baseURL else { return }
        let account = API.accountID(for: login)
        _ = accounts.forget(login.server)
        savedGateways = accounts.servers
        ComposerDisk.shared.forget(account)
        DevicePreferences.forget(account)
        let client = API.shared
        async let revoke: Void? = try? client.revokeSavedDevice(login)
        await InboxDisk.shared.forget(account)
        _ = await revoke
    }

    func signOut() {
        if let server = API.shared.baseURL { _ = accounts.forget(server) }
        if let account = inboxAccount {
            Task { await InboxDisk.shared.forget(account) }
            ComposerDisk.shared.forget(account)
            DevicePreferences.forget(account)
        }
        changeGateway(nil)
    }

    private func changeGateway(_ login: GatewayLogin?) {
        inboxPath.removeAll()
        for chat in chats.values { chat.cancelLocalFollow() }
        inboxes.removeAll()
        API.activate(login)
        savedGateways = accounts.servers
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
        botsLoaded = false
        botRequest = UUID()
        signedIn = login != nil
        chats = [:]
        newChats.removeAll()
        recentChatKeys.removeAll()
        visibleChats.removeAllObjects()
        catalogStore.reset()
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
        return Color(hue: Double(h % 360) / 360, saturation: 0.65, brightness: 0.46)
    }
}

struct BotAvatar: View {
    let id: String
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Bot.color(for: id))
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
