import SwiftUI

struct BotsView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = app.loadError {
                    VStack(alignment: .leading, spacing: HMDesign.small) {
                        Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(HMDesign.text2)
                        Button("Try again") { Task { await app.refreshBots() } }.hmTouchTarget()
                    }.hmRows()
                } else if !app.botsLoaded {
                    HStack { Spacer(); ProgressView("Loading bots…"); Spacer() }.listRowBackground(Color.clear)
                } else if app.bots.isEmpty {
                    Text("No bots reported. Pull to refresh.").foregroundStyle(HMDesign.text2).hmRows()
                }
                ForEach(app.bots) { bot in
                    NavigationLink(value: bot) { BotRow(bot: bot) }
                        .disabled(!bot.reachable)
                }.hmRows()
                ManagePersonasSection()  // build5 manage hook
            }
            .hmCanvas()
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
        HStack(alignment: .top, spacing: HMDesign.medium) {
            BotAvatar(id: bot.id, name: bot.name, size: 44)
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                AdaptiveTitleRow {
                    Text(bot.name).font(HMDesign.rowTitle)
                } trailing: {
                    if bot.front {
                        if HMTheme.isThermocline {
                            HMTag(text: "Front door")
                        } else {
                            Text("Front door").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                    }
                }
                if !bot.blurb.isEmpty { Text(bot.blurb).font(.subheadline).foregroundStyle(HMDesign.text2).lineLimit(2) }
                Text("\(bot.model) · \(bot.provider)").font(HMDesign.data)
                    .foregroundStyle(HMTheme.isThermocline ? HMDesign.text3 : HMDesign.text2).lineLimit(2)
                if !bot.skills.isEmpty {
                    Text(bot.skills.prefix(4).joined(separator: ", ") + (bot.skills.count > 4 ? " +\(bot.skills.count - 4)" : ""))
                        .font(HMDesign.data).foregroundStyle(HMTheme.isThermocline ? HMDesign.text3 : HMDesign.text2).lineLimit(1)
                }
                if !bot.reachable {
                    Label("No API key. Not reachable.", systemImage: "exclamationmark.triangle.fill")
                        .font(HMDesign.metadata).hmProblem(HMDesign.text2)
                }
            }
        }
        .padding(.vertical, HMDesign.micro)
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
    @State private var addons = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: ChatRef(profile: bot.id, sessionId: nil)) {
                    Label("New chat with \(bot.name)", systemImage: "square.and.pencil").font(.body.weight(.semibold))
                }
            } footer: { Text("Default: \(bot.model) · \(bot.provider). You can switch per chat.") }.hmRows()
            Section {
                Button { skillEditor = SkillEditor(name: "", appending: false) } label: {
                    Label("Teach a skill", systemImage: "plus")
                }
                if addons {
                    NavigationLink { AddonsView(profile: bot.id, botName: bot.name) } label: {
                        Label("Browse Add-ons", systemImage: "puzzlepiece.extension")
                    }
                }
                ForEach(skills, id: \.self) { name in
                    Button { skillEditor = SkillEditor(name: name, appending: true) } label: {
                        LabeledContent(name) { Image(systemName: "note.text.badge.plus").foregroundStyle(HMDesign.text2) }
                    }
                    .accessibilityLabel("Add a note to \(name)")
                }
            } header: {
                HMHeader("Skills")
            } footer: {
                Text(skills.isEmpty
                     ? "Teach \(bot.name) with /learn in a chat, or write a skill here. Hermes stores it on your Mac."
                     : "Tap a skill to append a note. /learn in a chat can also teach from a link or the conversation.")
            }.hmRows()
            Section {
                Toggle("Show scheduled & one-shot runs", isOn: $showAutomations)
            }.hmRows()
            ManageBotSection(bot: bot)  // build5 manage hook
            Section(header: HMHeader("Sessions")) {
                ForEach(sessions) { s in
                    NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
                        SessionRow(session: s, botName: bot.name)
                    }
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.task(id: cursor) { await more() }
                } else if sessions.isEmpty {
                    Text("No sessions yet. Start a chat above.").foregroundStyle(HMDesign.text2)
                }
            }.hmRows()
        }
        .hmCanvas()
        .navigationTitle(bot.name)
        .task(id: showAutomations) { skills = bot.skills; await load() }
        .task { addons = (try? await API.shared.capabilities())?.addons == true }
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
                    Section { Text(editor.name).font(.body.weight(.semibold)) } header: { HMHeader("Skill") }.hmRows()
                    Section(header: HMHeader("Note to append")) {
                        TextField("What should this skill also say?", text: $bodyText, axis: .vertical)
                            .lineLimit(4...10)
                    }.hmRows()
                } else {
                    Section(header: HMHeader("Name")) {
                        TextField("print-plates", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }.hmRows()
                    Section(header: HMHeader("What it is")) {
                        TextField("One line", text: $description)
                    }.hmRows()
                    Section(header: HMHeader("Instructions")) {
                        TextField("The steps this bot should follow", text: $bodyText, axis: .vertical)
                            .lineLimit(5...12)
                    }.hmRows()
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).hmProblem() }
            }
            .hmCanvas()
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
