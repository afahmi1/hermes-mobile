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
                .task { await app.refreshBots(); await app.refreshHealth() }
        } else {
            SignInView()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            ChatListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            BotsView()
                .tabItem { Label("Bots", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
