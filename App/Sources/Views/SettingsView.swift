import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Address", value: API.shared.baseURL?.absoluteString ?? "—")
                    LabeledContent("Gateway") {
                        if let h = app.health {
                            Label(h.ok ? (h.gatewayState ?? "running") : "not answering",
                                  systemImage: h.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(h.ok ? .green : .red)
                        } else { ProgressView() }
                    }
                    if let v = app.health?.version { LabeledContent("Hermes", value: v) }
                    LabeledContent("Bots", value: "\(app.bots.filter(\.reachable).count) of \(app.bots.count) reachable")
                }
                Section {
                    Text("Chats, bots and model choices live in Hermes on your Mac, so this phone and the desktop app always show the same thing. Away from home, keep Tailscale connected on this phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .refreshable { await app.refreshHealth(); await app.refreshBots() }
            .confirmationDialog("Sign out of your Mac?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { app.signOut() }
            }
        }
    }
}
