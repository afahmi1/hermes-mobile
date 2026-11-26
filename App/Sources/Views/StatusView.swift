import SwiftUI

/// The Mac's status dashboard, native: what's running, bots, cron jobs, incidents, providers, what's new.
/// Everything is discovered on the Mac on every refresh, so new bots and cron jobs appear on their own.
struct StatusView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var jobFilter: JobFilter = .active
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: StatusModel { app.status }
    private var p: JV? { status.payload }

    enum JobFilter: String, CaseIterable, Identifiable {
        case active = "Active", paused = "Paused", failing = "Failing", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                attention(p)
                if let p {
                    summary(p)
                    running(p)
                    changes(p)
                    jobs(p)
                    incidents(p)
                    recent(p)
                    gateway(p)
                    ProviderUsageSection()
                    tokens(p)
                } else if status.error == nil {
                    HStack { Spacer(); ProgressView("Loading status…"); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .hmCanvas()
            .navigationTitle("Status")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refreshNow() } } label: {
                        Group {
                            if status.refreshingProviders { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .hmTouchTarget()
                    }
                    .disabled(status.refreshingProviders)
                    .accessibilityLabel("Refresh status")
                }
            }
            .refreshable { await status.refresh(app: app) }
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .navigationDestination(for: Bot.self) { BotDetailView(bot: $0) }
            .onAppear {
                status.visible = true
                status.markSeen()
                Task { await status.refresh(app: app) }
            }
            .onDisappear { status.visible = false }
            .onChange(of: status.newestEventAt) { _, _ in if status.visible { status.markSeen() } }
        }
    }

    // MARK: attention and overview

    private func refreshNow() async {
        status.refreshingProviders = true
        await status.refresh(force: true, app: app)
        status.refreshingProviders = false
    }

    private func isFailing(_ job: JV) -> Bool {
        (job["failure_streak"].int ?? 0) > 0 || ["failed", "error"].contains(job["last_status"].string ?? "")
    }

    /// What needs a decision first: a failed refresh, emergency stop, gateway reasons. Freshness comes with it.
    @ViewBuilder private func attention(_ p: JV?) -> some View {
        let stop = p?["gateway"]["estop"].array.isEmpty == false
        let reasons = (p?["gateway"]["reasons"].array ?? []).compactMap(\.string)
        if status.error != nil || stop || !reasons.isEmpty {
            Section("Needs attention") {
                if let e = status.error {
                    VStack(alignment: .leading, spacing: HMDesign.small) {
                        Label(e, systemImage: "wifi.exclamationmark")
                        if p != nil { Text("Showing the last update.").font(HMDesign.metadata).foregroundStyle(.secondary) }
                        Button("Try again") { Task { await refreshNow() } }
                            .disabled(status.refreshingProviders)
                            .hmTouchTarget()
                    }
                }
                if stop {
                    Label {
                        Text("Emergency stop is on. Cron and new gateway turns are paused. Run `hermes resume` on the server.")
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private func stateLabel(_ text: String, _ symbol: String, _ tint: Color?) -> some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? Color.secondary)
        }
    }

    @ViewBuilder private func summary(_ p: JV) -> some View {
        let g = p["gateway"], J = p["jobs"]
        let jobs = J["jobs"].array
        let paused = jobs.filter { $0["paused"].bool }
        let failing = jobs.filter(isFailing)
        let incidents = J["incidents"].array.count
        let tokens = J["tokens_24h"].array.reduce(0) { $0 + ($1["prompt"].int ?? 0) + ($1["completion"].int ?? 0) }
        let health = g["health"].string ?? "unknown"
        let gatewayName = API.shared.baseURL.map(SavedGateways.displayName) ?? "Gateway"
        let running = p["agents"].array.count
        Section("Overview") {
            LabeledContent(gatewayName) {
                stateLabel(health.capitalized,
                           health == "healthy" ? "checkmark.circle.fill" : health == "down" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                           health == "healthy" ? HMDesign.success : health == "down" ? .red : .orange)
            }
            if let hb = g["heartbeat_age_s"].double {
                let age = max(0, Int(hb.rounded()))
                LabeledContent("Heartbeat") {
                    stateLabel(age == 0 ? "Just now" : "\(age)s ago", hb > 120 ? "clock.badge.exclamationmark" : "clock", hb > 120 ? .orange : nil)
                }
            }
            LabeledContent("Incidents") {
                stateLabel(incidents == 0 ? "None" : "\(incidents) open",
                           incidents == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", incidents == 0 ? HMDesign.success : .red)
            }
            if !failing.isEmpty {
                LabeledContent("Failing jobs") { stateLabel("\(failing.count)", "exclamationmark.triangle.fill", .red) }
            }
            LabeledContent("Running now") { stateLabel("\(running)", running == 0 ? "moon.zzz" : "play.circle.fill", running == 0 ? nil : HMDesign.success) }
            LabeledContent("Scheduled jobs") { Text("\(jobs.count - paused.count)").monospacedDigit() }
            LabeledContent("Bots") {
                HStack(spacing: HMDesign.small) {
                    Text("\(p["bots"].array.count)").monospacedDigit()
                    if p["bots"].array.contains(where: { $0["new"].bool }) { NewBadge() }
                }
            }
            LabeledContent("Tokens, 24h") { Text(Self.compact(tokens)).monospacedDigit() }
        }
    }

    // MARK: sections

    @ViewBuilder private func running(_ p: JV) -> some View {
        let agents = p["agents"].array
        Section {
            if agents.isEmpty {
                Text("Nothing is running right now.").foregroundStyle(.secondary)
            }
            ForEach(Array(agents.enumerated()), id: \.offset) { _, a in
                let row = AgentRow(agent: a, botName: app.botName(a["profile"].string ?? ""))
                if let sid = a["session_id"].string, let prof = a["profile"].string, a["kind"].string != "cron",
                   app.bot(prof)?.reachable == true {
                    NavigationLink(value: ChatRef(profile: prof, sessionId: sid)) { row }
                } else {
                    row
                }
            }
        } header: { Text("Running now") }
    }

    @ViewBuilder private func changes(_ p: JV) -> some View {
        let events = p["changes"]["events"].array
        if !events.isEmpty {
            Section("What's new") {
                ForEach(Array(events.prefix(8).enumerated()), id: \.offset) { _, e in
                    let change = e["type"].string == "removed" ? "Removed" : e["type"].string == "renamed" ? "Renamed" : "Added"
                    HStack(alignment: .firstTextBaseline, spacing: HMDesign.medium) {
                        Image(systemName: ["removed": "minus.circle.fill", "renamed": "pencil.circle.fill"][e["type"].string ?? ""] ?? "plus.circle.fill")
                            .foregroundStyle(e["type"].string == "removed" ? Color.secondary : e["type"].string == "renamed" ? Color.blue : Color.green)
                            .accessibilityHidden(true)
                        AdaptiveTitleRow {
                            VStack(alignment: .leading, spacing: HMDesign.micro) {
                                Text(e["name"].string ?? "Unnamed").font(HMDesign.rowTitle)
                                Text([change, e["kind"].string?.capitalized, e["kind"].string == "bot" ? nil : app.botName(e["profile"].string ?? ""),
                                      e["old_name"].string.map { "was \($0)" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(HMDesign.metadata).foregroundStyle(.secondary)
                            }
                        } trailing: {
                            RelTime(date: e["at"].date).font(HMDesign.metadata).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func jobs(_ p: JV) -> some View {
        let all = p["jobs"]["jobs"].array
        let filtered = all.filter { j in
            switch jobFilter {
            case .all: return true
            case .active: return !j["paused"].bool
            case .paused: return j["paused"].bool
            case .failing: return (j["failure_streak"].int ?? 0) > 0 || ["failed", "error"].contains(j["last_status"].string ?? "")
            }
        }.sorted { ($0["next_run_at"].date ?? .distantFuture) < ($1["next_run_at"].date ?? .distantFuture) }
        Section {
            if typeSize.isAccessibilitySize {
                Picker("Show", selection: $jobFilter) { ForEach(JobFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
            } else {
                Picker("Show", selection: $jobFilter) { ForEach(JobFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if filtered.isEmpty {
                Text(all.isEmpty ? "No cron jobs are set up on this Mac." : "No \(jobFilter.rawValue.lowercased()) jobs. Try another filter.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, j in JobRow(job: j, botName: app.botName(j["profile"].string ?? "")) }
        } header: { Text("Cron jobs · \(all.count)") }
    }

    @ViewBuilder private func incidents(_ p: JV) -> some View {
        let inc = p["jobs"]["incidents"].array
        if !inc.isEmpty {
            Section("Open incidents") {
                ForEach(Array(inc.enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: HMDesign.micro) {
                        AdaptiveTitleRow {
                            Text(i["name"].string ?? "Unnamed incident").font(HMDesign.rowTitle)
                        } trailing: {
                            StatusPill(text: i["state"].string)
                        }
                        Text([app.botName(i["profile"].string ?? ""), i["failure_type"].string].compactMap { $0 }.joined(separator: " · "))
                            .font(HMDesign.metadata).foregroundStyle(.secondary)
                        if let err = i["error"].string {
                            Label(err, systemImage: "exclamationmark.triangle.fill").font(HMDesign.metadata).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func recent(_ p: JV) -> some View {
        let rec = p["jobs"]["recent"].array
        if !rec.isEmpty {
            Section("Recent runs") {
                ForEach(Array(rec.prefix(10).enumerated()), id: \.offset) { _, r in
                    AdaptiveTitleRow {
                        VStack(alignment: .leading, spacing: HMDesign.micro) {
                            Text(r["name"].string ?? "Unnamed run").font(HMDesign.rowTitle)
                            Text(app.botName(r["profile"].string ?? "")).font(HMDesign.metadata).foregroundStyle(.secondary)
                            if let err = r["error"].string {
                                Label(err, systemImage: "exclamationmark.triangle.fill").font(HMDesign.metadata).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                    } trailing: {
                        VStack(alignment: .trailing, spacing: HMDesign.micro) {
                            StatusPill(text: r["status"].string)
                            RelTime(date: r["claimed_at"].date).font(HMDesign.metadata).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// The gateway, grouped runtime → provider → version → heartbeat → platforms, so the process's
    /// liveness reads first and the integrations it serves read last.
    @ViewBuilder private func gateway(_ p: JV) -> some View {
        let g = p["gateway"]
        Section {
            // Runtime — is the process up, and for how long.
            LabeledContent("State") { StatusPill(text: g["state"].string) }
            if let started = g["started_at"].date { LabeledContent("Up since") { RelTime(date: started) } }
            if let store = g["session_store"].string { LabeledContent("Session store") { StatusPill(text: store) } }
            // Provider — the model provider the gateway falls back to.
            if let provider = p["providers"]["default_provider"].string {
                LabeledContent("Provider", value: ProviderUsageSection.displayName(provider))
            }
            // Version — the running Hermes build.
            if let v = g["version"].string {
                LabeledContent("Version") {
                    HStack(spacing: 4) {
                        Text("v\(v)")
                        if let sha = g["sha"].string { Text(sha).font(HMDesign.metadata).foregroundStyle(.secondary) }
                    }
                }
            }
            // Heartbeat — how recently the gateway reported in.
            if let hb = g["heartbeat_age_s"].double {
                let age = max(0, Int(hb.rounded()))
                LabeledContent("Heartbeat") {
                    Label(age == 0 ? "Just now" : "\(age)s ago", systemImage: hb > 120 ? "exclamationmark.triangle.fill" : "clock")
                        .labelStyle(.titleAndIcon)
                }
            }
            // Platforms — chat platforms the gateway listens on.
            let platforms = g["platforms"].array
            if !platforms.isEmpty {
                ForEach(Array(platforms.enumerated()), id: \.offset) { _, pl in
                    platformRow(pl)
                }
            }
        } header: { Text("Gateway") }
    }

    private func platformRow(_ pl: JV) -> some View {
        VStack(alignment: .leading, spacing: HMDesign.micro) {
            AdaptiveTitleRow {
                Text(pl["name"].string ?? "Platform")
            } trailing: {
                HStack(spacing: HMDesign.micro) {
                    if pl["needs_attention"].bool {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).imageScale(.small)
                            .accessibilityLabel("Needs attention")
                    }
                    StatusPill(text: pl["state"].string)
                }
            }
            if let err = pl["error"].string {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(HMDesign.metadata).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    @ViewBuilder private func tokens(_ p: JV) -> some View {
        let t = p["jobs"]["tokens_24h"].array
        if !t.isEmpty {
            Section("Cron tokens · 24h") {
                ForEach(Array(t.enumerated()), id: \.offset) { _, row in
                    LabeledContent {
                        Text("\(row["runs"].int ?? 0) runs · \(Self.compact((row["prompt"].int ?? 0) + (row["completion"].int ?? 0)))").monospacedDigit()
                    } label: {
                        Text(row["model"].string ?? "Unknown model").font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                    }
                }
            }
        }
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Rows

struct StatusPill: View {
    let text: String?
    var label: String? = nil
    var body: some View {
        let t = text ?? "Unknown"
        let color: Color = switch t {
        case "ok", "completed", "delivered", "connected", "healthy": HMDesign.success
        case "running", "claimed": .blue
        case "failed", "error", "disconnected", "down": .red
        case "missed", "paused", "unknown", "degraded", "starting", "restarting", "draining", "waiting", "stopping": .orange
        default: .secondary
        }
        Text(label ?? t).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.15), in: Capsule())
    }
}

private struct NewBadge: View {
    var body: some View {
        Text("NEW").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.blue).background(Color.blue.opacity(0.15), in: Capsule())
    }
}

private struct RelTime: View {
    let date: Date?
    var body: some View {
        // A just-logged event can be a fraction of a second "in the future" when the phone's and the Mac's
        // clocks differ slightly; show that as now instead of "in 0 sec".
        if let date {
            let shown = date > .now && date.timeIntervalSinceNow < 5 ? Date.now : date
            Text(shown, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        } else { Text("Unknown") }
    }
}

private struct AgentRow: View {
    let agent: JV
    let botName: String
    var body: some View {
        let kind = agent["kind"].string ?? ""
        HStack(alignment: .firstTextBaseline, spacing: HMDesign.medium) {
            Image(systemName: ["chat": "bubble.left.and.bubble.right.fill", "subagent": "person.2.fill",
                               "cron": "clock.fill", "phone": "iphone"][kind] ?? "bolt.fill")
                .foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
            AdaptiveTitleRow {
                VStack(alignment: .leading, spacing: HMDesign.micro) {
                    Text(agent["title"].string ?? "Untitled").font(HMDesign.rowTitle).lineLimit(2)
                    Text([botName, kind == "subagent" ? "subagent" : kind == "cron" ? "cron run" : kind == "phone" ? "from phone" : nil,
                          agent["model"].string].compactMap { $0 }.joined(separator: " · "))
                        .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(2)
                }
            } trailing: {
                RelTime(date: agent["started_at"].date).font(HMDesign.metadata).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    let job: JV
    let botName: String
    var body: some View {
        VStack(alignment: .leading, spacing: HMDesign.micro) {
            AdaptiveTitleRow {
                HStack(spacing: HMDesign.small) {
                    Text(job["name"].string ?? "Unnamed job").font(HMDesign.rowTitle).lineLimit(2)
                    if job["new"].bool { NewBadge() }
                }
            } trailing: {
                StatusPill(text: job["paused"].bool ? "paused" : job["last_status"].string)
            }
            Text([botName, job["schedule"].string].compactMap { $0 }.joined(separator: " · "))
                .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(2)
            if !job["paused"].bool, let next = job["next_run_at"].date {
                HStack(spacing: HMDesign.micro) {
                    Text(next < .now ? "Overdue" : "Next run")
                    RelTime(date: next)
                }
                .font(HMDesign.metadata).foregroundStyle(.secondary)
            }
            if let streak = job["failure_streak"].int, streak > 0 {
                Label("\(streak)× failing", systemImage: "exclamationmark.triangle.fill")
                    .font(HMDesign.metadata).foregroundStyle(.red)
            }
            if let err = job["last_error"].string { Text(err).font(HMDesign.metadata).foregroundStyle(.red).lineLimit(3) }
            if let why = job["paused_reason"].string { Text(why).font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}
