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

/// Usage in words a person reads at a glance: what limit, how much is left, when it resets.
enum UsageWords {
    static func compact(_ n: Int) -> String { n.formatted(.number.notation(.compactName).precision(.significantDigits(2))) }

    /// "Weekly limit", "5-hour limit". The provider's own label, with "limit" added once.
    static func windowTitle(_ raw: String?) -> String {
        let label = (raw ?? "Usage").trimmingCharacters(in: .whitespaces)
        return label.lowercased().contains("limit") ? label : label + " limit"
    }

    /// "1% left · resets Sunday 1:49 AM (in 4 days)"
    static func windowDetail(used: Double, resets: Date?, now: Date = Date()) -> String {
        let left = max(0, 100 - Int(used.rounded()))
        var text = left == 0 ? "None left" : "\(left)% left"
        if let resets {
            let day = Calendar.current.isDateInToday(resets) ? "today" : Calendar.current.isDateInTomorrow(resets) ? "tomorrow"
                : resets.formatted(.dateTime.weekday(.wide))
            let rel = RelativeDateTimeFormatter().localizedString(for: resets, relativeTo: now)
            text += " · resets \(day) \(resets.formatted(date: .omitted, time: .shortened)) (\(rel))"
        }
        return text
    }

    static func severity(_ used: Double) -> Color {
        used >= 95 ? .red : used >= 80 ? HMDesign.warning : HMDesign.accent
    }

    /// The one line a provider row needs: its tightest limit, or what Hermes has used.
    static func headline(_ provider: JV) -> String? {
        let windows = provider["usage"]["windows"].array.compactMap { w -> (String, Double)? in
            guard let p = w["used_percent"].double else { return nil }
            return (windowTitle(w["label"].string), p)
        }
        if let worst = windows.max(by: { $0.1 < $1.1 }) { return "\(worst.0) · \(Int(worst.1.rounded()))% used" }
        if let usd = provider["usage"]["spend"]["usage_monthly"]["usd"].double { return usd.formatted(.currency(code: "USD")) + " this month" }
        return nil
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
                Text("Updated \(date, style: .relative) ago")
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
                if let headline = UsageWords.headline(provider) {
                    Text(headline).font(HMDesign.metadata.weight(.medium))
                        .foregroundStyle(provider["usage"]["windows"].array.contains { ($0["used_percent"].double ?? 0) >= 80 } ? HMDesign.warning : .secondary)
                }
                if let calls = local["calls"].int {
                    Text("\(UsageWords.compact(calls)) requests from Hermes\(modelSuffix(name))").font(HMDesign.metadata).foregroundStyle(.secondary)
                } else {
                    let count = provider["credentials"].array.count
                    Text("\(count) key\(count == 1 ? "" : "s") set up\(modelSuffix(name))").font(HMDesign.metadata).foregroundStyle(.secondary)
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
                Section {
                    if let calls = local["calls"].int {
                        LabeledContent("Requests", value: calls.formatted())
                        LabeledContent("Chats", value: (local["sessions"].int ?? 0).formatted())
                        LabeledContent("Tokens sent", value: UsageWords.compact(local["input_tokens"].int ?? 0))
                        LabeledContent("Tokens received", value: UsageWords.compact(local["output_tokens"].int ?? 0))
                        if let epoch = local["last_seen"].double {
                            LabeledContent("Last used") { Text(Date(timeIntervalSince1970: epoch), style: .relative) + Text(" ago") }
                        }
                    } else {
                        Text("Hermes hasn't used this provider yet.")
                    }
                } header: { Text("What Hermes used") } footer: {
                    if let coverage = inventory?["ledger"], let read = coverage["profiles_read"].int {
                        let missing = coverage["profiles_unavailable"].int ?? 0
                        Text("All time, across \(read) bot\(read == 1 ? "" : "s")" + (missing > 0 ? ". \(missing) couldn't be read." : "."))
                    }
                }
                modelsSection(historicalOnly: provider["historical_only"].bool)
                if !provider["historical_only"].bool {
                    Section("Your account") {
                        LabeledContent("Keys set up", value: provider["credentials"].array.count.formatted())
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
                                    Text("Counts \(reading["reporting"].int ?? 0) of your keys").font(.caption).foregroundStyle(.secondary)
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
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(UsageWords.windowTitle(w["label"].string))
                                        Spacer()
                                        Text("\(Int(used.rounded()))% used").monospacedDigit().foregroundStyle(UsageWords.severity(used))
                                    }
                                    ProgressView(value: used, total: 100).tint(UsageWords.severity(used)).accessibilityHidden(true)
                                    Text(UsageWords.windowDetail(used: used, resets: w["resets_at"].date))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                            } else if let reset = w["resets_at"].date {
                                LabeledContent(UsageWords.windowTitle(w["label"].string)) { Text("resets ") + Text(reset, style: .relative) }
                            }
                            if let detail = w["detail"].string { Text(detail).font(.footnote) }
                        }
                        ForEach(Array(usage["details"].array.enumerated()), id: \.offset) { _, d in
                            if let text = d.string { Text(text).font(.footnote) }
                        }
                        if let why = usage["unavailable_reason"].string { Text(why).foregroundStyle(.secondary) }
                        if usage["stale"].bool, let at = usage["stale_since"].date {
                            Label("Couldn't refresh. Showing the reading from \(at.formatted(date: .abbreviated, time: .shortened)).", systemImage: "clock").font(.footnote)
                        }
                        if let at = usage["checked_at"].date { LabeledContent("Checked") { Text(at, style: .relative) + Text(" ago") } }
                    }
                }
            } else { Text("This provider is no longer in the latest inventory. Pull to refresh.").foregroundStyle(.secondary) }
            if let error = app.status.error { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
        }
        .hmCanvas()
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
