import SwiftUI

/// Settings -> Deletion PIN (owner only). Each install chooses its own PIN; there is no default.
/// First set: new PIN twice. Change: current PIN plus the new one twice (the Mac's shared lockout applies).
/// The fields are cleared after every attempt and when the screen goes away.
struct DeletionPinView: View {
    @State private var configured: Bool?
    @State private var failure: String?
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var done: String?

    var body: some View {
        Form {
            if let configured {
                Section {
                    Text(configured ? "A deletion PIN is set on your Mac. It protects archiving projects and bots."
                                    : "No deletion PIN is set yet. Archiving projects and bots stays locked until you choose one.")
                        .font(.footnote).foregroundStyle(HMDesign.text2)
                }.hmRows()
                Section(configured ? "Change PIN" : "Choose a PIN") {
                    if configured { field("Current PIN", $current, id: "pinsetup.current") }
                    field("New 4-digit PIN", $new, id: "pinsetup.new")
                    field("New PIN again", $confirm, id: "pinsetup.confirm")
                }.hmRows()
                Section {
                    Button(configured ? "Change PIN" : "Set PIN") { Task { await save(configured) } }
                        .disabled(busy || PINSetup.problem(new: new, confirm: confirm, current: current, configured: configured) != nil)
                        .accessibilityIdentifier("pinsetup.save")
                } footer: {
                    if let p = PINSetup.problem(new: new, confirm: confirm, current: current, configured: configured),
                       !(new.isEmpty && confirm.isEmpty && current.isEmpty) { Text(p) }
                }.hmRows()
            } else if failure == nil {
                Section { ProgressView("Checking your Mac…") }.hmRows()
            }
            if let failure { Section { Text(failure).foregroundStyle(HMDesign.danger).accessibilityIdentifier("pinsetup.error") }.hmRows() }
            if let done { Section { Text(done).accessibilityIdentifier("pinsetup.done") }.hmRows() }
        }
        .hmCanvas()
        .navigationTitle("Deletion PIN")
        .task { await load() }
        .onDisappear { clear() }
    }

    private func field(_ title: String, _ text: Binding<String>, id: String) -> some View {
        SecureField(title, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = PINField.filter($0) }))
            .keyboardType(.numberPad)
            .textContentType(nil)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .privacySensitive()
            .accessibilityIdentifier(id)
    }

    private func clear() { current = ""; new = ""; confirm = "" }

    private func load() async {
        do { configured = try await API.shared.managePinConfigured(); failure = nil }
        catch { failure = (error as? ManageFailure ?? .server).message }
    }

    private func save(_ isSet: Bool) async {
        guard PINSetup.problem(new: new, confirm: confirm, current: current, configured: isSet) == nil else { return }
        let body = PINSetup.body(new: new, confirm: confirm, current: current, configured: isSet)
        clear()
        busy = true; defer { busy = false }
        do {
            try await API.shared.manageSetPin(body)
            failure = nil; done = isSet ? "PIN changed." : "PIN set."; configured = true
        } catch {
            done = nil; failure = (error as? ManageFailure ?? .server).message
        }
    }
}
