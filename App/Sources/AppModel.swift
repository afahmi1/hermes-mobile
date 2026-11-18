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
    var id: String { sessionId.map { "\(profile)/\($0)" } ?? "draft/\(draft.uuidString)" }
}

@MainActor @Observable
final class AppModel {
    var signedIn = API.shared.isSignedIn
    var bots: [Bot] = []
    var health: HealthInfo?
    var loadError: String?
    private var catalogs: [String: ModelCatalog] = [:]
    private var chats: [String: ChatModel] = [:]

    init() {
        #if DEBUG
        // Simulator / automation hook (debug builds only): `-HMServer <url> -HMToken <token>` signs in
        // without a password. Tokens come from `hermes_mobile_bridge.py --issue-token <name>` on the Mac.
        let d = UserDefaults.standard
        if let s = d.string(forKey: "HMServer"), let url = URL(string: s), let t = d.string(forKey: "HMToken"), !t.isEmpty {
            API.shared.baseURL = url
            API.shared.token = t
            signedIn = true
        }
        #endif
    }

    func bot(_ id: String) -> Bot? { bots.first { $0.id == id } }
    func botName(_ id: String) -> String { bot(id)?.name ?? id }

    func refreshBots() async {
        do {
            bots = try await API.shared.bots()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            if case APIError.http(401, _) = error { signOut() }
        }
    }

    func refreshHealth() async { health = try? await API.shared.health() }

    func catalog(for profile: String) async -> ModelCatalog? {
        if let c = catalogs[profile] { return c }
        guard let c = try? await API.shared.catalog(profile: profile) else { return nil }
        catalogs[profile] = c
        return c
    }

    /// One live ChatModel per session, so a reply keeps streaming while you look at other chats.
    func chat(for ref: ChatRef) -> ChatModel {
        let key = ref.id
        if let c = chats[key] { return c }
        let c = ChatModel(profile: ref.profile, sessionId: ref.sessionId, app: self)
        chats[key] = c
        return c
    }

    func adopt(_ chat: ChatModel, draftKey: String) {
        guard let sid = chat.sessionId else { return }
        chats["\(chat.profile)/\(sid)"] = chat
        chats[draftKey] = chat
    }

    func resumeLiveRuns() {
        for c in chats.values { c.resumeIfNeeded() }
    }

    func signOut() {
        API.shared.signOut()
        signedIn = false
        chats = [:]
        catalogs = [:]
    }

    // MARK: per-chat runtime choice (device-local mirror of the session lock in state.db)

    static func savedChoice(profile: String, session: String) -> RuntimeChoice? {
        guard let data = UserDefaults.standard.data(forKey: "runtime.\(profile)/\(session)") else { return nil }
        return try? JSONDecoder().decode(RuntimeChoice.self, from: data)
    }

    static func saveChoice(_ choice: RuntimeChoice, profile: String, session: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: "runtime.\(profile)/\(session)")
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
