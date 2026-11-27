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
    /// The provider and model lists stay folded until asked for (they're long).
    @State private var showPicker = false

    private var scope: CatalogScope? { app.catalogScope(profile) }

    private static func pname(_ p: String?) -> String {
        guard let p, !p.isEmpty else { return "" }
        return ProviderUsageSection.displayName(p)
    }

    /// What's answering, then this chat's money model by model: paid amounts, and what each plan covered.
    @ViewBuilder private func chatSummary(_ s: ServedRuntime) -> some View {
        let used = s.modelsUsed ?? []
        let paid = used.filter { $0.kind == "priced" && ($0.usd ?? 0) >= 0.0005 }
        let covered = used.filter { $0.kind == "included" }
        Section {
            if let pol = s.policy, let m = pol.model, !m.isEmpty {
                LabeledContent("Answering") {
                    Text([ModelName.short(m).components(separatedBy: " · ").first ?? m, Self.pname(pol.provider),
                          pol.effort.flatMap { Effort(rawValue: $0)?.label } ?? "Default effort"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                }
            } else if let m = s.model {
                LabeledContent("Last answered by") { Text([ModelName.short(m), Self.pname(s.provider)].filter { !$0.isEmpty }.joined(separator: " · ")) }
            }
            if let cost = s.cost, cost.usd >= 0.0005 {
                LabeledContent("Paid") { Text(CostSummary.money(cost.usd)).monospacedDigit().fontWeight(.semibold) }
            }
            if let cost = s.cost, cost.included {
                let plans = Array(Set(covered.compactMap { $0.provider }.map(Self.pname))).sorted()
                LabeledContent("Covered by " + (plans.isEmpty ? "your plan" : plans.joined(separator: ", "))) {
                    Text(cost.includedApiUsd >= 0.01 ? "≈ \(CostSummary.money(cost.includedApiUsd)) API" : "Included").monospacedDigit()
                }
            }
        } header: { HMHeader("This chat") } footer: {
            Text(s.cost?.unknown == true ? "Some steps ran on a model with no price on record, so they aren't counted."
                 : "From Hermes's usage records, including background helpers like summaries and image reading. The desktop app uses the same model setting.")
        }.hmRows()
        if !used.isEmpty {
            Section {
                ForEach(used, id: \.self) { u in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ModelName.short(u.model).components(separatedBy: " · ").first ?? u.model)
                            let calls = u.calls ?? 0
                            Text(([Self.pname(u.provider)] + ["\(calls) step\(calls == 1 ? "" : "s")"]
                                  + ((u.reasoningTokens ?? 0) > 0 ? ["\(UsageWords.compact(u.reasoningTokens ?? 0)) thinking"] : []))
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(HMDesign.text2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            switch u.kind {
                            case "priced":
                                Text(CostSummary.money(u.usd ?? 0)).monospacedDigit().fontWeight(.semibold)
                                Text("paid").font(.caption2).foregroundStyle(HMDesign.text2)
                            case "included":
                                Text("Plan").fontWeight(.semibold)
                                if let api = u.apiUsd, api >= 0.01 {
                                    Text("≈ \(CostSummary.money(api)) API").font(.caption2).monospacedDigit().foregroundStyle(HMDesign.text2)
                                }
                            default:
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: { HMHeader("Models that answered this chat") } footer: {
                if !paid.isEmpty, !covered.isEmpty { Text("Paid models were billed per use; plan models cost nothing extra.") }
            }.hmRows()
        }
    }
    private var catalogState: CatalogState { scope.map { app.catalogStore.state($0) } ?? CatalogState() }
    private var catalog: ModelCatalog? { catalogState.catalog }

    var body: some View {
        NavigationStack {
            Form {
                if running {
                    Section {
                        Label("The current reply will finish with its original model.", systemImage: "arrow.turn.down.right")
                        Text("Your selection applies to the next message you send or queue.").foregroundStyle(HMDesign.text2)
                    }.hmRows()
                }
                if let s = fresh ?? served { chatSummary(s) }
                Section {
                    effortStrip
                } header: { HMHeader("Effort") } footer: {
                    if !reasoningSupported { Text("This model uses its own reasoning settings.") }
                    else if !reasoningKnown { Text("Hermes hasn’t reported reasoning support for this model. Default uses its own settings.") }
                }.hmRows()
                .disabled(!reasoningSupported)

                Section {
                    Button {
                        withAnimation(.snappy) { showPicker.toggle() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Model").foregroundStyle(HMDesign.ink)
                                Text([model.map { ModelName.short($0) } ?? bot.map { ModelName.short($0.model) } ?? "Bot default",
                                      provider.flatMap { catalog?.provider(slug: $0)?.name } ?? (provider == nil ? "bot default" : provider!)]
                                        .joined(separator: " · "))
                                    .font(.caption).foregroundStyle(HMDesign.text2)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showPicker ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }.hmRows()
                if showPicker {
                Section {
                    Picker("Provider", selection: $provider) {
                        Text("Bot default").tag(String?.none)
                        ForEach(catalog?.usable ?? []) { p in
                            Text(p.isSubscription ? "\(p.name) · subscription" : "\(p.name) · pay per use").tag(Optional(p.slug))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(loading)
                    if !loading && (catalog?.usable.isEmpty ?? true) {
                        Text("Model list unavailable. You can keep this chat’s saved selection.").foregroundStyle(HMDesign.text2)
                    }
                    Button("Refresh models") {
                        Task { _ = await app.catalog(for: profile, refresh: true) }
                    }
                    .disabled(catalogState.isRefreshing)
                    if loading { HStack { ProgressView(); Text("Loading models…").foregroundStyle(HMDesign.text2) } }
                } header: { HMHeader("Provider") } footer: {
                    if provider == nil, let bot { Text("Uses \(bot.name)'s own setting: \(bot.model) · \(bot.provider).") }
                    if !loading { Text(catalogState.caption(now: Date())) }
                }.hmRows()

                if let provider, let model, let twin = catalog?.subscriptionTwin(of: model, on: provider) {
                    Section {
                        Button {
                            withAnimation { self.provider = twin.provider.slug; self.model = twin.model }
                        } label: {
                            Label("Use \(ModelName.short(twin.model)) on your \(twin.provider.name) subscription", systemImage: "checkmark.seal")
                        }
                    } footer: {
                        Text("This model is pay per use here. Your subscription has it, already paid for.")
                    }
                }

                if let p = selectedProvider {
                    Section(header: HMHeader("Model")) {
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
                                    Label("Use “\(typed)”", systemImage: "character.cursor.ibeam").foregroundStyle(HMDesign.ink)
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
                                    Text(m).foregroundStyle(HMDesign.ink)
                                    Spacer()
                                    if model == m { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }.hmRows()
                }
                }

            }
            .hmCanvas()
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
            withAnimation(HMMotion.standard) { effort = value }
        } label: {
            Text(label).font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? HMDesign.selectedFill : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .foregroundStyle(HMDesign.ink)
                .overlay { if on { Capsule().strokeBorder(HMDesign.accent, lineWidth: 1) } }
                .hmTouchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func filteredModels(_ p: ModelCatalog.Provider) -> [String] {
        let q = modelQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? p.models : p.models.filter { $0.lowercased().contains(q) }
    }
}
