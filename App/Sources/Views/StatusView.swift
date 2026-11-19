import SwiftUI

/// The Mac's status dashboard, native: what's running, bots, cron jobs, incidents, providers, what's new.
/// Everything is discovered on the Mac on every refresh, so new bots and cron jobs appear on their own.
struct StatusView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var jobFilter: JobFilter = .active

    private var status: StatusModel { app.status }
    private var p: JV? { status.payload }

    enum JobFilter: String, CaseIterable, Identifiable {
        case active = "Active", paused = "Paused", failing = "Failing", all = "All"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let e = status.error, p == nil {
                    Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                }
                if let p {
                    if !p["gateway"]["estop"].array.isEmpty {
                        Label("Emergency stop is on: cron and new gateway turns are paused. Run `hermes resume` on the Mac.",
                              systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                    Section { kpis(p) }
                    running(p)
                    changes(p)
                    bots(p)
                    jobs(p)
                    incidents(p)
                    recent(p)
                    gateway(p)
                    providers(p)
                    tokens(p)
                } else if status.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Status")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { liveDot }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            status.refreshingProviders = true
                            await status.refresh(force: true, app: app)
                            status.refreshingProviders = false
                        }
                    } label: {
                        if status.refreshingProviders { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Refresh provider usage")
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

    // MARK: header

    private var liveDot: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = status.updatedAt.map { ctx.date.timeIntervalSince($0) }
            HStack(spacing: 5) {
                Circle().fill(age.map { $0 < 15 } == true ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(age.map { $0 < 15 ? "Live" : "Stale \(Int($0))s" } ?? "Connecting")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func kpis(_ p: JV) -> some View {
        let g = p["gateway"], J = p["jobs"]
        let jobs = J["jobs"].array
        let paused = jobs.filter { $0["paused"].bool }
        let failing = jobs.filter { ($0["failure_streak"].int ?? 0) > 0 || ["failed", "error"].contains($0["last_status"].string ?? "") }
        let tokens = J["tokens_24h"].array.reduce(0) { $0 + ($1["prompt"].int ?? 0) + ($1["completion"].int ?? 0) }
        let health = g["health"].string ?? "unknown"
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Kpi(label: "Gateway", value: health.capitalized,
                tint: health == "healthy" ? .green : health == "down" ? .red : .orange)
            Kpi(label: "Bots", value: "\(p["bots"].array.count)",
                tint: p["bots"].array.contains { $0["new"].bool } ? .blue : nil)
            Kpi(label: "Running", value: "\(p["agents"].array.count)", tint: p["agents"].array.isEmpty ? nil : .green)
            Kpi(label: "Scheduled", value: "\(jobs.count - paused.count)", tint: nil)
            Kpi(label: "Incidents", value: "\(J["incidents"].array.count)",
                tint: J["incidents"].array.isEmpty && failing.isEmpty ? .green : .red)
            Kpi(label: "Tokens 24h", value: Self.compact(tokens), tint: nil)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .listRowBackground(Color.clear)
    }

    // MARK: sections

    @ViewBuilder private func running(_ p: JV) -> some View {
        let agents = p["agents"].array
        Section {
            if agents.isEmpty {
                Text("Nothing running right now.").foregroundStyle(.secondary)
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
                    HStack(spacing: 10) {
                        Image(systemName: ["removed": "minus.circle.fill", "renamed": "pencil.circle.fill"][e["type"].string ?? ""] ?? "plus.circle.fill")
                            .foregroundStyle(e["type"].string == "removed" ? Color.secondary : e["type"].string == "renamed" ? Color.blue : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e["name"].string ?? "—").font(.subheadline.weight(.semibold))
                            + Text(e["old_name"].string.map { "  (was \($0))" } ?? "").font(.caption).foregroundColor(.secondary)
                            Text([e["kind"].string?.capitalized, e["kind"].string == "bot" ? nil : app.botName(e["profile"].string ?? "")]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RelTime(date: e["at"].date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func bots(_ p: JV) -> some View {
        Section("Bots") {
            ForEach(Array(p["bots"].array.enumerated()), id: \.offset) { _, b in
                let id = b["id"].string ?? ""
                let label = BotStatusRow(bot: b)
                if let bot = app.bot(id), bot.reachable {
                    NavigationLink(value: bot) { label }
                } else {
                    label
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
            Picker("Show", selection: $jobFilter) { ForEach(JobFilter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if filtered.isEmpty { Text("No \(jobFilter.rawValue.lowercased()) jobs.").foregroundStyle(.secondary) }
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, j in JobRow(job: j, botName: app.botName(j["profile"].string ?? "")) }
        } header: { Text("Cron jobs · \(all.count)") }
    }

    @ViewBuilder private func incidents(_ p: JV) -> some View {
        let inc = p["jobs"]["incidents"].array
        if !inc.isEmpty {
            Section("Open incidents") {
                ForEach(Array(inc.enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(i["name"].string ?? "—").font(.subheadline.weight(.semibold))
                            Spacer()
                            StatusPill(text: i["state"].string)
                        }
                        Text("\(app.botName(i["profile"].string ?? "")) · \(i["failure_type"].string ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let err = i["error"].string { Text(err).font(.caption).foregroundStyle(.red).lineLimit(3) }
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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r["name"].string ?? "—").font(.subheadline)
                            Text(app.botName(r["profile"].string ?? "")).font(.caption).foregroundStyle(.secondary)
                            if let err = r["error"].string { Text(err).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            StatusPill(text: r["status"].string)
                            RelTime(date: r["claimed_at"].date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func gateway(_ p: JV) -> some View {
        let g = p["gateway"]
        Section("Gateway") {
            LabeledContent("State") { StatusPill(text: g["state"].string) }
            if let v = g["version"].string { LabeledContent("Hermes", value: "v\(v)") }
            if let started = g["started_at"].date { LabeledContent("Up since") { RelTime(date: started) } }
            if let hb = g["heartbeat_age_s"].double { LabeledContent("Heartbeat", value: "\(Int(hb))s ago") }
            ForEach(Array(g["platforms"].array.enumerated()), id: \.offset) { _, pl in
                LabeledContent(pl["name"].string ?? "platform") {
                    StatusPill(text: pl["needs_attention"].bool ? "error" : pl["state"].string)
                }
            }
        }
    }

    @ViewBuilder private func providers(_ p: JV) -> some View {
        let provs = p["providers"]["providers"].array
        Section {
            if provs.isEmpty { Text(p["providers"]["error"].string ?? "Loading provider usage…").foregroundStyle(.secondary) }
            ForEach(Array(provs.enumerated()), id: \.offset) { _, pv in ProviderRow(provider: pv) }
        } header: {
            HStack {
                Text("Providers")
                Spacer()
                if let at = p["providers"]["fetched_at"].date { Text("checked ").font(.caption) + Text(at, style: .relative).font(.caption) }
            }
        }
    }

    @ViewBuilder private func tokens(_ p: JV) -> some View {
        let t = p["jobs"]["tokens_24h"].array
        if !t.isEmpty {
            Section("Cron tokens · 24h") {
                ForEach(Array(t.enumerated()), id: \.offset) { _, row in
                    LabeledContent {
                        Text("\(row["runs"].int ?? 0) runs · \(Self.compact((row["prompt"].int ?? 0) + (row["completion"].int ?? 0)))")
                    } label: {
                        Text(row["model"].string ?? "—").font(.system(.subheadline, design: .monospaced)).lineLimit(1)
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

private struct Kpi: View {
    let label: String
    let value: String
    let tint: Color?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

struct StatusPill: View {
    let text: String?
    var label: String? = nil
    var body: some View {
        let t = text ?? "—"
        let color: Color = switch t {
        case "ok", "completed", "delivered", "connected", "healthy": .green
        case "running", "claimed": .blue
        case "failed", "error", "disconnected", "down": .red
        case "missed", "paused", "unknown", "degraded": .orange
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
        } else { Text("—") }
    }
}

private struct AgentRow: View {
    let agent: JV
    let botName: String
    var body: some View {
        let kind = agent["kind"].string ?? ""
        HStack(spacing: 10) {
            Image(systemName: ["chat": "bubble.left.and.bubble.right.fill", "subagent": "person.2.fill",
                               "cron": "clock.fill", "phone": "iphone"][kind] ?? "bolt.fill")
                .foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent["title"].string ?? "—").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([botName, kind == "subagent" ? "subagent" : kind == "cron" ? "cron run" : kind == "phone" ? "from phone" : nil,
                      agent["model"].string].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            RelTime(date: agent["started_at"].date).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BotStatusRow: View {
    let bot: JV
    var body: some View {
        let id = bot["id"].string ?? ""
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(id: id, name: bot["name"].string ?? id, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(bot["name"].string ?? id).font(.subheadline.weight(.semibold))
                    if bot["new"].bool { NewBadge() }
                    if (bot["running"].int ?? 0) > 0 { StatusPill(text: "running") }
                }
                Text("\(bot["model"].string ?? "") · \(bot["provider"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                Text(plural(bot["sessions"].int ?? 0, "chat") + " · " + plural(bot["jobs"].int ?? 0, "cron job")
                     + ((bot["jobs_paused"].int ?? 0) > 0 ? " (\(bot["jobs_paused"].int ?? 0) paused)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if !bot["served"].bool { StatusPill(text: "not served") }
                    if let n = bot["jobs_failing"].int, n > 0 { StatusPill(text: "failed", label: "\(n) failing") }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct JobRow: View {
    let job: JV
    let botName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(job["name"].string ?? "—").font(.subheadline.weight(.semibold)).lineLimit(1)
                if job["new"].bool { NewBadge() }
                Spacer()
                StatusPill(text: job["paused"].bool ? "paused" : job["last_status"].string)
            }
            Text([botName, job["schedule"].string].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                if !job["paused"].bool, let next = job["next_run_at"].date {
                    Text("Next").font(.caption).foregroundStyle(.secondary)
                    RelTime(date: next).font(.caption).foregroundStyle(next < .now ? .orange : .secondary)
                }
                if let streak = job["failure_streak"].int, streak > 0 {
                    Text("· \(streak)× failing").font(.caption).foregroundStyle(.red)
                }
            }
            if let err = job["last_error"].string { Text(err).font(.caption).foregroundStyle(.red).lineLimit(2) }
            if let why = job["paused_reason"].string { Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

private struct ProviderRow: View {
    let provider: JV
    var body: some View {
        let u = provider["usage"]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider["provider"].string ?? "—").font(.subheadline.weight(.semibold))
                if provider["is_default"].bool { StatusPill(text: "default") }
                Spacer()
                if let left = u["balance"]["remaining"].double {
                    Text(left, format: .currency(code: u["balance"]["currency"].string ?? "USD")).font(.subheadline.weight(.semibold))
                }
            }
            ForEach(Array(u["windows"].array.enumerated()), id: \.offset) { _, w in
                let used = min(100, max(0, w["used_percent"].double ?? 0))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(w["label"].string ?? "").font(.caption)
                        Spacer()
                        Text("\(Int((100 - used).rounded()))% left").font(.caption.weight(.semibold))
                        if let r = w["resets_at"].date { Text("· resets").font(.caption).foregroundStyle(.secondary) + Text(r, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    }
                    ProgressView(value: used, total: 100)
                        .tint(100 - used < 15 ? .red : 100 - used < 35 ? .orange : .green)
                }
            }
            if u["stale"].bool { Text("Showing an older reading; the latest check failed.").font(.caption).foregroundStyle(.orange) }
            if u["windows"].array.isEmpty, u["balance"].isNull, let why = u["unavailable_reason"].string {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
