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
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
            }
            if providers.isEmpty {
                if data == nil || data?["loading"].bool == true {
                    if app.status.error == nil { ProgressView("Reading providers…") }
                } else {
                    Text("No providers reported").foregroundStyle(.secondary)
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

    private func row(_ provider: JV) -> some View {
        let name = provider["provider"].string ?? "Unknown provider"
        let local = provider["local_usage"]
        return NavigationLink {
            ProviderUsageDetail(name: name)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(Self.displayName(name)).font(.body.weight(.medium))
                    if provider["is_default"].bool { Text("Default").font(.caption).foregroundStyle(.secondary) }
                }
                if let calls = local["calls"].int {
                    Text("\(calls.formatted()) recorded calls").font(.caption).foregroundStyle(.secondary)
                } else {
                    let count = provider["credentials"].array.count
                    Text("\(count) configured credential\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ProviderUsageDetail: View {
    let name: String
    @Environment(AppModel.self) private var app

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
            } else { Text("This provider is no longer in the latest inventory.") }
            if let error = app.status.error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle(ProviderUsageSection.displayName(name))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.status.refresh(force: true, app: app) }
        .task(id: inventory?["refreshing"].bool) {
            while !Task.isCancelled && app.status.payload?["providers"]["refreshing"].bool == true {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await app.status.refresh(app: app) }
            }
        }
    }
}
