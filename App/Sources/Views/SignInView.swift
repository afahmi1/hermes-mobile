import SwiftUI
import UIKit

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @State private var username = ""
    @State private var password = ""
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
                        Text("Every chat and every bot on your Mac, in your pocket.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("https://your-mac.tailnet.ts.net:10001", text: $server)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($focus, equals: .server)
                        .submitLabel(.next).onSubmit { focus = .user }
                } header: { Text("Your Mac") } footer: {
                    Text("The Hermes Mobile address Tailscale gives your Mac. Works anywhere your phone is on the tailnet.")
                }
                Section("Dashboard sign-in") {
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
                    SecureField("Password", text: $password)
                        .textContentType(.password).focused($focus, equals: .pass)
                        .submitLabel(.go).onSubmit { Task { await signIn() } }
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
                    .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func signIn() async {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s) else { error = "That address doesn't look right."; return }
        busy = true
        defer { busy = false }
        do {
            try await API.shared.signIn(server: url, username: username, password: password, device: UIDevice.current.name)
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.signedIn = true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            self.error = error.localizedDescription
        }
    }
}
