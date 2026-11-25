import SwiftUI

/// Provider → model → effort for one chat. Applies to the next message and is saved on the
/// session in Hermes, so the desktop and other devices see the same choice.
struct RuntimeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let bot: Bot?
    let current: RuntimeChoice
    let served: ServedRuntime?
    var sessionId: String? = nil
    var running = false
    @State private var fresh: ServedRuntime?
    let onApply: (RuntimeChoice) -> Void

    @State private var provider: String?
    @State private var model: String?
    @State private var effort: String?
    @State private var modelQuery = ""
    @State private var loading = true
    /// Set once the sheet has been filled from the chat's current setting; only later provider changes
    /// (the user's) may re-pick the model, so a custom model name survives reopening the sheet.
    @State private var seeded = false

    private var scope: CatalogScope? { app.catalogScope(profile) }
    private var catalogState: CatalogState { scope.map { app.catalogStore.state($0) } ?? CatalogState() }
    private var catalog: ModelCatalog? { catalogState.catalog }

    var body: some View {
        NavigationStack {
            Form {
                if running {
                    Section {
                        Label("The current reply will finish with its original model.", systemImage: "arrow.turn.down.right")
                        Text("Your selection applies to the next message you send or queue.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    effortStrip
                } header: { Text("Effort") } footer: {
                    if !reasoningSupported { Text("This model uses its own reasoning settings.") }
                    else if !reasoningKnown { Text("Hermes hasn’t reported reasoning support for this model. Default uses its own settings.") }
                }
                .disabled(!reasoningSupported)

                Section {
                    Picker("Provider", selection: $provider) {
                        Text("Bot default").tag(String?.none)
                        ForEach(catalog?.usable ?? []) { p in Text(p.name).tag(Optional(p.slug)) }
                    }
                    .pickerStyle(.menu)
                    .disabled(loading)
                    if !loading && (catalog?.usable.isEmpty ?? true) {
                        Text("Model list unavailable. You can keep this chat’s saved selection.").foregroundStyle(.secondary)
                    }
                    Button("Refresh models") {
                        Task { _ = await app.catalog(for: profile, refresh: true) }
                    }
                    .disabled(catalogState.isRefreshing)
                    if loading { HStack { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) } }
                } header: { Text("Provider") } footer: {
                    if provider == nil, let bot { Text("Uses \(bot.name)'s own setting: \(bot.model) · \(bot.provider).") }
                    if !loading { Text(catalogState.caption(now: Date())) }
                }

                if let p = selectedProvider {
                    Section("Model") {
                        if p.models.count > 8 || model.map({ !p.models.contains($0) }) == true {
                            TextField("Filter, or type an exact model name", text: $modelQuery)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        let typed = modelQuery.trimmingCharacters(in: .whitespaces)
                        if !typed.isEmpty, filteredModels(p).isEmpty {
                            Button {
                                withAnimation { model = typed }
                            } label: {
                                HStack {
                                    Label("Use “\(typed)”", systemImage: "character.cursor.ibeam").foregroundStyle(Color.primary)
                                    Spacer()
                                    if model == typed { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(filteredModels(p), id: \.self) { m in
                            Button {
                                withAnimation { model = m }
                            } label: {
                                HStack {
                                    Text(m).foregroundStyle(Color.primary)
                                    Spacer()
                                    if model == m { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let s = fresh ?? served {
                    if let pol = s.policy, let m = pol.model, !m.isEmpty {
                        Section {
                            LabeledContent("Model", value: m)
                            if let p = pol.provider, !p.isEmpty { LabeledContent("Provider", value: p) }
                            LabeledContent("Effort", value: pol.effort.flatMap { Effort(rawValue: $0)?.label } ?? "Default")
                        } header: { Text("Saved on this chat in Hermes") } footer: {
                            Text("The desktop app shows and uses the same setting.")
                        }
                    }
                    if let used = s.modelsUsed, !used.isEmpty {
                        Section("Models that answered this chat") {
                            ForEach(used, id: \.self) { u in
                                LabeledContent {
                                    Text("\(u.calls ?? 0) call\((u.calls ?? 0) == 1 ? "" : "s") · \(u.reasoningTokens ?? 0) reasoning tok")
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(u.model)
                                        if let p = u.provider, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Model & Effort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Set for next" : "Done") {
                        onApply(resolved)
                        dismiss()
                    }
                    .bold()
                    .disabled(loading || (provider != nil && model == nil))
                }
            }
            .onChange(of: provider) { _, slug in
                guard seeded else { return }
                modelQuery = ""
                guard let slug else { model = nil; return }
                guard let p = catalog?.provider(slug: slug) else { return }  // catalog still loading
                if !p.models.contains(model ?? "") { model = p.models.first(where: { $0 == bot?.model }) ?? p.models.first }
            }
            .sensoryFeedback(.selection, trigger: provider)
            .sensoryFeedback(.selection, trigger: model)
            .sensoryFeedback(.selection, trigger: effort)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDirty)
        .task {
            model = current.model
            provider = current.provider
            effort = current.effort
            _ = await app.catalog(for: profile)
            guard !Task.isCancelled else { return }
            loading = false
            if let scope { Task { await app.catalogStore.openCheck(scope) } }
            if let m = current.model, let p = selectedProvider, !p.models.contains(m) { modelQuery = m }  // show the custom row
            seeded = true
        }
        .task(id: sessionId) {
            guard let sid = sessionId else { return }
            let result = try? await API.shared.served(profile: profile, session: sid)
            if !Task.isCancelled { fresh = result }
        }
    }

    /// Unsaved picks: a swipe-down must not silently throw them away.
    private var isDirty: Bool { !loading && resolved != current }

    private var resolved: RuntimeChoice {
        RuntimeChoice(provider: provider, model: provider == nil ? nil : model, effort: reasoningSupported ? effort : nil)
    }

    private var selectedProvider: ModelCatalog.Provider? {
        guard let provider else { return nil }
        return catalog?.providers.first { $0.slug == provider }
    }

    private var reportedReasoning: Bool? {
        let slug = provider ?? bot?.provider
        let name = model ?? bot?.model
        guard let name, let slug, let p = catalog?.provider(slug: slug) else { return nil }
        return p.reasoning[name]
    }
    private var reasoningSupported: Bool { reportedReasoning != false }
    private var reasoningKnown: Bool { reportedReasoning != nil }

    private var effortStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "Default")
                ForEach(Effort.allCases) { chip($0.rawValue, $0.label) }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(_ value: String?, _ label: String) -> some View {
        let on = effort == value
        return Button {
            withAnimation(.snappy) { effort = value }
        } label: {
            Text(label).font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func filteredModels(_ p: ModelCatalog.Provider) -> [String] {
        let q = modelQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? p.models : p.models.filter { $0.lowercased().contains(q) }
    }
}
