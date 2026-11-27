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
                    if let gatewayError { Label(gatewayError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.danger) }
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Chats, files and approvals stay on the gateway you choose.")
                }.hmRows()
                AppearanceSection()
                Section(header: HMHeader("Hermes server")) {
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
                }.hmRows()
                Section {
                    NavigationLink { DeletionPinView() } label: { Label("Deletion PIN", systemImage: "lock") }
                        .accessibilityIdentifier("settings.deletionPin")
                        .accessibilityHint("Choose or change the PIN that protects archiving projects and bots")
                } footer: { Text("Owner only. Each Mac has its own PIN; there is no default.") }.hmRows()
                ProviderUsageSection()
                Section {
                    Text("Chats, bots and model choices live in Hermes on your server, so this phone and the desktop app show the same thing. Away from home, keep Tailscale on.")
                        .font(.footnote).foregroundStyle(HMDesign.text2)
                }.hmRows()
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Hermes Mobile \(appVersion)")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .accessibilityLabel("App version \(appVersion)")
                }.hmRows()
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
                .foregroundStyle(isCurrent ? HMDesign.accent : HMDesign.text2)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                Text(name).font(HMDesign.rowTitle).foregroundStyle(HMDesign.ink)
                Text(detail).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                    .lineLimit(2).truncationMode(.middle)
                if isCurrent {
                    Label {
                        Text("Current")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(HMDesign.success)
                    }
                    .font(HMDesign.metadata.weight(.semibold)).foregroundStyle(HMDesign.ink)
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
                    Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(HMDesign.text2)
                    Button("Try again") { Task { await app.refreshBots() } }.hmTouchTarget()
                }
            }
            if app.botsLoaded && app.bots.isEmpty && app.loadError == nil {
                Text("This gateway reported no bots. Pull to refresh.").foregroundStyle(HMDesign.text2)
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
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.danger) }
            if capabilities.manageDevices {
                Section(header: HMHeader("Signed-in devices")) {
                    ForEach(devices) { device in
                        AdaptiveTitleRow {
                            VStack(alignment: .leading, spacing: HMDesign.micro) {
                                Text(device.name).font(HMDesign.rowTitle)
                                Text("Expires " + Date(timeIntervalSince1970: device.expires).formatted(date: .abbreviated, time: .omitted))
                                    .font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                            }
                        } trailing: {
                            if device.id == capabilities.deviceID {
                                Text("This phone").font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                            } else {
                                Button("Revoke", role: .destructive) { selected = device }
                                    .buttonStyle(.borderless).disabled(busy).hmTouchTarget()
                            }
                        }
                    }
                }.hmRows()
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
                            .font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                    }
                } footer: { Text("A paired phone can access chats, tools and approvals on this bridge.") }.hmRows()
            } else {
                Section {
                    Text("This phone has its own revocable sign-in. The bridge owner can manage devices on the host.")
                }.hmRows()
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
                                    Text(url.absoluteString).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                                }
                                Spacer()
                                if url == API.shared.baseURL {
                                    Image(systemName: "checkmark").accessibilityLabel("Current gateway")
                                }
                            }
                        }
                    }
                    Button("Add gateway", systemImage: "plus") { adding = true }
                } header: { Text("Switch gateway") } footer: { Text("Chats, files and approvals stay on the gateway you choose.") }.hmRows()
                if app.savedGateways.count > 1 {
                    Section {
                        HStack {
                            TextField("Find a chat on any gateway", text: $input)
                                .submitLabel(.search).onSubmit(submit)
                                .onChange(of: input) { _, _ in search = nil; states.removeAll() }
                            Button("Search", action: submit)
                                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } footer: { Text("Search sends these words to each saved gateway.") }.hmRows()
                    if search != nil {
                        ForEach(app.savedGateways, id: \.self) { url in
                            Section {
                                switch states[url] {
                                case .none:
                                    HStack { ProgressView().controlSize(.small); Text("Searching…") }
                                case .failed(let reason):
                                    Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(HMDesign.text2)
                                case .matches(let login, let rows):
                                    if rows.isEmpty { Text("No matching chats").foregroundStyle(HMDesign.text2) }
                                    ForEach(rows, id: \.key) { row in
                                        Button {
                                            do { try app.openDestinationChat(row, on: login); dismiss() }
                                            catch { self.error = error.localizedDescription }
                                        } label: {
                                            VStack(alignment: .leading) {
                                                Text(row.displayTitle).lineLimit(2)
                                                Text(row.profile + " · " + row.sourceLabel).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                                    .textCase(nil)
                            }.hmRows()
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.danger) }
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

/// Appearance: theme (Thermocline or Classic) and mode (System, Light, Dark).
struct AppearanceSection: View {
    @AppStorage(HMTheme.themeKey) private var themeRaw = HMThemeKind.thermocline.rawValue
    @AppStorage(HMTheme.modeKey) private var modeRaw = HMMode.system.rawValue
    @AppStorage(HMGlass.key) private var glass = true

    var body: some View {
        Section(header: HMHeader("Appearance")) {
            Picker("Theme", selection: $themeRaw) {
                ForEach(HMThemeKind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text((HMThemeKind(rawValue: themeRaw) ?? .thermocline).detail).font(.caption).foregroundStyle(HMDesign.text2)
            Picker("Mode", selection: $modeRaw) {
                ForEach(HMMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if themeRaw == HMThemeKind.classic.rawValue, #available(iOS 26.0, *) {
                Toggle(isOn: $glass) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Liquid Glass")
                        Text("Glass message box and controls. Off uses flat colors.").font(.caption).foregroundStyle(HMDesign.text2)
                    }
                }
            }
        }.hmRows()
        .sensoryFeedback(.selection, trigger: themeRaw + modeRaw)
    }
}
