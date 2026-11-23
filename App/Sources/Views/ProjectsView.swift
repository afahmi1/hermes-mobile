import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectsView: View {
    private struct Selection: Hashable { let id: Project.ID }

    @Environment(AppModel.self) private var app
    @State private var model = ProjectsModel(fetch: { try await API.shared.projects() })
    @State private var path = NavigationPath()
    @State private var workspaces = WorkspaceIndexModel(fetch: { try await API.shared.workspaceIndex() })

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Projects")
                .modifier(ManageProjectsToolbar(reload: { await model.load() }))  // build5 manage hook
                .navigationDestination(for: Selection.self) { selection in
                    if case .loaded(let snapshot) = model.state,
                       let project = snapshot.projects.first(where: { $0.id == selection.id }) {
                        ProjectDetailView(project: project, snapshot: snapshot, workspaces: workspaces)
                    } else {
                        ContentUnavailableView("Project unavailable", systemImage: "folder")
                    }
                }
                .navigationDestination(for: Bot.self) { BotDetailView(bot: $0) }
                .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
                .navigationDestination(for: WorkspaceRoute.self) { WorkspaceView(scope: $0.scope) }
                .navigationDestination(for: WorkspaceChatRoute.self) { ChatView(ref: $0.ref, projectScope: $0.scope) }
                .onReceive(NotificationCenter.default.publisher(for: .workspaceOpenChat)) { note in
                    if let route = note.object as? WorkspaceChatRoute { path.append(route) }
                }
        }
        .task { await model.load() }
        .task { await workspaces.load() }  // separate from the catalog: its failure never hides it
        .onChange(of: model.state) { _, state in
            if state == .failed(.signedOut) { app.signOut() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured:
            panel("Projects aren't set up", "folder.badge.questionmark",
                  "Projects are turned off on your Mac's Hermes bridge. Turn them on there, then pull to refresh.")
        case .empty:
            panel("No projects yet", "folder", "The catalog on your Mac is empty. Pull to refresh after it changes.")
        case .failed(let failure):
            panel(failure.title, failure.isUpgrade ? "arrow.down.app" : "exclamationmark.triangle", failure.message) {
                Button("Try again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
            }
        case .loaded(let snapshot):
            let shown = snapshot.filtered(model.query)
            List {
                ForEach(shown) { project in
                    NavigationLink(value: Selection(id: project.id)) { ProjectRow(project: project, bots: app.bots) }
                }
            }
            .overlay {
                if shown.isEmpty { ContentUnavailableView.search(text: model.query) }
            }
            .searchable(text: Bindable(model).query, prompt: "Search projects")
            .refreshable { await model.load() }
        }
    }

    private func panel(_ title: String, _ symbol: String, _ message: String) -> some View {
        panel(title, symbol, message) { EmptyView() }
    }

    private func panel<Actions: View>(_ title: String, _ symbol: String, _ message: String,
                                      @ViewBuilder actions: () -> Actions) -> some View {
        ScrollView {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(message)
            } actions: {
                actions()
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .refreshable { await model.load() }
    }
}

private struct ProjectRow: View {
    let project: Project
    let bots: [Bot]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.title).font(.body.weight(.semibold))
            if let summary = project.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(botLine).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var botLine: String {
        guard !project.botIds.isEmpty else { return "No bot assigned" }
        return ProjectsSnapshot.botLinks(ids: project.botIds, bots: bots).map(\.displayName).joined(separator: ", ")
    }
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var app
    let project: Project
    let snapshot: ProjectsSnapshot
    var workspaces: WorkspaceIndexModel
    @State private var assignment: WorkspaceAssignmentModel

    init(project: Project, snapshot: ProjectsSnapshot, workspaces: WorkspaceIndexModel) {
        self.project = project; self.snapshot = snapshot; self.workspaces = workspaces
        _assignment = State(initialValue: WorkspaceAssignmentModel(client: .live(project: project.id)))
    }

    var body: some View {
        let refs = snapshot.references(for: project)
        let hasWorkspace = workspaces.isEnabled(project.id)
        List {
            if let summary = project.summary, !summary.isEmpty {
                Section { Text(summary) }
            }
            if hasWorkspace {
                Section {
                    NavigationLink(value: WorkspaceRoute(scope: WorkspaceScope(projectID: project.id, title: project.title))) {
                        Label("Workspace", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("ws.open")
                    .accessibilityHint("Opens instructions, files, chats and artifacts")
                    NavigationLink { BotAssignmentView(model: assignment) } label: {
                        HStack {
                            Label("Assigned bots", systemImage: "person.2")
                            Spacer()
                            Text(assignment.summary(name: { app.botName($0) }))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("ws.assign")
                    .accessibilityHint("Choose which bots can work in this project")
                } footer: { Text("Instructions, files, chats and artifacts.") }
            }
            ManageProjectSection(project: project)  // build5 manage hook
            Section("Catalog bots") {
                let links = snapshot.botLinks(for: project, bots: app.bots)
                if links.isEmpty {
                    Text("No bot is listed for this project in the catalog.").foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    if let bot = link.bot {
                        NavigationLink(value: bot) { Label(link.displayName, systemImage: "person.crop.circle") }
                    } else {
                        Label(link.displayName, systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                            .accessibilityHint("This bot isn't available on this device right now")
                    }
                }
            }
            Section("Sources") {
                if project.sources.isEmpty { Text("No sources listed.").foregroundStyle(.secondary) }
                ForEach(Array(project.sources.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.source)
                        Text(s.provider).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                if refs.shown.isEmpty { Text("No related files.").foregroundStyle(.secondary) }
                ForEach(refs.shown) { ref in
                    NavigationLink {
                        ReferenceDetailView(reference: ref, workspaceProject: hasWorkspace ? project.id : nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.path).font(.body.monospaced()).foregroundStyle(.primary)
                            Text(ref.rootName + (ref.kind == .vault ? " · vault" : ref.kind == .repo ? " · repo" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(ref.path) in \(ref.rootName)")
                    .accessibilityHint("Shows what this reference is and lets you copy its path")
                }
            } header: {
                Text("Related files")
            } footer: {
                if refs.hidden > 0 { Text("\(refs.hidden) reference(s) hidden because they weren't a safe relative path in a known root.") }
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: hasWorkspace) { if hasWorkspace { await assignment.load() } }
    }
}
