import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectsView: View {
    private struct Selection: Hashable { let id: Project.ID }

    @Environment(AppModel.self) private var app
    @State private var model = ProjectsModel(fetch: { try await API.shared.projects() })
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Projects")
                .navigationDestination(for: Selection.self) { selection in
                    if case .loaded(let snapshot) = model.state,
                       let project = snapshot.projects.first(where: { $0.id == selection.id }) {
                        ProjectDetailView(project: project, snapshot: snapshot)
                    } else {
                        ContentUnavailableView("Project unavailable", systemImage: "folder")
                    }
                }
                .navigationDestination(for: Bot.self) { BotDetailView(bot: $0) }
                .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
        }
        .task { await model.load() }
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
    @State private var copied: String?

    var body: some View {
        let refs = snapshot.references(for: project)
        List {
            if let summary = project.summary, !summary.isEmpty {
                Section { Text(summary) }
            }
            Section("Bots") {
                let links = snapshot.botLinks(for: project, bots: app.bots)
                if links.isEmpty {
                    Text("No bot is assigned to this project.").foregroundStyle(.secondary)
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
                    Button {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: ref.copyText]],
                                                     options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        copied = ref.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.path).font(.body.monospaced()).foregroundStyle(.primary)
                            Text(ref.rootName + (ref.kind == .vault ? " · vault" : ref.kind == .repo ? " · repo" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(ref.path) in \(ref.rootName)")
                    .accessibilityHint("Copies the root name and path")
                }
            } header: {
                Text("Related files")
            } footer: {
                if refs.hidden > 0 { Text("\(refs.hidden) reference(s) hidden because they weren't a safe relative path in a known root.") }
                else if copied != nil { Text("Copied.") }
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
