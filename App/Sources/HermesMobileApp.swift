import SwiftUI

private final class NotificationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launched the app still reaches the delegate.
        ReplyNotifier.shared.install()
        #if DEBUG
        if DemoMode.isOn { return true }  // fixtures: banners and taps work, nothing registers with APNs
        #endif
        ReplyNotifier.shared.registerIfAuthorized()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.received(deviceToken) }
    }

    // Simulators and builds without the Push capability land here. Local notifications still work.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}

@main
struct HermesMobileApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var delegate
    #if DEBUG
    // Screenshot QA (debug builds only): `-HMTab N` starts on tab N.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "HMTab")
    #else
    @State private var selectedTab = 0
    #endif
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var backgroundedAt: Date?
    @AppStorage(HMTheme.themeKey) private var themeRaw = HMThemeKind.thermocline.rawValue
    @AppStorage(HMTheme.modeKey) private var modeRaw = HMMode.system.rawValue
    @AppStorage(HMTheme.classicKey) private var classicRaw = HMThemeChoice.native.rawValue
    @AppStorage(HMTheme.accentKey) private var accentRaw = HMAccent.theme.rawValue
    @AppStorage(HMTheme.thermoclineAccentKey) private var thermoclineAccentRaw = Thermocline.Accent.crown.rawValue

    init() {
        HMTheme.applyChrome()
        // Upload copies a month old (sent long ago, or a draft abandoned) are removed in the background.
        Task.detached(priority: .background) { UploadFiles.prune(keep: []) }
    }

    /// Everything that changes how colors resolve. The root rebuilds once when it changes.
    @AppStorage(Thermocline.Palette.darkCanvasKey) private var darkCanvas = "black"
    private var look: String { [themeRaw, modeRaw, classicRaw, accentRaw, thermoclineAccentRaw, darkCanvas].joined(separator: "|") }

    var body: some Scene {
        WindowGroup {
            RootView(selectedTab: $selectedTab)
                .environment(app)
                .tint(HMDesign.accent)
                .thermoclineAccent(HMTheme.thermoclineAccent)
                .preferredColorScheme(HMTheme.scheme)
                // Theme colors resolve when views are built: rebuild once on a theme change.
                .id(look)
                .onChange(of: look) { _, _ in HMTheme.applyChrome() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    app.retryDraftStorage()
                }
                .onReceive(NotificationCenter.default.publisher(for: .hermesNetworkChanged)) { _ in
                    // New network path: old sockets are bound to the old interface. Reconnect and send what's waiting.
                    Task {
                        await API.shared.refreshConnections()
                        ActionQueue.shared.wake()
                        app.resumeLiveRuns()
                        NotificationCenter.default.post(name: .hermesForeground, object: nil)
                    }
                }
                #if DEBUG
                .task {
                    guard !DemoMode.isOn else { return }
                    DesignReview.signInIfAsked(app)
                    let defaults = UserDefaults.standard
                    if let tab = defaults.string(forKey: "HMReviewTab").flatMap(Int.init) { selectedTab = tab }
                    if let chat = defaults.string(forKey: "HMReviewChat"),
                       let url = URL(string: "prometheus://chat/" + chat) {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        _ = app.open(url)
                    }
                }
                #endif
                .onOpenURL { url in
                    if app.open(url) { selectedTab = 0 }
                }
                .onChange(of: app.gatewaySession) { _, _ in PushRegistration.shared.sync() }
                .onChange(of: ReplyNotifier.shared.destination, initial: true) { _, destination in
                    guard let destination else { return }
                    if destination.open(in: app) { selectedTab = 0 }
                    ReplyNotifier.shared.destination = nil
                }
        }
        .onChange(of: phase) { old, now in
            if now == .background {
                backgroundedAt = Date()
                // Ask iOS for a little time so a live reply or an unsent message can finish going out.
                let following = app.hasLiveRuns || app.hasUnsentMessages
                ReplyNotifier.shared.left(liveRuns: following)
                // Always tell the bridge: a stream a suspended app left open must not look like someone watching.
                PushRegistration.shared.presence(away: true, following: following)
            }
            if now == .active {
                ReplyNotifier.shared.returned()
                PushRegistration.shared.presence(away: false)
                PushRegistration.shared.sync()
                app.retryDraftStorage()
                if old == .background {
                    let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    Task {
                        // A quick switch (a text, a glance at another app) leaves the sockets and the live stream
                        // alone: iOS kept them, and tearing them down is what made "Reconnecting…" crawl. Away
                        // longer, iOS and Tailscale have likely dropped them: start fresh, all at once.
                        if away >= 10 { await API.shared.refreshConnections() }
                        StreamRoutes.shared.nudge()
                        ActionQueue.shared.wake()
                        app.resumeLiveRuns()
                        NotificationCenter.default.post(name: .hermesForeground, object: nil)
                        await app.refreshHealth()
                    }
                } else {
                    app.resumeLiveRuns()
                }
            }
        }
    }
}

struct RootView: View {
    @Binding var selectedTab: Int
    @Environment(AppModel.self) private var app

    var body: some View {
        #if DEBUG
        if DemoMode.isOn && UserDefaults.standard.bool(forKey: "HMShowSignIn") {
            SignInView()
        } else {
            signedInContent
        }
        #else
        signedInContent
        #endif
    }

    @ViewBuilder private var signedInContent: some View {
        if app.signedIn {
            MainTabs(selectedTab: $selectedTab)
                .id(app.gatewaySession)
                .task(id: app.gatewaySession) { await app.refreshBots() }
        } else {
            SignInView()
        }
    }
}

struct MainTabs: View {
    @Binding var selectedTab: Int
    @Environment(\.scenePhase) private var phase
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)
            BotsView()
                .tabItem { Label("Bots", systemImage: "person.2") }
                .tag(1)
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(2)
            StatusView()
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                .tag(3)
                .badge(app.status.badge)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .task(id: phase) {
            guard phase == .active else { return }
            var misses = 0
            while !Task.isCancelled {
                await app.refreshHealth()
                misses = app.healthFailure == nil ? 0 : misses + 1
                let transitioning = ["starting", "restarting", "draining", "stopping", "waiting"].contains(app.health?.phase ?? "")
                // After a miss, retry fast (1, 2, 4 s): a waking tunnel usually answers within seconds.
                let wait = misses > 0 ? Double(min(1 << (misses - 1), 15)) : transitioning ? 3 : 15
                try? await Task.sleep(for: .seconds(wait))
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
                if HMTheme.isThermocline {
                    Label(text, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(HMTintedIconLabel(icon: Thermocline.plum))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .hmGlass(Capsule())
                        .transition(.offset(y: -8).combined(with: .opacity))
                        .padding(.top, 4)
                } else {
                    Label(text, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 6, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 4)
                }
            }
        }
        .animation(HMMotion.pick(Thermocline.Motion.large, classic: .spring(duration: 0.35)), value: shown)
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
    /// Icon only (details on tap). Inside a chat the full "frostbyte · Online" label pushed the chat title
    /// and its model picker out of the navigation bar.
    var compact = false
    var reloadDisabled = false
    /// Inside a chat: the popover offers Reload chat, so the chat needs no separate refresh button.
    var onReload: (() async -> Void)? = nil
    /// The inbox's gateway pill: a status dot and the gateway's name. Its popover offers "Switch gateway".
    var pill = false
    var onSwitch: (() -> Void)? = nil
    @State private var detail = false
    @State private var reloading = false
    @Environment(AppModel.self) private var app

    private var diagnostic: JV? {
        guard let at = app.status.updatedAt,
              Date().timeIntervalSince(at) < 45 else { return nil }
        return app.status.payload?["gateway"]
    }

    private var hostName: String {
        guard let url = API.shared.baseURL else { return "" }
        return SavedGateways.displayName(url)
    }

    private func named(_ label: String) -> String {
        hostName.isEmpty ? label : "\(hostName) · \(label)"
    }

    private var state: (label: String, symbol: String, color: Color) {
        guard app.checkedConnection else { return (named("Checking"), "clock.fill", HMDesign.pending) }
        if app.needsLogin { return (named("Sign in"), "lock.fill", HMDesign.warning) }
        if app.healthFailure != nil { return (named("Unreachable"), "wifi.slash", HMDesign.danger) }
        guard let health = app.health else { return (named("Offline"), "xmark.circle.fill", HMDesign.danger) }
        switch health.phase {
        case "starting": return (named("Starting"), "clock.fill", HMDesign.pending)
        case "restarting": return (named("Restarting"), "arrow.clockwise.circle.fill", HMDesign.pending)
        case "draining": return (named("Finishing work"), "clock.fill", HMDesign.pending)
        case "waiting": return (named("Waiting"), "clock.fill", HMDesign.pending)
        case "stopping": return (named("Stopping"), "clock.fill", HMDesign.pending)
        case "stopped", "unavailable": return (named("Gateway down"), "xmark.circle.fill", HMDesign.danger)
        default: break
        }
        let gateway = health.gatewayState?.lowercased() ?? ""
        if !health.ok || ["stopped", "down", "failed", "offline"].contains(gateway) {
            return (named("Gateway down"), "xmark.circle.fill", HMDesign.danger)
        }
        if ["degraded", "down"].contains(diagnostic?["health"].string ?? "") || (!gateway.isEmpty && !["running", "healthy", "ok", "ready"].contains(gateway)) {
            return (named("Degraded"), "exclamationmark.triangle.fill", HMDesign.warning)
        }
        return (named("Online"), "checkmark.circle.fill", HMDesign.success)
    }

    var body: some View {
        Button { detail.toggle() } label: {
            HStack(spacing: HMDesign.micro) {
                if pill {
                    Circle().fill(state.color).frame(width: 8, height: 8)
                        .overlay { if reloading { ProgressView().controlSize(.mini) } }
                    Text(hostName.isEmpty ? "Gateway" : hostName)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                } else if compact {
                    // A dot, not a badge: green says all is well without taking the title's room.
                    Circle().fill(state.color).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .overlay { if reloading { ProgressView().controlSize(.mini) } }
                } else {
                    Image(systemName: state.symbol).foregroundStyle(state.color)
                    Text(state.label).font(.subheadline.weight(.medium)).foregroundStyle(HMDesign.ink)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .hmTouchTarget()
        }
        .accessibilityLabel("Hermes connection, " + state.label)
        .popover(isPresented: $detail) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.label).font(.headline)
                Text(API.shared.baseURL?.absoluteString ?? "Hermes gateway").textSelection(.enabled).font(.footnote).foregroundStyle(HMDesign.text2)
                if let at = app.lastHealthCheck {
                    Text("Last response \(at, style: .relative) ago").font(.caption).foregroundStyle(HMDesign.text2)
                }
                if !app.checkedConnection {
                    Text("Checking the bridge and gateway.")
                } else if app.needsLogin {
                    Button("Sign in again") { app.sessionExpired() }
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
                    if diagnostic?["health"].string == "down" {
                        Text("The gateway answered the live probe. The host process record disagrees.")
                    }
                    ForEach(Array((diagnostic?["reasons"].array ?? []).enumerated()), id: \.offset) { _, reason in
                        if let text = reason.string { Text(text) }
                    }
                }
                if app.healthFailure == nil, let reason = app.health?.reason { Text(reason).foregroundStyle(HMDesign.text2) }
                if let fallback = app.health?.inboxFallback { Text("Using gateway history · " + fallback).font(.caption) }
                if let recent = app.health?.recent, recent.count > 1 {
                    Divider()
                    Text("Recent gateway changes").font(.caption.weight(.semibold))
                    ForEach(Array(recent.prefix(3).enumerated()), id: \.offset) { _, change in
                        HStack { Text(change.phase.capitalized); Spacer(); Text(Date(timeIntervalSince1970: change.at), style: .time) }
                    }
                }
                HStack(spacing: 16) {
                    if let onSwitch {
                        Button {
                            detail = false
                            onSwitch()
                        } label: { Label("Switch gateway", systemImage: "arrow.left.arrow.right") }
                    }
                    if let onReload {
                        Button {
                            detail = false
                            reloading = true
                            Task { await onReload(); reloading = false }
                        } label: { Label("Reload chat", systemImage: "arrow.clockwise") }
                        .disabled(reloadDisabled)
                    }
                    Button("Check again") {
                        Task {
                            async let health: Void = app.refreshHealth()
                            await app.status.refresh(app: app)
                            await health
                        }
                    }
                }
            }
            .font(.footnote)
            .padding().frame(idealWidth: 275, maxWidth: 340, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
