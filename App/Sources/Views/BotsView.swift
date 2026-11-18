import SwiftUI

struct BotsView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = app.loadError { Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
                ForEach(app.bots) { bot in
                    NavigationLink(value: bot) { BotRow(bot: bot) }
                        .disabled(!bot.reachable)
                }
            }
            .navigationTitle("Bots")
            .navigationDestination(for: Bot.self) { BotDetailView(bot: $0) }
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .refreshable { await app.refreshBots() }
        }
    }
}

struct BotRow: View {
    let bot: Bot
    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(id: bot.id, name: bot.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(bot.name).font(.body.weight(.semibold))
                    if bot.front { Text("Front door").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: Capsule()) }
                }
                if !bot.blurb.isEmpty { Text(bot.blurb).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text("\(bot.model) · \(bot.provider)").font(.caption).foregroundStyle(.tertiary)
                if !bot.reachable { Text("No API key — not reachable").font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct BotDetailView: View {
    @Environment(AppModel.self) private var app
    let bot: Bot
    @State private var sessions: [SessionSummary] = []
    @State private var cursor: String?
    @State private var showAutomations = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: ChatRef(profile: bot.id, sessionId: nil)) {
                    Label("New chat with \(bot.name)", systemImage: "square.and.pencil").font(.body.weight(.semibold))
                }
            } footer: { Text("Default: \(bot.model) · \(bot.provider). You can switch per chat.") }
            Section {
                Toggle("Show scheduled & one-shot runs", isOn: $showAutomations)
            }
            Section("Sessions") {
                ForEach(sessions) { s in
                    NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
                        SessionRow(session: s, botName: bot.name)
                    }
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.task(id: cursor) { await more() }
                } else if sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(bot.name)
        .task(id: showAutomations) { await load() }
        .refreshable { await load() }
    }

    private var exclude: [String] { showAutomations ? [] : ["cron", "oneshot", "subagent", "tool"] }

    private func load() async {
        guard let page = try? await API.shared.sessions(cursor: nil, profile: bot.id, exclude: exclude) else { return }
        sessions = page.data
        cursor = page.next
    }

    private func more() async {
        guard let c = cursor, let page = try? await API.shared.sessions(cursor: c, profile: bot.id, exclude: exclude) else {
            cursor = nil; return
        }
        var seen = Set(sessions.map(\.key))
        sessions += page.data.filter { seen.insert($0.key).inserted }
        cursor = page.next
    }
}
