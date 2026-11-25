import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceRoute: Hashable { let scope: WorkspaceScope }
struct WorkspaceChatRoute: Hashable { let ref: ChatRef; let scope: WorkspaceScope }

private enum WorkspaceTab: String, CaseIterable, Identifiable {
    case context = "Context", chats = "Chats", artifacts = "Artifacts"
    var id: String { rawValue }
}

/// Project workspace: persistent instructions + reference files, chats with an explicitly chosen bot,
/// and artifacts. Reached from a project in the Projects tab.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    let scope: WorkspaceScope
    private let originClient = API.shared
    @State private var model: WorkspaceProjectModel
    @State private var tab = WorkspaceTab.context
    @State private var importing = false
    @State private var newFile = false
    @State private var chatTitle = ""
    @State private var pendingDelete: WorkspaceFile?

    init(scope: WorkspaceScope) {
        self.scope = scope
        _model = State(initialValue: WorkspaceProjectModel(client: .live(project: scope.projectID)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(WorkspaceTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding([.horizontal, .top])
            content
        }
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newFile = true } label: { Label("New text file", systemImage: "square.and.pencil") }
                        .accessibilityIdentifier("ws.add.new")
                    Button { importing = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("ws.add.import")
                } label: { Label("Add", systemImage: "plus") }
                    .disabled(model.phase != .loaded || !model.canAddFile)
                    .accessibilityIdentifier("ws.add")
                    .accessibilityLabel("Add file")
            }
        }
        .sheet(isPresented: $newFile) {
            NewFileSheet(project: scope.projectID, existingCount: model.detail.files.count) { Task { await model.load() } }
        }
        .task { await model.load() }
        .onChange(of: model.phase) { _, p in if p == .failed(.signedOut), API.shared === originClient { app.sessionExpired() } }
        .alert("Workspace", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.notice ?? "") }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try WorkspaceValidation.boundedRead(url)
                Task { await model.addFile(name: url.lastPathComponent, data: data) }
            } catch {
                model.notice = (error as? WorkspaceValidation.Problem)?.message ?? "That file couldn't be read."
            }
        }
        .confirmationDialog("Remove this reference file?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { file in
            Button("Remove \(file.name)", role: .destructive) { Task { await model.deleteFile(file) } }
        }
    }

    private static let importTypes: [UTType] =
        [.plainText, .commaSeparatedText, .json] + [UTType(filenameExtension: "md")].compactMap { $0 }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Loading workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let f):
            ContentUnavailableView {
                Label("Workspace unavailable", systemImage: "exclamationmark.triangle")
            } description: { Text(f.message) } actions: {
                Button("Try again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
            }
        case .loaded:
            switch tab {
            case .context: contextTab
            case .chats: chatsTab
            case .artifacts: artifactsTab
            }
        }
    }

    // MARK: context

    private var contextTab: some View {
        List {
            Section {
                NavigationLink { InstructionsView(model: model) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instructions")
                        Text(model.detail.instructions.isEmpty ? "None yet" : model.detail.instructions)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("ws.instructions")
                .accessibilityHint("Opens the project instructions")
            } footer: {
                Text("Saved on your Mac. Sent to a bot only when you switch project context on for a message.")
            }
            Section {
                if model.detail.files.isEmpty { Text(model.detail.editable ? "No files yet. Use Add to create or import one." : "No files yet.").foregroundStyle(.secondary) }
                ForEach(model.detail.files) { file in
                    NavigationLink {
                        WorkspaceFileView(file: file, project: scope.projectID) { Task { await model.load() } }
                    } label: {
                        HStack {
                            Label(file.name, systemImage: "doc.text")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("ws.file.\(file.name)")
                    .accessibilityHint("Opens this file")
                    .swipeActions {
                        if model.detail.editable { Button("Remove", role: .destructive) { pendingDelete = file } }
                    }
                }
            } header: { Text("Files (\(model.detail.files.count)/\(WorkspaceLimits.maxFiles))") } footer: {
                Text(".txt, .md, .csv or .json; UTF-8, up to 8192 bytes each.")
            }
        }
        .refreshable { await model.load() }
    }

    // MARK: chats

    private var chatsTab: some View {
        let bots = model.selectableBots(app.bots)
        return List {
            Section {
                Picker("Bot", selection: Bindable(model).selectedBot) {
                    Text("Choose a bot").tag(String?.none)
                    ForEach(bots) { Text($0.name).tag(String?.some($0.id)) }
                }
                TextField("Title (optional)", text: $chatTitle)
                Button {
                    Task {
                        if let chat = await model.startChat(bots: app.bots, title: chatTitle), API.shared === originClient {
                            chatTitle = ""
                            open(chat)
                        }
                    }
                } label: { Label("Start chat", systemImage: "square.and.pencil") }
                    .disabled(model.selectedBot == nil)
            } header: { Text("New chat") } footer: {
                Text(bots.isEmpty ? "No reachable bot is enabled for this project." : "Starting a chat opens a real session with the bot you choose.")
            }
            Section("Chats") {
                if model.detail.chats.isEmpty { Text("No chats yet.").foregroundStyle(.secondary) }
                ForEach(model.detail.chats) { chat in
                    let usable = bots.contains { $0.id == chat.profile }
                    NavigationLink(value: WorkspaceChatRoute(ref: ChatRef(profile: chat.profile, sessionId: chat.sessionId), scope: scope)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title?.nilIfEmpty ?? "Untitled chat")
                            Text(app.botName(chat.profile)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!usable)
                    .accessibilityHint(usable ? "Resumes this chat" : "This bot isn't available right now")
                }
            }
        }
    }

    private func open(_ chat: WorkspaceChat) {
        NotificationCenter.default.post(name: .workspaceOpenChat, object: WorkspaceChatRoute(
            ref: ChatRef(profile: chat.profile, sessionId: chat.sessionId), scope: scope))
    }

    // MARK: artifacts

    private var artifactsTab: some View {
        let bots = model.selectableBots(app.bots)
        return List {
            Section("This project") {
                if model.detail.artifacts.isEmpty { Text("No artifacts yet.").foregroundStyle(.secondary) }
                ForEach(model.detail.artifacts) { a in
                    NavigationLink { ArtifactDetailView(artifact: a) } label: { ArtifactRow(artifact: a) }
                }
            }
            Section("Chat artifacts") {
                if model.detail.chats.isEmpty { Text("No chats yet.").foregroundStyle(.secondary) }
                ForEach(model.detail.chats) { chat in
                    NavigationLink {
                        ArtifactListView(title: chat.title?.nilIfEmpty ?? "Chat", profile: chat.profile, session: chat.sessionId)
                    } label: { Text(chat.title?.nilIfEmpty ?? "Untitled chat") }
                }
            }
            Section {
                if bots.isEmpty { Text("No reachable bot is enabled for this project.").foregroundStyle(.secondary) }
                ForEach(bots) { bot in
                    NavigationLink { ArtifactListView(title: bot.name, profile: bot.id, session: nil, project: scope.projectID) } label: { Text(bot.name) }
                }
            } header: {
                Text("Bot library")
            } footer: {
                Text("Files this bot made in this project only. Other projects' files are never shown here.")
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the workspace screen when a chat was just started, so the Projects stack can push it.
    static let workspaceOpenChat = Notification.Name("hermes.workspace.openChat")
}

private struct ArtifactRow: View {
    let artifact: WorkspaceArtifact
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artifact.name).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ArtifactListView: View {
    @Environment(AppModel.self) private var app
    let title: String
    let profile: String
    let session: String?
    var project: String? = nil
    @State private var items: [WorkspaceArtifact]?
    @State private var failure: WorkspacesFailure?

    var body: some View {
        List {
            if let failure {
                Text(failure.message).foregroundStyle(.secondary)
            } else if let items {
                if items.isEmpty { Text("No artifacts yet.").foregroundStyle(.secondary) }
                ForEach(items) { a in NavigationLink { ArtifactDetailView(artifact: a) } label: { ArtifactRow(artifact: a) } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let account = app.inboxAccount
        do {
            items = try await API.shared.workspaceArtifacts(profile: profile, session: session, project: project)
            failure = nil
        } catch {
            if Task.isCancelled { return }
            let f = error as? WorkspacesFailure ?? .network
            failure = f
            if f == .signedOut, account == app.inboxAccount { app.sessionExpired() }
        }
    }
}

struct ArtifactDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Downloads on demand (max 8 MiB). Text types show literally; everything else is exported, not rendered.
struct ArtifactDetailView: View {
    @Environment(AppModel.self) private var app
    let artifact: WorkspaceArtifact
    @State private var download: WorkspaceDownload?
    @State private var failure: WorkspacesFailure?
    @State private var loading = false
    @State private var exporting = false

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: artifact.name)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
                if let m = artifact.mime { LabeledContent("Type", value: m) }
            }
            Section {
                if let d = download {
                    if case .text(let s) = ArtifactPreview.make(data: d.data, mime: artifact.mime) {
                        Text(verbatim: s).font(.footnote.monospaced()).textSelection(.enabled)
                    } else {
                        Text("No preview for this type. Save it to open in another app.").foregroundStyle(.secondary)
                    }
                    Button { exporting = true } label: { Label("Save to Files", systemImage: "square.and.arrow.down") }
                } else if loading {
                    ProgressView()
                } else {
                    Button { Task { await fetch() } } label: { Label("Download", systemImage: "arrow.down.circle") }
                        .disabled(artifact.size > WorkspaceLimits.artifactDownloadBytes)
                }
                if let failure { Text(failure.message).foregroundStyle(.red).font(.footnote) }
                if artifact.size > WorkspaceLimits.artifactDownloadBytes {
                    Text(WorkspacesFailure.tooLarge.message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: ArtifactDocument(data: download?.data ?? Data()),
                      contentType: .data, defaultFilename: download?.filename ?? artifact.name) { _ in }
    }

    private func fetch() async {
        let account = app.inboxAccount
        loading = true; failure = nil
        defer { loading = false }
        do { download = try await API.shared.workspaceFile(id: artifact.id, fallbackName: artifact.name) }
        catch {
            if Task.isCancelled { return }
            let f = error as? WorkspacesFailure ?? .network
            failure = f
            if f == .signedOut, account == app.inboxAccount { app.sessionExpired() }
        }
    }
}
