import SwiftUI

/// The Mac's status dashboard, native: what's running, bots, cron jobs, incidents, providers, what's new.
/// Everything is discovered on the Mac on every refresh, so new bots and cron jobs appear on their own.
struct StatusView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var jobFilter: JobFilter = .all
    @State private var showAllJobs = false
    @State private var expanded: Set<String> = []
    @State private var gatewayOpen: Bool?
    @State private var tokensOpen = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: StatusModel { app.status }
    private var p: JV? { status.payload }

    enum JobFilter: String, CaseIterable, Identifiable {
        case active = "Active", paused = "Paused", failing = "Failing", all = "All"
        var id: String { rawValue }
    }

    init() {
        #if DEBUG
        // Screenshot QA (debug builds only): `-HMStatusShowAllJobs YES` starts with the full job list open.
        _showAllJobs = State(initialValue: UserDefaults.standard.bool(forKey: "HMStatusShowAllJobs"))
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
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
            #if DEBUG
            .task(id: p != nil) {
                // `-HMStatusScrollJobs YES` scrolls the cron jobs section to the top for screenshots.
                guard p != nil, UserDefaults.standard.bool(forKey: "HMStatusScrollJobs") else { return }
                try? await Task.sleep(for: .seconds(1))
                if UserDefaults.standard.bool(forKey: "HMStatusScrollEnd") { proxy.scrollTo("jobsEnd", anchor: .bottom) }
                else { proxy.scrollTo("jobs", anchor: UnitPoint(x: 0.5, y: -0.1)) }
            }
            #endif
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
    }

    // MARK: attention and overview

    private func refreshNow() async {
        status.refreshingProviders = true
        await status.refresh(force: true, app: app)
        status.refreshingProviders = false
    }

    private func isFailing(_ job: JV) -> Bool { StatusJobs.isFailing(job) }

    /// The one "Show all N" / "Show fewer" row every capped list ends with.
    private func moreRow(_ key: String, total: Int, open: Bool) -> some View {
        Button {
            withAnimation(.snappy) { if open { expanded.remove(key) } else { expanded.insert(key) } }
        } label: {
            HStack {
                Text(open ? "Show fewer" : "Show all \(total)")
                Spacer(minLength: HMDesign.small)
                Image(systemName: open ? "chevron.up" : "chevron.down").imageScale(.small).accessibilityHidden(true)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityHint(open ? "Collapses the list" : "Expands the list")
    }

    /// The first `limit` rows, and a Show all / Show fewer row when there are more.
    @ViewBuilder private func capped<Row: View>(_ key: String, _ items: [JV], limit: Int,
                                                @ViewBuilder row: @escaping (JV) -> Row) -> some View {
        let open = expanded.contains(key)
        let shown = open ? items : Array(items.prefix(limit))
        ForEach(Array(shown.enumerated()), id: \.offset) { _, item in row(item) }
        if items.count > limit { moreRow(key, total: items.count, open: open) }
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

    /// One compact tile: tinted symbol, value, caption. A single accessibility element.
    @ScaledMetric(relativeTo: .body) private var iconHeight: CGFloat = 20

    private func tile(_ caption: String, _ value: String, _ symbol: String, _ tint: Color, badge: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.medium).frame(height: iconHeight).accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if badge { NewBadge() }
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(badge ? "\(value), new" : value)
    }

    @ViewBuilder private func summary(_ p: JV) -> some View {
        let g = p["gateway"], J = p["jobs"]
        let jobs = J["jobs"].array
        let active = jobs.filter { !$0["paused"].bool }.count
        let failing = jobs.filter(isFailing).count
        let incidents = J["incidents"].array.count
        let tokens = J["tokens_24h"].array.reduce(0) { $0 + ($1["prompt"].int ?? 0) + ($1["completion"].int ?? 0) }
        let health = g["health"].string ?? "unknown"
        let gatewayName = API.shared.baseURL.map(SavedGateways.displayName) ?? "Gateway"
        let running = p["agents"].array.count
        let columns = Array(repeating: GridItem(.flexible(), spacing: HMDesign.small, alignment: .top), count: typeSize.isAccessibilitySize ? 2 : 4)
        Section {
            LazyVGrid(columns: columns, alignment: .center, spacing: HMDesign.medium) {
                tile(gatewayName, health.capitalized,
                     health == "healthy" ? "checkmark.circle.fill" : health == "down" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                     health == "healthy" ? HMDesign.success : health == "down" ? .red : .orange)
                if let hb = g["heartbeat_age_s"].double {
                    let age = max(0, Int(hb.rounded()))
                    tile("Heartbeat", age == 0 ? "Now" : "\(age)s", hb > 120 ? "clock.badge.exclamationmark" : "clock", hb > 120 ? .orange : .secondary)
                }
                tile("Running", "\(running)", running == 0 ? "moon.zzz" : "play.circle.fill", running == 0 ? .secondary : HMDesign.success)
                tile("Jobs", "\(active)", "calendar.badge.clock", .secondary)
                if failing > 0 { tile("Failing", "\(failing)", "exclamationmark.triangle.fill", .red) }
                tile("Incidents", "\(incidents)", incidents == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                     incidents == 0 ? HMDesign.success : .red)
                tile("Bots", "\(p["bots"].array.count)", "person.2.fill", .secondary,
                     badge: p["bots"].array.contains(where: { $0["new"].bool }))
                tile("Tokens 24h", Self.compact(tokens), "number.circle", .secondary)
            }
            .padding(.vertical, HMDesign.micro)
            .listRowInsets(EdgeInsets(top: HMDesign.small, leading: HMDesign.medium, bottom: HMDesign.small, trailing: HMDesign.medium))
        }
    }

    // MARK: sections

    @ViewBuilder private func running(_ p: JV) -> some View {
        let agents = p["agents"].array
        if !agents.isEmpty {
            Section("Running now") {
                capped("running", agents, limit: 5) { a in
                    let row = AgentRow(agent: a, botName: app.botName(a["profile"].string ?? ""))
                    if let sid = a["session_id"].string, let prof = a["profile"].string, a["kind"].string != "cron",
                       app.bot(prof)?.reachable == true {
                        NavigationLink(value: ChatRef(profile: prof, sessionId: sid)) { row }
                    } else {
                        row
                    }
                }
            }
        }
    }

    @ViewBuilder private func changes(_ p: JV) -> some View {
        let events = Array(p["changes"]["events"].array.prefix(8))
        if !events.isEmpty {
            Section("What's new") {
                capped("changes", events, limit: 3) { e in
                    let change = e["type"].string == "removed" ? "Removed" : e["type"].string == "renamed" ? "Renamed" : "Added"
                    HStack(alignment: .firstTextBaseline, spacing: HMDesign.medium) {
                        Image(systemName: ["removed": "minus.circle.fill", "renamed": "pencil.circle.fill"][e["type"].string ?? ""] ?? "plus.circle.fill")
                            .foregroundStyle(e["type"].string == "removed" ? Color.secondary : e["type"].string == "renamed" ? Color.blue : Color.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HMDesign.micro) {
                            Text(e["name"].string ?? "Unnamed").font(HMDesign.rowTitle).lineLimit(1)
                            (Text([change, e["kind"].string?.capitalized, e["kind"].string == "bot" ? nil : app.botName(e["profile"].string ?? ""),
                                   e["old_name"].string.map { "was \($0)" }]
                                .compactMap { $0 }.joined(separator: " · ")) + RelTime.suffix(e["at"].date))
                                .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func jobs(_ p: JV) -> some View {
        let all = p["jobs"]["jobs"].array
        let top = StatusJobs.top(all)
        let ranked = StatusJobs.ranked(all)
        let filtered = ranked.filter { j in
            switch jobFilter {
            case .all: return true
            case .active: return !j["paused"].bool
            case .paused: return j["paused"].bool
            case .failing: return isFailing(j)
            }
        }
        Section {
            if showAllJobs {
                if typeSize.isAccessibilitySize {
                    Picker("Show", selection: $jobFilter) { ForEach(JobFilter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.menu)
                } else {
                    Picker("Show", selection: $jobFilter) { ForEach(JobFilter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }
                if filtered.isEmpty {
                    Text("No \(jobFilter.rawValue.lowercased()) jobs. Try another filter.").foregroundStyle(.secondary)
                }
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, j in
                    JobRow(job: j, botName: app.botName(j["profile"].string ?? ""), showReason: true)
                }
            } else {
                if all.isEmpty { Text("No cron jobs are set up on this Mac.").foregroundStyle(.secondary) }
                ForEach(Array(top.enumerated()), id: \.offset) { _, j in
                    JobRow(job: j, botName: app.botName(j["profile"].string ?? ""), showReason: false)
                }
            }
            if all.count > StatusJobs.defaultLimit {
                Button {
                    withAnimation(.snappy) { showAllJobs.toggle(); jobFilter = .all }
                } label: {
                    HStack {
                        Text(showAllJobs ? "Show fewer" : "All jobs · \(all.count)")
                        Spacer(minLength: HMDesign.small)
                        Image(systemName: showAllJobs ? "chevron.up" : "chevron.down").imageScale(.small).accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityHint(showAllJobs ? "Collapses the job list" : "Shows every cron job")
                .id("jobsEnd")
            }
        } header: { Text("Cron jobs · \(all.filter { !$0["paused"].bool }.count) active").id("jobs") }
    }

    @ViewBuilder private func incidents(_ p: JV) -> some View {
        let inc = p["jobs"]["incidents"].array
        if !inc.isEmpty {
            Section("Open incidents") {
                capped("incidents", inc, limit: 5) { i in
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
        let rec = Array(p["jobs"]["recent"].array.prefix(10))
        if !rec.isEmpty {
            Section("Recent runs") {
                capped("recent", rec, limit: 5) { r in
                    VStack(alignment: .leading, spacing: HMDesign.micro) {
                        HStack(spacing: HMDesign.small) {
                            Text(r["name"].string ?? "Unnamed run").font(HMDesign.rowTitle).lineLimit(1)
                            Spacer(minLength: HMDesign.small)
                            StatusMark(text: r["status"].string)
                        }
                        (Text(app.botName(r["profile"].string ?? "")) + RelTime.suffix(r["claimed_at"].date))
                            .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(1)
                        if ["failed", "error"].contains(r["status"].string ?? ""), let err = r["error"].string {
                            Label(err, systemImage: "exclamationmark.triangle.fill").font(HMDesign.metadata).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    /// Problems stay visible; the runtime facts and healthy platforms sit in one collapsed group.
    @ViewBuilder private func gateway(_ p: JV) -> some View {
        let g = p["gateway"]
        let platforms = g["platforms"].array
        let troubled = platforms.filter { $0["needs_attention"].bool || $0["error"].string != nil }
        let healthy = platforms.filter { !($0["needs_attention"].bool || $0["error"].string != nil) }
        let state = g["state"].string ?? "unknown"
        let problem = !["ok", "running", "healthy", "connected"].contains(state)
        Section("Gateway") {
            ForEach(Array(troubled.enumerated()), id: \.offset) { _, pl in platformRow(pl) }
            DisclosureGroup("Gateway details", isExpanded: Binding(get: { gatewayOpen ?? problem }, set: { gatewayOpen = $0 })) {
                LabeledContent("State") { StatusPill(text: g["state"].string) }
                if let started = g["started_at"].date { LabeledContent("Up since") { RelTime(date: started) } }
                if let store = g["session_store"].string { LabeledContent("Session store") { StatusPill(text: store) } }
                if let provider = p["providers"]["default_provider"].string {
                    LabeledContent("Provider", value: ProviderUsageSection.displayName(provider))
                }
                if let v = g["version"].string {
                    LabeledContent("Version") {
                        HStack(spacing: 4) {
                            Text("v\(v)")
                            if let sha = g["sha"].string { Text(sha).font(HMDesign.metadata).foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(Array(healthy.enumerated()), id: \.offset) { _, pl in platformRow(pl) }
            }
        }
    }

    private func platformRow(_ pl: JV) -> some View {
        VStack(alignment: .leading, spacing: HMDesign.micro) {
            HStack(spacing: HMDesign.small) {
                Text(pl["name"].string ?? "Platform").lineLimit(1)
                Spacer(minLength: HMDesign.small)
                HStack(spacing: HMDesign.micro) {
                    if pl["needs_attention"].bool {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).imageScale(.small)
                            .accessibilityLabel("Needs attention")
                    }
                    StatusMark(text: pl["state"].string)
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
            Section {
                DisclosureGroup("Cron tokens · 24h", isExpanded: $tokensOpen) {
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
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Rows

/// Page-local: success states collapse to a small green check; everything else keeps the pill.
struct StatusMark: View {
    let text: String?
    var body: some View {
        if let t = text, ["ok", "completed", "delivered", "connected", "healthy"].contains(t) {
            Image(systemName: "checkmark.circle.fill").imageScale(.small).foregroundStyle(HMDesign.success)
                .accessibilityLabel(t)
        } else { StatusPill(text: text) }
    }
}

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

    /// " · 5d ago" for a metadata line, or nothing when the date is missing.
    static func suffix(_ date: Date?) -> Text { date == nil ? Text("") : Text(" · ") + text(date) }

    /// The same text as a `Text`, so it can join a sentence on one line.
    static func text(_ date: Date?) -> Text {
        guard let date else { return Text("Unknown") }
        let shown = date > .now && date.timeIntervalSinceNow < 5 ? Date.now : date
        return Text(shown, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
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
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                Text(agent["title"].string ?? "Untitled").font(HMDesign.rowTitle).lineLimit(1)
                (Text([botName, kind == "subagent" ? "subagent" : kind == "cron" ? "cron run" : kind == "phone" ? "from phone" : nil,
                       agent["model"].string].compactMap { $0 }.joined(separator: " · ")) + RelTime.suffix(agent["started_at"].date))
                    .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct JobRow: View {
    let job: JV
    let botName: String
    var showReason = false
    var body: some View {
        let failing = StatusJobs.isFailing(job)
        let paused = job["paused"].bool
        VStack(alignment: .leading, spacing: HMDesign.micro) {
            HStack(spacing: HMDesign.small) {
                Text(job["name"].string ?? "Unnamed job").font(HMDesign.rowTitle).lineLimit(1)
                if job["new"].bool { NewBadge() }
                Spacer(minLength: HMDesign.small)
                if paused || job["last_status"].string != nil { StatusMark(text: paused ? "paused" : job["last_status"].string) }
            }
            line2
                .font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(2)
            if failing {
                let streak = job["failure_streak"].int ?? 0
                let detail = [streak > 0 ? "\(streak)× failing" : nil, job["last_error"].string].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(HMDesign.metadata).foregroundStyle(.red).lineLimit(2)
                }
            }
            if showReason, let why = job["paused_reason"].string { Text(why).font(HMDesign.metadata).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    /// bot · schedule · next run (or Overdue), one wrapped line of metadata.
    private var line2: Text {
        var t = Text([botName, job["schedule"].string].compactMap { $0 }.joined(separator: " · "))
        if !job["paused"].bool, let next = job["next_run_at"].date {
            t = t + Text(" · ") + Text(next < .now ? "Overdue " : "Next ") + RelTime.text(next)
        }
        return t
    }
}
