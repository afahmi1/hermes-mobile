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
                // Where this phone is connected, as one card. Other gateways live one tap in.
                Section {
                    NavigationLink {
                        GatewaysPage(addingGateway: $addingGateway, gatewayError: $gatewayError, forgetting: $forgetting)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HMDesign.accent.opacity(0.16))
                                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(HMDesign.accent)
                            }
                            .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(API.shared.baseURL.map(SavedGateways.displayName) ?? "Not connected").font(.headline)
                                HStack(spacing: 6) {
                                    Circle().fill(app.health?.ok == true ? HMDesign.success : .orange).frame(width: 8, height: 8)
                                    Text([app.health?.version.map { "Hermes " + $0 }, app.savedGateways.count > 1 ? "\(app.savedGateways.count) gateways" : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }.hmRows()
                AppearanceSection()
                Section(header: HMHeader("Hermes")) {
                    NavigationLink { SettingsBotsList() } label: {
                        SettingsRow("Bots", "person.2.fill", .indigo, value: botsSummary)
                    }
                    .accessibilityIdentifier("settings.bots")
                    .accessibilityHint("Shows every bot and whether it is reachable")
                    if let caps = capabilities, caps.features.contains("device_grants") {
                        NavigationLink { DeviceAccessView(capabilities: caps) } label: {
                            SettingsRow("Devices", "iphone", .blue)
                        }
                    }
                    NavigationLink { DeletionPinView() } label: { SettingsRow("Deletion PIN", "lock.fill", .orange) }
                        .accessibilityIdentifier("settings.deletionPin")
                        .accessibilityHint("Choose or change the PIN that protects archiving projects and bots")
                }.hmRows()
                ProviderUsageSection()
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Hermes Mobile \(appVersion)")
                        .multilineTextAlignment(.center)
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

/// A settings row: a small tinted icon tile, the title, and an optional value on the right (like iOS Settings).
struct SettingsRow: View {
    let title: String, symbol: String, tint: Color
    var value: String? = nil
    init(_ title: String, _ symbol: String, _ tint: Color, value: String? = nil) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.value = value
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Every gateway this phone knows: the current one, the others (tap to switch), and Add.
private struct GatewaysPage: View {
    @Environment(AppModel.self) private var app
    @Binding var addingGateway: Bool
    @Binding var gatewayError: String?
    @Binding var forgetting: URL?

    var body: some View {
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
                }.hmRows()
        }
        .hmCanvas()
        .navigationTitle("Gateways")
        .navigationBarTitleDisplayMode(.inline)
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
                Text(detail).font(HMDesign.data).foregroundStyle(HMTheme.isThermocline ? HMDesign.link : HMDesign.text2)
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
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").hmProblem() }
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
                                    Text(url.absoluteString).font(HMDesign.data).foregroundStyle(HMTheme.isThermocline ? HMDesign.link : HMDesign.text2)
                                }
                                Spacer()
                                if url == API.shared.baseURL {
                                    Image(systemName: "checkmark").accessibilityLabel("Current gateway")
                                }
                            }
                        }
                    }
                    Button("Add gateway", systemImage: "plus") { adding = true }
                } header: { HMHeader("Switch gateway") } footer: { Text("Chats, files and approvals stay on the gateway you choose.") }.hmRows()
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
                                HMHeader(url.absoluteString.replacingOccurrences(of: "https://", with: ""), uppercase: false)
                            }.hmRows()
                        }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").hmProblem() }
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

/// Appearance: Theme (Thermocline or Classic), then that theme's own options. Every visual choice shows itself
/// in a small preview instead of a bare name, applies at once, and marks the current value.
struct AppearanceSection: View {
    @AppStorage(HMTheme.themeKey) private var themeRaw = HMThemeKind.thermocline.rawValue
    @AppStorage(HMTheme.modeKey) private var modeRaw = HMMode.system.rawValue
    @AppStorage(HMTheme.classicKey) private var classicRaw = HMThemeChoice.native.rawValue
    @AppStorage(HMTheme.accentKey) private var accentRaw = HMAccent.theme.rawValue
    @AppStorage(HMTheme.thermoclineAccentKey) private var thermoclineAccentRaw = Thermocline.Accent.crown.rawValue
    @AppStorage(HMGlass.key) private var glass = true
    @AppStorage(ThinkingStyle.key) private var thinkingRaw = ThinkingStyle.orbs.rawValue
    @AppStorage(ChatIconStyle.key) private var iconRaw = ChatIconStyle.auto.rawValue
    @AppStorage(StatusPulse.key) private var pulse = true
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isThermocline: Bool { themeRaw != HMThemeKind.classic.rawValue }

    var body: some View {
        Section(header: HMHeader("Appearance")) {
            let stack = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            stack {
                ForEach(HMThemeKind.allCases) { themeCard($0) }
            }
            .padding(.vertical, 6)
            if isThermocline {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mode").font(.subheadline)
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout { ForEach(HMMode.allCases) { modeTile($0) } }
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent").font(.subheadline)
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 4))
                    layout {
                        ForEach(Thermocline.Accent.allCases) { accent in
                            Button { thermoclineAccentRaw = accent.rawValue } label: {
                                AccentSwatch(accent: accent, selected: thermoclineAccentRaw == accent.rawValue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                // Classic: Build 31's own looks, accents and Liquid Glass, unchanged.
                ForEach(HMThemeChoice.allCases) { theme in
                    Button { classicRaw = theme.rawValue } label: {
                        HStack(spacing: 12) {
                            classicSwatch(theme)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(theme.title).foregroundStyle(.primary)
                                Text(theme.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if classicRaw == theme.rawValue {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(HMDesign.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(classicRaw == theme.rawValue ? .isSelected : [])
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent").font(.subheadline)
                    HStack(spacing: 10) {
                        ForEach(HMAccent.allCases) { accent in
                            Button { accentRaw = accent.rawValue } label: {
                                Circle()
                                    .fill(accentFill(accent))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Color(uiColor: HMTheme.classicUIColor(\.ink)).opacity(accentRaw == accent.rawValue ? 0.9 : 0), lineWidth: 2).padding(-4))
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
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Thinking").font(.subheadline)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(ThinkingStyle.allCases) { style in
                        Button { thinkingRaw = style.rawValue } label: {
                            VStack(spacing: 6) {
                                ThinkingIndicator(size: 18, style: style).frame(height: 24)
                                Text(style.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                                    .foregroundStyle(thinkingRaw == style.rawValue ? Color.primary : .secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(thinkingRaw == style.rawValue ? HMDesign.accent.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(thinkingRaw == style.rawValue ? HMDesign.accent : HMDesign.separator, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title + " thinking indicator")
                        .accessibilityAddTraits(thinkingRaw == style.rawValue ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)
            Picker("Chat icons", selection: $iconRaw) {
                ForEach(ChatIconStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Heartbeat strip on Status", isOn: $pulse)
        }.hmRows()
        .sensoryFeedback(.selection, trigger: [themeRaw, modeRaw, classicRaw, accentRaw, thermoclineAccentRaw, thinkingRaw, iconRaw].joined(separator: "|"))
    }

    private func themeCard(_ kind: HMThemeKind) -> some View {
        let selected = (kind == .thermocline) == isThermocline
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { themeRaw = kind.rawValue } label: {
            VStack(alignment: .leading, spacing: 8) {
                ThemePreview(kind: kind)
                    .frame(height: 78)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(selected ? HMDesign.accent : HMDesign.separator, lineWidth: selected ? 2 : 0.5))
                HStack(spacing: 4) {
                    Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.ink)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(HMDesign.accent).accessibilityHidden(true) }
                }
                Text(kind.detail).font(.caption).foregroundStyle(HMDesign.text2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title) theme. \(kind.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeTile(_ mode: HMMode) -> some View {
        let selected = modeRaw == mode.rawValue
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { modeRaw = mode.rawValue } label: {
            VStack(spacing: 6) {
                ModePreview(mode: mode)
                    .frame(height: 46)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(selected ? HMDesign.accent : HMDesign.separator, lineWidth: selected ? 2 : 0.5))
                Text(mode.title).font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? HMDesign.ink : HMDesign.text2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title + " mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func accentFill(_ accent: HMAccent) -> Color {
        guard let pair = accent.hex else { return HMTheme.classicColor(\.accent) }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: pair.1) : UIColor(hex: pair.0) })
    }

    private func classicSwatch(_ theme: HMThemeChoice) -> some View {
        let palette: HMPalette = switch theme {
        case .paper: .paper
        case .oled: .oled
        case .phosphor: .phosphor
        case .ink: .ink
        default: .ash
        }
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8).fill(theme == .native ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: UIColor(hex: palette.canvas)))
            RoundedRectangle(cornerRadius: 4).fill(Color(uiColor: UIColor(hex: palette.surface))).frame(width: 22, height: 12).padding(5)
            Circle().fill(theme == .native ? Color.accentColor : Color(uiColor: UIColor(hex: palette.accent))).frame(width: 7, height: 7).padding(3)
        }
        .overlay(alignment: .trailing) {
            // Auto: night on the left, day on the right.
            if theme == .system {
                GeometryReader { g in
                    Color(uiColor: UIColor(hex: HMPalette.paper.canvas)).frame(width: g.size.width / 2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(width: 40, height: 40)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: HMTheme.classicUIColor(\.separator)), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// A theme in miniature: its canvas, a card with two lines of text and an outgoing bubble.
private struct ThemePreview: View {
    let kind: HMThemeKind

    var body: some View {
        ZStack(alignment: .topLeading) {
            if kind == .thermocline {
                HMDepthField()
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Thermocline.text.opacity(0.75)).frame(width: 44, height: 4)
                    Capsule().fill(Thermocline.text3.opacity(0.6)).frame(width: 30, height: 3)
                }
                .padding(8)
                .frame(width: 70, alignment: .leading)
                .hmGlass(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(10)
                Capsule().fill(HMTheme.thermoclineAccent.color).frame(width: 34, height: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            } else {
                HMTheme.classicChoice == .native ? Color(uiColor: .systemGroupedBackground) : HMTheme.classicColor(\.canvas)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(Color(uiColor: HMTheme.classicUIColor(\.ink)).opacity(0.75)).frame(width: 44, height: 4)
                    Capsule().fill(Color(uiColor: .secondaryLabel)).frame(width: 30, height: 3)
                }
                .padding(8)
                .frame(width: 70, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(10)
                Capsule().fill(HMTheme.classicChoice == .native ? HMTheme.nativeAccent : HMTheme.classicColor(\.accent)).frame(width: 34, height: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Thermocline in one mode: paper or ink with a card and a lead dot. Match iPhone shows both, split.
private struct ModePreview: View {
    let mode: HMMode

    var body: some View {
        Group {
            switch mode {
            case .light: scene.environment(\.colorScheme, .light)
            case .dark: scene.environment(\.colorScheme, .dark)
            case .system:
                ZStack {
                    scene.environment(\.colorScheme, .light)
                    scene.environment(\.colorScheme, .dark)
                        .mask {
                            GeometryReader { geometry in
                                let w = geometry.size.width, h = geometry.size.height
                                Path { p in
                                    p.move(to: CGPoint(x: w * 0.68, y: 0))
                                    p.addLine(to: CGPoint(x: w, y: 0))
                                    p.addLine(to: CGPoint(x: w, y: h))
                                    p.addLine(to: CGPoint(x: w * 0.32, y: h))
                                    p.closeSubpath()
                                }
                            }
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var scene: some View {
        ZStack(alignment: .bottomLeading) {
            Thermocline.bg
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(HMDesign.card)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Thermocline.line, lineWidth: 0.5))
                .frame(width: 38, height: 18).padding(8)
            Circle().fill(HMTheme.thermoclineAccent.color).frame(width: 9, height: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
        }
    }
}
