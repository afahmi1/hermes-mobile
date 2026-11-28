import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import QuickLook

extension Notification.Name {
    /// Posted when a chat became a project: the app switches to Projects and opens it.
    static let openAutoProject = Notification.Name("hermes.autoProject.open")
}

/// The project a chat just became, carried by the `.openAutoProject` notification.
struct AutoProjectOpen {
    let id: String
}

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let ref: ChatRef
    /// Set only when opened from a project's workspace; the only place project context can be offered.
    var projectScope: WorkspaceScope?

    var body: some View {
        let chat = app.chat(for: ref)
        ChatScreen(chat: chat, draftKey: ref.id, projectScope: projectScope)
            .id(ObjectIdentifier(chat))
    }
}

struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    let draftKey: String
    var projectScope: WorkspaceScope?
    /// Off for every send; switched back off after each one.
    @State private var includeProjectContext = false
    @State private var followLatest = true
    /// Points above the newest message (from `ReadingPosition`), and how many rows arrived while you were up there.
    @State private var distanceFromLatest: CGFloat = 0
    @State private var unseenSinceAway = 0
    /// The Latest button appears only once you're clearly reading back, never for a nudge at the bottom.
    private let latestThreshold: CGFloat = 280
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRuntime = false
    @State private var sendTick = 0
    @State private var showFullComposer = false
    @State private var previewedImage: UIImage?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var landTick = 0
    @State private var pathPreview: URL?
    @State private var revealTimes = false
    @State private var showPicker = false
    @State private var showFilePicker = false
    @State private var showCamera = false
    @State private var preparingMedia = false
    @State private var pickedVideo: URL?
    @State private var chooseVideo = false
    @State private var mediaCapabilities: MediaCapabilities?
    @State private var showPins = false
    @State private var showCommands = false
    @State private var keyboardUp = false
    @State private var toast: String?
    /// Which pin the bar shows; tapping the bar jumps to it, then moves to the next older pin (Telegram-style).
    @State private var pinCursor = 0
    @State private var highlighted: String?
    @State private var makingProject = false
    /// Find in chat: open, the words, the hits (oldest first) and which one is shown.
    @State private var finding = UserDefaults.standard.string(forKey: "HMDemoFind") != nil
    @State private var makeProjectError: String?

    private var bot: Bot? { app.bot(chat.profile) }

    @ViewBuilder private var makeProjectMenu: some View {
        Menu {
            Button { withAnimation(HMMotion.standard) { finding = true } } label: {
                Label("Search in chat", systemImage: "magnifyingglass")
            }
            .disabled(chat.sessionId == nil)
            Button {
                Task { await makeProject() }
            } label: {
                if makingProject { Label("Making a project…", systemImage: "gearshape.2") }
                else { Label("Make a project", systemImage: "folder.badge.plus") }
            }
            .disabled(makingProject || chat.sessionId == nil)
        } label: {
            Image(systemName: makingProject ? "gearshape.2" : "ellipsis.circle")
                .accessibilityLabel("Chat actions")
        }
    }

    /// Split out of `body` so the type checker can finish (one expression that size times out).
    @ViewBuilder private var trailingActions: some View {
        HStack(spacing: HMDesign.small) {
            makeProjectMenu
            // One dot. Tap it for the gateway's state, Reload chat and Check again.
            ConnectionBadge(compact: true, reloadDisabled: chat.isLoading || chat.isRunning) {
                await chat.load(quiet: true)
                landTick &+= 1
            }
        }
    }

    private var makeProjectFailed: Binding<Bool> {
        Binding(get: { makeProjectError != nil }, set: { if !$0 { makeProjectError = nil } })
    }

    /// Turn this chat into a project on the Mac (title, summary, instructions, context, files and the chat itself),
    /// then jump to it in the Projects tab.
    private func makeProject() async {
        guard let sid = chat.sessionId, !makingProject else { return }
        makingProject = true
        defer { makingProject = false }
        do {
            let made = try await API.shared.makeProject(profile: chat.profile, session: sid)
            NotificationCenter.default.post(name: .openAutoProject, object: AutoProjectOpen(id: made.id))
        } catch let f as API.AutoProjectFailure {
            makeProjectError = f.message
        } catch {
            makeProjectError = API.AutoProjectFailure.failed.message
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: HMDesign.medium) {
                    if let saved = chat.cachedAt {
                        Text("Saved on this iPhone \(saved, style: .relative) ago")
                            .font(.footnote).foregroundStyle(HMDesign.text2)
                    }
                    if chat.hasOlder {
                        Button(chat.loadingOlder ? "Loading earlier messages…" : "Load earlier messages") {
                            followLatest = false
                            let anchor = chat.items.first?.id
                            Task {
                                await chat.loadOlder()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                        .font(HMDesign.metadata).frame(minHeight: HMDesign.touch).disabled(chat.loadingOlder)
                    }
                    if chat.items.isEmpty && !chat.isLoading {
                        emptyState.padding(.vertical, HMDesign.section)
                    }
                    let days = Self.dayStarts(chat.items)
                    let timeMarks = Self.timeMarks(chat.items)
                    let lastReply = chat.isRunning ? nil : chat.items.last(where: { $0.kind == .assistant && !$0.streaming })?.id
                    ForEach(chat.items) { item in
                        if let day = days[item.id] { DaySeparator(date: day) }
                        MessageRow(item: item, profile: chat.profile, session: chat.sessionId,
                                   pinned: chat.isPinned(item), highlighted: highlighted == item.id,
                                   onPin: chat.pinsAvailable && chat.sessionId != nil && MessagePin.messageID(for: item) != nil
                                        ? { Task { await chat.togglePin(item) } } : nil,
                                   onCompose: { text, replace in compose(text, replace: replace) },
                                   showActions: item.kind == .assistant && !item.streaming,  // every finished reply, like T3
                                   chat: chat,
                                   showTime: revealTimes || timeMarks.contains(item.id))
                            .id(item.id)
                    }
                    if !backgroundTasks.isEmpty {
                        // Like the desktop: each subagent is a card you can open and watch.
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chat.isRunning ? "Working in the background" : backgroundTasks.count == 1
                                 ? "Will resume when 1 background task finishes"
                                 : "Will resume when \(backgroundTasks.count) background tasks finish")
                                .font(.footnote.weight(.semibold)).foregroundStyle(HMDesign.text2)
                            ForEach(backgroundTasks) { task in SubagentCard(task: task) }
                        }
                        .padding(.horizontal, 12)
                    }
                    if let s = chat.status {
                        ThinkingStatus(chat: chat, status: s)
                        .padding(.horizontal, 16).id("status")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // Tight at the bottom: the newest line (or the thinking row) sits just above the composer.
                .padding(.top, 12).padding(.bottom, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(ReadingPosition(followLatest: $followLatest, distance: $distanceFromLatest,
                                      pastEnd: { land(proxy) }))
            .modifier(LatestControl(distance: distanceFromLatest, threshold: latestThreshold, count: chat.items.count,
                                    unseen: $unseenSinceAway) {
                followLatest = true
                withAnimation(HMMotion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { drag in
                // Swipe left, like iMessage, to see every message's time.
                let sideways = drag.translation.width < -40 && abs(drag.translation.width) > abs(drag.translation.height) * 1.5
                if sideways != revealTimes { withAnimation(HMMotion.standard) { revealTimes = sideways } }
            }.onEnded { _ in
                if revealTimes { withAnimation(HMMotion.standard) { revealTimes = false } }
            })
            .onChange(of: chat.textRevision) { _, _ in
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.items.last?.id) { _, _ in
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Land on the newest message after a reload, and when coming back to the chat. A lazy list that
            // gets a whole transcript at once can otherwise sit past its content: a blank screen until you scroll.
            .onChange(of: landTick) { _, _ in land(proxy) }
            .onAppear {
                if followLatest { land(proxy) }
                if let sid = chat.sessionId { ChatSeen.mark(chat.profile + "|" + sid) }
            }
            .onDisappear { if let sid = chat.sessionId { ChatSeen.mark(chat.profile + "|" + sid) } }
            // A long transcript arriving all at once can leave a lazy list parked below its content (a blank
            // screen until you scroll). Land on the newest message once a page is in, then again after the rows
            // have measured themselves. Keyed on the newest row, not on "empty": the cached copy shown at open is
            // replaced by the fresh page (different row heights) without the list ever being empty in between.
            .task(id: chat.items.last?.id) {
                guard !chat.items.isEmpty, followLatest else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(450))
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay { if chat.isLoading { ProgressView("Loading messages…") } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if finding {
                    FindBar(chat: chat, open: $finding) { itemID in await reveal(itemID, proxy: proxy) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if !chat.pins.isEmpty {
                    PinnedBar(pins: chat.pins, cursor: min(pinCursor, chat.pins.count - 1)) {
                        let pin = chat.pins[min(pinCursor, chat.pins.count - 1)]
                        pinCursor = (pinCursor + 1) % chat.pins.count
                        jump(to: pin, proxy: proxy)
                    } list: { showPins = true }
                }
            }
            .sheet(isPresented: $showPins) {
                PinsSheet(chat: chat) { pin in
                    showPins = false
                    jump(to: pin, proxy: proxy)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .hmCanvas()
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showRuntime = true } label: { titleBlock.frame(minHeight: HMDesign.touch).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Change model, provider and effort")
                    .disabled(chat.savingRuntime)
            }
            ToolbarItem(placement: .topBarTrailing) { trailingActions }
        }
        .alert("Couldn't make the project", isPresented: makeProjectFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(makeProjectError ?? "")
        }
        .sheet(isPresented: $showRuntime) {
            RuntimeSheet(profile: chat.profile, bot: bot, current: chat.choice, served: chat.served,
                         sessionId: chat.sessionId, running: chat.isRunning) { choice in
                Task { await chat.apply(choice) }
            }
        }
        .sheet(item: $chat.approval) { req in
            ApprovalSheet(req: req, busy: chat.answeringApproval, error: chat.approvalError) { answer in Task { await chat.answer(req, choice: answer) } }
        }
        .fullScreenCover(isPresented: $showFullComposer) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 8) {
                    draftShelf
                    composerField(expanded: true).padding(.horizontal, 16)
                    if let error = chat.error { Text(error).font(.footnote).foregroundStyle(HMDesign.caution).padding(.horizontal) }
                }
                .hmCanvas()
                .navigationTitle("Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showFullComposer = false } }
                }
                .fullScreenCover(isPresented: previewPresented) { imagePreview }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !showFullComposer && previewedImage != nil },
                                             set: { if !$0 { previewedImage = nil } })) { imagePreview }
        .modifier(MediaInputsModifier(host: self))
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .sensoryFeedback(.success, trigger: chat.completedTick)
        .sensoryFeedback(.error, trigger: chat.failedTick)
        .task { await chat.load() }
        .task { await chat.loadPalette() }
        .modifier(VisibleChat(destination: chat.notificationDestination))
        .task(id: chat.sessionId) { await chat.loadPins() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onReceive(NotificationCenter.default.publisher(for: .hermesOpenPath)) { note in
            guard let path = note.object as? String, let sid = chat.sessionId else { return }
            Task { await openPath(path, session: sid) }
        }
        .quickLookPreview($pathPreview)
        // A chat running somewhere else (a subagent, the desktop, Telegram): follow it while it works.
        .task(id: chat.sessionId) { await followElsewhere() }
        .onReceive(NotificationCenter.default.publisher(for: .hermesForeground)) { _ in
            // Anything waiting to go tries again right away, then backs off quietly.
            chat.outboxWake()
            // Back from the background: show what happened while away, then land on it.
            guard !chat.isRunning else { return }
            // Only land on the newest message if that's where you were. Reading higher up stays put.
            let wasAtBottom = followLatest
            Task { await chat.load(quiet: true); if wasAtBottom { landTick &+= 1 } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesCopied)) { note in
            let text = note.object as? String ?? "Copied"
            withAnimation(HMMotion.standard) { toast = text }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                if toast == text { withAnimation(HMMotion.standard) { toast = nil } }
            }
        }
        .overlay(alignment: .top) {
            if let toast { CopiedToast(text: toast).padding(.top, 8).allowsHitTesting(false) }
        }
        .alert(chat.runtimeConfirmation?.title ?? "Model selection warning",
               isPresented: Binding(get: { chat.runtimeConfirmation != nil }, set: { if !$0 { chat.runtimeConfirmation = nil } }),
               presenting: chat.runtimeConfirmation) { pending in
            Button("Use this model") { Task { await chat.apply(pending.choice, confirm: true) } }
            Button("Keep current", role: .cancel) {}
        } message: { pending in Text(pending.message) }
        .sheet(isPresented: $showCommands) {
            CommandsSheet(commands: chat.slashCommands, skills: chat.skillDetails, pick: { name in
                chat.draft = "/" + name + " "
            }, usePrompt: { text, now in
                if now && !chat.isRunning && chat.draftAttachments.isEmpty && chat.draft.isEmpty {
                    chat.draft = text
                    send()
                } else if now && chat.isRunning {
                    chat.draft = text
                    followUp("queue")
                } else {
                    chat.draft = chat.draft.isEmpty ? text : chat.draft + "\n\n" + text
                }
            })
        }
        .onChange(of: chat.pins.count) { _, _ in pinCursor = 0 }
        // Re-ask when the gateway comes back: one failed probe must not hide attachments for the visit.
        .task(id: [chat.profile, app.health?.ok == true ? "up" : "down"]) {
            if let latest = try? await API.shared.mediaCapabilities(profile: chat.profile), !Task.isCancelled {
                mediaCapabilities = latest
            }
        }
        .task(id: scenePhase) { if scenePhase == .active { await poll() } }
    }

    /// The pickers, camera and video consent dialog. Kept out of `body`: one long modifier chain is more
    /// than the Swift type checker will solve in reasonable time.
    fileprivate func mediaInputs<Content: View>(_ content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                      maxSelectionCount: max(1, ChatMedia.maxAttachments - chat.draftAttachments.count),
                      selectionBehavior: .ordered,
                      matching: imagesAvailable ? .any(of: [.images, .videos]) : .videos)
            .task(id: pickerItems) { if !pickerItems.isEmpty { await importPicked(pickerItems) } }
            // .package: Pages, Keynote and Numbers documents and .rtfd are folders on disk; they go up zipped.
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .package], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
            .sheet(isPresented: $showCamera) {
            CameraPhoto { image in
                showCamera = false
                guard let image else { return }
                let account = app.inboxAccount
                preparingMedia = true
                Task {
                    defer { preparingMedia = false }
                    do {
                        // Full resolution like a library photo. Re-encoding from the decoded image carries no
                        // location or camera metadata.
                        let data = try await Task.detached(priority: .userInitiated) {
                            guard let data = image.jpegData(compressionQuality: 0.9) else { throw ChatMedia.Failure.unreadable }
                            return data
                        }.value
                        appendMedia([try await photoAttachment(data, prefix: "Camera")], account: account)
                    } catch { chat.error = error.localizedDescription }
                }
            }.ignoresSafeArea()
        }
            .confirmationDialog("How should Hermes receive this video?", isPresented: $chooseVideo) {
            if mediaCapabilities?.maxUploadBytes != nil {
                Button("Send the original video file") { prepareOriginal() }
            }
            if mediaCapabilities?.video == true, chat.draftAttachments.isEmpty {
                Button("Send clip for Hermes video analysis") { prepareClip() }
            }
            if imagesAvailable { Button("Choose from up to 3 frames") { prepareFrames() } }
            Button("Cancel", role: .cancel) { discardVideo() }
        } message: { Text(mediaCapabilities?.video == true ? "A clip includes audio and may be processed by the gateway’s video provider. Frames are still images you can review before sending." : "This gateway accepts still images. Review and remove frames before sending. Frames contain no audio.") }
            .onDisappear { discardVideo() }
    }

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(bot?.name ?? chat.profile).font(.headline).lineLimit(1)
            HStack(spacing: 3) {
                if chat.served?.fallbackActive == true || answeredByOther != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.caution)
                        .accessibilityLabel("The last reply came from a different model than the one picked")
                }
                Text(runtimeLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).imageScale(.small).accessibilityHidden(true)
            }
            .font(.caption2).foregroundStyle(HMDesign.text2)
        }
    }

    /// "Opus 5.5 · High". The provider and raw id live in the model sheet, one tap away.
    private var answeredByOther: ServedRuntime.LastAnswer? {
        chat.served?.stand(in: chat.choice.model ?? bot?.model)
    }

    private var runtimeLabel: String {
        if chat.savingRuntime { return "Saving model…" }
        let c = chat.choice
        let who = ModelName.short(c.model ?? bot?.model ?? "Default model").components(separatedBy: " · ").first ?? ""
        if chat.isRunning, chat.runtimeNotice != nil { return "Next · " + who }
        // A fallback (or an older answer) wrote the last reply: say both, so the header never claims a model
        // that didn't answer. "Grok 4.7 answered · Opus 5.5 next".
        if let other = answeredByOther {
            return (ModelName.short(other.model).components(separatedBy: " · ").first ?? other.model) + " answered · " + who + " next"
        }
        var parts = [who]
        if let effort = c.effort.flatMap({ Effort(rawValue: $0)?.label }) { parts.append(effort) }
        // What was actually charged, plus "+ plan" when a subscription covered the rest, so the label changes
        // as plan usage grows instead of looking frozen (the model sheet shows the API-price equivalent).
        if let cost = chat.served?.cost {
            if cost.usd >= 0.01 { parts.append(CostSummary.money(cost.usd) + (cost.included ? " + plan" : "")) }
            else if cost.included, cost.includedApiUsd >= 0.01 { parts.append("Plan") }
        }
        return parts.joined(separator: " · ")
    }

    /// Every 5 s, only while this chat is running somewhere other than this phone's own reply.
    private func followElsewhere() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard let sid = chat.sessionId, !chat.isRunning else { continue }
            let agents = app.status.payload?["agents"].array ?? []
            if agents.contains(where: { $0["session_id"].string == sid }) { await chat.load(quiet: true) }
        }
    }

    private var backgroundTasks: [SubagentInfo] {
        guard let session = chat.sessionId else { return [] }
        return (app.status.payload?["agents"].array ?? []).compactMap { row in
            guard row["kind"].string == "subagent", row["parent_session_id"].string == session else { return nil }
            return SubagentInfo(sessionID: row["session_id"].string, profile: row["profile"].string ?? chat.profile,
                                title: row["title"].string ?? row["name"].string ?? "Background task",
                                goal: row["goal"].string, model: row["model"].string ?? "",
                                provider: row["provider"].string, steps: row["steps"].int,
                                started: row["started_at"].date)
        }
    }

    private var emptyState: some View {
        VStack(spacing: HMDesign.small) {
            BotAvatar(id: chat.profile, name: bot?.name ?? chat.profile, size: 64).accessibilityHidden(true)
            Text(bot?.name ?? chat.profile).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let b = bot?.blurb, !b.isEmpty {
                Text(b).font(.subheadline).foregroundStyle(HMDesign.text2).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Text("Write a message to start the conversation.")
                .font(.subheadline).foregroundStyle(HMDesign.text2).multilineTextAlignment(.center)
            Button { showRuntime = true } label: {
                VStack(spacing: 2) {
                    Label(runtimeLabel, systemImage: "cpu").font(HMDesign.metadata)
                    Text("Tap to pick the model and effort").font(.caption2).foregroundStyle(HMDesign.text2)
                }
                .frame(minHeight: HMDesign.touch)
            }
            .buttonStyle(.borderless)
        }
    }

    private var imagesAvailable: Bool {
        mediaCapabilities?.images == true || (mediaCapabilities == nil && app.health?.imageAttachments == true)
    }

    /// Every bridge since Build 20 accepts files. Until the probe answers, assume it does, so the
    /// attach button never blinks out of the composer; the bridge still validates every file on send.
    private var filesAvailable: Bool { mediaCapabilities?.files ?? true }

    /// The attach button stays in the composer, even while a reply runs: anything picked then is staged
    /// in the draft and goes out with the next message (follow-ups are text only).
    private var canAttach: Bool {
        imagesAvailable || filesAvailable || mediaCapabilities?.video == true
    }

    private var attachmentLimitReached: Bool {
        chat.draftAttachments.count >= ChatMedia.maxAttachments || chat.draftAttachments.contains { $0.mime == "video/mp4" }
    }

    private var previewPresented: Binding<Bool> {
        Binding(get: { previewedImage != nil }, set: { if !$0 { previewedImage = nil } })
    }

    @ViewBuilder private var imagePreview: some View {
        if let previewedImage { FullImagePreview(image: previewedImage) }
    }

    private func composerField(expanded: Bool) -> some View {
        ComposerField(text: $chat.draft, placeholder: "Message \(bot?.name ?? "Hermes")",
                      expanded: expanded, onPasteText: chat.absorbPaste, onPasteImage: importPastedImage,
                      onPasteFile: importPastedFile)
    }

    @ViewBuilder private var draftShelf: some View {
        let quotes = chat.pastedTexts.filter(\.isQuote)
        if !quotes.isEmpty {
            // Replying to several messages: each pill keeps its own answer; the newest one's answer is the box.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(quotes.enumerated()), id: \.element.id) { i, quote in
                        if !quote.text.isEmpty {
                            QuoteChip(text: quote.text, count: quotes.count > 1 ? (i + 1, quotes.count) : nil) {
                                withAnimation(.snappy) { chat.removeReplyQuote(quote.id) }
                            }
                        }
                        if i < quotes.count - 1 {
                            TextField("Your reply to this…", text: Binding(
                                get: { chat.pastedTexts.first { $0.id == quote.id }?.answer ?? "" },
                                set: { v in if let k = chat.pastedTexts.firstIndex(where: { $0.id == quote.id }) { chat.pastedTexts[k].answer = v } }),
                                      axis: .vertical)
                                .lineLimit(1...4)
                                .font(.subheadline)
                                .padding(.leading, 13).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: quotes.count > 1 ? 260 : nil)
            .fixedSize(horizontal: false, vertical: quotes.count == 1)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if chat.pastedTexts.contains(where: { !$0.isQuote }) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(chat.pastedTexts.filter { !$0.isQuote }) { chunk in
                        PasteChip(text: Binding(get: { chat.pastedTexts.first { $0.id == chunk.id }?.text ?? "" },
                                               set: { value in
                                if let index = chat.pastedTexts.firstIndex(where: { $0.id == chunk.id }) { chat.pastedTexts[index].text = value }
                            })) {
                            chat.removePastedText(chunk.id)
                        }
                    }
                }.padding(.horizontal, 12)
            }.scrollIndicators(.hidden)
        }
        if !chat.draftAttachments.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(chat.draftAttachments.enumerated()), id: \.offset) { index, asset in
                        AttachmentChip(attachment: asset, preview: {
                            // Uploaded photos live as files; both kinds open, downsampled to screen size.
                            Task {
                                let image = await Task.detached(priority: .userInitiated) { ChatMedia.previewImage(asset, pixels: 2400) }.value
                                if let image { previewedImage = image } else { chat.error = "This photo couldn’t be opened. Remove it and attach it again." }
                            }
                        }) {
                            chat.removeDraftAttachment(at: index)
                        }
                    }
                }.padding(.horizontal, 12)
            }.scrollIndicators(.hidden)
        }
    }

    private var composer: some View {
        VStack(spacing: HMDesign.micro) {
            if let e = chat.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HMDesign.caution).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e).font(HMDesign.metadata)
                        if chat.hasUnconfirmedSend {
                            Button("Move back to composer") { Task { await chat.cancelUnconfirmedSend() } }
                                .font(.footnote.weight(.semibold))
                                .frame(minHeight: 44, alignment: .leading)
                                .accessibilityHint("Stops waiting for confirmation and returns the message for editing")
                        }
                    }
                    Spacer()
                    Button { chat.error = nil } label: { Image(systemName: "xmark").hmTouchTarget() }
                        .accessibilityLabel("Dismiss error")
                }
                .padding(HMDesign.small)
                .background(HMDesign.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: HMDesign.panelRadius))
                .padding(.horizontal, HMDesign.medium)
            }
            if let scope = projectScope {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Include \(scope.title) context with next message", isOn: $includeProjectContext)
                        .font(.subheadline)
                        .disabled(chat.isRunning)
                    Text(ProjectContext.disclosure).font(.caption2).foregroundStyle(HMDesign.text2)
                }
                .padding(.horizontal, 16)
            }
            if let filter = SlashCommand.filter(in: chat.draft), chat.draftAttachments.isEmpty, !chat.isRunning {
                SlashMenu(commands: chat.slashCommands, skills: chat.skillDetails, filter: filter) { name in
                    chat.draft = "/" + name + " "
                }
            }
            if !chat.questions.isEmpty { QuestionPanel(chat: chat) }
            if chat.queue?.paused == true { QueuePausedBanner(chat: chat) }
            if !chat.outgoing.isEmpty { OutboxTray(chat: chat) }
            draftShelf
            if chat.isRunning, let notice = chat.runtimeNotice {
                Text(notice).font(HMDesign.metadata).foregroundStyle(HMDesign.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HMDesign.gutter)
            }
            // One row: tools left, the field, send right. The model lives in the title, so no pill here,
            // and every line the composer does not take is a line of conversation.
            HStack(alignment: .bottom, spacing: 0) {
                if canAttach { attachmentMenu }
                Button { showCommands = true } label: {
                    Image(systemName: "command").font(.body).frame(width: 34, height: HMDesign.touch).contentShape(Rectangle())
                }
                .foregroundStyle(HMDesign.text2)
                .accessibilityLabel("Commands and skills")
                composerField(expanded: false)
                    .padding(.leading, HMDesign.medium).padding(.vertical, HMDesign.small)
                    .padding(.trailing, (longDraft || keyboardUp) ? 30 : HMDesign.medium)
                    .frame(maxWidth: .infinity, minHeight: HMDesign.touch)
                    .hmField()
                    .overlay(alignment: .topTrailing) {
                        if longDraft {
                            Button { showFullComposer = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .foregroundStyle(HMDesign.text2)
                            .accessibilityLabel("Expand composer")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if keyboardUp {
                            Button { Self.hideKeyboard() } label: {
                                Image(systemName: "keyboard.chevron.compact.down").font(.caption)
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .foregroundStyle(HMDesign.text2)
                            .accessibilityLabel("Hide keyboard")
                        }
                    }
                    .padding(.horizontal, HMDesign.micro)
                if chat.isRunning {
                    Button { Task { await chat.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(HMDesign.danger)
                            .hmTouchTarget()
                    }
                    .accessibilityLabel("Stop reply")
                    // While Hermes replies, Send queues the message for right after this reply.
                    // Touch and hold to guide the current reply instead.
                    let canQueue = !(preparingMedia || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                    Button { followUp("queue") } label: {
                        Group {
                            if HMTheme.isThermocline { HMSendGlyph(enabled: canQueue) }
                            else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        }
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "clock.fill").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(HMTheme.isThermocline ? HMDesign.bubbleText : .white, HMDesign.accentFill)
                                    .background(Circle().fill(HMDesign.canvas).padding(-1))
                                    .offset(x: 2, y: 2)
                            }
                            .hmTouchTarget()
                    }
                    .disabled(preparingMedia || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                    .contextMenu {
                        Button { followUp("queue") } label: { Label("Send next (after this reply)", systemImage: "text.line.last.and.arrowtriangle.forward") }
                        Button { followUp("steer") } label: { Label("Guide this reply now", systemImage: "arrow.turn.up.right") }
                    }
                    .accessibilityLabel("Queue message")
                    .accessibilityHint("Sends it right after the current reply. Touch and hold to guide this reply instead.")
                } else {
                    let canSend = !(preparingMedia || chat.savingRuntime || chat.slashBusy
                                    || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                    Button { send() } label: {
                        Group {
                            if HMTheme.isThermocline { HMSendGlyph(enabled: canSend) }
                            else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        }
                        .hmTouchTarget()
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, HMDesign.small).padding(.bottom, HMDesign.micro)
            // Send already queues. Guide only shows once there is something to say: an empty row costs a line of chat.
            if chat.isRunning, !chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftAttachments.isEmpty {
                HStack(spacing: HMDesign.gutter) {
                    Button { followUp("steer") } label: {
                        Label("Guide this reply instead", systemImage: "arrow.turn.up.right").hmTouchTarget()
                    }
                    Spacer()
                    Text("Send queues it").font(.caption).foregroundStyle(HMDesign.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.subheadline.weight(.medium))
                .disabled(!chat.acceptsFollowUp || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                .padding(.horizontal, 16).padding(.bottom, 5)
            }
        }
        .padding(.top, HMDesign.micro)
        .hmBar(.top)
    }

    private var attachmentMenu: some View {
        Menu {
            if imagesAvailable || mediaCapabilities?.video == true {
                Button { showPicker = true } label: {
                    Label(imagesAvailable ? "Photo or video" : "Video", systemImage: "photo.on.rectangle")
                }
            }
            if imagesAvailable, UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { openCamera() } label: { Label("Take photo", systemImage: "camera") }
            }
            if filesAvailable {
                Button { showFilePicker = true } label: { Label("Choose file", systemImage: "doc") }
            }
        } label: {
            Group {
                if preparingMedia { ProgressView() }
                else { Image(systemName: "plus.circle").font(.title2) }
            }
            .hmTouchTarget()
        }
        .disabled(attachmentLimitReached || preparingMedia)
        .accessibilityLabel(preparingMedia ? "Preparing attachment" : "Add attachment")
    }

    private var longDraft: Bool {
        chat.combinedDraft.count > 140 || chat.draft.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= 2
    }

    static func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Quote prepends to the draft; Edit replaces it (asking nothing: the old draft is one Undo away in the field).
    private func compose(_ text: String, replace: Bool) {
        // A reply quote becomes a compact chip, not raw "> " lines in the box.
        if !replace, text.hasPrefix("> ") {
            let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : String($0) }.joined(separator: "\n")
            chat.setReplyQuote(raw)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if replace, chat.restoreReplies(from: text) {
            // Editing a sent reply: each quote goes back into a pill with its words, the last words into the box.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        chat.draft = replace || chat.draft.isEmpty ? text : text + chat.draft
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Which rows show a time: the last row before a pause of five minutes or more, and the newest row.
    /// Like iMessage, a burst of messages carries one time, not one each. Swipe left shows them all.
    static func timeMarks(_ items: [ChatItem]) -> Set<String> {
        let stamped = items.filter { $0.timestamp != nil && $0.kind != .tools && $0.kind != .notice }
        var marks = Set<String>()
        for (index, item) in stamped.enumerated() {
            guard let t = item.timestamp else { continue }
            if index == stamped.count - 1 { marks.insert(item.id); continue }
            let next = stamped[index + 1]
            if (next.timestamp ?? t) - t >= 300 || (next.kind == .user) != (item.kind == .user) { marks.insert(item.id) }
        }
        return marks
    }

    /// The first item of each calendar day, so the transcript can say "Today", "Yesterday" or the date.
    static func dayStarts(_ items: [ChatItem]) -> [String: Date] {
        var out: [String: Date] = [:]
        var last: Date?
        let calendar = Calendar.current
        for item in items {
            guard let ts = item.timestamp else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: ts))
            if day != last { out[item.id] = day; last = day }
        }
        return out
    }

    /// A path Hermes wrote in a reply: fetch it through the bridge (which re-checks it) and preview it.
    private func openPath(_ path: String, session: String) async {
        do {
            let data = try await API.shared.chatFile(profile: chat.profile, session: session, path: path)
            let name = (path as NSString).lastPathComponent
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-paths", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name.isEmpty ? "file" : name)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            pathPreview = url
        } catch APIError.http(404, _) {
            Clipboard.copy(path, what: "Path copied")
            chat.error = "Hermes can't share that file (it's gone, private, or not a previewable type), so the path was copied."
        } catch {
            chat.error = "Couldn't open that file: " + error.localizedDescription
        }
    }

    /// Bottom, then again once rows have measured themselves (lazy rows report estimated heights first).
    private func land(_ proxy: ScrollViewProxy) {
        followLatest = true
        proxy.scrollTo("bottom", anchor: .bottom)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo("bottom", anchor: .bottom)
            try? await Task.sleep(for: .milliseconds(380))
            if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// Scrolls to a pinned message, loading earlier pages if needed, and flashes it.
    private func jump(to pin: MessagePin, proxy: ScrollViewProxy) {
        Task {
            if !(await reveal(pin.itemID, proxy: proxy)) {
                chat.error = "That pinned message is no longer in this chat's history. Its text is kept in Pinned."
            }
        }
    }

    /// Load earlier pages until a stored message is here, scroll it to the middle and flash it. False when it's gone.
    @discardableResult
    private func reveal(_ itemID: String, proxy: ScrollViewProxy) async -> Bool {
        followLatest = false
        guard await chat.reveal(itemID: itemID) else { return false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(itemID, anchor: .center) }
        highlighted = itemID
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == itemID { withAnimation { highlighted = nil } }
        }
        return true
    }

    private func openCamera() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { showCamera = true }
            else { chat.error = "Allow camera access in iPhone Settings to take a photo." }
        }
    }

    private func issue(for assets: [SendAttachment]) -> String? {
        AttachmentSelection.issue(assets, fileLimit: mediaCapabilities?.maxFileBytes ?? 4 * 1024 * 1024,
                                   videoLimit: mediaCapabilities?.maxVideoBytes ?? 4 * 1024 * 1024,
                                   uploadLimit: mediaCapabilities?.maxUploadBytes,
                                   messageLimit: mediaCapabilities?.maxMessageBytes)
    }

    /// Add prepared attachments to the draft. False when they can't go in (the chat or account changed, the task
    /// was cancelled, or a limit says no); their phone copies are then deleted, so nothing is left behind.
    @discardableResult
    private func appendMedia(_ assets: [SendAttachment], account: String?) -> Bool {
        guard !assets.isEmpty else { return true }
        guard !Task.isCancelled, let account, account == app.inboxAccount else {
            UploadFiles.discard(assets, keeping: UploadFiles.names(chat.draftAttachments))
            return false
        }
        let proposed = fitToBudget(chat.draftAttachments + assets)
        if let problem = issue(for: proposed) {
            chat.error = problem
            // Includes copies fitToBudget made of photos already in the draft; the draft keeps its own.
            UploadFiles.discard(proposed + assets, keeping: UploadFiles.names(chat.draftAttachments))
            return false
        }
        chat.draftAttachments = proposed
        return true
    }

    /// Photos ride inline by default, and a message's inline bytes share one small budget. Fifteen photos blow
    /// it, so the biggest ones move to the Mac's resumable upload (which takes up to 50 MB) instead of the
    /// send being refused. Nothing is recompressed: the same JPEG travels by a different road.
    private func fitToBudget(_ assets: [SendAttachment]) -> [SendAttachment] {
        let limit = mediaCapabilities?.maxFileBytes ?? 4 * 1024 * 1024
        guard let uploadLimit = mediaCapabilities?.maxUploadBytes else { return assets }
        var out = assets
        func inlineTotal() -> Int { out.filter { !$0.isUpload }.reduce(0) { $0 + $1.byteCount } }
        guard inlineTotal() > limit else { return out }
        // Biggest first, so the fewest moves get under the budget.
        let order = out.indices.filter { !out[$0].isUpload && out[$0].mime.hasPrefix("image/") }
            .sorted { out[$0].byteCount > out[$1].byteCount }
        for i in order {
            guard inlineTotal() > limit else { break }
            guard out[i].byteCount <= uploadLimit else { continue }
            if let moved = try? UploadFiles.promote(out[i], filename: out[i].filename, mime: out[i].mime) { out[i] = moved }
        }
        return out
    }

    /// Full resolution through the Mac's resumable upload when it has one; otherwise the small inline JPEG.
    /// `share`: how many photos split the message's room, so a batch of fifteen fits Hermes's per-message cap.
    /// `prefix`: the file's name ("Photo-…", "Camera-…", "Pasted image-…").
    private func photoAttachment(_ data: Data, share: Int = 1, prefix: String = "Photo") async throws -> SendAttachment {
        let uploadMax = mediaCapabilities?.maxUploadBytes
        let room = (mediaCapabilities?.maxMessageBytes ?? 128 * 1024 * 1024) * 9 / 10
            - chat.draftAttachments.filter { $0.isUpload && $0.mime.hasPrefix("image/") }.reduce(0) { $0 + $1.byteCount }
        let budget = max(2 * 1024 * 1024, room / max(1, share))
        let originals = mediaCapabilities?.originalImages == true
        return try await Task.detached(priority: .userInitiated) {
            if let uploadMax, originals { return try ChatMedia.original(from: data, uploadMax: uploadMax, budget: budget, prefix: prefix) }
            if let uploadMax { return try ChatMedia.fullImage(from: data, uploadMax: uploadMax, budget: budget, name: prefix) }
            if prefix == "Pasted image" {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = ChatMedia.thumbnail(source, pixels: 2048) else { throw ChatMedia.Failure.unreadable }
                return try ChatMedia.pasted(UIImage(cgImage: image))
            }
            return try ChatMedia.image(from: data)
        }.value
    }

    /// Several photos at once, like a Telegram album. A video still goes on its own (it has its own
    /// consent choice), so a mixed pick keeps the photos and says what it skipped.
    private func importPicked(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        if items.count == 1, let only = items.first { await importMedia(only); return }
        let isVideo: (PhotosPickerItem) -> Bool = { $0.supportedContentTypes.contains { $0.conforms(to: .movie) } }
        let photos = items.filter { !isVideo($0) }
        let skipped = items.count - photos.count
        let account = app.inboxAccount
        preparingMedia = true
        defer { preparingMedia = false }
        var assets: [SendAttachment] = []
        var failed: [String] = []
        for item in photos {
            if Task.isCancelled { break }
            do {
                let data = try await MediaImport.imageData(from: item)
                if Task.isCancelled { break }
                assets.append(try await photoAttachment(data, share: photos.count))
            } catch {
                if Task.isCancelled { break }
                failed.append(error.localizedDescription)
            }
        }
        // Leaving the chat or picking again stops this batch. Its copies go, and the person hears about it.
        if Task.isCancelled {
            UploadFiles.discard(assets, keeping: UploadFiles.names(chat.draftAttachments))
            chat.error = "Adding \(photos.count) photos stopped before it finished. Choose them again."
            return
        }
        var notes: [String] = []
        // A limit can refuse the whole batch; that reason comes first, then what happened to each photo.
        let fit = appendMedia(assets, account: account)
        guard account == app.inboxAccount else { return }
        if !fit, let refused = chat.error { notes.append(refused) }
        // Say what happened to every photo, not just the last error: "Added 13 of 15 photos. 2 couldn't…".
        if !failed.isEmpty {
            let reason = Dictionary(grouping: failed, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? ""
            notes.append("Added \(fit ? assets.count : 0) of \(photos.count) photos. \(failed.count) couldn't be loaded. \(reason)")
        }
        if skipped > 0 { notes.append("Videos go one per message, so \(skipped == 1 ? "the video was" : "\(skipped) videos were") left out.") }
        if !notes.isEmpty { chat.error = notes.joined(separator: " ") }
    }

    private func importMedia(_ item: PhotosPickerItem) async {
        let account = app.inboxAccount
        preparingMedia = true
        defer { preparingMedia = false }
        do {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                discardVideo()
                let file = try await MediaImport.videoFile(from: item)
                guard !Task.isCancelled, let account, account == app.inboxAccount else {
                    try? FileManager.default.removeItem(at: file)
                    if Task.isCancelled { chat.error = "Adding the video stopped before it finished. Choose it again." }
                    return
                }
                pickedVideo = file
                chooseVideo = true
            } else {
                let data = try await MediaImport.imageData(from: item)
                try Task.checkCancellation()
                let asset = try await photoAttachment(data)
                // Cancelled: appendMedia deletes the copy instead of adding it.
                if !appendMedia([asset], account: account), Task.isCancelled { throw CancellationError() }
            }
        } catch {
            chat.error = Task.isCancelled || error is CancellationError
                ? "Adding the photo stopped before it finished. Choose it again." : error.localizedDescription
        }
    }

    /// An image pasted into the composer becomes a reviewable attachment. The pasteboard is read
    /// only at paste time (never on load); the budget, the active account and cancellation are all
    /// re-checked before anything is committed to the draft.
    private func importPastedImage(_ image: UIImage) {
        guard imagesAvailable else { chat.error = "This bot cannot receive images."; return }
        guard !preparingMedia else { chat.error = "Wait for the current attachment to finish."; return }
        if chat.draftAttachments.contains(where: { $0.mime == "video/mp4" }) {
            chat.error = "Remove the video before pasting an image."
            return
        }
        guard chat.draftAttachments.count < ChatMedia.maxAttachments else {
            chat.error = "Remove an attachment before pasting another."
            return
        }
        let account = app.inboxAccount
        preparingMedia = true
        Task {
            defer { preparingMedia = false }
            do {
                // Full resolution, like a library photo. The re-encode carries no location metadata.
                let data = try await Task.detached(priority: .userInitiated) {
                    guard let data = image.jpegData(compressionQuality: 0.9) else { throw ChatMedia.Failure.unreadable }
                    return data
                }.value
                try Task.checkCancellation()
                appendMedia([try await photoAttachment(data, prefix: "Pasted image")], account: account)
            } catch {
                if !Task.isCancelled { chat.error = error.localizedDescription }
            }
        }
    }

    /// A copied file (a PDF from Files, a document) pasted into the composer attaches like a file from Files.
    private func importPastedFile(_ provider: NSItemProvider, type: UTType) {
        guard !preparingMedia else { chat.error = "Wait for the current attachment to finish."; return }
        preparingMedia = true
        Task {
            do {
                let url = try await PastedFile.load(provider, type: type)
                preparingMedia = false
                importFileURLs([url], owned: true)
            } catch {
                preparingMedia = false
                chat.error = "The pasted file couldn’t be read. Copy it again, or attach it from Files."
            }
        }
    }

    /// Files keeps the original bytes and type; only images reuse the photo pipeline. The
    /// security-scoped URL is read inside the scope, and base64 happens off the main actor.
    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError { return }
            chat.error = "Files couldn’t open the selection. Try choosing it again."
        case .success(let urls):
            importFileURLs(urls, owned: false)
        }
    }

    /// Add every file it can and report each one it couldn't, by name. `owned`: the URLs are this app's own
    /// temporary copies (a pasted file), deleted once read.
    private func importFileURLs(_ urls: [URL], owned: Bool) {
        guard !urls.isEmpty else { return }
        let account = app.inboxAccount
        let cap = mediaCapabilities?.maxFileBytes ?? 4 * 1024 * 1024
        let uploadMax = mediaCapabilities?.maxUploadBytes
        let originals = mediaCapabilities?.originalImages == true
        func display(_ url: URL) -> String { (try? FileImport.safeName(url)) ?? "A file" }
        func isMovie(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension))?
                .conforms(to: .movie) == true
        }
        // One video on its own opens the clip / original / frames choice, as from Photos.
        if urls.count == 1, let url = urls.first, isMovie(url) {
            preparingMedia = true
            Task {
                defer { preparingMedia = false; if owned { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let snapshot = try await Task.detached(priority: .userInitiated) {
                        try FileImport.coordinated(url) { local, _, _ in try MediaStaging.stage(local) }
                    }.value
                    guard !Task.isCancelled, account == app.inboxAccount else { try? FileManager.default.removeItem(at: snapshot); return }
                    discardVideo()
                    pickedVideo = snapshot
                    chooseVideo = true
                } catch {
                    if !(error is CancellationError) { chat.error = display(url) + ": " + error.localizedDescription }
                }
            }
            return
        }
        preparingMedia = true
        Task {
            defer {
                preparingMedia = false
                if owned { for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            }
            var added: [SendAttachment] = []
            var problems: [String] = []
            let slots = max(0, ChatMedia.maxAttachments - chat.draftAttachments.count)
            var left = cap - chat.draftAttachments.filter { !$0.isUpload }.reduce(0) { $0 + $1.byteCount }
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let name = display(url)
                guard added.count < slots else {
                    problems.append("\(urls.count - index) more left out: one message takes \(ChatMedia.maxAttachments) attachments.")
                    break
                }
                if chat.draftAttachments.contains(where: { $0.mime == "video/mp4" }) {
                    problems.append("\(name): remove the video first; a video goes on its own.")
                    continue
                }
                if isMovie(url) {
                    problems.append("\(name): choose a video on its own to send the original, a clip or frames.")
                    continue
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let asset = try await Task.detached(priority: .userInitiated) {
                        try FileImport.coordinated(url) { local, filename, _ in
                            try FileImport.attachment(from: local, filename: filename, maxBytes: cap, uploadMax: uploadMax, originals: originals)
                        }
                    }.value
                    if asset.mime.hasPrefix("image/") && !imagesAvailable {
                        UploadFiles.discard([asset])
                        problems.append("\(name): this bot can’t receive images.")
                        continue
                    }
                    if !asset.isUpload {
                        guard asset.byteCount <= left else {
                            problems.append("\(name): " + FileImport.Failure.tooLarge(cap).localizedDescription)
                            continue
                        }
                        left -= asset.byteCount
                    }
                    added.append(asset)
                } catch is CancellationError {
                    break
                } catch {
                    problems.append("\(name): " + error.localizedDescription)
                }
            }
            if Task.isCancelled {
                UploadFiles.discard(added, keeping: UploadFiles.names(chat.draftAttachments))
                chat.error = "Adding files stopped before it finished. Choose them again."
                return
            }
            var notes: [String] = []
            if !appendMedia(added, account: account) {
                if account != app.inboxAccount { return }
                if let refused = chat.error { notes.append(refused) }
                added = []
            }
            if !problems.isEmpty {
                if urls.count > 1 { notes.append("Added \(added.count) of \(urls.count) files.") }
                notes += problems
            }
            chat.error = notes.isEmpty ? chat.error : notes.joined(separator: " ")
        }
    }

    private func discardVideo() {
        if let url = pickedVideo { try? FileManager.default.removeItem(at: url) }
        pickedVideo = nil
    }

    private func prepareClip() {
        guard let url = pickedVideo, let caps = mediaCapabilities, caps.video, chat.draftAttachments.isEmpty else { return }
        pickedVideo = nil
        preparingMedia = true
        let account = app.inboxAccount
        Task {
            defer { preparingMedia = false; try? FileManager.default.removeItem(at: url) }
            do {
                let clip = try await ChatMedia.clip(from: url, maxBytes: caps.maxVideoBytes, uploadMax: caps.maxUploadBytes)
                appendMedia([clip], account: account)
            } catch { chat.error = error.localizedDescription }
        }
    }

    /// The video as recorded, uploaded in resumable chunks. Hermes gets the real file and decides how to use it.
    private func prepareOriginal() {
        guard let url = pickedVideo, let uploadMax = mediaCapabilities?.maxUploadBytes else { return }
        pickedVideo = nil
        preparingMedia = true
        let account = app.inboxAccount
        Task {
            defer { preparingMedia = false; try? FileManager.default.removeItem(at: url) }
            do {
                // The staged snapshot is this app's own file: move it into the upload folder rather than copy
                // a multi-gigabyte video a second time.
                let file = try await Task.detached(priority: .userInitiated) { try ChatMedia.original(from: url, uploadMax: uploadMax, move: true) }.value
                appendMedia([file], account: account)
            } catch { chat.error = error.localizedDescription }
        }
    }

    private func prepareFrames() {
        guard let url = pickedVideo else { return }
        pickedVideo = nil
        preparingMedia = true
        let account = app.inboxAccount
        Task {
            defer { preparingMedia = false; try? FileManager.default.removeItem(at: url) }
            do {
                let frames = try await ChatMedia.frames(from: url, count: min(3, ChatMedia.maxAttachments - chat.draftAttachments.count))
                appendMedia(frames, account: account)
            } catch { chat.error = error.localizedDescription }
        }
    }

    /// Model name without a `vendor/` prefix.
    private func shortModel(_ m: String) -> String { m.split(separator: "/").last.map(String.init) ?? m }

    private var chipLabel: String {
        let c = chat.choice
        let model = shortModel(c.model ?? bot?.model ?? "Bot default")
        guard let e = c.effort.flatMap({ Effort(rawValue: $0)?.label }) else { return model }
        return model + " · " + e
    }

    private func isCurrent(_ c: RuntimeChoice) -> Bool {
        chat.choice.model == c.model && (chat.choice.provider == nil || c.provider == nil || chat.choice.provider == c.provider)
    }

    /// Current model first, then recents, then the bot's own model, deduped and capped.
    private var menuModels: [RuntimeChoice] {
        let current = chat.choice.model == nil ? [] : [chat.choice]
        let botModel = bot.map { [RuntimeChoice(provider: $0.provider, model: $0.model)] } ?? []
        return RecentModels.merged(current, RecentModels.load(profile: chat.profile) + botModel)
    }

    /// One-tap model switch above the input. Everything goes through `chat.apply`, so it is saved on
    /// the session and waits for the next message while a reply is running.
    private func runModelCommand() -> Bool {
        guard chat.pastedTexts.isEmpty, chat.draftAttachments.isEmpty,
              let cmd = ModelCommand.parse(chat.draft) else { return false }
        let line = chat.draft
        if case .picker = cmd {} else if case .badEffort = cmd {} else { chat.error = nil }
        func done() { if chat.draft == line { chat.draft = "" } }
        switch cmd {
        case .picker:
            showRuntime = true
            done()
        case .reset:
            Task { await chat.apply(.botDefault); if chat.error == nil { done() } }
        case .effort(let level):
            var next = chat.choice
            next.effort = level
            Task { await chat.apply(next); if chat.error == nil { done() } }
        case .badEffort:
            chat.error = "Use /effort " + Effort.allCases.map(\.rawValue).joined(separator: ", ") + "."
        case .model(let query, let provider):
            let profile = chat.profile
            Task {
                guard let catalog = await app.catalog(for: profile) else {
                    chat.error = "Model list isn’t available yet. Try again in a moment."
                    return
                }
                let table = Dictionary(catalog.usable.map { ($0.slug, $0.models) }, uniquingKeysWith: { a, _ in a })
                switch ModelCommand.resolve(query, provider: provider, catalog: table) {
                case .found(let p, let m):
                    var next = chat.choice
                    next.provider = p
                    next.model = m
                    chat.error = nil
                    await chat.apply(next)
                    if chat.error == nil { done() }
                case .ambiguous(let names):
                    chat.error = "More than one model matches “\(query)”: " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
                case .unknown:
                    chat.error = "No model matches “\(query)”. Type /model to browse."
                }
            }
        }
        return true
    }

    private func followUp(_ mode: String) {
        if runModelCommand() { return }
        let draftAtSend = chat.draft
        let pastedAtSend = chat.pastedTexts
        let text = chat.combinedDraft
        let files = fitToBudget(chat.draftAttachments)
        if let problem = issue(for: files) { chat.error = problem; return }
        Task {
            // Saved to this phone first, then sent. Closing the app or losing signal never loses it.
            let accepted = await chat.enqueue(text, mode: mode, attachments: files)
            if accepted, chat.draft == draftAtSend, chat.pastedTexts == pastedAtSend {
                chat.draft = ""
                chat.pastedTexts = []
            }
        }
    }

    /// Split a big photo batch into messages Hermes can see whole. The words and any files go with the first;
    /// every message says which photos it holds. They queue in order (saved on this phone first, like any
    /// queued message), so each goes after the reply to the one before.
    private func sendInBatches(_ text: String, attachments: [SendAttachment], perMessage: Int) {
        let photos = attachments.filter { $0.mime.hasPrefix("image/") }
        let others = attachments.filter { !$0.mime.hasPrefix("image/") }
        let batches = BatchPlan.split(photos.count, perMessage: perMessage)
        let draftAtSend = chat.draft, pastedAtSend = chat.pastedTexts
        followLatest = true
        sendTick += 1
        Task {
            for (n, range) in batches.enumerated() {
                let words = BatchPlan.text(text, range: range, total: photos.count, first: n == 0)
                let files = Array(photos[range]) + (n == 0 ? others : [])
                guard await chat.enqueue(words, mode: "queue", attachments: files) else { return }
            }
            if chat.draft == draftAtSend, chat.pastedTexts == pastedAtSend {
                chat.draft = ""
                chat.pastedTexts = []
            }
            if chat.draftAttachments == attachments { chat.draftAttachments = [] }
            app.adopt(chat, draftKey: draftKey)
        }
    }

    private func send() {
        if runModelCommand() { return }
        let attachments = fitToBudget(chat.draftAttachments)
        let text = chat.combinedDraft
        if let problem = issue(for: attachments) {
            chat.error = problem
            return
        }
        // Hermes looks at 10 images per message (more are only handed over as paths, which models often can't
        // hold). A bigger batch goes as several messages of 10, in order, each with all its photos seen.
        let perMessage = max(1, mediaCapabilities?.nativeImages ?? 10)
        if attachments.filter({ $0.mime.hasPrefix("image/") }).count > perMessage {
            sendInBatches(text, attachments: attachments, perMessage: perMessage)
            return
        }
        if attachments.isEmpty, chat.acceptsSlash(text) {
            followLatest = true
            sendTick += 1
            Task { await chat.runSlash(text) }
            return
        }
        // The draft and pasted text are cleared by ChatModel.send only after the outbox is staged,
        // so a failed send keeps the composer intact instead of wiping it up front.
        followLatest = true
        sendTick += 1
        let context = ProjectContext.chosen(scope: projectScope?.projectID, optedIn: includeProjectContext && !chat.isRunning)
        let opted = includeProjectContext
        includeProjectContext = false  // ask every send
        Task {
            await chat.send(text, projectContext: context, attachments: attachments)
            app.adopt(chat, draftKey: draftKey)
            // A send that never left keeps its draft, so it keeps the context choice made for it too.
            if opted, !chat.isRunning, !chat.hasUnconfirmedSend, chat.combinedDraft == text, chat.draftAttachments == attachments { includeProjectContext = true }
        }
    }

    /// Picks up turns taken on the desktop (or iMessage) while this chat is open.
    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled && !chat.isRunning && chat.sessionId != nil { await chat.load(quiet: true) }
        }
    }
}

/// A collapsed long paste, editable and removable before send.
struct PasteChip: View {
    @Binding var text: String
    let remove: () -> Void
    @State private var editing = false

    var body: some View {
        HStack(spacing: 0) {
            Button { editing = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard").font(.caption)
                    Text("Pasted text · \(text.count.formatted()) characters").font(.caption2).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit pasted text, \(text.count) characters")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(HMDesign.text2)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove pasted text, \(text.count) characters")
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $editing) {
            PasteEditSheet(text: $text) { remove() }
        }
    }
}

/// Edits one collapsed paste in place; the chip and the sendable draft stay bound to the same text.
struct PasteEditSheet: View {
    @Binding var text: String
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .hmCanvas()
                .navigationTitle("Pasted text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Remove", role: .destructive) { remove(); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear { focused = true }
    }
}

/// A native, growing text field that intercepts the standard paste gesture so an image on the
/// pasteboard becomes an attachment instead of being dropped, and long text still rides the
/// existing PasteSplit path. The pasteboard is never read on load — only inside `paste(_:)`.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var expanded: Bool
    var onPasteText: (String) -> Void
    var onPasteImage: (UIImage) -> Void
    var onPasteFile: (NSItemProvider, UTType) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.isEditable = true
        view.dataDetectorTypes = []
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.smartQuotesType = .yes
        view.smartDashesType = .yes
        view.smartInsertDeleteType = .yes
        view.keyboardDismissMode = .interactive
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onPasteText = onPasteText
        view.onPasteImage = onPasteImage
        view.onPasteFile = onPasteFile
        view.focusOnAppearance = expanded
        view.accessibilityLabel = placeholder
        view.placeholder = placeholder
        view.text = text
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        view.placeholder = placeholder
        view.onPasteText = onPasteText
        view.onPasteImage = onPasteImage
        view.onPasteFile = onPasteFile
        view.updatePlaceholder()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        if expanded, let height = proposal.height, height.isFinite { return CGSize(width: width, height: height) }
        let line = uiView.font?.lineHeight ?? 21
        // Five lines, then it scrolls: the transcript keeps the screen. Expand opens a full editor.
        let height = min(max(uiView.textHeight(forWidth: width), line), line * 5)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            let view = textView as? PasteTextView
            if textView.text != parent.text { parent.text = textView.text }
            view?.updatePlaceholder()
        }
    }
}

final class PasteTextView: UITextView {
    var onPasteText: ((String) -> Void)?
    var onPasteImage: ((UIImage) -> Void)?
    var onPasteFile: ((NSItemProvider, UTType) -> Void)?
    var focusOnAppearance = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if focusOnAppearance, window != nil {
            focusOnAppearance = false
            becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages || pastedFileType != nil { return isEditable }
        return super.canPerformAction(action, withSender: sender)
    }
    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder; updatePlaceholder() }
    }

    private let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        if HMTheme.isThermocline {
            textColor = UIColor(Thermocline.text)
            placeholderLabel.textColor = UIColor(Thermocline.text3)
        } else {
            placeholderLabel.textColor = .placeholderText
        }
        placeholderLabel.numberOfLines = 1
        addSubview(placeholderLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// Read the pasteboard only at the moment of an actual paste, never on load or appear.
    override func paste(_ sender: Any?) {
        // Spreadsheets, slides and Universal Clipboard often carry a picture of the copied text beside
        // the text itself. Text wins when both are present; an image-only pasteboard attaches the image.
        let board = UIPasteboard.general
        if !board.hasStrings, board.hasImages, let image = board.image {
            onPasteImage?(image)
            return
        }
        // A copied file (a PDF or document from Files) attaches as that file, like choosing it in Files.
        if !board.hasStrings, let type = pastedFileType,
           let provider = board.itemProviders.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) {
            onPasteFile?(provider, type)
            return
        }
        if let pasted = UIPasteboard.general.string, PasteSplit.collapse(pasted) {
            onPasteText?(pasted)
            if let selection = selectedTextRange, !selection.isEmpty { replace(selection, withText: "") }
            return
        }
        super.paste(sender)
    }

    /// The type of a copied file on the pasteboard. Reads only the type names, which never shows a paste prompt.
    private var pastedFileType: UTType? {
        let board = UIPasteboard.general
        guard !board.hasStrings, !board.hasImages else { return nil }
        return PastedFile.type(in: board.types)
    }

    func textHeight(forWidth width: CGFloat) -> CGFloat {
        let insets = textContainerInset
        let padding = textContainer.lineFragmentPadding
        let maxWidth = max(0, width - insets.left - insets.right - padding * 2)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font ?? .preferredFont(forTextStyle: .body)],
            context: nil)
        return ceil(rect.height) + insets.top + insets.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        let y = textContainerInset.top
        placeholderLabel.sizeToFit()
        placeholderLabel.frame.origin = CGPoint(x: x, y: y)
    }
}

struct MessageRow: View {
    @State private var toolsExpanded = false
    @State private var activityExpanded = false
    @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true
    let item: ChatItem
    var profile: String = ""
    var session: String?
    var pinned = false
    var highlighted = false
    /// Present only for stored user/assistant messages on a bridge that supports pins.
    var onPin: (() -> Void)?
    @State private var selecting = false

    /// Puts text in the composer: (text, replace). Quote prepends; Edit replaces the draft.
    var onCompose: ((String, Bool) -> Void)?
    /// The last reply of a finished turn shows a small row of actions under it, like T3.
    var showActions = false
    /// Set by the chat screen: lets a failed reply offer Try again / Try at reset.
    var chat: ChatModel? = nil
    /// Times show where the conversation pauses (or everywhere while the transcript is swiped left).
    var showTime = true
    @State private var showFull = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func toolLabel(_ item: ChatItem) -> String {
        let base = item.activities.isEmpty
            ? "\(item.tools.count) tool call\(item.tools.count == 1 ? "" : "s")"
            : ToolLanguage.summary(item.activities)
        guard let start = item.timestamp, let end = item.ended, end > start else { return base }
        let seconds = Int(end - start)
        guard seconds >= 1 else { return base }
        let span = seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" + (seconds % 60 >= 10 ? " \(seconds % 60)s" : "")
            : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        return "Worked \(span) · " + base
    }

    private func workLabel(_ text: String) -> String { kawaiiFaces ? text : KawaiiFilter.strip(text) }

    private func quoteSelection(_ words: String) {
        onCompose?(ReplyQuote.markdown(ReplyQuote.excerpt(words)) + "\n\n", false)
    }

    private var quoted: String {
        // Plain words, not Markdown syntax: the chip and the quote Hermes gets both read cleanly.
        let source = item.kind == .assistant ? MarkdownBlock.plainText(item.text) : (ReplyQuote.split(item.text).body)
        return ReplyQuote.markdown(ReplyQuote.excerpt(source)) + "\n\n"
    }

    @ViewBuilder private var messageMenu: some View {
        Button { Clipboard.copy(item.kind == .assistant ? MarkdownBlock.plainText(item.text) : item.text) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if item.kind == .assistant {
            Button { Clipboard.copy(item.text, what: "Copied as Markdown") } label: { Label("Copy as Markdown", systemImage: "text.badge.checkmark") }
        }
        Button { selecting = true } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
        if let onCompose {
            Button { onCompose(quoted, false) } label: { Label("Reply with Quote", systemImage: "text.quote") }
            if item.kind == .user {
                Button { onCompose(item.text, true) } label: { Label("Edit as New Message", systemImage: "square.and.pencil") }
            }
        }
        let blocks = MarkdownBlock.parse(item.text).compactMap { block -> String? in
            if case .code(_, let body, _, _) = block { return body } else { return nil }
        }
        if blocks.count == 1 {
            Button { Clipboard.copy(blocks[0], what: "Copied code") } label: { Label("Copy Code", systemImage: "chevron.left.forwardslash.chevron.right") }
        } else if blocks.count > 1 {
            Menu {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, body in
                    Button("Block \(index + 1): " + String(body.prefix(40))) { Clipboard.copy(body, what: "Copied code") }
                }
            } label: { Label("Copy Code", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        if let onPin {
            Button(action: onPin) { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
        }
        if let chat, chat.canBranch(from: item) {
            // A new chat with everything up to here; this one stays as it is.
            Button { Task { await chat.branch(from: item) } } label: {
                Label("Branch from Here", systemImage: "arrow.triangle.branch")
            }
        }
        ShareLink(item: item.text)
    }

    /// Long pastes fold to their first lines so one message never fills the screen.
    private var replySplit: (quote: String?, body: String) { ReplyQuote.split(item.text) }

    private func userBubble(_ words: String) -> some View {
        Text(words)
            .padding(.horizontal, HMDesign.gutter).padding(.vertical, HMDesign.medium)
            .foregroundStyle(HMDesign.bubbleText)
            .hmBubble(bubbleShape)
            .overlay(bubbleShape.strokeBorder(HMTheme.isThermocline ? Thermocline.text : HMDesign.accent,
                                              lineWidth: highlighted ? 2 : 0))
    }
    private var userIsLong: Bool { item.text.count > 700 || item.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 14 }
    private var userText: String {
        guard userIsLong, !showFull else { return item.text }
        let head = item.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n")
        return String(head.prefix(600)) + "…"
    }

    /// The outgoing bubble: Thermocline's 18 pt continuous corners; Classic keeps its 20 pt shape.
    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HMDesign.messageRadius, style: HMTheme.isThermocline ? .continuous : .circular)
    }

    private var pinMark: some View {
        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(HMDesign.accent)
            .rotationEffect(.degrees(45))
            .accessibilityLabel("Pinned")
    }

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if let note = item.contextNote {
                        Label(note, systemImage: "folder.badge.gearshape").font(.caption2).foregroundStyle(HMDesign.text2)
                    }
                    if !item.text.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            if pinned { pinMark }
                            VStack(alignment: .leading, spacing: 8) {

                                let segs = ReplyQuote.segments(item.text)
                                if segs.filter({ $0.quote != nil }).count > 1 && !userIsLong {
                                    // A reply to several messages: each quote card with its answer under it.
                                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                                        if let q = seg.quote { QuoteCard(text: q) }
                                        if !seg.body.isEmpty { userBubble(seg.body) }
                                    }
                                } else {
                                    if let q = replySplit.quote { QuoteCard(text: q) }
                                    userBubble(replySplit.quote == nil ? userText : replySplit.body)
                                }
                            }
                                .contextMenu { messageMenu }
                        }
                    }
                    if userIsLong {
                        Button(showFull ? "Show less" : "Show full message") { withAnimation(HMMotion.standard) { showFull.toggle() } }
                            .font(.caption.weight(.semibold)).foregroundStyle(HMDesign.text2)
                            .frame(minHeight: HMDesign.touch)
                    }
                    TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .trailing,
                                     previews: item.previews,
                                     upload: chat?.uploadingItem == item.id ? chat?.uploadFraction : nil)
                    let note = item.annotation.flatMap { $0.isEmpty ? nil : $0 }
                    if note != nil || (showTime && item.timestamp != nil) {
                        HStack(spacing: 4) {
                            if let note { Text(note) }
                            if note != nil, showTime, item.timestamp != nil { Text("·") }
                            if showTime, let ts = item.timestamp { Text(Date(timeIntervalSince1970: ts), style: .time) }
                        }
                        .hmTime(classic: HMDesign.text2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .assistant:
            // Replies run full width without a bubble (as in T3 and the desktop app): more of the
            // conversation fits on screen, and code blocks get the whole line.
            VStack(alignment: .leading, spacing: 6) {
                if ChatModel.isFailedTurn(item.text), let chat {
                    FailedTurnCard(chat: chat, itemID: item.id, text: item.text,
                                   isLatest: item.id == chat.items.last(where: { $0.kind == .assistant })?.id)
                } else {
                // Long-press selects text (like T3); the menu has Copy, Copy as Markdown and Reply with quote.
                // Images sit where Hermes put them in the reply when the bridge says where.
                if let parts = item.parts, !parts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            if let words = part.text {
                                MarkdownText(text: words, onQuote: quoteSelection)
                            } else if let i = part.media, item.media.indices.contains(i) {
                                TranscriptImages(refs: [item.media[i]], profile: profile, session: session, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(highlighted ? HMDesign.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) { if pinned { pinMark.offset(x: 2, y: -2) } }
                } else {
                    if !item.text.isEmpty {
                        MarkdownText(text: item.text, onQuote: quoteSelection)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(highlighted ? HMDesign.selectedFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) { if pinned { pinMark.offset(x: 2, y: -2) } }
                    }
                    TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .leading)
                }
                }
                if showActions || item.footer != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if showActions, !item.text.isEmpty {
                            HStack(spacing: HMDesign.micro) {
                                ActionIcon(symbol: "doc.on.doc", label: "Copy reply") { Clipboard.copy(MarkdownBlock.plainText(item.text)) }
                                if let onPin {
                                    ActionIcon(symbol: pinned ? "pin.slash" : "pin", label: pinned ? "Unpin" : "Pin", action: onPin)
                                }
                                if let onCompose {
                                    ActionIcon(symbol: "text.quote", label: "Reply with quote") { onCompose(quoted, false) }
                                }
                                ShareLink(item: item.text) {
                                    Image(systemName: "square.and.arrow.up").font(.footnote).hmTouchTarget()
                                }
                                .foregroundStyle(HMDesign.text2)
                                .accessibilityLabel("Share reply")
                                Spacer(minLength: 0)
                                if let ts = item.timestamp {
                                    Text(Date(timeIntervalSince1970: ts), style: .time).hmTime(classic: HMDesign.text3)
                                }
                            }
                        }
                        if let f = item.footer {
                            Label(f, systemImage: "cpu").font(HMTheme.isThermocline ? HMType.meta : .caption).foregroundStyle(HMDesign.text2)
                                .accessibilityLabel("Answered by \(f)")
                        }
                    }
                    .padding(.leading, HMDesign.micro)
                }
                if showTime, !(showActions && !item.text.isEmpty), let ts = item.timestamp {
                    Text(Date(timeIntervalSince1970: ts), style: .time)
                        .hmTime(classic: HMDesign.text3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .control:
            // Their words, not a gray system card. The tag says whether it was queued or used to guide the reply.
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    if !item.text.isEmpty {
                        Text(item.text).textSelection(.enabled)
                            .padding(.horizontal, HMDesign.gutter).padding(.vertical, HMDesign.medium)
                            .foregroundStyle(HMDesign.bubbleText)
                            .hmBubble(bubbleShape)
                    }
                    if !item.previews.isEmpty {
                        TranscriptImages(refs: [], profile: profile, session: session, alignment: .trailing,
                                         previews: item.previews)
                    }
                    // Where the message is: hollow while waiting, filled once Hermes has read it.
                    let stage = item.annotation ?? "sent"
                    HStack(spacing: 4) {
                        Image(systemName: stage == "read" ? "checkmark.circle.fill" : stage == "next" ? "arrow.down.circle" : "circle.dotted")
                            .foregroundStyle(stage == "read" ? HMDesign.success : Color.secondary)
                            .symbolEffect(.pulse, isActive: stage == "sent")
                        Text(item.footer ?? "Sent")
                        if let ts = item.timestamp { Text(Date(timeIntervalSince1970: ts), style: .time) }
                    }
                    .hmTime(classic: HMDesign.text2)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy, value: stage)
                }
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        case .tools:
            DisclosureGroup(isExpanded: $toolsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if item.activities.isEmpty {
                        ForEach(Array(item.tools.enumerated()), id: \.offset) { _, tool in
                            Text(workLabel(tool).replacingOccurrences(of: "_", with: " ")).font(.caption.monospaced())
                        }
                    } else {
                        ForEach(item.activities) { row in
                            let label = ToolLanguage.title(row, display: workLabel)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: row.state == "failed" ? "xmark.circle.fill" : ToolLanguage.icon(row.name))
                                    .font(.caption).frame(width: 16)
                                    .foregroundStyle(row.state == "failed" ? HMDesign.danger : HMDesign.text2)
                                    .symbolEffect(.pulse, isActive: row.state == "running" && !reduceMotion)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(label)
                                            .font(.caption)
                                            .foregroundStyle(row.state == "failed" ? HMDesign.dangerText : HMDesign.ink)
                                        Spacer(minLength: 4)
                                        ToolStamp(row: row)
                                    }
                                    if !row.result.isEmpty {
                                        Text(row.result).font(.caption2.monospaced()).foregroundStyle(HMDesign.text2).lineLimit(3)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(label + (row.state == "failed" ? ", failed" : row.state == "running" ? ", running" : ""))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(Self.toolLabel(item), systemImage: "wrench.and.screwdriver")
                    .font(HMTheme.isThermocline ? HMType.data : .subheadline)
            }
            .foregroundStyle(HMDesign.text2)
            .padding(.horizontal, 18)
        case .activity where !item.entries.isEmpty:
            ActivityCard(item: item, expanded: $activityExpanded)
                .padding(.horizontal, 12)
        case .activity:
            DisclosureGroup(isExpanded: $activityExpanded) {
                if !item.detail.isEmpty {
                    Text(workLabel(item.detail)).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label(workLabel(item.text), systemImage: item.failed ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    .font(.subheadline)
                    .labelStyle(HMTintedIconLabel(icon: item.failed ? HMDesign.danger : HMDesign.text2))
                    .foregroundStyle(item.failed ? HMDesign.dangerText : HMDesign.text2)
                    .strikethrough(item.failed, color: HMDesign.danger)
            }
            .padding(.horizontal, 18)
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(HMDesign.text2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(HMTheme.isThermocline ? HMDesign.card.opacity(0.7) : Color(.tertiarySystemFill).opacity(0.6), in: Capsule())
                .overlay { if HMTheme.isThermocline { Capsule().strokeBorder(Thermocline.line, lineWidth: 0.5) } }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
        }
    }
}

struct ApprovalSheet: View {
    let req: ApprovalRequest
    let busy: Bool
    let error: String?
    let answer: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(req.description) }.hmRows()
                if !req.command.isEmpty {
                    Section(header: HMHeader("Command")) { Text(req.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }.hmRows()
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle") }
                Section {
                    ForEach(req.choices, id: \.self) { c in
                        Button(role: c == "deny" ? .destructive : nil) { answer(c) } label: {
                            if HMTheme.isThermocline && c == "deny" {
                                Label(label(c), systemImage: "xmark.circle").hmProblem()
                            } else {
                                Text(label(c))
                            }
                        }
                    }
                }.hmRows()
            }
            .disabled(busy)
            .hmCanvas()
            .navigationTitle("Approve?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func label(_ c: String) -> String {
        switch c {
        case "once": "Allow once"
        case "session": "Allow for this chat"
        case "always": "Always allow"
        case "deny": "Deny"
        default: c.capitalized
        }
    }
}

private enum ToolLanguage {
    static func icon(_ name: String) -> String {
        switch name {
        case "terminal", "execute_code", "process_manage": "terminal"
        case "read_file", "list_files": "eye"
        case "search_files", "session_search", "tool_search": "magnifyingglass"
        case "web_search", "web_extract", "x_search": "globe"
        case "patch", "write_file", "skill_manage": "square.and.pencil"
        case "delegate_task": "person.2"
        case "skill_view", "skills_list": "book"
        case "memory": "brain"
        case "vision_analyze", "image_generate": "photo"
        case "clarify": "questionmark.bubble"
        case "cronjob", "cronjob_manage": "clock"
        default: name.hasPrefix("browser") ? "safari" : name.hasPrefix("mcp_") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func title(_ row: ToolActivity, display: (String) -> String) -> String {
        let preview = display(row.preview)
        switch row.name {
        case "skill_view": return preview.isEmpty ? "Loaded a skill" : "Loaded skill · \(preview)"
        case "skill_manage": return preview.isEmpty ? "Updated skills" : "Skills · \(preview)"
        case "terminal", "execute_code": return preview.isEmpty ? "Ran a command" : "Ran · \(preview)"
        case "read_file", "search_files", "list_files": return preview.isEmpty ? "Explored files" : "Explored · \(preview)"
        case "web_search", "web_extract": return preview.isEmpty ? "Searched" : "Searched · \(preview)"
        case "delegate_task": return preview.isEmpty ? "Delegated a task" : "Delegated · \(preview)"
        case "tool_search": return "Looked up tools"
        default:
            let spoken = display(row.name).replacingOccurrences(of: "_", with: " ")
            return preview.isEmpty ? spoken : "\(spoken) · \(preview)"
        }
    }

    /// One line: the two biggest kinds of work, then how many other steps. The full list is one tap away.
    static func summary(_ rows: [ToolActivity]) -> String {
        var counts: [(String, String, Int)] = []  // (singular, plural, n)
        func add(_ one: String, _ many: String, _ n: Int) { if n > 0 { counts.append((one, many, n)) } }
        let names = rows.map(\.name)
        func n(_ set: Set<String>) -> Int { names.filter(set.contains).count }
        add("command", "commands", n(["terminal", "execute_code"]))
        add("file read", "files read", n(["read_file", "search_files", "list_files"]))
        add("edit", "edits", n(["patch", "write_file"]))
        add("search", "searches", n(["web_search", "web_extract", "x_search"]))
        add("subagent", "subagents", n(["delegate_task"]))
        add("skill", "skills", n(["skill_view"]))
        add("skill edit", "skill edits", n(["skill_manage"]))
        let shown = counts.sorted { $0.2 > $1.2 }.prefix(2)
        var parts = shown.map { "\($0.2) \($0.2 == 1 ? $0.0 : $0.1)" }
        let rest = rows.count - shown.reduce(0) { $0 + $1.2 }
        if rest > 0 { parts.append(parts.isEmpty ? (rest == 1 ? "1 step" : "\(rest) steps") : "\(rest) more") }
        var text = parts.joined(separator: " · ")
        let failed = rows.filter { $0.state == "failed" }.count
        if failed > 0 { text += " · \(failed) failed" }
        if rows.contains(where: { $0.state == "running" }) { text += " · working" }
        return text
    }
}

private struct SlashMenu: View {
    let commands: [SlashCommand]
    let skills: [SkillInfo]
    let filter: String
    let pick: (String) -> Void

    var body: some View {
        // Every match, not the first eight: the list scrolls. (A cap hid /learn behind the alphabet.)
        let shown = commands.filter { filter.isEmpty || $0.name.hasPrefix(filter) }
        // Hundreds of skills: ranked by name, then category and description, so "/pentest" finds them by
        // purpose. A bare "/" shows a handful; typing narrows it. The ⌘ sheet browses them all.
        let skillHits = filter.isEmpty ? [] : Array(SkillInfo.search(skills, filter).prefix(60))
        if !shown.isEmpty || !skillHits.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown)) { cmd in
                        Button { pick(cmd.name) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/" + cmd.name).font(.subheadline.weight(.semibold))
                                Text(cmd.hint.isEmpty ? cmd.description : "\(cmd.description) \(cmd.hint)")
                                    .font(.caption).foregroundStyle(HMDesign.text2).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                    if !skillHits.isEmpty {
                        Text("Skills").font(.caption.weight(.semibold)).foregroundStyle(HMDesign.text2)
                            .padding(.horizontal, 12).padding(.top, 4)
                        ForEach(skillHits) { skill in
                            Button { pick(skill.name) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("/" + skill.name).font(.subheadline)
                                    if !skill.description.isEmpty {
                                        Text(skill.description).font(.caption2).foregroundStyle(HMDesign.text2).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            .modifier(SlashMenuSurface())
            .padding(.horizontal, 12)
        }
    }
}

/// The slash menu floats over the transcript: glass in Thermocline, material in Classic.
private struct SlashMenuSurface: ViewModifier {
    func body(content: Content) -> some View {
        if HMTheme.isThermocline {
            content.hmGlass(RoundedRectangle(cornerRadius: Thermocline.Radius.md, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct TranscriptImages: View {
    let refs: [ChatMediaRef]
    let profile: String
    let session: String?
    var alignment: HorizontalAlignment = .leading
    /// The phone's own copies of these photos (`SentPreviews`): shown while sending, and wherever the Mac's
    /// copy can't be loaded. Matched to the Mac's images by position, like T3, only when the counts agree.
    var previews: [URL] = []
    /// Upload progress over the photos while this message is still going up (0...1).
    var upload: Double? = nil
    @State private var preview: UIImage?

    private var images: [ChatMediaRef] { session == nil ? [] : refs.filter { $0.kind == "image" } }
    private var files: [ChatMediaRef] { session == nil ? [] : refs.filter { $0.kind != "image" } }
    /// Mac images when there are any; otherwise the phone's copies.
    private var tiles: [Tile] {
        if !images.isEmpty {
            let paired = previews.count == images.count
            return images.enumerated().map { n, ref in .remote(ref, fallback: paired ? previews[n] : nil) }
        }
        return previews.map { .local($0) }
    }

    enum Tile: Hashable {
        case remote(ChatMediaRef, fallback: URL?)
        case local(URL)
        var id: String {
            switch self {
            case .remote(let ref, _): ref.digest
            case .local(let url): url.lastPathComponent
            }
        }
    }

    var body: some View {
        if !tiles.isEmpty || !files.isEmpty {
            VStack(alignment: alignment, spacing: 6) {
                if tiles.count >= 2 {
                    // Several images in one message: one even-height row you swipe through, in the order sent.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tiles, id: \.id) { tile in view(tile, height: 150) }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
                    .frame(height: 150)
                    .overlay(alignment: alignment == .trailing ? .bottomLeading : .bottomTrailing) {
                        Text(upload == nil ? "\(tiles.count) photos" : "\(tiles.count) photos · uploading")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule()).padding(6)
                    }
                    .overlay { uploadVeil }
                } else {
                    ForEach(tiles, id: \.id) { tile in view(tile, height: nil) }
                        .overlay { uploadVeil }
                }
                ForEach(files, id: \.digest) { ref in
                    TranscriptFile(ref: ref, profile: profile, session: session ?? "")
                }
            }
            .animation(HMMotion.standard, value: upload == nil)
            .fullScreenCover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview { FullImagePreview(image: preview) }
            }
        }
    }

    @ViewBuilder private func view(_ tile: Tile, height: CGFloat?) -> some View {
        switch tile {
        case .remote(let ref, let fallback):
            TranscriptImage(profile: profile, session: session ?? "", digest: ref.digest, name: ref.name,
                            tileHeight: height, fallback: fallback) { preview = $0 }
        case .local(let url):
            LocalPhoto(url: url, tileHeight: height) { preview = $0 }
        }
    }

    /// While uploading: the photos dim slightly under one percentage, like T3's tray.
    @ViewBuilder private var uploadVeil: some View {
        if let upload {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.28))
                Text("\(Int(upload * 100))%").font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityLabel("Uploading, \(Int(upload * 100)) percent")
        }
    }
}

/// A photo from this phone's own copies (a message you sent).
private struct LocalPhoto: View {
    let url: URL
    var tileHeight: CGFloat? = nil
    let open: (UIImage) -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { PhotoTile(image: image, name: url.lastPathComponent, tileHeight: tileHeight, open: open) }
            else { RoundedRectangle(cornerRadius: 12).fill(HMDesign.card).frame(width: 110, height: tileHeight ?? 110) }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            image = loaded
        }
    }
}

/// One image in a message: tap to open full screen. Never blown up past its real size.
private struct PhotoTile: View {
    let image: UIImage
    let name: String
    var tileHeight: CGFloat? = nil
    let open: (UIImage) -> Void

    var body: some View {
        Button { open(image) } label: {
            if let h = tileHeight {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: min(240, max(90, h * image.size.width / max(image.size.height, 1))), height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: min(240, image.size.width), maxHeight: min(220, image.size.height))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

private struct TranscriptImage: View {
    let profile: String
    let session: String
    let digest: String
    let name: String
    /// Set inside a multi-image row: every tile the same height, width from the image's shape.
    var tileHeight: CGFloat? = nil
    /// The phone's own copy: shown while the Mac's loads and in its place if that fails (expired on the Mac).
    var fallback: URL? = nil
    let open: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var local: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Button { open(image) } label: {
                    if let h = tileHeight {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: min(240, max(90, h * image.size.width / max(image.size.height, 1))), height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        // Never blown up past its real size: a small image stays small.
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: min(240, image.size.width), maxHeight: min(220, image.size.height))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            } else if let local {
                PhotoTile(image: local, name: name, tileHeight: tileHeight, open: open)
            } else if failed {
                Label(name, systemImage: "photo").font(.caption).foregroundStyle(HMDesign.text2)
            } else {
                ProgressView().frame(width: 44, height: 44)
            }
        }
        .task {
            if let fallback, local == nil {
                local = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: fallback.path) }.value
            }
            guard image == nil, !failed else { return }
            do {
                let data = try await API.shared.chatMedia(profile: profile, session: session, digest: digest)
                if let decoded = UIImage(data: data) { image = decoded } else { failed = true }
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Pinned messages

/// The strip under the title, like Telegram's pinned bar: one pin at a time, newest first. Tapping it jumps
/// to that message and advances to the next older pin; the list button opens every pin.
struct PinnedBar: View {
    let pins: [MessagePin]
    let cursor: Int
    let jump: () -> Void
    let list: () -> Void

    var body: some View {
        let pin = pins[max(0, min(cursor, pins.count - 1))]
        HStack(spacing: 10) {
            Button(action: jump) {
                HStack(spacing: 10) {
                    PinTicks(count: pins.count, current: cursor)
                    VStack(alignment: .leading, spacing: 1) {
                        if HMTheme.isThermocline {
                            Text(pins.count == 1 ? "Pinned" : "Pinned · \(cursor + 1) of \(pins.count)")
                                .hmLabel(HMDesign.accent)
                        } else {
                            Text(pins.count == 1 ? "Pinned message" : "Pinned message \(cursor + 1) of \(pins.count)")
                                .font(.caption.weight(.semibold)).foregroundStyle(HMDesign.accent)
                        }
                        Text(pin.excerpt).font(.footnote).lineLimit(1).foregroundStyle(HMDesign.ink)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: HMDesign.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pinned message \(cursor + 1) of \(pins.count): \(pin.excerpt)")
            .accessibilityHint("Jumps to it, then shows the next pin")
            Button(action: list) {
                Image(systemName: "list.bullet").hmTouchTarget()
            }
            .accessibilityLabel("All pinned messages")
        }
        .padding(.leading, 14).padding(.vertical, 6)
        .hmBar(.bottom)
    }
}

/// The thin vertical ticks on the bar's left edge, one per pin (capped), highlighting the one shown.
private struct PinTicks: View {
    let count: Int
    let current: Int

    var body: some View {
        let shown = min(count, 4)
        let window = max(0, min(current - shown + 1, count - shown))
        VStack(spacing: 2) {
            ForEach(0..<shown, id: \.self) { slot in
                Capsule()
                    .fill(window + slot == current ? HMDesign.accent : HMDesign.accent.opacity(0.3))
                    .frame(width: 2.5)
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

/// Every pin in this chat. Tap to jump, swipe to unpin. "Unpin all" asks twice.
struct PinsSheet: View {
    @Bindable var chat: ChatModel
    let jump: (MessagePin) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var confirmClearAgain = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chat.pins) { pin in
                        Button { jump(pin) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: pin.isMine ? "person.fill" : "sparkles").font(.caption2)
                                    Text(pin.isMine ? "You" : "Hermes").font(.caption.weight(.semibold))
                                    Spacer()
                                    if let at = pin.messageAt {
                                        Text(Date(timeIntervalSince1970: at), format: .dateTime.month(.abbreviated).day().hour().minute())
                                            .font(.caption2)
                                    }
                                }
                                .foregroundStyle(HMDesign.text2)
                                Text(pin.text).font(.subheadline).lineLimit(6).foregroundStyle(HMDesign.ink)
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = pin.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { Task { await chat.unpin(pin) } } label: { Label("Unpin", systemImage: "pin.slash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await chat.unpin(pin) } } label: { Label("Unpin", systemImage: "pin.slash") }
                        }
                    }
                } footer: {
                    Text("Pins live on your Mac, so every device signed in to it sees them. A chat with pins asks before it is archived, and archiving keeps the pins.")
                }.hmRows()
            }
            .overlay { if chat.pins.isEmpty { ContentUnavailableView("No pinned messages", systemImage: "pin", description: Text("Touch and hold a message, then choose Pin.")) } }
            .hmCanvas()
            .navigationTitle(chat.pins.isEmpty ? "Pinned" : "Pinned · \(chat.pins.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if chat.pins.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Unpin all", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Unpin all \(chat.pins.count) messages?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Unpin all \(chat.pins.count)", role: .destructive) { confirmClearAgain = true }
            } message: { Text("The messages stay in the chat; only the pins go.") }
            .alert("Are you sure?", isPresented: $confirmClearAgain) {
                Button("Unpin \(chat.pins.count) messages", role: .destructive) { Task { await chat.unpinAll() } }
                Button("Keep pins", role: .cancel) {}
            } message: { Text("This can't be undone. You would have to pin each message again.") }
            .task { await chat.loadPins() }
        }
        .presentationDetents([.medium, .large])
    }
}


// MARK: - Background work cards

/// Background commands and subagent tasks, readable at a glance: what ran, where, how it ended and how long it
/// took. Open it for the exact command and the tail of its output, each with Copy.
struct ActivityCard: View {
    let item: ChatItem
    @Binding var expanded: Bool
    @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true

    private func workLabel(_ text: String) -> String { kawaiiFaces ? text : KawaiiFilter.strip(text) }

    private var worst: String {
        if item.entries.contains(where: \.failed) { return "failed" }
        if item.entries.contains(where: { $0.status == "stopped" || $0.status == "warning" }) { return "stopped" }
        return "ok"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(HMMotion.standard) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusGlyph(status: worst)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workLabel(item.text)).font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.ink)
                            .multilineTextAlignment(.leading).lineLimit(expanded ? nil : 2)
                        if let ts = item.timestamp {
                            Text(Date(timeIntervalSince1970: ts), style: .time).hmTime(classic: HMDesign.text2)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HMDesign.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details" : "Shows each command and its output")

            if item.entries.count > 1 || expanded {
                VStack(alignment: .leading, spacing: expanded ? 12 : 5) {
                    ForEach(Array(item.entries.enumerated()), id: \.offset) { _, entry in
                        EntryRow(entry: entry, expanded: expanded)
                    }
                }
                .padding(.leading, 26)
            } else if let entry = item.entries.first, !entry.meta.isEmpty {
                Text(workLabel(entry.meta)).font(.caption).foregroundStyle(HMDesign.text2).padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hmPanel(radius: 14)
        .overlay(RoundedRectangle(cornerRadius: HMTheme.isThermocline ? Thermocline.Radius.md : 14, style: .continuous)
            .strokeBorder(worst == "failed" ? HMDesign.danger.opacity(HMTheme.isThermocline ? 0.5 : 0.35)
                          : HMTheme.isThermocline ? .clear : HMDesign.separator.opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private struct EntryRow: View {
        let entry: ActivityEntry
        let expanded: Bool
        @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true

        private func workLabel(_ text: String) -> String { kawaiiFaces ? text : KawaiiFilter.strip(text) }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusGlyph(status: entry.status, small: true)
                    Image(systemName: entry.isProcess ? "terminal" : "person.2").font(.caption2).foregroundStyle(HMDesign.text2)
                    Text(workLabel(entry.label))
                        .font(entry.isProcess ? .footnote.monospaced() : .footnote)
                        .lineLimit(expanded ? 4 : 1)
                    Spacer(minLength: 4)
                    if !expanded, !entry.meta.isEmpty {
                        Text(workLabel(entry.meta)).font(.caption2).foregroundStyle(entry.failed ? HMDesign.dangerText : HMDesign.text2).lineLimit(1)
                    }
                }
                if expanded {
                    if !entry.meta.isEmpty { Text(workLabel(entry.meta)).font(.caption).foregroundStyle(entry.failed ? HMDesign.dangerText : HMDesign.text2) }
                    if let command = entry.command, !command.isEmpty {
                        CodeBlockView(language: "shell", code: command, foldAfter: 8, title: "command")
                    }
                    if let output = entry.output, !output.isEmpty {
                        CodeBlockView(language: "", code: output, foldAfter: 12,
                                      title: entry.isProcess ? "output (last lines)" : "result")
                    }
                }
            }
        }
    }
}

private struct StatusGlyph: View {
    let status: String
    var small = false

    var body: some View {
        let (name, color): (String, Color) = switch status {
        case "ok": ("checkmark.circle.fill", HMDesign.success)
        case "failed": ("xmark.octagon.fill", HMDesign.danger)
        case "stopped", "warning": ("stop.circle.fill", HMDesign.caution)
        default: ("clock.fill", .secondary)
        }
        Image(systemName: name).foregroundStyle(color).font(small ? .caption : .subheadline)
            .accessibilityLabel(status == "ok" ? "Succeeded" : status == "failed" ? "Failed" : "Stopped")
    }
}

// MARK: - Files in replies

/// A file Hermes handed over in a reply (MEDIA:/path). Tap to download it and open it in Quick Look, where it
/// can be read, played, viewed in 3D or AR (USDZ), shared or saved to Files.
struct TranscriptFile: View {
    let ref: ChatMediaRef
    let profile: String
    let session: String
    @State private var loading = false
    @State private var preview: URL?
    @State private var failed: String?

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(for: ref.name))
                    .font(.title3).foregroundStyle(HMDesign.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(failed ?? Self.kind(for: ref.name)).font(.caption2)
                        .foregroundStyle(failed == nil ? HMDesign.text2 : HMDesign.dangerText).lineLimit(1)
                }
                Spacer(minLength: 6)
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.down.circle").foregroundStyle(HMDesign.text2) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: 300, alignment: .leading)
            .hmPanel(radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .quickLookPreview($preview)
        .accessibilityLabel("File \(ref.name)")
        .accessibilityHint("Opens it in Quick Look")
    }

    private func open() async {
        loading = true
        failed = nil
        defer { loading = false }
        do {
            let data = try await API.shared.chatMedia(profile: profile, session: session, digest: ref.digest)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-files", isDirectory: true)
                .appendingPathComponent(String(ref.digest.prefix(16)), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = ref.name.replacingOccurrences(of: "/", with: "_")
            let url = folder.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            preview = url
        } catch {
            failed = "Couldn't open: " + error.localizedDescription
        }
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "md", "txt", "rtf", "log": "doc.text"
        case "csv", "tsv", "xlsx", "numbers": "tablecells"
        case "json", "yaml", "yml", "toml", "xml", "py", "js", "ts", "tsx", "swift", "sh", "rb", "go", "rs", "c", "h",
             "cpp", "java", "kt", "sql", "ipynb", "html", "htm": "chevron.left.forwardslash.chevron.right"
        case "zip": "doc.zipper"
        case "mp3", "m4a", "wav", "aac": "waveform"
        case "mp4", "mov", "m4v": "film"
        case "stl", "3mf", "obj", "usdz", "step", "stp": "cube"
        case "docx", "pages": "doc.text.fill"
        case "pptx", "keynote": "rectangle.on.rectangle"
        case "svg": "photo"
        default: "doc"
        }
    }

    static func kind(for name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File · tap to open" : "\(ext) · tap to open"
    }
}

// MARK: - Commands

/// Every slash command and skill this bot offers, searchable. Tapping one puts it in the composer.
/// A prompt kept for one-tap reuse. `sendNow` sends it as is; otherwise it lands in the composer to edit.
struct SavedPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var sendNow: Bool

    static let key = "hm.savedPrompts"
    static let starters = [
        SavedPrompt(title: "Status", text: "Where are you on this? One short paragraph, then what's next.", sendNow: true),
        SavedPrompt(title: "Continue", text: "Continue.", sendNow: true),
        SavedPrompt(title: "Summarize", text: "Summarize this chat so far: decisions, open questions, next steps.", sendNow: true),
        SavedPrompt(title: "Explain simply", text: "Explain that again simply, like I'm new to it.", sendNow: false),
    ]
    static func load() -> [SavedPrompt] {
        guard let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([SavedPrompt].self, from: data)
        else { return starters }
        return list
    }
    static func save(_ list: [SavedPrompt]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct CommandsSheet: View {
    enum Side: String, CaseIterable { case saved = "Saved", commands = "Commands", skills = "Skills" }

    let commands: [SlashCommand]
    let skills: [SkillInfo]
    let pick: (String) -> Void
    /// (text, send now)
    var usePrompt: ((String, Bool) -> Void)? = nil
    @State private var prompts = SavedPrompt.load()
    @State private var editing: SavedPrompt?
    var start: Side = .commands
    @State private var side: Side = .commands
    @State private var query = ""
    @State private var category: String?
    @AppStorage("hm.recentSkills") private var recentRaw = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { query.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    private var grouped: [(String, [SlashCommand])] {
        let q = trimmed.lowercased()
        let hits = commands.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        var order: [String] = []
        var buckets: [String: [SlashCommand]] = [:]
        for command in hits {
            let key = command.category.isEmpty ? "Commands" : command.category
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(command)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var recent: [SkillInfo] {
        let names = recentRaw.split(separator: ",").map(String.init)
        return names.compactMap { name in skills.first { $0.name == name } }
    }

    private var categories: [(String, Int)] {
        var counts: [String: Int] = [:]
        for skill in skills { counts[skill.category.isEmpty ? "General" : skill.category, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var skillHits: [SkillInfo] {
        var pool = skills
        if let category { pool = pool.filter { ($0.category.isEmpty ? "General" : $0.category) == category } }
        return SkillInfo.search(pool, trimmed)
    }

    private func choose(_ name: String, skill: Bool) {
        if skill {
            var names = recentRaw.split(separator: ",").map(String.init).filter { $0 != name }
            names.insert(name, at: 0)
            recentRaw = names.prefix(8).joined(separator: ",")
        }
        pick(name)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                if side == .saved {
                    Section {
                        ForEach(prompts.filter { trimmed.isEmpty || ($0.title + " " + $0.text).localizedCaseInsensitiveContains(trimmed) }) { prompt in
                            Button {
                                usePrompt?(prompt.text, prompt.sendNow)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: prompt.sendNow ? "paperplane.fill" : "square.and.pencil")
                                        .foregroundStyle(HMDesign.accent).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(prompt.title).font(.body.weight(.semibold))
                                        Text(prompt.text).font(.caption).foregroundStyle(HMDesign.text2).lineLimit(2)
                                    }
                                }
                            }
                            .foregroundStyle(HMDesign.ink)
                            .swipeActions {
                                Button(role: .destructive) { prompts.removeAll { $0.id == prompt.id }; SavedPrompt.save(prompts) } label: { Label("Delete", systemImage: "trash") }
                                Button { editing = prompt } label: { Label("Edit", systemImage: "pencil") }.tint(HMDesign.accent)
                            }
                        }
                        .onMove { from, to in prompts.move(fromOffsets: from, toOffset: to); SavedPrompt.save(prompts) }
                        Button { editing = SavedPrompt(title: "", text: "", sendNow: true) } label: { Label("New saved prompt", systemImage: "plus") }
                    } footer: {
                        Text("A paper plane sends right away. A pencil puts the text in the message box to edit first. Swipe to edit or delete.")
                    }.hmRows()
                } else if side == .commands {
                    ForEach(grouped, id: \.0) { group, rows in
                        Section(header: HMHeader(group)) {
                            ForEach(rows) { command in
                                Button { choose(command.name, skill: false) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("/" + command.name).font(.body.monospaced().weight(.semibold))
                                            if !command.hint.isEmpty {
                                                Text(command.hint).font(.caption.monospaced()).foregroundStyle(HMDesign.text2)
                                            }
                                        }
                                        Text(command.description).font(.caption).foregroundStyle(HMDesign.text2)
                                    }
                                }
                                .foregroundStyle(HMDesign.ink)
                            }
                        }.hmRows()
                    }
                } else {
                    if trimmed.isEmpty, category == nil, !recent.isEmpty {
                        Section(header: HMHeader("Recent")) { ForEach(recent) { skillRow($0) } }.hmRows()
                    }
                    if trimmed.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    chip("All", count: skills.count, on: category == nil) { category = nil }
                                    ForEach(categories, id: \.0) { name, count in
                                        chip(name, count: count, on: category == name) { category = category == name ? nil : name }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }.hmRows()
                    }
                    Section(header: HMHeader(category.map { "\($0) · \(skillHits.count)" } ?? "\(skillHits.count) skills")) {
                        ForEach(skillHits) { skillRow($0) }
                    }.hmRows()
                }
            }
            .sheet(item: $editing) { prompt in
                SavedPromptEditor(prompt: prompt) { saved in
                    if let i = prompts.firstIndex(where: { $0.id == saved.id }) { prompts[i] = saved } else { prompts.append(saved) }
                    SavedPrompt.save(prompts)
                }
            }
            .overlay {
                if (side == .commands && grouped.isEmpty) || (side == .skills && skillHits.isEmpty) {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: side == .saved ? "Find a saved prompt" : side == .commands ? "Find a command" : "Search \(skills.count) skills by name or purpose")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $side) {
                        Text("Saved").tag(Side.saved)
                        Text("Commands").tag(Side.commands)
                        Text("Skills · \(skills.count)").tag(Side.skills)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: side) { _, _ in category = nil }
            .onAppear { side = start }
            .sensoryFeedback(.selection, trigger: side)
        }
        .presentationDetents([.medium, .large])
    }

    private func skillRow(_ skill: SkillInfo) -> some View {
        Button { choose(skill.name, skill: true) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/" + skill.name).font(.callout.monospaced().weight(.medium))
                    if !skill.category.isEmpty, category == nil {
                        if HMTheme.isThermocline {
                            HMTag(text: skill.category)
                        } else {
                            Text(skill.category).font(.caption2).foregroundStyle(HMDesign.text2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.caption).foregroundStyle(HMDesign.text2).lineLimit(2)
                }
            }
        }
        .foregroundStyle(HMDesign.ink)
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if HMTheme.isThermocline {
                Text("\(title) \(count)").font(.caption.weight(on ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .hmChip(active: on)
            } else {
                Text("\(title) \(count)").font(.caption.weight(on ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? HMDesign.accent.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(on ? HMDesign.accent : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The small "Copied" pill that confirms any copy in the chat.
struct SavedPromptEditor: View {
    @State var prompt: SavedPrompt
    let save: (SavedPrompt) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $prompt.title)
                TextField("What to send", text: $prompt.text, axis: .vertical).lineLimit(3...10)
                Toggle("Send right away", isOn: $prompt.sendNow)
            }
            .hmCanvas()
            .navigationTitle(prompt.title.isEmpty ? "Saved prompt" : prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = prompt
                        if p.title.trimmingCharacters(in: .whitespaces).isEmpty { p.title = String(p.text.prefix(24)) }
                        save(p); dismiss()
                    }
                    .disabled(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct CopiedToast: View {
    let text: String

    var body: some View {
        if HMTheme.isThermocline {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .labelStyle(HMTintedIconLabel(icon: Thermocline.success))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .hmGlass(Capsule())
                .transition(.offset(y: -8).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        } else {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(HMDesign.separator.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}


/// "Today", "Yesterday", "Monday" or "Nov 3": where a new day starts in the transcript.
struct DaySeparator: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(HMDesign.separator).frame(height: 0.5)
            if HMTheme.isThermocline {
                Text(label).hmLabel().fixedSize()
            } else {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(HMDesign.text2).fixedSize()
            }
            Rectangle().fill(HMDesign.separator).frame(height: 0.5)
        }
        .padding(.horizontal, 24).padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small icon button for the row under a reply.
struct ActionIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote).hmTouchTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(HMDesign.text2)
        .accessibilityLabel(label)
    }
}

private struct MediaInputsModifier: ViewModifier {
    let host: ChatScreen
    func body(content: Content) -> some View { host.mediaInputs(content) }
}

// MARK: - Outbox tray

/// Messages written while Hermes was busy or the connection was down. Each says plainly where it is.
/// Tap to edit; touch and hold for the rest. Nothing here is ever lost: it is on disk until it starts.
struct OutboxTray: View {
    @Bindable var chat: ChatModel
    @State private var editing: Outgoing?

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(chat.outgoing.enumerated()), id: \.element.id) { index, item in
                    row(item, position: index)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: chat.outgoing.count > 2 ? 150 : nil)
        .fixedSize(horizontal: false, vertical: chat.outgoing.count <= 2)
        .padding(.horizontal, 12)
        .sheet(item: $editing) { item in
            OutgoingEditor(item: item) { text in Task { await chat.editOutgoing(item.id, text: text) } }
        }
        .animation(HMMotion.large, value: chat.outgoing)
    }

    private func status(_ item: Outgoing, position: Int) -> (String, String, Color) {
        switch item.phase {
        case .needsYou(let problem):
            return ("exclamationmark.triangle.fill", "Didn't send: \(problem). Tap to edit.", HMDesign.warningText)
        case .editPending:
            return ("pencil.circle", "Edit saved · applies as soon as your Mac answers", .secondary)
        case .onMac:
            let ahead = chat.outgoing.prefix(position).filter(\.onMac).count
            return ("checkmark.circle.fill", ahead == 0 ? "On your Mac · next up" : "On your Mac · #\(ahead + 1) in line", HMDesign.success)
        case .retrying:
            return ("icloud.and.arrow.up", "Saved on this phone · sends when your Mac answers", .secondary)
        case .onPhone:
            if item.mode == "steer" { return ("arrow.turn.up.right", "Will guide this reply", HMDesign.accent) }
            return ("clock.arrow.circlepath", chat.isRunning ? "Sends after this reply" : "Sending…", HMDesign.accent)
        }
    }

    @ViewBuilder private func row(_ item: Outgoing, position: Int) -> some View {
        let (icon, caption, tint) = status(item, position: position)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.edit ?? item.label).font(.subheadline).lineLimit(2)
                Text(caption).font(.caption).foregroundStyle(item.problem == nil ? HMDesign.text2 : tint)
                if let note = item.note { Text(note).font(.caption2).foregroundStyle(HMDesign.text2) }
            }
            Spacer(minLength: 0)
            if item.files > 0 {
                Label("\(item.files)", systemImage: "paperclip").font(.caption2).foregroundStyle(HMDesign.text2).labelStyle(.titleAndIcon)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if canEdit(item) { editing = item } }
        .contextMenu {
            if canEdit(item) { Button { editing = item } label: { Label("Edit", systemImage: "pencil") } }
            if item.mode == "queue", chat.isRunning, item.problem == nil {
                Button { Task { await chat.guideNow(item.id) } } label: { Label("Guide this reply now", systemImage: "arrow.turn.up.right") }
            }
            Button { Task { await chat.removeOutgoing(item.id, toComposer: true) } } label: {
                Label("Move back to message box", systemImage: "arrow.uturn.down")
            }
            Button(role: .destructive) { Task { await chat.removeOutgoing(item.id, toComposer: false) } } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(canEdit(item) ? "Double-tap to edit. Touch and hold for more." : "Touch and hold for more.")
    }

    /// A steer that may already have reached the running reply can't be taken back, so it can't be edited.
    private func canEdit(_ item: Outgoing) -> Bool {
        !(item.mode == "steer" && item.attempts > 0 && item.problem == nil) && chat.allows(.edit, item)
    }
}

/// Hermes restarted while answering, cut that reply off, and holds the queue until someone says go.
struct QueuePausedBanner: View {
    @Bindable var chat: ChatModel
    @State private var working = false

    var body: some View {
        let waiting = chat.queue?.rows.filter { $0.status == "queued" }.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Label("Hermes restarted mid-reply", systemImage: "arrow.clockwise.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.warningText)
            Text("The reply to “\(String((chat.queue?.lost?.text ?? "your message").prefix(80)))” was cut off. "
                 + "\(waiting) message\(waiting == 1 ? " is" : "s are") waiting behind it.")
                .font(.caption).foregroundStyle(HMDesign.text2)
            HStack {
                Button { working = true; Task { await chat.continueQueue(); working = false } } label: {
                    Text(working ? "Continuing…" : "Continue").font(.subheadline.weight(.semibold))
                }
                .hmProminent().disabled(working)
                if let lost = chat.queue?.lost?.text, !lost.isEmpty {
                    Button("Copy cut-off message") { Clipboard.copy(lost, what: "Copied") }.font(.subheadline)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((HMTheme.isThermocline ? HMDesign.caution : HMDesign.warning).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }
}

struct OutgoingEditor: View {
    let item: Outgoing
    let save: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $text, axis: .vertical).lineLimit(3...14)
                } footer: {
                    Text(item.onMac
                         ? "Your Mac swaps in the edit if Hermes hasn't started it yet. It keeps its place after the current reply."
                         : "It hasn't left this phone yet, so the edit is instant.")
                }.hmRows()
            }
            .hmCanvas()
            .navigationTitle(item.mode == "steer" ? "Edit guidance" : "Edit queued message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = item.edit ?? item.text }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Hermes asked something mid-reply (1 to 5 questions at once). Like T3's input panel: every question in one
/// scrolling card, each choice as a tappable card (title, then its explanation), "+" for your own answer, one
/// Submit for all. Collapsible, so you can read the reply above it first. Typing in the message box answers too.
struct QuestionPanel: View {
    @Bindable var chat: ChatModel
    /// Off only for snapshot renders (ImageRenderer draws no ScrollView content).
    var scrolls = true
    @State private var picks: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var writing: Set<String> = []
    @State private var collapsed = false

    private var answers: [String: String] {
        var out: [String: String] = [:]
        for q in chat.questions {
            let own = custom[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if writing.contains(q.id), !own.isEmpty { out[q.id] = own; continue }
            let chosen = q.choices.filter { picks[q.id]?.contains($0) == true }
            if !chosen.isEmpty { out[q.id] = chosen.map { ClarifyChoice($0).title }.joined(separator: ", ") }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("INPUT NEEDED").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(HMDesign.accent)
                        Text(chat.questions.count == 1 ? "Hermes has a question" : "Fill in \(chat.questions.count) answers")
                            .font(.headline).foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? 180 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                let list = VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(chat.questions.enumerated()), id: \.element.id) { index, q in
                        questionView(q, number: chat.questions.count > 1 ? index + 1 : nil)
                    }
                }
                if scrolls {
                    ScrollView { list }.frame(maxHeight: 360).scrollBounceBehavior(.basedOnSize)
                } else { list }
                Button {
                    let now = answers
                    Task { if await chat.answer(now) { picks = [:]; custom = [:]; writing = [] } }
                } label: {
                    Text(chat.answering ? "Sending…" : answers.count < chat.questions.count && chat.questions.count > 1
                         ? "Submit \(answers.count) of \(chat.questions.count)" : "Submit")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                }
                .hmSystemProminent()
                .disabled(answers.isEmpty || chat.answering)
            }
        }
        .padding(14)
        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HMDesign.separator, lineWidth: 1))
        .padding(.horizontal, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: chat.questions.count)
    }

    @ViewBuilder private func questionView(_ q: ClarifyRequest, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let number { Text("\(number).").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                Text(q.question).font(.subheadline).textSelection(.enabled)
            }
            ForEach(q.choices, id: \.self) { raw in
                let choice = ClarifyChoice(raw)
                let on = picks[q.id]?.contains(raw) == true && !writing.contains(q.id)
                Button {
                    writing.remove(q.id)
                    var set = picks[q.id] ?? []
                    if q.multiSelect { if set.contains(raw) { set.remove(raw) } else { set.insert(raw) } }
                    else { set = set.contains(raw) ? [] : [raw] }
                    picks[q.id] = set
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = choice.detail {
                            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(on ? HMDesign.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? HMDesign.accent : HMDesign.separator, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chat.answering)
            }
            if writing.contains(q.id) || q.choices.isEmpty {
                TextField("Your answer", text: Binding(get: { custom[q.id] ?? "" }, set: { custom[q.id] = $0 }), axis: .vertical)
                    .lineLimit(1...5)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HMDesign.accent, lineWidth: 1.5))
                    .onAppear { writing.insert(q.id) }
            } else {
                Button { writing.insert(q.id) } label: {
                    Label("Write my own", systemImage: "plus").font(.subheadline).foregroundStyle(.secondary)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A choice as Hermes writes it ("Restart it now (Recommended) — Kill the frozen Chrome and…"): a short title and
/// the explanation under it. Plain choices stay a title.
struct ClarifyChoice {
    let title: String
    let detail: String?
    init(_ raw: String) {
        for sep in [" — ", " – ", " - ", ": ", "\n"] {
            if let r = raw.range(of: sep), raw.distance(from: raw.startIndex, to: r.lowerBound) <= 70 {
                title = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                detail = rest.isEmpty ? nil : rest
                return
            }
        }
        title = raw
        detail = nil
    }
}

/// The message you're replying to, above the message box: accent bar, two lines, remove button.
struct QuoteChip: View {
    let text: String
    /// (n, of) when replying to several messages.
    var count: (Int, Int)? = nil
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(HMDesign.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Label(count.map { "Replying to \($0.0) of \($0.1)" } ?? "Replying to", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(HMDesign.accent)
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove reply quote")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 10).padding(.vertical, 6).padding(.trailing, 2)
        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A quoted message inside a sent bubble: small, muted, three lines at most.
struct QuoteCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(HMDesign.accent.opacity(0.7)).frame(width: 3)
            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Where the reader is. On iOS 18+ the real scroll position decides "following the newest message": within
/// 80 pt of the bottom follows, anywhere else holds still, however you got there (drag, flick, scroll-to-top tap).
/// The list starts at the bottom, but growing content (a streaming reply, an older page) doesn't drag you down.
struct ReadingPosition: ViewModifier {
    @Binding var followLatest: Bool
    /// How far above the newest message the view is, in points (0 at the bottom). Drives the Latest button.
    @Binding var distance: CGFloat
    /// The list parked itself past its last row (a blank screen): land again.
    var pastEnd: () -> Void = {}
    /// True while your finger or a flick is moving the list. Growing content alone never stops following.
    @State private var userScrolling = false
    @State private var atBottom = true
    @State private var lastRescue = Date.distantPast
    @State private var latestGap: CGFloat = 0
    @State private var rescueQueued = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height)
                } action: { _, gap in
                    distance = max(0, gap)
                    let bottom = gap < 80
                    if bottom != atBottom { atBottom = bottom }
                    if bottom { if !followLatest { followLatest = true } }
                    else if userScrolling { followLatest = false }
                    // Far below the content with nobody scrolling: a lazy list that measured short. Never a reading spot.
                    latestGap = gap
                    if gap < -120, !userScrolling {
                        if Date().timeIntervalSince(lastRescue) > 1 {
                            lastRescue = Date()
                            pastEnd()
                        } else if !rescueQueued {
                            // Throttled, and the geometry may never change again: look once more shortly.
                            rescueQueued = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.05))
                                rescueQueued = false
                                if latestGap < -120, !userScrolling { lastRescue = Date(); pastEnd() }
                            }
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                    if userScrolling && !atBottom { followLatest = false }
                    if phase == .idle && atBottom { followLatest = true }
                }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// A subagent working for this chat (from Status's running list).
struct SubagentInfo: Identifiable {
    let sessionID: String?
    let profile: String
    let title: String
    let goal: String?
    let model: String
    let provider: String?
    let steps: Int?
    let started: Date?
    var id: String { sessionID ?? title }
}

/// One background task: what it was asked, which model and provider, how long and how many steps.
/// Tap to open its own transcript and follow it.
struct SubagentCard: View {
    let task: SubagentInfo
    @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true

    var body: some View {
        let title = task.title.replacingOccurrences(of: "Subagent: ", with: "")
        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ThinkingIndicator(size: 14, activity: task.goal ?? task.title)
                Text(kawaiiFaces ? title : KawaiiFilter.strip(title)).font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let started = task.started {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ActivityBadge.elapsed(ctx.date.timeIntervalSince(started))).monospacedDigit()
                    }
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(HMDesign.text2)
                }
                if task.sessionID != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            if let goal = task.goal, !goal.isEmpty {
                Text(goal).font(.footnote).foregroundStyle(HMDesign.text2).lineLimit(3)
            }
            Text([ModelName.short(task.model).components(separatedBy: " · ").first,
                  task.provider.map(ProviderUsageSection.displayName),
                  task.steps.map { "\($0) steps" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HMDesign.separator, lineWidth: 0.5))
        if let id = task.sessionID {
            NavigationLink(value: ChatRef(profile: task.profile, sessionId: id)) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}

/// "10:42:07 · 3.2s" next to a tool step: when it ran and how long it took (live steps count up).
struct ToolStamp: View {
    let row: ToolActivity
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        if let start = row.started {
            HStack(spacing: 4) {
                Text(Self.clock.string(from: Date(timeIntervalSince1970: start)))
                if let end = row.ended, end >= start {
                    Text("· " + Self.span(end - start))
                } else if row.state == "running" {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("· " + Self.span(ctx.date.timeIntervalSince1970 - start))
                    }
                }
            }
            .font(.system(.caption2, design: .monospaced)).monospacedDigit().foregroundStyle(.tertiary)
            .fixedSize()
        }
    }

    static func span(_ t: Double) -> String {
        t < 1 ? "<1s" : t < 60 ? String(format: "%.1fs", t) : "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}

/// A reply that didn't go through (provider error, usage limit, lost connection): retry now, or have the Mac send
/// it again later, by default when the provider's usage window resets. The scheduled send lives on the Mac.
struct FailedTurnCard: View {
    @Bindable var chat: ChatModel
    let itemID: String
    let text: String
    let isLatest: Bool
    @Environment(AppModel.self) private var app
    @State private var busy = false

    /// The soonest future reset among usage windows that are nearly full (or the chat's provider's soonest reset).
    private var reset: (date: Date, label: String)? {
        let providers = app.status.payload?["providers"]["providers"].array ?? []
        let mine = chat.served?.provider
        var best: (Date, String)?
        for p in providers {
            let name = p["provider"].string ?? ""
            for w in p["usage"]["windows"].array {
                guard let at = w["resets_at"].date, at > Date() else { continue }
                let full = (w["used_percent"].double ?? 0) >= 90
                guard full || (mine != nil && name == mine) else { continue }
                if best == nil || at < best!.0 { best = (at, ProviderUsageSection.displayName(name)) }
            }
        }
        return best
    }

    private var waiting: API.ScheduledSend? {
        guard let ask = chat.askBefore(itemID) else { return nil }
        return chat.scheduled.first { $0.text == ask }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("That reply didn't go through", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.ink)
            Text(text.hasPrefix("This turn") ? "Hermes stopped partway. Some steps may already have run."
                 : "The model didn't answer (often a usage limit or a dropped connection).")
                .font(.footnote).foregroundStyle(HMDesign.text2)
            if let w = waiting {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(HMDesign.accent)
                    (Text("Your Mac sends it again ") + Text(w.due, style: .relative) + Text(w.due < Date() ? " ago" : ""))
                        .font(.footnote)
                    Spacer()
                    Button("Cancel") { Task { await chat.cancelScheduled(w.id) } }.font(.footnote.weight(.semibold))
                }
                if let e = w.error { Text(e).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            } else if isLatest, chat.askBefore(itemID) != nil {
                HStack(spacing: 8) {
                    Button { act { await chat.retryNow(itemID) } } label: {
                        Label("Try again", systemImage: "arrow.clockwise").font(.footnote.weight(.semibold))
                    }
                    .hmSystemProminent()
                    Menu {
                        if let r = reset {
                            Button("When \(r.label) resets · \(r.date.formatted(date: .omitted, time: .shortened))") {
                                act { await chat.retryLater(itemID, at: r.date.addingTimeInterval(60), reason: "limits") }
                            }
                        }
                        Button("In 15 minutes") { act { await chat.retryLater(itemID, at: .now + 900, reason: "later") } }
                        Button("In 1 hour") { act { await chat.retryLater(itemID, at: .now + 3600, reason: "later") } }
                        Button("In 5 hours") { act { await chat.retryLater(itemID, at: .now + 5 * 3600, reason: "later") } }
                    } label: {
                        Label(reset.map { "At reset · " + $0.date.formatted(date: .omitted, time: .shortened) } ?? "Later",
                              systemImage: "clock").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HMDesign.separator, lineWidth: 0.5))
        .task(id: itemID) { if isLatest { await chat.refreshScheduled() } }
    }

    private func act(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }
}

/// The chat on screen doesn't need a notification for its own replies; other chats still do.
struct VisibleChat: ViewModifier {
    let destination: ReplyDestination?
    @State private var onScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                onScreen = true
                ReplyNotifier.shared.watch(destination)
            }
            .onDisappear {
                onScreen = false
                ReplyNotifier.shared.unwatch(destination)
            }
            // A new chat gets its session with the first send.
            .onChange(of: destination) { _, chat in
                if onScreen { ReplyNotifier.shared.watch(chat) }
            }
    }
}


/// Jump back to the newest message: a small glass circle, translucent so the words behind it stay readable,
/// shown only while you're reading back. A dot and a count say when new messages arrived meanwhile.
private struct LatestButton: View {
    let unseen: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(unseen > 0 ? HMDesign.accent : HMDesign.text2)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(HMDesign.text2.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .opacity(0.88)
                .overlay(alignment: .topTrailing) {
                    if unseen > 0 {
                        Text(unseen > 99 ? "99+" : "\(unseen)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(HMDesign.bubbleText)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(HMDesign.accent, in: Capsule())
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: HMDesign.touch, height: HMDesign.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: unseen)
        .accessibilityLabel(unseen > 0 ? "Jump to latest, \(unseen) new" : "Jump to latest message")
    }
}

/// The Latest button and its "new" count, kept out of the chat's body (one modifier chain that long is more than
/// the type checker will solve in reasonable time).
private struct LatestControl: ViewModifier {
    let distance: CGFloat
    let threshold: CGFloat
    let count: Int
    @Binding var unseen: Int
    let jump: () -> Void

    func body(content: Content) -> some View {
        let away = distance > threshold
        content
            .onChange(of: count) { old, new in
                // Count what arrives while you're reading further up.
                if new > old, away { unseen += new - old }
            }
            .onChange(of: away) { _, isAway in if !isAway { unseen = 0 } }
            .overlay(alignment: .bottomTrailing) {
                if away {
                    LatestButton(unseen: unseen) { unseen = 0; jump() }
                        .padding(.trailing, 14).padding(.bottom, 10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(HMMotion.standard, value: away)
    }
}


/// Find in this chat, like find-on-page: type, see "3 of 17", step older and newer, or open every match.
/// Searches the whole history on the Mac (not just loaded pages); jumping to an old match loads back to it.
private struct FindBar: View {
    let chat: ChatModel
    @Binding var open: Bool
    let reveal: (String) async -> Bool
    @State private var query = UserDefaults.standard.string(forKey: "HMDemoFind") ?? ""
    @State private var result: ChatSearchResult?
    @State private var index = 0
    @State private var busy = false
    @State private var failed: String?
    @State private var showList = false
    @FocusState private var focused: Bool

    private var hits: [ChatSearchHit] { result?.results ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(HMDesign.text2).font(.subheadline)
                    TextField("Search this chat", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { step(-1) }
                    if busy { ProgressView().controlSize(.mini) }
                    else if !query.isEmpty {
                        Button { query = ""; result = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(HMDesign.text2)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).frame(minHeight: 36)
                .background(HMDesign.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(countLabel).font(.caption.monospacedDigit()).foregroundStyle(HMDesign.text2)
                    .frame(minWidth: 44)
                    .onTapGesture { if !hits.isEmpty { showList = true } }
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(hits.isEmpty).accessibilityLabel("Older match")
                    .frame(width: 32, height: HMDesign.touch)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(hits.isEmpty).accessibilityLabel("Newer match")
                    .frame(width: 32, height: HMDesign.touch)
                Button("Done") { close() }.font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HMDesign.accent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            if let failed {
                Text(failed).font(.caption).foregroundStyle(HMDesign.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 6)
            } else if let hit = hits[safe: index] {
                Button { showList = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hit.role == "user" ? "person.fill" : "sparkle").font(.caption2)
                        Text(hit.attributed).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "list.bullet").font(.caption2)
                    }
                    .foregroundStyle(HMDesign.text2)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all matches")
            }
            Divider()
        }
        .background(.bar)
        .onAppear { focused = true }
        .task(id: query) { await search() }
        .sheet(isPresented: $showList) {
            FindList(query: query, result: result, current: index) { pick in
                showList = false
                go(to: pick)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var countLabel: String {
        guard let result, query.count >= 2 else { return "" }
        if result.total == 0 { return "None" }
        return "\(index + 1) of \(result.total)\(result.truncated ? "+" : "")"
    }

    private func search() async {
        failed = nil
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2, let sid = chat.sessionId else { result = nil; return }
        try? await Task.sleep(for: .milliseconds(250))   // typing: wait for a pause
        guard !Task.isCancelled else { return }
        busy = true
        defer { busy = false }
        do {
            let found = try await API.shared.searchChat(profile: chat.profile, session: sid, query: words)
            guard !Task.isCancelled else { return }
            result = found
            // Start at the newest match, like find on a page you're at the bottom of.
            if !found.results.isEmpty { go(to: found.results.count - 1) }
        } catch {
            guard !Task.isCancelled else { return }
            failed = "Couldn't search: your Mac may be offline. \(error.localizedDescription)"
        }
    }

    /// -1 older, +1 newer; wraps around.
    private func step(_ by: Int) {
        guard !hits.isEmpty else { return }
        go(to: (index + by + hits.count) % hits.count)
    }

    private func go(to n: Int) {
        guard let hit = hits[safe: n] else { return }
        index = n
        Task {
            if !(await reveal(hit.itemID)) { failed = "That match is no longer in this chat's loaded history." }
        }
    }

    private func close() {
        focused = false
        withAnimation(HMMotion.standard) { open = false }
    }
}

/// Every match in one list: who said it, when, and the words around it.
private struct FindList: View {
    let query: String
    let result: ChatSearchResult?
    let current: Int
    let pick: (Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let result, result.truncated {
                    Text("Showing the first \(result.results.count) of \(result.total). Search more precisely to see the rest.")
                        .font(.caption).foregroundStyle(HMDesign.text2)
                }
                ForEach(Array((result?.results ?? []).enumerated()).reversed(), id: \.element.id) { n, hit in
                    Button { pick(n) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hit.role == "user" ? "You" : "Hermes").font(.caption.weight(.semibold))
                                Spacer()
                                if let ts = hit.timestamp {
                                    Text(Date(timeIntervalSince1970: ts), format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption2).foregroundStyle(HMDesign.text2)
                                }
                            }
                            Text(hit.attributed).font(.subheadline).lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(n == current ? HMDesign.accent.opacity(0.12) : nil)
                }
            }
            .navigationTitle(result.map { "\($0.total) match\($0.total == 1 ? "" : "es")" } ?? "Matches")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
