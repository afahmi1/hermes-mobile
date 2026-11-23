import SwiftUI

/// Every session from every profile, newest first — GUI, Telegram, iMessage, terminal, scheduled.
struct ChatListView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .chats
    @State private var sessions: [SessionSummary] = []
    @State private var cursor: String?
    @State private var generation = UUID()
    @State private var lastSync: Date?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var results: [SessionSummary]?
    @State private var botPath: [ChatRef] = []
    private var navigation: Binding<[ChatRef]> {
        if fixedProfile != nil { return $botPath }
        let session = app.gatewaySession
        return Binding(get: { app.inboxPath }, set: { path in
            if session == app.gatewaySession { app.inboxPath = path }
        })
    }
    @State private var showNew = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var batchBusy = false
    @State private var showGateways = false
    @State private var showSourceGuide = false
    private let fixedProfile: String?
    @State private var selectedBot: String?
    private var profile: String? { fixedProfile ?? selectedBot }
    init(profile: String? = nil) { fixedProfile = profile }


    enum Filter: String, CaseIterable, Identifiable {
        case chats = "Conversations", desktop = "Hermes apps", telegram = "Telegram", all = "Everything", archived = "Archived"
        var source: String? {
            switch self {
            case .desktop: "desktop"   // wire value; the bridge expands it to local/gui/desktop
            case .telegram: "telegram"
            case .archived: "archived"
            default: nil
            }
        }
        var cacheKey: String {
            switch self {
            case .chats: "Chats"
            case .desktop: "Desktop & phone"
            default: rawValue
            }
        }
        var id: String { rawValue }
        var explanation: String {
            switch self {
            case .chats: "Every chat you can continue: Hermes's own interface, Telegram, iMessage and terminal. Scheduled and subagent runs stay out."
            case .desktop: "Conversations in Hermes's own interface. The desktop app and this app share a source, so Hermes can't always say which device started a chat."
            case .telegram: "Chats Hermes saved from Telegram."
            case .all: "Every unarchived source, including scheduled, one-shot, subagent and tool runs."
            case .archived: "Chats you archived. Swipe left to unarchive, or select several."
            }
        }
    }

    var body: some View {
        NavigationStack(path: navigation) {
            inboxNavigation
                .sheet(isPresented: $showSourceGuide) { SourceGuideView() }
                .sheet(isPresented: $showGateways) { GatewayDestinationsView() }
                .sheet(isPresented: $showNew) {
                    NewChatSheet { bot in
                        showNew = false
                        navigation.wrappedValue.append(ChatRef(profile: bot.id, sessionId: nil))
                    }
                }
                .refreshable { await reload() }
                .task(id: inboxScope) { await restoreInbox() }
                .task(id: scenePhase) { if scenePhase == .active { await autoRefresh() } }

        }
    }

    private var inboxNavigation: some View {
        content
            .navigationTitle(selecting ? "\(selection.count) selected" : (profile.map { app.botName($0) } ?? "Chats"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .searchable(text: $query, prompt: "Search this gateway")
            .task(id: [query] + inboxScope) { await runSearch() }
            .toolbar { inboxToolbar }
            .onChange(of: inboxScope) { _, _ in endSelection() }
            .onChange(of: query) { _, _ in endSelection() }
    }

    @ToolbarContentBuilder private var inboxToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("Cancel") { endSelection() }.disabled(batchBusy)
            } else {
                Button("Select") { beginSelection() }.disabled(visibleSessions.isEmpty)
                    .accessibilityLabel("Select chats")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button("Select all") { selection = Set(visibleSessions.map(\.key)) }
                    .disabled(batchBusy || visibleSessions.isEmpty)
                    .accessibilityLabel("Select all loaded chats")
            } else {
                Button { startNew() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
            }
        }
    }

    private var selectionActions: some View {
        HStack {
            Button { Task { await batch(["archived": filter != .archived]) } } label: {
                Label(filter == .archived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Spacer()
            if batchBusy { ProgressView().controlSize(.small); Spacer() }
            Menu {
                Button("Pin", systemImage: "pin") { Task { await batch(["pinned": true]) } }
                Button("Unpin", systemImage: "pin.slash") { Task { await batch(["pinned": false]) } }
            } label: { Label("Pin options", systemImage: "pin") }
        }
        .padding(.horizontal, 20).frame(minHeight: 48).background(.bar)
        .disabled(batchBusy || selection.isEmpty)
    }

    private var inboxScope: [String] { [filter.rawValue, profile ?? "", app.inboxAccount ?? ""] }

    private func restoreInbox() async {
        let request = UUID()
        generation = request
        loading = false
        let scope = filter
        error = nil
        let key = app.inboxKey(profile: profile, filter: scope.cacheKey)
        var saved = key.flatMap { app.inboxes[$0] }
        sessions = saved?.sessions ?? []
        cursor = saved?.cursor
        lastSync = saved?.savedAt
        if saved == nil, let key {
            saved = await InboxDisk.shared.read(key)
            guard !Task.isCancelled, generation == request, filter == scope, key == app.inboxKey(profile: profile, filter: scope.cacheKey) else { return }
            if let saved {
                app.inboxes[key] = saved
                sessions = saved.sessions
                cursor = saved.cursor
                lastSync = saved.savedAt
            }
        }
        if saved.map({ Date().timeIntervalSince($0.savedAt) < 12 }) != true { await reload() }
    }

    @ViewBuilder private var content: some View {
        List {
            Section {
                // One quiet strip above the list: where you are, how it is doing, and what is shown.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let url = API.shared.baseURL {
                            Button { showGateways = true } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "server.rack").imageScale(.small)
                                    Text(SavedGateways.displayName(url)).lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(selecting || fixedProfile != nil)
                            .accessibilityLabel("Choose gateway, current gateway " + SavedGateways.displayName(url))
                        }
                        Spacer(minLength: 6)
                        ConnectionBadge().buttonStyle(.borderless)
                    }
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
                    layout { filters }
                    .disabled(selecting)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listSectionSpacing(.compact)
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "wifi.exclamationmark")
                    if let lastSync { Text("Last synced \(lastSync, style: .relative) ago").font(.footnote) }
                }.foregroundStyle(.secondary)
            }
            if let results {
                if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                ForEach(results, id: \.key) { row($0) }
            } else {
                ForEach(grouped, id: \.0) { section in
                    Section(section.0) { ForEach(section.1, id: \.key) { row($0) } }
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .task(id: cursor) { await loadMore() }  // re-runs for every new page, even an empty one
                } else if sessions.isEmpty && !loading && error == nil {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left",
                                           description: Text(filter == .telegram ? "Telegram chats appear here after this bot saves them in Hermes." : "Choose another source or start a chat with the compose button."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionActions } }
        .overlay {
            if loading && sessions.isEmpty { ProgressView("Loading chats…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    @ViewBuilder private var filters: some View {
        Menu {
            Picker("Source", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("About chat sources", systemImage: "info.circle") { showSourceGuide = true }
        } label: { filterLabel(filter.rawValue, symbol: "line.3.horizontal.decrease").fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true) }
        .buttonStyle(.borderless)
        .accessibilityLabel("Source, " + filter.rawValue)
        if fixedProfile == nil {
            Menu {
                Picker("Bot", selection: $selectedBot) {
                    Text("All bots").tag(String?.none)
                    ForEach(app.bots) { bot in Text(bot.name == bot.id ? bot.name : "\(bot.name) · \(bot.id)").tag(Optional(bot.id)) }
                }
            } label: { filterLabel(selectedBot.map { app.botName($0) } ?? "All bots", symbol: "person.2") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Bot, " + (selectedBot.map { app.botName($0) } ?? "All bots"))
        }
    }

    private func filterLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.small)
            Text(title).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func row(_ s: SessionSummary) -> some View {
        if selecting {
            Button { toggle(s) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection.contains(s.key) ? "checkmark.circle.fill" : "circle")
                        .frame(width: 44, height: 44)
                        .font(.title3)
                        .foregroundStyle(selection.contains(s.key) ? Color.accentColor : Color.secondary)
                    SessionRow(session: s, botName: app.botName(s.profile), showAvatar: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(batchBusy)
            .accessibilityAddTraits(selection.contains(s.key) ? .isSelected : [])
        } else {
            HStack(spacing: 10) {
                Button { beginSelection(); toggle(s) } label: {
                    BotAvatar(id: s.profile, name: app.botName(s.profile), size: 38)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Select " + s.displayTitle)
                NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
                    SessionRow(session: s, botName: app.botName(s.profile), showAvatar: false)
                }
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
            .contextMenu {
                Button {
                    Task { await setFlag(s, "pinned", !(s.pinned ?? false)) }
                } label: {
                    Label(s.pinned == true ? "Unpin" : "Pin",
                          systemImage: s.pinned == true ? "pin.slash" : "pin")
                }
                Button {
                    beginSelection()
                    toggle(s)
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Button {
                    UIPasteboard.general.string = s.displayTitle
                } label: {
                    Label("Copy Title", systemImage: "doc.on.doc")
                }
                Divider()
                Button {
                    Task { await setFlag(s, "archived", !(s.archived ?? false)) }
                } label: {
                    Label(s.archived == true ? "Unarchive" : "Archive",
                          systemImage: s.archived == true ? "tray.and.arrow.up" : "archivebox")
                }
            }
        }
    }

    private var visibleSessions: [SessionSummary] { results ?? sessions }

    private func beginSelection() {
        selecting = true
        selection.removeAll()
    }

    private func endSelection() {
        selecting = false
        selection.removeAll()
    }

    private func toggle(_ s: SessionSummary) {
        if selection.contains(s.key) { selection.remove(s.key) } else { selection.insert(s.key) }
    }

    /// One request per profile; the bridge fans the gateway's per-session PATCH out in parallel.
    private func batch(_ fields: [String: Bool]) async {
        guard !batchBusy, !selection.isEmpty else { return }
        let targets = visibleSessions.filter { selection.contains($0.key) }
        guard !targets.isEmpty else { endSelection(); return }
        batchBusy = true
        defer { batchBusy = false }
        let api = API.shared
        let gateway = app.gatewaySession
        let scope = inboxScope
        var failures = Set<String>()
        for (pid, rows) in Dictionary(grouping: targets, by: \.profile) {
            for start in stride(from: 0, to: rows.count, by: 200) {
                guard gateway == app.gatewaySession else { return }
                let chunk = rows[start..<min(start + 200, rows.count)]
                do {
                    let response = try await api.updateSessions(profile: pid, ids: chunk.map(\.id), fields: fields)
                    let updated = Set(response.updated)
                    failures.formUnion(chunk.filter { !updated.contains($0.id) }.map(\.key))
                } catch APIError.http(404, _) {
                    for row in chunk {
                        guard gateway == app.gatewaySession else { return }
                        do { try await api.updateSession(profile: pid, session: row.id, fields: fields) }
                        catch { failures.insert(row.key) }
                    }
                } catch { failures.formUnion(chunk.map(\.key)) }
            }
        }
        guard gateway == app.gatewaySession, inboxScope == scope else { return }
        if failures.isEmpty { endSelection() } else { selection = failures }
        await reload()
        if !query.isEmpty { await runSearch() }
        if failures.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        else { error = "Updated \(targets.count - failures.count) of \(targets.count) chats. The others are selected for retry." }
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
        let request = UUID()
        generation = request
        let requestedFilter = filter
        let key = app.inboxKey(profile: profile, filter: requestedFilter.cacheKey)
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let page = try await API.shared.sessions(cursor: nil, profile: profile, exclude: exclude, source: filter.source)
            guard !Task.isCancelled, generation == request, requestedFilter == filter, key == app.inboxKey(profile: profile, filter: filter.cacheKey) else { return }
            if let warning = page.partialWarning {
                sessions = dedupe(page.data + sessions)
                cursor = nil
                error = warning
                return
            }
            sessions = dedupe(page.data)
            cursor = page.next
            error = nil
            rememberPage(key)
        } catch {
            guard !Task.isCancelled, generation == request, requestedFilter == filter, key == app.inboxKey(profile: profile, filter: filter.cacheKey) else { return }
            self.error = error.localizedDescription
            if case APIError.http(401, _) = error { app.signOut() }
        }
    }

    private func rememberPage(_ key: String?) {
        guard let key else { return }
        let snapshot = InboxSnapshot(sessions: sessions, cursor: cursor, savedAt: Date())
        lastSync = snapshot.savedAt
        app.inboxes[key] = snapshot
        Task { await InboxDisk.shared.save(snapshot, key: key) }
    }

    private func loadMore() async {
        let request = generation
        let requestedFilter = filter
        let key = app.inboxKey(profile: profile, filter: requestedFilter.cacheKey)
        guard var c = cursor else { return }
        while loading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }  // a refresh in flight: wait, don't drop the page
        guard !Task.isCancelled, generation == request, filter == requestedFilter, cursor == c else { return }
        loading = true
        defer { if generation == request { loading = false } }
        // Keep going while pages come back empty but more remain (all-cron stretches on the Chats filter).
        for _ in 0..<5 {
            guard let page = try? await API.shared.sessions(cursor: c, profile: profile, exclude: exclude, source: filter.source) else {
                guard !Task.isCancelled, generation == request, filter == requestedFilter, key == app.inboxKey(profile: profile, filter: filter.cacheKey) else { return }
                error = "Couldn't load older chats. Pull down to retry."
                return
            }
            guard !Task.isCancelled, generation == request, filter == requestedFilter, key == app.inboxKey(profile: profile, filter: filter.cacheKey) else { return }
            if let warning = page.partialWarning {
                error = warning
                cursor = nil
                return
            }
            sessions = page.reset == true ? dedupe(page.data) : dedupe(sessions + page.data)
            cursor = page.next
            if sessions.count <= 220, let key {
                app.inboxes[key] = InboxSnapshot(sessions: sessions, cursor: cursor, savedAt: Date())
            }
            guard page.data.isEmpty, let next = page.next else { return }
            c = next
        }
    }

    /// Picks up chats started on the desktop while this list is on screen.
    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            let request = generation
            let requestedFilter = filter
            let key = app.inboxKey(profile: profile, filter: requestedFilter.cacheKey)
            guard !Task.isCancelled, results == nil, filter != .archived, !loading,
                  let page = try? await API.shared.sessions(cursor: nil, profile: profile, exclude: exclude, source: filter.source) else { continue }
            guard !Task.isCancelled, request == generation, requestedFilter == filter, key == app.inboxKey(profile: profile, filter: filter.cacheKey) else { continue }
            if let warning = page.partialWarning { error = warning; continue }
            error = nil
            if sessions.isEmpty || page.next == nil { cursor = page.next }
            let fresh = page.data
            let keys = Set(fresh.map(\.key))
            let rest = page.next == nil ? [] : sessions.filter { !keys.contains($0.key) }
            let combined = (fresh + rest).sorted(by: Self.order)
            if combined != sessions { sessions = combined }
            if let key {
                lastSync = Date()
                let firstPage = InboxSnapshot(sessions: fresh, cursor: page.next, savedAt: Date())
                if sessions.count <= 220 {
                    app.inboxes[key] = InboxSnapshot(sessions: sessions, cursor: cursor, savedAt: firstPage.savedAt)
                }
                await InboxDisk.shared.save(firstPage, key: key)
            }
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
        do {
            let found = try await API.shared.search(q, archived: filter == .archived, profile: profile, source: filter == .archived ? nil : filter.source, scope: filter == .chats ? "chats" : "all")
            guard !Task.isCancelled else { return }
            results = profile.map { p in found.filter { $0.profile == p } } ?? found
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = nil
            self.error = error.localizedDescription
        }
    }

    private func setFlag(_ s: SessionSummary, _ flag: String, _ value: Bool) async {
        let api = API.shared
        let destination = app.gatewaySession
        do {
            try await api.updateSession(profile: s.profile, session: s.id, fields: [flag: value])
            guard destination == app.gatewaySession else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await reload()
            if !query.isEmpty { await runSearch() }
        } catch {
            guard destination == app.gatewaySession else { return }
            self.error = error.localizedDescription
        }
    }

    private func startNew() {
        if let profile { navigation.wrappedValue.append(ChatRef(profile: profile, sessionId: nil)) } else { showNew = true }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let botName: String
    var showAvatar = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showAvatar { BotAvatar(id: session.profile, name: botName, size: 38) }
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
                    Text(botName)
                    if !session.sourceLabel.isEmpty { Text("·"); Text(session.sourceLabel) }
                    if let m = session.model, !m.isEmpty { Text("·"); Text(Self.shortModel(m)).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary) }
                    if session.pinned == true { Image(systemName: "pin.fill").font(.caption2) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "deepseek/deepseek-v4.1-pro" reads as "deepseek-v4.1-pro": the provider prefix repeats the family
    /// and pushes the part that differs off the row. Bracketed routing suffixes are dropped the same way.
    static func shortModel(_ model: String) -> String {
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if let bracket = name.firstIndex(of: "["), bracket > name.startIndex { name = String(name[..<bracket]) }
        return name
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

/// Plain-language guide to the inbox's filters and source labels. The list is intentionally
/// read-only: it explains what the app already shows instead of adding another control surface.
private struct GuideEntry: Identifiable {
    let id: String
    let detail: String
}

private struct SourceGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let sources = [
        GuideEntry(id: "Mobile", detail: "The mobile bridge recorded the creation of this conversation."),
        GuideEntry(id: "Hermes app, Local, Desktop", detail: "The source recorded by Hermes. Older shared app sessions have no device recorded."),
        GuideEntry(id: "API", detail: "Started through Hermes's gateway API server."),
        GuideEntry(id: "Browser", detail: "Started through Hermes's browser platform."),
        GuideEntry(id: "iMessage", detail: "Imported from iMessage."),
        GuideEntry(id: "Telegram", detail: "Imported from Telegram."),
        GuideEntry(id: "Terminal", detail: "Started in the Hermes CLI or TUI."),
        GuideEntry(id: "Scheduled, One-shot, Subagent, Tool run", detail: "Automation. Visible under Everything, not under Chats."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Views") {
                    ForEach(ChatListView.Filter.allCases) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.rawValue).font(.subheadline.weight(.semibold))
                            Text(entry.explanation).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("Where a chat came from") {
                    ForEach(sources) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.id).font(.subheadline.weight(.semibold))
                            Text(entry.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("Faster actions") {
                    Text("Touch and hold a chat to archive, pin or select it. Swipe left to archive, swipe right to pin. Tap Select, or the avatar beside a chat, to choose several at once.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Chats, explained")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
