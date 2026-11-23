import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Hermes server") {
                    LabeledContent("Address", value: API.shared.baseURL?.absoluteString ?? "—")
                    LabeledContent("Gateway") { ConnectionBadge() }
                    if let v = app.health?.version { LabeledContent("Hermes", value: v) }
                    NavigationLink { SettingsBotsList() } label: {
                        LabeledContent("Bots", value: "\(app.bots.filter(\.reachable).count) of \(app.bots.count) reachable")
                    }
                    .accessibilityIdentifier("settings.bots")
                    .accessibilityHint("Shows every bot and whether it is reachable")
                }
                Section {
                    NavigationLink { DeletionPinView() } label: { Label("Deletion PIN", systemImage: "lock") }
                        .accessibilityIdentifier("settings.deletionPin")
                        .accessibilityHint("Choose or change the PIN that protects archiving projects and bots")
                } footer: { Text("Owner only. Each Mac has its own PIN; there is no default.") }
                ProviderUsageSection()
                Section {
                    Text("Chats, bots and model choices live in Hermes on your server, so this phone and the desktop app always show the same thing. Away from home, keep Tailscale connected on this phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .refreshable {
                async let health: Void = app.refreshHealth()
                async let bots: Void = app.refreshBots()
                await app.status.refresh(force: true, app: app)
                _ = await (health, bots)
            }
            .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { app.signOut() }
            }
        }
    }
}

/// Read-only list of the bots Hermes knows. Nothing here changes server settings.
private struct SettingsBotsList: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            if let e = app.loadError { Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
            if app.bots.isEmpty { Text("No bots found.").foregroundStyle(.secondary) }
            ForEach(app.bots) { bot in
                NavigationLink { BotDetailView(bot: bot) } label: { BotRow(bot: bot) }
                    .disabled(!bot.reachable)
            }
        }
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.refreshBots() }
    }
}
