import SwiftUI

/// Every session from every profile, newest first — desktop, phone, iMessage, terminal, scheduled.
struct ChatListView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .chats
    @State private var sessions: [SessionSummary] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var results: [SessionSummary]?
    @State private var path = NavigationPath()
    @State private var showNew = false
    var profile: String? = nil

    enum Filter: String, CaseIterable, Identifiable {
        case chats = "Chats", all = "Everything", archived = "Archived"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(profile.map { app.botName($0) } ?? "Chats")
                .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
                .searchable(text: $query, prompt: "Search titles and messages")
                .task(id: query) { await runSearch() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { startNew() } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New chat")
                    }
                }
                .sheet(isPresented: $showNew) {
                    NewChatSheet { bot in
                        showNew = false
                        path.append(ChatRef(profile: bot.id, sessionId: nil))
                    }
                }
                .refreshable { await reload() }
                .task { if sessions.isEmpty { await reload() } }
                .task { await autoRefresh() }
                .onChange(of: filter) { _, _ in Task { await reload() } }
        }
    }

    @ViewBuilder private var content: some View {
        List {
            if profile == nil && results == nil {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
            }
            if let results {
                if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                ForEach(results) { row($0) }
            } else {
                ForEach(grouped, id: \.0) { section in
                    Section(section.0) { ForEach(section.1) { row($0) } }
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .task(id: cursor) { await loadMore() }  // re-runs for every new page, even an empty one
                } else if sessions.isEmpty && !loading && error == nil {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left",
                                           description: Text("Start one with the compose button."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if loading && sessions.isEmpty { ProgressView() } }
    }

    private func row(_ s: SessionSummary) -> some View {
        NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
            SessionRow(session: s, botName: app.botName(s.profile))
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await setFlag(s, "archived", !(s.archived ?? false)) }
            } label: {
                Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox")
            }.tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await setFlag(s, "pinned", !(s.pinned ?? false)) }
            } label: {
                Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin")
            }.tint(.orange)
        }
    }

    private var grouped: [(String, [SessionSummary])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for s in sessions {
            let k: String
            if s.pinned == true { k = "Pinned" }
            else if cal.isDateInToday(s.date) { k = "Today" }
            else if cal.isDateInYesterday(s.date) { k = "Yesterday" }
            else if s.date > Date().addingTimeInterval(-7 * 86400) { k = "This Week" }
            else if s.date > Date().addingTimeInterval(-30 * 86400) { k = "This Month" }
            else { k = s.date.formatted(.dateTime.month(.wide).year()) }
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(s)
        }
        return order.map { ($0, buckets[$0]!) }
    }

    private var exclude: [String] { filter == .chats ? ["cron", "oneshot", "subagent", "tool"] : [] }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            if filter == .archived && profile == nil {
                sessions = try await API.shared.search("", archived: true)
                cursor = nil
            } else {
                let page = try await API.shared.sessions(cursor: nil, profile: profile, exclude: exclude)
                sessions = dedupe(page.data)
                cursor = page.next
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            if case APIError.http(401, _) = error { app.signOut() }
        }
    }

    private func loadMore() async {
        guard var c = cursor else { return }
        while loading { try? await Task.sleep(for: .milliseconds(150)) }  // a refresh in flight: wait, don't drop the page
        guard cursor == c else { return }
        loading = true
        defer { loading = false }
        // Keep going while pages come back empty but more remain (all-cron stretches on the Chats filter).
        for _ in 0..<5 {
            guard let page = try? await API.shared.sessions(cursor: c, profile: profile, exclude: exclude) else {
                error = "Couldn't load older chats. Pull down to retry."
                return
            }
            sessions = dedupe(sessions + page.data)
            cursor = page.next
            guard page.data.isEmpty, let next = page.next else { return }
            c = next
        }
    }

    /// Picks up chats started on the desktop while this list is on screen.
    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard results == nil, filter != .archived, !loading,
                  let page = try? await API.shared.sessions(cursor: nil, profile: profile, exclude: exclude) else { continue }
            let fresh = page.data
            let rest = sessions.filter { s in !fresh.contains { $0.key == s.key } }
            withAnimation { sessions = dedupe(fresh + rest).sorted(by: Self.order) }
        }
    }

    static func order(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned == true }
        return a.date > b.date
    }

    private func dedupe(_ list: [SessionSummary]) -> [SessionSummary] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.key).inserted }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let found = (try? await API.shared.search(q)) ?? []
        results = profile.map { p in found.filter { $0.profile == p } } ?? found
    }

    private func setFlag(_ s: SessionSummary, _ flag: String, _ value: Bool) async {
        do {
            try await API.shared.updateSession(profile: s.profile, session: s.id, fields: [flag: value])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startNew() {
        if let profile { path.append(ChatRef(profile: profile, sessionId: nil)) } else { showNew = true }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let botName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(id: session.profile, name: botName, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(session.date, format: relative).font(.caption).foregroundStyle(.secondary)
                }
                if let p = session.preview, !p.isEmpty, p != session.displayTitle {
                    Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(botName).foregroundStyle(Bot.color(for: session.profile))
                    if !session.sourceLabel.isEmpty { Text("·"); Text(session.sourceLabel) }
                    if let m = session.model, !m.isEmpty { Text("·"); Text(m).lineLimit(1) }
                    if session.pinned == true { Image(systemName: "pin.fill").font(.caption2) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var relative: Date.FormatStyle {
        Calendar.current.isDateInToday(session.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()
    }
}

/// Pick which bot a new chat goes to.
struct NewChatSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: (Bot) -> Void

    var body: some View {
        NavigationStack {
            List(app.bots.filter(\.reachable)) { bot in
                Button { onPick(bot) } label: { BotRow(bot: bot) }
                    .buttonStyle(.plain)
            }
            .navigationTitle("New chat with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
