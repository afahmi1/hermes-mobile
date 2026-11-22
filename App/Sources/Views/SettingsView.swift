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
                    LabeledContent("Bots", value: "\(app.bots.filter(\.reachable).count) of \(app.bots.count) reachable")
                }
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
