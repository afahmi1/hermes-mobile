import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false
    @State private var localSignOut = false
    @State private var addingGateway = false
    @State private var gatewayError: String?
    @State private var capabilities: BridgeCapabilities?
    @State private var forgetting: URL?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Reachability is a count only once the bot list has loaded; before then it is unknown, not zero.
    private var botsSummary: String {
        if app.loadError != nil { return "Unavailable" }
        guard app.botsLoaded else { return "Checking…" }
        if app.bots.isEmpty { return "No bots reported" }
        return "\(app.bots.filter(\.reachable).count) of \(app.bots.count) reachable"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let current = API.shared.baseURL {
                        GatewayRow(name: SavedGateways.displayName(current), detail: current.absoluteString, isCurrent: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Current gateway, \(SavedGateways.displayName(current))")
                    }
                    ForEach(app.savedGateways.filter { $0 != API.shared.baseURL }, id: \.self) { url in
                        Button {
                            do { try app.switchGateway(url) } catch { gatewayError = error.localizedDescription }
                        } label: {
                            GatewayRow(name: SavedGateways.displayName(url), detail: url.absoluteString, isCurrent: false)
                        }
                        .accessibilityLabel("Switch to gateway \(SavedGateways.displayName(url))")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", systemImage: "trash", role: .destructive) { forgetting = url }
                        }
                    }
                    Button("Add Gateway", systemImage: "plus") { addingGateway = true }
                    if let gatewayError { Label(gatewayError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Chats, files and approvals stay on the gateway you choose.")
                }
                AppearanceSection()
                Section("Hermes server") {
                    if let caps = capabilities, caps.features.contains("device_grants") {
                        NavigationLink { DeviceAccessView(capabilities: caps) } label: {
                            Label("Device access", systemImage: "iphone")
                        }
                    }
                    LabeledContent("Gateway") { ConnectionBadge() }
                    if let v = app.health?.version { LabeledContent("Hermes", value: v) }
                    NavigationLink { SettingsBotsList() } label: {
                        LabeledContent("Bots", value: botsSummary)
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
                    Text("Chats, bots and model choices live in Hermes on your server, so this phone and the desktop app show the same thing. Away from home, keep Tailscale on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Hermes Mobile \(appVersion)")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .accessibilityLabel("App version \(appVersion)")
                }
            }
            .hmCanvas()
            .navigationTitle("Settings")
            .sheet(isPresented: $addingGateway) { SignInView(adding: true) }
            .task(id: app.inboxAccount) {
                capabilities = nil
                let caps = try? await API.shared.capabilities()
                if !Task.isCancelled { capabilities = caps }
            }
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .refreshable {
                async let health: Void = app.refreshHealth()
                async let bots: Void = app.refreshBots()
                await app.status.refresh(force: true, app: app)
                _ = await (health, bots)
            }
            .confirmationDialog("Remove this gateway from the phone?", isPresented: Binding(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
            ), titleVisibility: .visible, presenting: forgetting) { url in
                Button("Remove " + SavedGateways.displayName(url), role: .destructive) {
                    Task { await app.forgetGateway(url) }
                }
            } message: { _ in
                Text("Its saved sign-in, cached chats and drafts are deleted from this phone. Chats stay on the gateway.")
            }
            .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        let account = app.inboxAccount
                        do {
                            try await API.shared.revokeDevice("current")
                        } catch APIError.http(let code, _) where code == 401 || code == 404 {
                            // Already revoked, or this older bridge predates device grants.
                        } catch {
                            if account == app.inboxAccount { localSignOut = true }
                            return
                        }
                        if account == app.inboxAccount { app.signOut() }
                    }
                }
            }
            .confirmationDialog("The bridge couldn’t confirm revocation.", isPresented: $localSignOut, titleVisibility: .visible) {
                Button("Sign Out on This Phone", role: .destructive) { app.signOut() }
                Button("Keep Signed In", role: .cancel) {}
            } message: {
                Text("Signing out here clears this phone. You can revoke its grant later on the host.")
            }
        }
    }
}

/// One saved gateway. `isCurrent` marks the origin this phone is signed in to now; the rest are
/// switchable rows, so chats, files and approvals move as a unit and never bleed between Macs.
private struct GatewayRow: View {
    let name: String
    let detail: String
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: HMDesign.medium) {
            Image(systemName: "server.rack")
                .foregroundStyle(isCurrent ? HMDesign.accent : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                Text(name).font(HMDesign.rowTitle).foregroundStyle(.primary)
                Text(detail).font(HMDesign.metadata).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                if isCurrent {
                    Label {
                        Text("Current")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(HMDesign.metadata.weight(.semibold)).foregroundStyle(.primary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Read-only list of the bots Hermes knows. Nothing here changes server settings.
private struct SettingsBotsList: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            if let e = app.loadError {
                VStack(alignment: .leading, spacing: HMDesign.small) {
                    Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Button("Try again") { Task { await app.refreshBots() } }.hmTouchTarget()
                }
            }
            if app.botsLoaded && app.bots.isEmpty && app.loadError == nil {
                Text("This gateway reported no bots. Pull to refresh.").foregroundStyle(.secondary)
            } else if !app.botsLoaded && app.loadError == nil {
                HStack { Spacer(); ProgressView("Loading bots…"); Spacer() }.listRowBackground(Color.clear)
            }
            ForEach(app.bots) { bot in
                NavigationLink { BotDetailView(bot: bot) } label: { BotRow(bot: bot) }
                    .disabled(!bot.reachable)
            }
        }
        .hmCanvas()
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.refreshBots() }
    }
}

private struct DeviceAccessView: View {
    let capabilities: BridgeCapabilities
    @State private var devices: [DeviceGrant] = []
    @State private var offer: DevicePairCode?
    @State private var error: String?
    @State private var selected: DeviceGrant?
    @State private var busy = false

    var body: some View {
        Form {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if capabilities.manageDevices {
                Section("Signed-in devices") {
                    ForEach(devices) { device in
                        AdaptiveTitleRow {
                            VStack(alignment: .leading, spacing: HMDesign.micro) {
                                Text(device.name).font(HMDesign.rowTitle)
                                Text("Expires " + Date(timeIntervalSince1970: device.expires).formatted(date: .abbreviated, time: .omitted))
                                    .font(HMDesign.metadata).foregroundStyle(.secondary)
                            }
                        } trailing: {
                            if device.id == capabilities.deviceID {
                                Text("This phone").font(HMDesign.metadata).foregroundStyle(.secondary)
                            } else {
                                Button("Revoke", role: .destructive) { selected = device }
                                    .buttonStyle(.borderless).disabled(busy).hmTouchTarget()
                            }
                        }
                    }
                }
                Section {
                    Button("Create One-Time Pairing Code") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { offer = try await API.shared.pairingCode(); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy)
                    if let offer {
                        Text(offer.code).font(.body.monospaced()).textSelection(.enabled)
                        Text("Expires at " + Date(timeIntervalSince1970: offer.expires).formatted(date: .omitted, time: .shortened))
                            .font(HMDesign.metadata).foregroundStyle(.secondary)
                    }
                } footer: { Text("A paired phone can access chats, tools and approvals on this bridge.") }
            } else {
                Section {
                    Text("This phone has its own revocable sign-in. The bridge owner can manage devices on the host.")
                }
            }
        }
        .hmCanvas()
        .navigationTitle("Device access")
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("Revoke this device’s access?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible, presenting: selected) { device in
            Button("Revoke " + device.name, role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await API.shared.revokeDevice(device.id); await reload() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func reload() async {
        guard capabilities.manageDevices else { return }
        do { devices = try await API.shared.devices(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

/// Open a saved host directly, or explicitly search the unarchived history on every paired host.
struct GatewayDestinationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var input = ""
    @State private var search: Search?
    @State private var states: [URL: Outcome] = [:]
    @State private var error: String?

    private struct Search: Equatable {
        let id = UUID()
        let text: String
    }

    private enum Outcome {
        case matches(GatewayLogin, [SessionSummary])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.savedGateways, id: \.self) { url in
                        Button {
                            do {
                                if url != API.shared.baseURL { try app.switchGateway(url) }
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: HMDesign.micro) {
                                    Text(SavedGateways.displayName(url)).font(HMDesign.rowTitle)
                                    Text(url.absoluteString).font(HMDesign.metadata).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if url == API.shared.baseURL {
                                    Image(systemName: "checkmark").accessibilityLabel("Current gateway")
                                }
                            }
                        }
                    }
                    Button("Add gateway", systemImage: "plus") { adding = true }
                } header: { Text("Switch gateway") } footer: { Text("Chats, files and approvals stay on the gateway you choose.") }
                if app.savedGateways.count > 1 {
                    Section {
                        HStack {
                            TextField("Find a chat on any gateway", text: $input)
                                .submitLabel(.search).onSubmit(submit)
                                .onChange(of: input) { _, _ in search = nil; states.removeAll() }
                            Button("Search", action: submit)
                                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } footer: { Text("Search sends these words to each saved gateway.") }
                    if search != nil {
                        ForEach(app.savedGateways, id: \.self) { url in
                            Section {
                                switch states[url] {
                                case .none:
                                    HStack { ProgressView().controlSize(.small); Text("Searching…") }
                                case .failed(let reason):
                                    Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                                case .matches(let login, let rows):
                                    if rows.isEmpty { Text("No matching chats").foregroundStyle(.secondary) }
                                    ForEach(rows, id: \.key) { row in
                                        Button {
                                            do { try app.openDestinationChat(row, on: login); dismiss() }
                                            catch { self.error = error.localizedDescription }
                                        } label: {
                                            VStack(alignment: .leading) {
                                                Text(row.displayTitle).lineLimit(2)
                                                Text(row.profile + " · " + row.sourceLabel).font(HMDesign.metadata).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                                    .textCase(nil)
                            }
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .hmCanvas()
            .navigationTitle("Gateways")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { SignInView(adding: true) }
            .task(id: search) { if let search { await find(search) } }
        }
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        error = nil
        states.removeAll()
        search = Search(text: text)
    }

    @MainActor private func find(_ request: Search) async {
        let client = API.shared
        await withTaskGroup(of: (URL, Outcome).self) { group in
            for url in app.savedGateways {
                guard let login = API.accounts.credential(url) else {
                    states[url] = .failed("Sign in again to search this gateway.")
                    continue
                }
                group.addTask {
                    do { return (url, .matches(login, try await client.searchDestination(login, text: request.text))) }
                    catch { return (url, .failed(error.localizedDescription)) }
                }
            }
            for await (url, state) in group {
                guard !Task.isCancelled, request == search, client === API.shared else { group.cancelAll(); return }
                states[url] = state
            }
        }
    }
}

/// Theme and accent. Swatches show the real canvas, surface and accent, so the choice is visual, not a name.
struct AppearanceSection: View {
    @AppStorage(HMTheme.themeKey) private var themeRaw = HMThemeChoice.system.rawValue
    @AppStorage(HMTheme.accentKey) private var accentRaw = HMAccent.theme.rawValue
    @AppStorage(HMGlass.key) private var glass = true

    var body: some View {
        Section("Appearance") {
            ForEach(HMThemeChoice.allCases) { theme in
                Button { themeRaw = theme.rawValue } label: {
                    HStack(spacing: 12) {
                        swatch(theme)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(theme.title).foregroundStyle(.primary)
                            Text(theme.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if themeRaw == theme.rawValue {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(HMDesign.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(themeRaw == theme.rawValue ? .isSelected : [])
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Accent").font(.subheadline)
                HStack(spacing: 10) {
                    ForEach(HMAccent.allCases) { accent in
                        Button { accentRaw = accent.rawValue } label: {
                            Circle()
                                .fill(accentFill(accent))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(HMDesign.ink.opacity(accentRaw == accent.rawValue ? 0.9 : 0), lineWidth: 2).padding(-4))
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accent.title + " accent")
                        .accessibilityAddTraits(accentRaw == accent.rawValue ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)
            if #available(iOS 26.0, *) {
                Toggle(isOn: $glass) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Liquid Glass")
                        Text("Glass message box and controls. Off uses the theme's flat colors.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: themeRaw + accentRaw)
    }

    private func accentFill(_ accent: HMAccent) -> Color {
        guard let pair = accent.hex else { return HMDesign.accent }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: pair.1) : UIColor(hex: pair.0) })
    }

    private func swatch(_ theme: HMThemeChoice) -> some View {
        let palette: HMPalette = theme == .paper ? .paper : theme == .oled ? .oled : .ash
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: UIColor(hex: palette.canvas)))
            RoundedRectangle(cornerRadius: 4).fill(Color(uiColor: UIColor(hex: palette.surface))).frame(width: 22, height: 12).padding(5)
            Circle().fill(Color(uiColor: UIColor(hex: palette.accent))).frame(width: 7, height: 7).padding(3)
        }
        .overlay {
            if theme == .system {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: UIColor(hex: HMPalette.paper.canvas)))
                    .mask(Rectangle().rotationEffect(.degrees(45)).offset(x: 20, y: 20))
            }
        }
        .frame(width: 40, height: 40)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HMDesign.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
