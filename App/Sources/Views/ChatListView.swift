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
    @State private var draftScopes = Set<String>()
    /// Archiving chats that hold pinned messages asks twice: a dialog naming the pins, then an alert.
    @State private var pinGuard: PinGuard?
    @State private var pinGuardConfirm: PinGuard?

    /// Chats about to be archived that still hold pinned messages.
    struct PinGuard: Identifiable {
        let id = UUID()
        let targets: [SessionSummary]
        let batch: Bool
        var held: [SessionSummary] { targets.filter { $0.pinnedMessages > 0 } }
        var pinTotal: Int { held.reduce(0) { $0 + $1.pinnedMessages } }
        var title: String {
            let pins = pinTotal == 1 ? "1 pinned message" : "\(pinTotal) pinned messages"
            if !batch || targets.count == 1 { return "This chat has \(pins)" }
            return held.count == 1 ? "1 selected chat has \(pins)" : "\(held.count) selected chats have \(pins)"
        }
    }
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
                .safeAreaInset(edge: .bottom) { QueuedActionsBar() }
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
                // Returning from a chat is when a draft may have appeared or been sent.
                .task(id: [String(navigation.wrappedValue.count), app.inboxAccount ?? ""]) {
                    draftScopes = app.inboxAccount.map(ComposerDisk.shared.scopes) ?? []
                }
                .confirmationDialog(pinGuard?.title ?? "", isPresented: Binding(get: { pinGuard != nil }, set: { if !$0 { pinGuard = nil } }),
                                    titleVisibility: .visible, presenting: pinGuard) { guarded in
                    Button(guarded.batch && guarded.targets.count > 1 ? "Archive all, keep pins" : "Archive, keep pins", role: .destructive) {
                        pinGuardConfirm = guarded
                    }
                    if guarded.batch, guarded.held.count < guarded.targets.count {
                        Button("Archive only chats without pins") {
                            let keep = Set(guarded.held.map(\.key))
                            Task { await batch(["archived": true], only: guarded.targets.filter { !keep.contains($0.key) }) }
                        }
                    }
                    if !guarded.batch, let first = guarded.held.first {
                        Button("Open chat to review pins") {
                            navigation.wrappedValue.append(ChatRef(profile: first.profile, sessionId: first.id))
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("Pins mark what matters in a chat. Archiving keeps them, and they come back when you unarchive.")
                }
                .alert("Archive with pins?", isPresented: Binding(get: { pinGuardConfirm != nil }, set: { if !$0 { pinGuardConfirm = nil } }),
                       presenting: pinGuardConfirm) { guarded in
                    Button("Archive", role: .destructive) {
                        if guarded.batch { Task { await batch(["archived": true], only: guarded.targets, confirmPins: true) } }
                        else if let s = guarded.targets.first { Task { await archive(s, confirmPins: true) } }
                    }
                    Button("Keep in inbox", role: .cancel) {}
                } message: { guarded in
                    Text("Are you sure? \(guarded.pinTotal == 1 ? "1 pinned message" : "\(guarded.pinTotal) pinned messages") will be out of sight until you unarchive.")
                }

        }
    }

    private var inboxNavigation: some View {
        content
            .hmCanvas()
            .navigationTitle(selecting ? "\(selection.count) selected" : (profile.map { app.botName($0) } ?? "Chats"))
            // Large title only on the real top-level inbox, not a bot's inbox or while selecting.
            .navigationBarTitleDisplayMode(fixedProfile == nil && !selecting ? .large : .inline)
            .navigationDestination(for: ChatRef.self) { ChatView(ref: $0) }
            .searchable(text: $query, prompt: "Search chats")
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
            Button { requestBatchArchive() } label: {
                Label(filter == .archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    .hmTouchTarget()
            }
            Spacer()
            if batchBusy { ProgressView().controlSize(.small); Spacer() }
            Menu {
                Button("Pin", systemImage: "pin") { Task { await batch(["pinned": true]) } }
                Button("Unpin", systemImage: "pin.slash") { Task { await batch(["pinned": false]) } }
            } label: { Label("Pin options", systemImage: "pin").hmTouchTarget() }
        }
        .padding(.horizontal, HMDesign.gutter).frame(minHeight: HMDesign.touch).hmBar(.none)
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
                VStack(alignment: .leading, spacing: HMDesign.micro) {
                    let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout())
                    header {
                        if let url = API.shared.baseURL {
                            Button { showGateways = true } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "server.rack").imageScale(.small)
                                    Text(SavedGateways.displayName(url)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                                }
                                .font(.subheadline.weight(.medium))
                                .hmTouchTarget()
                            }
                            .buttonStyle(.borderless)
                            .disabled(selecting || fixedProfile != nil)
                            .accessibilityLabel("Choose gateway, current gateway " + SavedGateways.displayName(url))
                        }
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 6) }
                        ConnectionBadge().buttonStyle(.borderless)
                    }
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
                    layout { filters }
                    .disabled(selecting)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }.hmRows()
            .listSectionSpacing(.compact)
            if let error, !(sessions.isEmpty && results == nil) {
                // Cached or partial rows stay visible; say what failed and offer the existing refresh.
                VStack(alignment: .leading, spacing: HMDesign.micro) {
                    Label(error, systemImage: "wifi.exclamationmark")
                    if let lastSync { Text("Last synced \(lastSync, style: .relative) ago").font(.footnote) }
                    Button("Try again") { Task { await reload() } }
                        .buttonStyle(.borderless)
                        .hmTouchTarget()
                        .disabled(loading)
                }.foregroundStyle(HMDesign.text2)
            }
            if let results {
                if results.isEmpty { ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces)) }
                ForEach(results, id: \.key) { row($0) }
            } else {
                ForEach(grouped, id: \.0) { section in
                    Section(header: HMHeader(section.0)) { ForEach(section.1, id: \.key) { row($0) } }.hmRows()
                }
                if cursor != nil {
                    HStack { Spacer(); ProgressView().accessibilityLabel("Loading more chats"); Spacer() }
                        .task(id: cursor) { await loadMore() }  // re-runs for every new page, even an empty one
                } else if sessions.isEmpty && !loading {
                    Group { if let error { failureState(error) } else { emptyState } }.listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionActions } }
        .overlay {
            if loading && sessions.isEmpty { ProgressView("Loading chats…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: HMDesign.panelRadius)) }
        }
    }

    private var emptyState: some View {
        let title: String, detail: String, symbol: String
        switch filter {
        case .archived: (title, detail, symbol) = ("No archived chats", "Chats you archive show up here. You can unarchive them any time.", "archivebox")
        case .telegram: (title, detail, symbol) = ("No Telegram chats", "Telegram chats appear here after this bot saves them in Hermes.", "bubble.left")
        case .desktop: (title, detail, symbol) = ("No Hermes app chats", "Chats started in the Hermes app on your Mac show up here.", "bubble.left")
        case .all: (title, detail, symbol) = ("Nothing here yet", "Chats and automated runs show up here once Hermes records them.", "tray")
        case .chats: (title, detail, symbol) = ("No chats yet", "Start a chat, or choose another source from the filter above.", "bubble.left")
        }
        return ContentUnavailableView {
            if HMTheme.isThermocline {
                HorizonEyeMark().frame(width: 64, height: 64).accessibilityHidden(true)
                Text(title).font(.title2.bold())
            } else {
                Label(title, systemImage: symbol)
            }
        } description: {
            Text(detail)
        } actions: {
            if filter != .archived { Button("New chat") { startNew() } }
        }
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't load chats", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await reload() } }.disabled(loading)
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
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(HMDesign.text2)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(HMDesign.ink)
        .padding(.horizontal, HMDesign.medium).padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .hmTouchTarget()
    }

    @ViewBuilder private func row(_ s: SessionSummary) -> some View {
        if selecting {
            Button { toggle(s) } label: {
                HStack(spacing: HMDesign.medium) {
                    Image(systemName: selection.contains(s.key) ? "checkmark.circle.fill" : "circle")
                        .frame(width: HMDesign.touch, height: HMDesign.touch)
                        .font(.title3)
                        .foregroundStyle(selection.contains(s.key) ? HMDesign.accent : HMDesign.text2)
                    SessionRow(session: s, botName: app.botName(s.profile), showAvatar: false, hasDraft: draftScopes.contains(s.profile + "|session/" + s.id))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(batchBusy)
            .accessibilityAddTraits(selection.contains(s.key) ? .isSelected : [])
        } else {
            HStack(spacing: HMDesign.medium) {
                // Bot name is in the row's metadata, so give the text the width at accessibility sizes.
                if !typeSize.isAccessibilitySize {
                    BotAvatar(id: s.profile, name: app.botName(s.profile), size: 38)
                        .frame(width: HMDesign.touch, height: HMDesign.touch)
                        .accessibilityHidden(true)
                }
                NavigationLink(value: ChatRef(profile: s.profile, sessionId: s.id)) {
                    SessionRow(session: s, botName: app.botName(s.profile), showAvatar: false, hasDraft: draftScopes.contains(s.profile + "|session/" + s.id))
                }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    requestArchive(s)
                } label: {
                    Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox")
                }.tint(HMDesign.link)
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await setFlag(s, "pinned", !(s.pinned ?? false)) }
                } label: {
                    Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin")
                }.tint(HMDesign.caution)
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
                    requestArchive(s)
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
    /// Archive (or unarchive) the selection, asking first when any selected chat holds pinned messages.
    private func requestBatchArchive() {
        let archiving = filter != .archived
        let targets = visibleSessions.filter { selection.contains($0.key) }
        if archiving, targets.contains(where: { $0.pinnedMessages > 0 }) {
            pinGuard = PinGuard(targets: targets, batch: true)
        } else {
            Task { await batch(["archived": archiving]) }
        }
    }

    /// Swipe/menu archive for one chat. Unarchiving never asks; archiving a chat with pins does.
    private func requestArchive(_ s: SessionSummary) {
        if s.archived == true { Task { await setFlag(s, "archived", false) } }
        else if s.pinnedMessages > 0 { pinGuard = PinGuard(targets: [s], batch: false) }
        else { Task { await archive(s, confirmPins: false) } }
    }

    /// Archives through the bridge's flag endpoint, which refuses chats with pins unless confirmed. An older
    /// bridge without that endpoint falls back to the gateway's per-session PATCH.
    private func archive(_ s: SessionSummary, confirmPins: Bool) async {
        let destination = app.gatewaySession
        do {
            let result = try await API.shared.updateSessions(profile: s.profile, ids: [s.id], fields: ["archived": true],
                                                             confirmPins: confirmPins)
            guard destination == app.gatewaySession else { return }
            if let held = result.heldForPins[s.id] {
                // Pinned from another device since this list loaded: show the count and ask.
                var fresh = s
                fresh.pinCount = held
                if let index = sessions.firstIndex(where: { $0.key == s.key }) { sessions[index].pinCount = held }
                pinGuard = PinGuard(targets: [fresh], batch: false)
                return
            }
            if let problem = result.errors[s.id] { self.error = problem; return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            apply("archived", true, to: s.key)
            if !query.isEmpty { await runSearch() }
        } catch APIError.http(404, _) {
            await setFlag(s, "archived", true)
        } catch where ActionQueue.isOffline(error) {
            guard destination == app.gatewaySession else { return }
            await queueFlags([s], ["archived": true], confirmPins: confirmPins)
        } catch {
            guard destination == app.gatewaySession else { return }
            self.error = error.localizedDescription
        }
    }

    /// The Mac can't be reached: save the change on this phone, show it now, send it when the Mac answers.
    private func queueFlags(_ targets: [SessionSummary], _ fields: [String: Bool], confirmPins: Bool = false) async {
        guard let account = API.shared.accountID else { return }
        for (pid, rows) in Dictionary(grouping: targets, by: \.profile) {
            let action = QueuedAction(account: account, kind: .flags, profile: pid, ids: rows.map(\.id), fields: fields,
                                      confirmPins: confirmPins)
            _ = await ActionQueue.shared.perform(action)
        }
        for row in targets { for (flag, value) in fields { apply(flag, value, to: row.key) } }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func batch(_ fields: [String: Bool], only: [SessionSummary]? = nil, confirmPins: Bool = false) async {
        guard !batchBusy, only != nil || !selection.isEmpty else { return }
        let targets = only ?? visibleSessions.filter { selection.contains($0.key) }
        guard !targets.isEmpty else { endSelection(); return }
        var heldForPins = 0
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
                    let response = try await api.updateSessions(profile: pid, ids: chunk.map(\.id), fields: fields,
                                                                confirmPins: confirmPins)
                    heldForPins += response.heldForPins.count
                    let updated = Set(response.updated)
                    failures.formUnion(chunk.filter { !updated.contains($0.id) }.map(\.key))
                } catch APIError.http(404, _) {
                    for row in chunk {
                        guard gateway == app.gatewaySession else { return }
                        do { try await api.updateSession(profile: pid, session: row.id, fields: fields) }
                        catch { failures.insert(row.key) }
                    }
                } catch where ActionQueue.isOffline(error) {
                    // Offline: these go out when the Mac answers. Not failures.
                    await queueFlags(Array(chunk), fields, confirmPins: confirmPins)
                } catch { failures.formUnion(chunk.map(\.key)) }
            }
        }
        guard gateway == app.gatewaySession, inboxScope == scope else { return }
        if failures.isEmpty { endSelection() } else { selection = failures }
        await reload()
        if !query.isEmpty { await runSearch() }
        if failures.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        else if heldForPins > 0 {
            error = "Archived \(targets.count - failures.count) of \(targets.count) chats. \(heldForPins == 1 ? "1 chat has" : "\(heldForPins) chats have") pinned messages and stayed; they are selected. Tap Archive again to confirm."
        }
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
            if case APIError.http(401, _) = error { app.sessionExpired() }
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
            // Apply the change in place. Reloading would collapse a long list back to its first page
            // and lose the reader's position; the periodic refresh reconciles with the gateway.
            apply(flag, value, to: s.key)
            if !query.isEmpty { await runSearch() }
        } catch where ActionQueue.isOffline(error) {
            guard destination == app.gatewaySession else { return }
            await queueFlags([s], [flag: value])
        } catch {
            guard destination == app.gatewaySession else { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ flag: String, _ value: Bool, to key: String) {
        guard let index = sessions.firstIndex(where: { $0.key == key }) else { return }
        if flag == "archived" {
            // Archiving leaves every view but Archived; unarchiving leaves only that one.
            if value != (filter == .archived) { sessions.remove(at: index) }
        } else {
            sessions[index].pinned = value
            if filter != .archived { sessions.sort(by: Self.order) }
        }
        if let cacheKey = app.inboxKey(profile: profile, filter: filter.cacheKey), sessions.count <= 220 {
            app.inboxes[cacheKey] = InboxSnapshot(sessions: sessions, cursor: cursor, savedAt: lastSync ?? Date())
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
    var hasDraft = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var large: Bool { typeSize.isAccessibilitySize }

    private var metadata: [String] {
        var parts = [botName]
        if !session.sourceLabel.isEmpty { parts.append(session.sourceLabel) }
        if let m = session.model, !m.isEmpty { parts.append(Self.shortModel(m)) }
        return parts
    }

    var body: some View {
        HStack(alignment: .top, spacing: HMDesign.medium) {
            if showAvatar && !large { BotAvatar(id: session.profile, name: botName, size: 38).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                // Title keeps the full width; the time moves below it at accessibility sizes.
                let head = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: HMDesign.micro)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: HMDesign.small))
                head {
                    Text(session.displayTitle).font(HMDesign.rowTitle).lineLimit(large ? 4 : 2)
                    if !large { Spacer(minLength: HMDesign.micro) }
                    Text(session.date, format: relative).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                        .monospacedDigit().fixedSize(horizontal: true, vertical: false)
                }
                if hasDraft {
                    // An unsent message is the most useful line a row can show: it is why you come back.
                    Label("Draft", systemImage: "pencil.line")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.tint)
                        .accessibilityLabel("Unsent draft")
                } else if let p = session.preview, !p.isEmpty, p != session.displayTitle {
                    Text(p).font(.subheadline).foregroundStyle(HMDesign.text2).lineLimit(large ? 4 : 2)
                }
                // One wrapping line, so a long bot or model name never squeezes the title or the pin state.
                Text(metadata.joined(separator: " · "))
                    .font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                    .lineLimit(large ? 4 : 2).truncationMode(.middle)
                    .accessibilityLabel(metadata.joined(separator: ", "))
                if session.pinned == true || session.pinnedMessages > 0 {
                    let pins = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: HMDesign.micro)) : AnyLayout(HStackLayout(spacing: HMDesign.small))
                    pins {
                        if session.pinned == true {
                            Label("Pinned", systemImage: "pin.fill")
                        }
                        if session.pinnedMessages > 0 {
                            Label(session.pinnedMessages == 1 ? "1 pinned message" : "\(session.pinnedMessages) pinned messages", systemImage: "pin.circle.fill")
                        }
                    }
                    .font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                }
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
            .hmCanvas()
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
                Section(header: HMHeader("Views")) {
                    ForEach(ChatListView.Filter.allCases) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.rawValue).font(.subheadline.weight(.semibold))
                            Text(entry.explanation).font(.footnote).foregroundStyle(HMDesign.text2)
                        }
                        .padding(.vertical, 2)
                    }
                }.hmRows()
                Section(header: HMHeader("Where a chat came from")) {
                    ForEach(sources) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.id).font(.subheadline.weight(.semibold))
                            Text(entry.detail).font(.footnote).foregroundStyle(HMDesign.text2)
                        }
                        .padding(.vertical, 2)
                    }
                }.hmRows()
                Section(header: HMHeader("Faster actions")) {
                    Text("Touch and hold a chat to archive, pin or select it. Swipe left to archive, swipe right to pin. Tap Select to choose several at once.")
                        .font(.footnote)
                }.hmRows()
            }
            .hmCanvas()
            .navigationTitle("Chats, explained")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// "2 changes waiting for your Mac": actions taken offline, sent in order when the Mac answers.
struct QueuedActionsBar: View {
    private var queue = ActionQueue.shared

    var body: some View {
        let mine = queue.mine
        if !mine.isEmpty {
            let stuck = mine.filter { $0.problem != nil }
            Menu {
                ForEach(mine) { action in
                    Section(header: HMHeader(action.problem.map { "Didn't apply: " + $0 } ?? "Waiting")) {
                        Button(role: .destructive) { queue.discard(action.id) } label: {
                            Label("Cancel: " + action.summary, systemImage: "xmark")
                        }
                    }.hmRows()
                }
                Button { queue.wake() } label: { Label("Try now", systemImage: "arrow.clockwise") }
            } label: {
                Label(stuck.isEmpty ? "\(mine.count) change\(mine.count == 1 ? "" : "s") waiting for your Mac"
                                    : "\(stuck.count) change\(stuck.count == 1 ? "" : "s") didn't apply",
                      systemImage: stuck.isEmpty ? "icloud.and.arrow.up" : "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(stuck.isEmpty ? HMDesign.text2 : HMDesign.warning)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .hmCapsule()
            }
            .padding(.bottom, 6)
            .accessibilityHint("Shows changes saved on this phone. They apply when your Mac is reachable.")
        }
    }
}
