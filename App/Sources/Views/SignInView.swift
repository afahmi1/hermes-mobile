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
    @FocusState private var focus: Field?
    private enum Field { case server, user, pass }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.tint)
                        Text("Hermes").font(.largeTitle.bold())
                        Text("Connect to your Hermes gateway.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                if !adding && !app.savedGateways.isEmpty {
                    Section("Saved gateways") {
                        ForEach(app.savedGateways, id: \.self) { gateway in
                            Button(gateway.absoluteString) {
                                do { try app.switchGateway(gateway) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Section {
                    TextField("https://your-server.tailnet.ts.net:10001", text: $server)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($focus, equals: .server)
                        .submitLabel(.next).onSubmit { focus = .user }
                } header: { Text("Server address") } footer: {
                    if let peerOrigin {
                        Text("Connect to " + peerOrigin.absoluteString)
                    } else if adding, SavedGateways.peerOrigin("peer", relativeTo: API.shared.baseURL) != nil {
                        Text("Enter a machine name on this tailnet, or the full HTTPS address of a bridge.")
                    } else {
                        Text("Enter the HTTPS address of your Hermes Mobile bridge. Keep Tailscale connected on your phone.")
                    }
                }
                Section {
                    Picker("Sign-in method", selection: $pairing) {
                        Text("Password").tag(false)
                        Text("Pairing code").tag(true)
                    }.pickerStyle(.segmented)
                    if pairing {
                        SecureField("One-time code", text: $code)
                            .textContentType(.oneTimeCode).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { Task { await signIn() } }
                    } else {
                        TextField("Username", text: $username)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
                        SecureField("Password", text: $password)
                            .textContentType(.password).focused($focus, equals: .pass)
                            .submitLabel(.go).onSubmit { Task { await signIn() } }
                    }
                } header: { Text("Connect this phone") } footer: {
                    Text(pairing ? "Use a code from the host or an owner’s signed-in device. Codes expire in five minutes."
                                 : "Use your Hermes dashboard credentials. Google sign-in connects Tailscale.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Sign In").bold() }; Spacer() }
                    }
                    .disabled(busy || server.isEmpty || (pairing ? code.isEmpty : username.isEmpty || password.isEmpty))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
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
