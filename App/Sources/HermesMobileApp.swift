import SwiftUI

@main
struct HermesMobileApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Color.accentColor)
        }
        .onChange(of: phase) { _, now in
            if now == .active { app.resumeLiveRuns() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.signedIn {
            MainTabs()
                .task { await app.refreshBots() }
        } else {
            SignInView()
        }
    }
}

struct MainTabs: View {
    @Environment(\.scenePhase) private var phase
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            BotsView()
                .tabItem { Label("Bots", systemImage: "person.2") }
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                .badge(app.status.badge)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            app.checkedConnection = false
            while !Task.isCancelled {
                await app.refreshHealth()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task { await app.status.poll(app: app) }  // keeps the badge and bot lists current from any tab
        .overlay(alignment: .top) { Announcement(text: app.status.announcement, tick: app.status.announceTick) }
        .sensoryFeedback(.success, trigger: app.status.announceTick)
    }
}

/// A brief banner when a bot or cron job is created (or removed) on the Mac while the app is open.
private struct Announcement: View {
    let text: String?
    let tick: Int
    @State private var shown = false

    var body: some View {
        Group {
            if shown, let text {
                Label(text, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
            }
        }
        .animation(.spring(duration: 0.35), value: shown)
        .task(id: tick) {  // a newer announcement restarts the timer instead of being hidden early
            guard tick > 0 else { return }
            shown = true
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { shown = false }
        }
    }
}

/// An authenticated health probe checks both the bridge and the Hermes gateway.
struct ConnectionBadge: View {
    @Environment(AppModel.self) private var app

    private var state: (String, Color) {
        guard app.checkedConnection else { return ("Checking", .secondary) }
        guard let health = app.health else { return ("Offline", .red) }
        guard health.ok else { return ("Gateway down", .orange) }
        if let state = health.gatewayState, !["running", "healthy", "ok", "ready"].contains(state.lowercased()) {
            return (state.capitalized, .orange)
        }
        return ("Online", .green)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.1).frame(width: 7, height: 7)
            Text(state.0).font(.caption.weight(.medium))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes connection, " + state.0)
    }
}
