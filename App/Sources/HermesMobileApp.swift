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
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                .badge(app.status.badge)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await app.refreshHealth()
                let transitioning = ["starting", "restarting", "draining", "stopping", "waiting"].contains(app.health?.phase ?? "")
                try? await Task.sleep(for: .seconds(transitioning ? 3 : 15))
            }
        }
        .task(id: phase) { if phase == .active { await app.status.poll(app: app) } }  // keeps the badge and bot lists current from any tab
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
    @State private var detail = false
    @Environment(AppModel.self) private var app

    private var diagnostic: JV? {
        guard let at = app.status.updatedAt,
              Date().timeIntervalSince(at) < 45 else { return nil }
        return app.status.payload?["gateway"]
    }

    private var state: (label: String, symbol: String, color: Color) {
        guard app.checkedConnection else { return ("Checking", "clock.fill", .yellow) }
        if app.needsLogin { return ("Sign in", "lock.fill", .yellow) }
        if app.healthFailure != nil { return ("Unreachable", "wifi.slash", .red) }
        guard let health = app.health else { return ("Offline", "xmark.circle.fill", .red) }
        switch health.phase {
        case "starting": return ("Starting", "clock.fill", .yellow)
        case "restarting": return ("Restarting", "arrow.clockwise.circle.fill", .yellow)
        case "draining": return ("Finishing work", "clock.fill", .yellow)
        case "waiting": return ("Waiting", "clock.fill", .yellow)
        case "stopping": return ("Stopping", "clock.fill", .yellow)
        case "stopped", "unavailable": return ("Gateway down", "xmark.circle.fill", .red)
        default: break
        }
        let gateway = health.gatewayState?.lowercased() ?? ""
        if !health.ok || ["stopped", "down", "failed", "offline"].contains(gateway) || diagnostic?["health"].string == "down" {
            return ("Gateway down", "xmark.circle.fill", .red)
        }
        if diagnostic?["health"].string == "degraded" || (!gateway.isEmpty && !["running", "healthy", "ok", "ready"].contains(gateway)) {
            return ("Degraded", "exclamationmark.triangle.fill", .yellow)
        }
        return ("Online", "checkmark.circle.fill", .green)
    }

    var body: some View {
        Button { detail.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: state.symbol).foregroundStyle(state.color)
                Text(state.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel("Hermes connection, " + state.label)
        .popover(isPresented: $detail) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.label).font(.headline)
                Text(API.shared.baseURL?.host ?? "Hermes gateway").font(.footnote).foregroundStyle(.secondary)
                if let at = app.lastHealthCheck {
                    Text("Last response \(at, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
                if !app.checkedConnection {
                    Text("Checking the bridge and gateway.")
                } else if app.needsLogin {
                    Button("Sign in again") { app.signOut() }
                } else if let failure = app.healthFailure {
                    Text(failure)
                    if let last = app.health?.phase { Text("Last known gateway state: " + last).font(.caption) }
                } else if app.health == nil {
                    Text("Check Tailscale and the bridge address.")
                } else if ["starting", "restarting", "draining", "stopping", "waiting"].contains(app.health?.phase ?? "") {
                    Text("The bridge is reachable. This view will update as Hermes becomes ready.")
                } else if app.health?.ok == false {
                    Text("The bridge answered. The gateway health check failed.")
                } else {
                    ForEach(Array((diagnostic?["reasons"].array ?? []).enumerated()), id: \.offset) { _, reason in
                        if let text = reason.string { Text(text) }
                    }
                }
                if app.healthFailure == nil, let reason = app.health?.reason { Text(reason).foregroundStyle(.secondary) }
                if let fallback = app.health?.inboxFallback { Text("Using gateway history · " + fallback).font(.caption) }
                if let recent = app.health?.recent, recent.count > 1 {
                    Divider()
                    Text("Recent gateway changes").font(.caption.weight(.semibold))
                    ForEach(Array(recent.prefix(3).enumerated()), id: \.offset) { _, change in
                        HStack { Text(change.phase.capitalized); Spacer(); Text(Date(timeIntervalSince1970: change.at), style: .time) }
                    }
                }
                Button("Check again") {
                    Task {
                        async let health: Void = app.refreshHealth()
                        await app.status.refresh(app: app)
                        await health
                    }
                }
            }
            .font(.footnote)
            .padding().frame(idealWidth: 275, maxWidth: 340, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
