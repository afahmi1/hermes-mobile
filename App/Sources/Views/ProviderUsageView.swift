import SwiftUI

private struct ProviderEntry: Identifiable {
    let id: String
    let data: JV
    init?(_ data: JV) {
        guard let name = data["provider"].string else { return nil }
        self.id = name
        self.data = data
    }
}

struct ProviderUsageSection: View {
    @Environment(AppModel.self) private var app
    @State private var showHistorical = false
    private var data: JV? { app.status.payload?["providers"] }

    var body: some View {
        let providers = (data?["providers"].array ?? []).compactMap(ProviderEntry.init)
        let historical = providers.filter { $0.data["historical_only"].bool }
        Section {
            if let error = data?["error"].string ?? app.status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote)
            }
            if providers.isEmpty {
                if data == nil || data?["loading"].bool == true {
                    if app.status.error == nil { ProgressView("Reading providers…") }
                } else {
                    Text("No providers reported. Pull to refresh.").foregroundStyle(.secondary)
                }
            }
            ForEach(providers.filter { !$0.data["historical_only"].bool }) { row($0.data) }
            if !historical.isEmpty {
                DisclosureGroup("Recorded only (\(historical.count))", isExpanded: $showHistorical) {
                    ForEach(historical) { row($0.data) }
                }
            }
        } header: {
            Text("Provider usage")
        } footer: {
            if data?["refreshing"].bool == true {
                Text("Updating provider readings…")
            } else if let date = data?["fetched_at"].date {
                Text("Inventory checked \(date, style: .relative) ago")
            }
        }
    }

    static func displayName(_ name: String) -> String {
        switch name {
        case "custom": return "Custom route (unspecified)"
        case "auto": return "Automatic route (unspecified)"
        case "unattributed": return "Unattributed activity"
        default: return name
        }
    }

    private func modelSuffix(_ slug: String) -> String {
        guard let scope = app.catalogScope(ProviderModels.profile),
              let p = app.catalogStore.state(scope).catalog?.provider(slug: slug) else { return "" }
        return " · \(p.models.count) model\(p.models.count == 1 ? "" : "s")"
    }

    private func row(_ provider: JV) -> some View {
        let name = provider["provider"].string ?? "Unknown provider"
        let local = provider["local_usage"]
        return NavigationLink {
            ProviderUsageDetail(name: name)
        } label: {
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                Text(Self.displayName(name)).font(HMDesign.rowTitle)
                if let calls = local["calls"].int {
                    Text("\(calls.formatted()) recorded calls\(modelSuffix(name))").font(HMDesign.metadata).foregroundStyle(.secondary)
                } else {
                    let count = provider["credentials"].array.count
                    Text("\(count) configured credential\(count == 1 ? "" : "s")\(modelSuffix(name))").font(HMDesign.metadata).foregroundStyle(.secondary)
                }
                if provider["is_default"].bool {
                    Label("Default provider", systemImage: "checkmark.circle").font(HMDesign.metadata).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

enum ProviderModels {
    /// The Mac's front-door profile; it owns the shared provider credentials.
    static let profile = "default"
}

private struct ProviderUsageDetail: View {
    let name: String
    @Environment(AppModel.self) private var app

    private var scope: CatalogScope? { app.catalogScope(ProviderModels.profile) }
    private var catalogState: CatalogState { scope.map { app.catalogStore.state($0) } ?? CatalogState() }

    /// Kept apart from "Hermes activity" (history) and "Provider account" (credentials). A catalog failure stays in here.
    @ViewBuilder private func modelsSection(historicalOnly: Bool) -> some View {
        let state = catalogState
        let listed = state.catalog?.provider(slug: name)
        if !historicalOnly || listed != nil {
            Section {
                if let listed {
                    LabeledContent("Models", value: listed.models.count.formatted())
                    ForEach(listed.models, id: \.self) { Text(verbatim: $0).font(.callout.monospaced()) }
                } else if state.catalog != nil {
                    Text("Hermes’s model catalog doesn’t list this provider.").foregroundStyle(.secondary)
                } else if state.isRefreshing || state.fetchedAt == nil && state.lastError == nil {
                    ProgressView("Loading models…")
                }
                if state.catalog == nil, let error = state.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.secondary) }
                Button("Refresh models") {
                    if let scope { Task { await app.catalogStore.refresh(scope) } }
                }
                .disabled(state.isRefreshing || scope == nil)
            } header: { Text("Available models") } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    if state.catalog != nil || state.lastError != nil { Text(state.caption(now: Date())) }
                    Text("From Hermes’s model catalog (default profile)")
                }
            }
        }
    }

    var body: some View {
        let inventory = app.status.payload?["providers"]
        let provider = inventory?["providers"].array.first { $0["provider"].string == name }
        List {
            if let provider {
                let local = provider["local_usage"]
                let usage = provider["usage"]
                Section("Hermes activity") {
                    if let calls = local["calls"].int {
                        LabeledContent("Calls", value: calls.formatted())
                        LabeledContent("Sessions", value: (local["sessions"].int ?? 0).formatted())
                        LabeledContent("Input tokens", value: (local["input_tokens"].int ?? 0).formatted())
                        LabeledContent("Output tokens", value: (local["output_tokens"].int ?? 0).formatted())
                        if let epoch = local["last_seen"].double {
                            LabeledContent("Last activity", value: Date(timeIntervalSince1970: epoch).formatted())
                        }
                    } else {
                        Text("No activity attributed to this provider in the available Hermes ledgers.")
                    }
                    if let coverage = inventory?["ledger"], let read = coverage["profiles_read"].int {
                        Text("Lifetime totals across \(read) profile ledgers. Unavailable ledgers: \(coverage["profiles_unavailable"].int ?? 0).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                modelsSection(historicalOnly: provider["historical_only"].bool)
                if !provider["historical_only"].bool {
                    Section("Provider account") {
                        LabeledContent("Configured credentials", value: provider["credentials"].array.count.formatted())
                        if let plan = usage["plan"].string { LabeledContent("Plan", value: plan) }
                        if let count = usage["key_count"].int {
                            LabeledContent("Keys reporting", value: "\(usage["keys_reporting"].int ?? 0) of \(count)")
                        }
                        if let scope = usage["scope"].string { Text(scope).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(["usage_daily", "usage_monthly", "usage"], id: \.self) { period in
                            let reading = usage["spend"][period]
                            if let usd = reading["usd"].double {
                                let label = ["usage_daily": "Spent today", "usage_monthly": "This month", "usage": "All-time spend"][period]!
                                LabeledContent(label, value: usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                                if reading["reporting"].int != usage["key_count"].int {
                                    Text("\(reading["reporting"].int ?? 0) keys included").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        let balance = usage["balance"]
                        if let left = balance["remaining"].double {
                            LabeledContent("Balance", value: left.formatted(.currency(code: balance["currency"].string ?? "USD")))
                            if let label = balance["label"].string { Text(label).font(.footnote).foregroundStyle(.secondary) }
                        }
                        ForEach(Array(usage["windows"].array.enumerated()), id: \.offset) { _, w in
                            if let percent = w["used_percent"].double {
                                let used = max(0, min(100, percent))
                                LabeledContent(w["label"].string ?? "Quota", value: "\(Int(used.rounded()))% used")
                                ProgressView(value: used, total: 100).accessibilityHidden(true)
                            }
                            if let reset = w["resets_at"].date { LabeledContent("Resets", value: reset.formatted()) }
                            if let detail = w["detail"].string { Text(detail).font(.footnote) }
                        }
                        ForEach(Array(usage["details"].array.enumerated()), id: \.offset) { _, d in
                            if let text = d.string { Text(text).font(.footnote) }
                        }
                        if let why = usage["unavailable_reason"].string { Text(why).foregroundStyle(.secondary) }
                        if usage["stale"].bool, let at = usage["stale_since"].date {
                            Label("Last successful reading \(at.formatted())", systemImage: "clock").font(.footnote)
                        }
                        if let at = usage["checked_at"].date { LabeledContent("Last check", value: at.formatted()) }
                    }
                }
            } else { Text("This provider is no longer in the latest inventory. Pull to refresh.").foregroundStyle(.secondary) }
            if let error = app.status.error { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
        }
        .navigationTitle(ProviderUsageSection.displayName(name))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            async let status: Void = app.status.refresh(force: true, app: app)
            if let scope { await app.catalogStore.refresh(scope) }
            await status
        }
        .task(id: app.gatewaySession) {
            if let scope { await app.catalogStore.openCheck(scope) }
        }
        .task(id: inventory?["refreshing"].bool) {
            while !Task.isCancelled && app.status.payload?["providers"]["refreshing"].bool == true {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await app.status.refresh(app: app) }
            }
        }
    }
}
