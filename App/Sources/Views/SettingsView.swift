import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false
    @State private var localSignOut = false
    @State private var addingGateway = false
    @State private var gatewayError: String?
    @State private var capabilities: BridgeCapabilities?

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateways") {
                    ForEach(app.savedGateways, id: \.self) { url in
                        if url == API.shared.baseURL {
                            Label(url.absoluteString, systemImage: "checkmark")
                                .accessibilityLabel("Active gateway, " + url.absoluteString)
                        } else {
                            Button(url.absoluteString) {
                                do { try app.switchGateway(url) } catch { gatewayError = error.localizedDescription }
                            }
                        }
                    }
                    Button("Add Gateway", systemImage: "plus") { addingGateway = true }
                    if let gatewayError { Text(gatewayError).foregroundStyle(.red) }
                }
                Section("Hermes server") {
                    if let caps = capabilities, caps.features.contains("device_grants") {
                        NavigationLink { DeviceAccessView(capabilities: caps) } label: {
                            Label("Device access", systemImage: "iphone")
                        }
                    }
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

private struct DeviceAccessView: View {
    let capabilities: BridgeCapabilities
    @State private var devices: [DeviceGrant] = []
    @State private var offer: DevicePairCode?
    @State private var error: String?
    @State private var selected: DeviceGrant?
    @State private var busy = false

    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red) }
            if capabilities.manageDevices {
                Section("Signed-in devices") {
                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text("Expires " + Date(timeIntervalSince1970: device.expires).formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == capabilities.deviceID {
                                Text("This phone").font(.caption)
                            } else {
                                Button("Revoke", role: .destructive) { selected = device }
                                    .buttonStyle(.borderless).disabled(busy)
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
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: { Text("A paired phone can access chats, tools and approvals on this bridge.") }
            } else {
                Section {
                    Text("This phone has its own revocable sign-in. The bridge owner can manage devices on the host.")
                }
            }
        }
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
                                VStack(alignment: .leading) {
                                    Text(SavedGateways.displayName(url)).font(.headline)
                                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
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
                                                Text(row.profile + " · " + row.sourceLabel).font(.caption).foregroundStyle(.secondary)
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
                if let error { Text(error).foregroundStyle(.red) }
            }
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
