import SwiftUI

// Owner-management screens (build 5, slice B). All the logic is in Management.swift; these views only
// bind to those models. ProjectsView / BotsView each carry one-line hooks into this file.

// MARK: - Shared pieces

private struct ManageErrorLabel: View {
    let failure: ManageFailure?
    var body: some View {
        if let failure {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(HMDesign.danger)
                .accessibilityLabel("Error: \(failure.message)")
        }
    }
}

private func announceChange() { NotificationCenter.default.post(name: .manageChanged, object: nil) }

/// Confirm sheet for archiving a project or bot. The PIN is held by ArchiveModel only while this sheet is
/// open; it is cleared after each request and on dismiss, and is sent only in the JSON body.
struct ArchiveConfirmSheet: View {
    let title: String
    let noun: String
    let onDone: () -> Void
    @State private var model: ArchiveModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(title: String, noun: String, perform: @escaping (String) async throws -> Void, onDone: @escaping () -> Void) {
        self.title = title
        self.noun = noun
        self.onDone = onDone
        _model = State(initialValue: ArchiveModel(archive: perform))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This archives “\(title)”. It's a logical archive: nothing is deleted and you can restore the \(noun) later from Archived.")
                        .font(.subheadline)
                }.hmRows()
                Section {
                    SecureField("4-digit deletion PIN", text: Bindable(model).pinInput)
                        .keyboardType(.numberPad)
                        .textContentType(nil)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .privacySensitive()
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("pin.field")
                        .accessibilityLabel("Deletion PIN")
                        .accessibilityHint("Enter the four digit PIN you set on the Mac")
                    ManageErrorLabel(failure: model.failure)
                } footer: { Text("The PIN is checked on your Mac and isn't saved on this phone.") }.hmRows()
            }
            .hmCanvas()
            .navigationTitle("Archive \(noun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.clear(); dismiss() }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("pin.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Archive", role: .destructive) {
                        Task {
                            if await model.submit() { onDone(); dismiss() }
                        }
                    }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("pin.confirm")
                    .accessibilityHint("Archives the \(noun) after the Mac checks your PIN")
                }
            }
            .interactiveDismissDisabled(model.isWorking)
            .onDisappear { model.clear() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.clear() } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Projects

/// Adds the '+' (add project) and Archived buttons to the Projects list and reloads it after changes.
struct ManageProjectsToolbar: ViewModifier {
    let reload: @MainActor () async -> Void
    @State private var adding = false
    @State private var showArchived = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showArchived = true } label: { Label("Archived", systemImage: "archivebox") }
                        .accessibilityIdentifier("manage.archived")
                        .accessibilityLabel("Archived projects and bots")
                        .accessibilityHint("Shows archived items you can restore")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("manage.addProject")
                        .accessibilityLabel("Add project")
                        .accessibilityHint("Creates a new project")
                }
            }
            .sheet(isPresented: $adding) { AddProjectView(onCreated: { announceChange() }) }
            #if DEBUG
            .task {
                if DemoMode.isOn && UserDefaults.standard.bool(forKey: "HMOpenProjectEditor") { adding = true }
            }
            #endif
            .sheet(isPresented: $showArchived) { ArchivedView() }
            .onReceive(NotificationCenter.default.publisher(for: .manageChanged)) { _ in Task { await reload() } }
    }
}

struct AddProjectView: View {
    let onCreated: () -> Void
    @State private var model = AddProjectModel(create: { try await API.shared.manageCreateProject($0) })
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title)
                        .accessibilityIdentifier("manage.project.title")
                    field(.title)
                    TextField("Summary (optional)", text: $model.summary, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("manage.project.summary")
                    field(.summary)
                }.hmRows()
                Section {
                    TextField("ID (optional)", text: $model.idText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manage.project.id")
                    field(.id)
                } header: { HMHeader("ID") } footer: {
                    Text(model.effectiveID.isEmpty ? "The ID is made from the title." : "ID: \(model.effectiveID)")
                        .accessibilityIdentifier("manage.project.slug")
                }.hmRows()
                if model.failure != nil { Section { ManageErrorLabel(failure: model.failure) }.hmRows() }
            }
            .hmCanvas()
            .navigationTitle("Add project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving { ProgressView() } else {
                        Button("Save") {
                            Task { if await model.save() { onCreated(); dismiss() } }
                        }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("manage.project.save")
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }

    @ViewBuilder private func field(_ f: ManageField) -> some View {
        if let m = model.issue(f), !(f == .title && model.title.isEmpty) {
            Text(m).font(.footnote).foregroundStyle(HMDesign.danger)
        }
    }
}

struct EditProjectView: View {
    let project: Project
    let onSaved: () -> Void
    @State private var model: EditProjectModel
    @Environment(\.dismiss) private var dismiss

    init(project: Project, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        let id = project.id
        _model = State(initialValue: EditProjectModel(title: project.title, summary: project.summary) { t, s in
            try await API.shared.manageEditProject(id: id, title: t, summary: s)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title).accessibilityIdentifier("manage.edit.title")
                    if let m = model.issue(.title) { Text(m).font(.footnote).foregroundStyle(HMDesign.danger) }
                    TextField("Summary", text: $model.summary, axis: .vertical).lineLimit(2...5)
                        .accessibilityIdentifier("manage.edit.summary")
                    if let m = model.issue(.summary) { Text(m).font(.footnote).foregroundStyle(HMDesign.danger) }
                }.hmRows()
                if model.failure != nil { Section { ManageErrorLabel(failure: model.failure) }.hmRows() }
            }
            .hmCanvas()
            .navigationTitle("Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving { ProgressView() } else {
                        Button("Save") { Task { if await model.save() { onSaved(); dismiss() } } }
                            .disabled(!model.canSave)
                            .accessibilityIdentifier("manage.edit.save")
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
    }
}

/// The 'Manage' section of a project's detail: edit (managed projects) and archive.
struct ManageProjectSection: View {
    let project: Project
    @State private var editing = false
    @State private var archiving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            if project.managed {
                Button { editing = true } label: {
                    HStack { Label("Edit title and summary", systemImage: "pencil"); Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(HMDesign.text3) }
                        .contentShape(Rectangle())
                }
                .foregroundStyle(HMDesign.ink)
                .accessibilityIdentifier("manage.editProject")
                .accessibilityHint("Opens a form to change the title and summary")
            } else {
                Label("This project comes from the Mac's catalog, so its title and summary are read-only here.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(HMDesign.text2)
            }
            Button(role: .destructive) { archiving = true } label: {
                Label("Archive project", systemImage: "archivebox").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityIdentifier("manage.archiveProject")
            .accessibilityHint("Asks for your deletion PIN, then hides the project. You can restore it later")
        } header: { HMHeader("Manage") }.hmRows()
        .sheet(isPresented: $editing) { EditProjectView(project: project, onSaved: { announceChange() }) }
        .sheet(isPresented: $archiving) {
            let id = project.id
            ArchiveConfirmSheet(title: project.title, noun: "project",
                                perform: { try await API.shared.manageArchiveProject(id: id, pin: $0) },
                                onDone: { announceChange(); dismiss() })
        }
    }
}

// MARK: - Archived

struct ArchivedView: View {
    @State private var model = ArchivedModel(
        fetch: { try await API.shared.manageArchived() },
        restoreProject: { try await API.shared.manageRestoreProject(id: $0) },
        restoreBot: { try await API.shared.manageRestoreBot(id: $0) })
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .hmCanvas()
                .navigationTitle("Archived")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading archive…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let f):
            ContentUnavailableView {
                Label("Can't load the archive", systemImage: "exclamationmark.triangle")
            } description: { Text(f.message) } actions: {
                Button("Try again") { Task { await model.load() } }.hmButton(.quiet, classic: .prominent)
            }
        case .loaded(let info):
            if info.isEmpty {
                ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                                       description: Text("Archived projects and bots show up here, and you can restore them."))
            } else {
                List {
                    if let f = model.restoreFailure { Section { ManageErrorLabel(failure: f) }.hmRows() }
                    if !info.projects.isEmpty {
                        Section(header: HMHeader("Projects")) { ForEach(info.projects) { row($0, project: true) } }.hmRows()
                    }
                    if !info.bots.isEmpty {
                        Section(header: HMHeader("Bots")) { ForEach(info.bots) { row($0, project: false) } }.hmRows()
                    }
                }
                .refreshable { await model.load() }
            }
        }
    }

    private func row(_ e: ArchivedEntry, project: Bool) -> some View {
        HStack {
            Text(e.title)
            Spacer()
            if model.isRestoring(project: project, id: e.id) { ProgressView() } else {
                Button("Restore") {
                    Task { if await model.restore(project: project, id: e.id) { announceChange() } }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Restore \(e.title)")
                .accessibilityIdentifier("manage.restore.\(e.id)")
            }
        }
    }
}

// MARK: - Bots

/// Adds the '+' (add bot) button to the Bots list and refreshes the bots after changes.
struct ManageBotsToolbar: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("manage.addBot")
                        .accessibilityLabel("Add bot")
                        .accessibilityHint("Creates an app-made bot")
                }
            }
            .sheet(isPresented: $adding) { AddBotView(onCreated: { announceChange() }) }
            .onReceive(NotificationCenter.default.publisher(for: .manageChanged)) { _ in Task { await app.refreshBots() } }
    }
}

struct AddBotView: View {
    let onCreated: () -> Void
    @State private var model = AddBotModel(
        loadHosts: { try await API.shared.manageBots().hosts },
        create: { try await API.shared.manageCreateBot(name: $0, persona: $1, host: $2) })
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("An app-made bot is a persona that runs on an existing bot; it doesn't create a new Hermes profile.")
                        .font(.subheadline)
                }.hmRows()
                Section(header: HMHeader("Name")) {
                    TextField("Name", text: $model.name).accessibilityIdentifier("manage.bot.name")
                    if let m = model.issue(.name), !model.name.isEmpty { Text(m).font(.footnote).foregroundStyle(HMDesign.danger) }
                }.hmRows()
                Section {
                    TextEditor(text: $model.persona)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("manage.bot.persona")
                        .accessibilityLabel("Persona")
                } header: { HMHeader("Persona") } footer: {
                    let over = model.personaBytes > ManageLimits.personaBytes
                    Text("\(model.personaBytes) / \(ManageLimits.personaBytes) bytes")
                        .foregroundStyle(over ? HMDesign.danger : .secondary)
                        .accessibilityLabel("\(model.personaBytes) of \(ManageLimits.personaBytes) bytes used")
                }.hmRows()
                Section {
                    if !model.hostsLoaded && model.hostsFailure == nil {
                        HStack { ProgressView(); Text("Loading bots…") }
                    } else if let f = model.hostsFailure, !model.hostsLoaded {
                        ManageErrorLabel(failure: f)
                        Button("Try again") { Task { await model.load() } }
                    } else if model.noHosts {
                        Text("No runtime is enabled for app-made bots on the Mac.").foregroundStyle(HMDesign.text2)
                            .accessibilityIdentifier("manage.bot.noHosts")
                    } else {
                        Picker("Runs on", selection: $model.hostID) {
                            ForEach(model.hosts) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .accessibilityIdentifier("manage.bot.host")
                    }
                } header: { HMHeader("Runs on") }.hmRows()
                if model.failure != nil { Section { ManageErrorLabel(failure: model.failure) }.hmRows() }
            }
            .hmCanvas()
            .navigationTitle("Add bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving { ProgressView() } else {
                        Button("Save") { Task { if await model.save() { onCreated(); dismiss() } } }
                            .disabled(!model.canSave)
                            .accessibilityIdentifier("manage.bot.save")
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
        }
        .task { await model.load() }
    }
}

/// App-made bots (personas) as a Bots-list section; each row opens its detail.
struct ManagePersonasSection: View {
    @State private var model = ManageBotsModel(fetch: { try await API.shared.manageBots() })

    var body: some View {
        Group {
            if let info = model.info, !info.personas.isEmpty {
                Section(header: HMHeader("App-made bots")) {
                    ForEach(info.personas) { p in
                        NavigationLink {
                            PersonaDetailView(persona: p)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body.weight(.semibold))
                                if !p.host.isEmpty { Text("Runs on \(p.host)").font(.caption).foregroundStyle(HMDesign.text2) }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("manage.persona.\(p.id)")
                        .accessibilityHint("Opens this app-made bot")
                    }
                }.hmRows()
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .manageChanged)) { _ in Task { await model.load() } }
    }
}

struct PersonaDetailView: View {
    let persona: ManagedPersona
    @State private var opening = false
    @State private var failure: ManageFailure?
    @State private var chat: ChatRef?
    @State private var archiving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button { Task { await newChat() } } label: {
                    HStack {
                        Label("New chat", systemImage: "square.and.pencil").font(.body.weight(.semibold))
                        Spacer()
                        if opening { ProgressView() }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(opening)
                .accessibilityIdentifier("manage.persona.newChat")
                ManageErrorLabel(failure: failure)
            } footer: {
                Text("Runs the persona on \(persona.host.isEmpty ? "its host bot" : persona.host). It isn't a separate Hermes profile.")
            }.hmRows()
            if !persona.persona.isEmpty { Section(header: HMHeader("Persona")) { Text(persona.persona).font(.callout) }.hmRows() }
            Section {
                Button(role: .destructive) { archiving = true } label: {
                    Label("Archive bot", systemImage: "archivebox").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .accessibilityIdentifier("manage.archiveBot")
                .accessibilityHint("Asks for your deletion PIN, then hides this bot. You can restore it later")
            } header: { HMHeader("Manage") }.hmRows()
        }
        .hmCanvas()
        .navigationTitle(persona.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $chat) { ChatView(ref: $0) }
        .sheet(isPresented: $archiving) {
            let id = persona.id
            ArchiveConfirmSheet(title: persona.name, noun: "bot",
                                perform: { try await API.shared.manageArchiveBot(id: id, pin: $0) },
                                onDone: { announceChange(); dismiss() })
        }
    }

    private func newChat() async {
        opening = true
        failure = nil
        defer { opening = false }
        do {
            let r = try await API.shared.manageNewPersonaChat(id: persona.id, fallbackHost: persona.host)
            chat = ChatRef(profile: r.profile, sessionId: r.session)
        } catch {
            failure = ManageFailure.classify(error)
        }
    }
}

/// Live bot detail: an Archive row only when the Mac lists the bot as manageable; otherwise a static note.
/// Default and protected bots are never listed, so they never get an archive action.
struct ManageBotSection: View {
    let bot: Bot
    @State private var model = ManageBotsModel(fetch: { try await API.shared.manageBots() })
    @State private var archiving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            if model.canArchive(bot.id) {
                Button(role: .destructive) { archiving = true } label: {
                    Label("Archive bot", systemImage: "archivebox").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .accessibilityIdentifier("manage.archiveBot")
                .accessibilityHint("Asks for your deletion PIN, then hides this bot. You can restore it later")
            } else if model.state == .loading || model.state == .idle {
                EmptyView()
            } else {
                Text("This bot is managed on the Mac.").font(.footnote).foregroundStyle(HMDesign.text2)
                    .accessibilityIdentifier("manage.botManagedOnMac")
            }
        }.hmRows()
        .task { await model.load() }
        .sheet(isPresented: $archiving) {
            let id = bot.id
            ArchiveConfirmSheet(title: bot.name, noun: "bot",
                                perform: { try await API.shared.manageArchiveBot(id: id, pin: $0) },
                                onDone: { announceChange(); dismiss() })
        }
    }
}
