import SwiftUI

struct BotsView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = app.loadError { Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
                ForEach(app.bots) { bot in
                    NavigationLink(value: bot) { BotRow(bot: bot) }
                        .disabled(!bot.reachable)
                }
                ManagePersonasSection()  // build5 manage hook
            }
            .navigationTitle("Bots")
            .modifier(ManageBotsToolbar())  // build5 manage hook
            .navigationDestination(for: Bot.self) { BotDetailView(bot: $0) }
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .refreshable { await app.refreshBots() }
        }
    }
}

struct BotRow: View {
    let bot: Bot
    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(id: bot.id, name: bot.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(bot.name).font(.body.weight(.semibold))
                    if bot.front { Text("Front door").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: Capsule()) }
                }
                if !bot.blurb.isEmpty { Text(bot.blurb).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                Text("\(bot.model) · \(bot.provider)").font(.caption).foregroundStyle(.tertiary)
                if !bot.skills.isEmpty {
                    Text(bot.skills.prefix(4).joined(separator: ", ") + (bot.skills.count > 4 ? " +\(bot.skills.count - 4)" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !bot.reachable { Text("No API key — not reachable").font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct BotDetailView: View {
    @Environment(AppModel.self) private var app
    let bot: Bot
    @State private var sessions: [SessionSummary] = []
    @State private var cursor: String?
    @State private var showAutomations = false
    @State private var skills: [String] = []
    @State private var skillEditor: SkillEditor?

    var body: some View {
        List {
            Section {
                NavigationLink(value: ChatRef(profile: bot.id, sessionId: nil)) {
                    Label("New chat with \(bot.name)", systemImage: "square.and.pencil").font(.body.weight(.semibold))
                }
            } footer: { Text("Default: \(bot.model) · \(bot.provider). You can switch per chat.") }
            Section {
                Button { skillEditor = SkillEditor(name: "", appending: false) } label: {
                    Label("Teach a skill", systemImage: "plus")
                }
                ForEach(skills, id: \.self) { name in
                    Button { skillEditor = SkillEditor(name: name, appending: true) } label: {
                        LabeledContent(name) { Image(systemName: "note.text.badge.plus").foregroundStyle(.secondary) }
                    }
                    .accessibilityLabel("Add a note to \(name)")
                }
            } header: {
                Text("Skills")
            } footer: {
                Text(skills.isEmpty
                     ? "Teach \(bot.name) with /learn in a chat, or write a skill here. Hermes stores it on your Mac."
                     : "Tap a skill to append a note. /learn in a chat can also teach from a link or the conversation.")
            }
            Section {
                Toggle("Show scheduled & one-shot runs", isOn: $showAutomations)
            }
            ManageBotSection(bot: bot)  // build5 manage hook
            Section("Sessions") {
                ForEach(sessions) { s in
                    NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
                        SessionRow(session: s, botName: bot.name)
                    }
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.task(id: cursor) { await more() }
                } else if sessions.isEmpty {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(bot.name)
        .task(id: showAutomations) { skills = bot.skills; await load() }
        .refreshable { await load() }
        .sheet(item: $skillEditor) { editor in
            SkillEditorSheet(bot: bot, editor: editor) { skills = $0 }
        }
    }

    private var exclude: [String] { showAutomations ? [] : ["cron", "oneshot", "subagent", "tool"] }

    private func load() async {
        guard let page = try? await API.shared.sessions(cursor: nil, profile: bot.id, exclude: exclude) else { return }
        sessions = page.data
        cursor = page.next
    }

    private func more() async {
        guard let c = cursor, let page = try? await API.shared.sessions(cursor: c, profile: bot.id, exclude: exclude) else {
            cursor = nil; return
        }
        var seen = Set(sessions.map(\.key))
        sessions += page.data.filter { seen.insert($0.key).inserted }
        cursor = page.next
    }
}

struct SkillEditor: Identifiable {
    let id = UUID()
    var name: String
    var appending: Bool
}

private struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    let editor: SkillEditor
    let saved: ([String]) -> Void
    @State private var name: String
    @State private var description = ""
    @State private var bodyText = ""
    @State private var error: String?
    @State private var saving = false

    init(bot: Bot, editor: SkillEditor, saved: @escaping ([String]) -> Void) {
        self.bot = bot
        self.editor = editor
        self.saved = saved
        _name = State(initialValue: editor.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                if editor.appending {
                    Section { Text(editor.name).font(.body.weight(.semibold)) } header: { Text("Skill") }
                    Section("Note to append") {
                        TextField("What should this skill also say?", text: $bodyText, axis: .vertical)
                            .lineLimit(4...10)
                    }
                } else {
                    Section("Name") {
                        TextField("print-plates", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("What it is") {
                        TextField("One line", text: $description)
                    }
                    Section("Instructions") {
                        TextField("The steps this bot should follow", text: $bodyText, axis: .vertical)
                            .lineLimit(5...12)
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle(editor.appending ? "Add a note" : "New skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.appending ? "Append" : "Create") { Task { await save() } }
                        .disabled(saving || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count < (editor.appending ? 2 : 8)
                                  || (!editor.appending && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        do {
            let names: [String]
            if editor.appending {
                names = try await API.shared.saveSkill(profile: bot.id, action: "append", name: editor.name, note: bodyText)
            } else {
                names = try await API.shared.saveSkill(profile: bot.id, action: "create", name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       description: description, body: bodyText)
            }
            saved(names)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            saving = false
        }
    }
}
