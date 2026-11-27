import SwiftUI
import UIKit

struct SignInView: View {
    @Environment(AppModel.self) private var app
    let adding: Bool
    @State private var server: String
    init(adding: Bool = false) {
        self.adding = adding
        _server = State(initialValue: adding ? "" : UserDefaults.standard.string(forKey: "server") ?? "")
    }
    private var peerOrigin: URL? { adding ? SavedGateways.peerOrigin(server, relativeTo: API.shared.baseURL) : nil }
    @State private var username = ""
    @State private var password = ""
    @State private var pairing = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: Field?
    private enum Field { case server, user, pass }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: HMDesign.small) {
                        HStack(spacing: HMDesign.small) {
                            if HMTheme.isThermocline { HorizonEyeMark().frame(width: 40, height: 40).accessibilityHidden(true) }
                            else { Image(systemName: "flame.fill").font(.title2).foregroundStyle(.tint).accessibilityHidden(true) }
                            Text("Hermes").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        }
                        Text(adding ? "Add a gateway." : "Sign in to your gateway.")
                            .font(.subheadline).foregroundStyle(HMDesign.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, HMDesign.small)
                    .listRowBackground(Color.clear)
                }.hmRows()
                if !adding && !app.savedGateways.isEmpty {
                    Section(header: HMHeader("Saved gateways")) {
                        ForEach(app.savedGateways, id: \.self) { gateway in
                            Button {
                                do { try app.switchGateway(gateway) } catch { self.error = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading, spacing: HMDesign.micro) {
                                    Text(SavedGateways.displayName(gateway)).font(HMDesign.rowTitle)
                                    Text(gateway.absoluteString).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                .hmTouchTarget()
                            }
                        }
                    }.hmRows()
                }
                Section {
                    TextField("Server address", text: $server, prompt: Text("https://your-server.tailnet.ts.net:10001").foregroundStyle(HMDesign.text2))
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($focus, equals: .server)
                        .accessibilityLabel("Server address")
                        .submitLabel(.next).onSubmit { focus = .user }
                } header: { Text("Server") } footer: {
                    if let peerOrigin {
                        Text("Connect to " + peerOrigin.absoluteString)
                    } else if adding, SavedGateways.peerOrigin("peer", relativeTo: API.shared.baseURL) != nil {
                        Text("Enter a machine name on this tailnet or a full HTTPS address.")
                    } else {
                        Text("Use your Hermes bridge’s HTTPS address. Keep Tailscale connected.")
                    }
                }.hmRows()
                Section {
                    methodPicker
                    if pairing {
                        SecureField("One-time code", text: $code, prompt: Text("One-time code").foregroundStyle(HMDesign.text2))
                            .accessibilityLabel("One-time code")
                            .textContentType(.oneTimeCode).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { Task { await signIn() } }
                    } else {
                        TextField("Username", text: $username, prompt: Text("Username").foregroundStyle(HMDesign.text2))
                            .accessibilityLabel("Username")
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
                        SecureField("Password", text: $password, prompt: Text("Password").foregroundStyle(HMDesign.text2))
                            .accessibilityLabel("Password")
                            .textContentType(.password).focused($focus, equals: .pass)
                            .submitLabel(.go).onSubmit { Task { await signIn() } }
                    }
                } header: { Text("Account") } footer: {
                    Text(pairing ? "Use a code from the host or a signed-in owner device. It expires in five minutes."
                                 : "Use your Hermes dashboard login. Google sign-in is for Tailscale.")
                }.hmRows()
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.danger) }.hmRows()
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Group {
                            if busy { ProgressView(pairing ? "Pairing…" : "Signing in…") } else { Text("Sign In").font(.headline) }
                        }
                        .frame(maxWidth: .infinity, minHeight: HMDesign.touch)
                    }
                    .accessibilityLabel(busy ? (pairing ? "Pairing" : "Signing in") : "Sign In")
                    .disabled(busy || server.isEmpty || (pairing ? code.isEmpty : username.isEmpty || password.isEmpty))
                }.hmRows()
            }
            .hmCanvas()
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
        }
    }

    @ViewBuilder private var methodPicker: some View {
        if typeSize.isAccessibilitySize {
            Picker("Sign-in method", selection: $pairing) {
                Text("Password").tag(false)
                Text("Pairing code").tag(true)
            }.pickerStyle(.menu)
        } else {
            Picker("Sign-in method", selection: $pairing) {
                Text("Password").tag(false)
                Text("Pairing code").tag(true)
            }.pickerStyle(.segmented)
        }
    }

    private func signIn() async {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard !busy, let parsed = peerOrigin ?? URL(string: s), let url = SavedGateways.origin(parsed), let scheme = url.scheme else { error = "That address doesn't look right."; return }
        busy = true
        defer { busy = false }
        let client = API.shared
        do {
            let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
            guard scheme == "https" || local else {
                error = "Use the HTTPS address of your bridge."
                return
            }
            let login: GatewayLogin
            if pairing {
                login = try await client.pair(server: url, code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                                          device: UIDevice.current.name)
                code = ""
            } else {
                login = try await client.signIn(server: url, username: username, password: password, device: UIDevice.current.name)
            }
            guard !Task.isCancelled, client === API.shared else { return }
            try app.connect(login)
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)

        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = error.localizedDescription
        }
    }
}
