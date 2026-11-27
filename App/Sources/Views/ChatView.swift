import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import QuickLook

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

    private var bot: Bot? { app.bot(chat.profile) }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: HMDesign.medium) {
                    if let saved = chat.cachedAt {
                        Text("Saved on this iPhone \(saved, style: .relative) ago")
                            .font(.footnote).foregroundStyle(.secondary)
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
                                   showActions: item.id == lastReply,
                                   showTime: revealTimes || timeMarks.contains(item.id))
                            .id(item.id)
                    }
                    if !chat.isRunning, !backgroundTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backgroundTasks.count == 1
                                 ? "Will resume when 1 background task finishes"
                                 : "Will resume when \(backgroundTasks.count) background tasks finish")
                                .font(.subheadline.weight(.semibold))
                            ForEach(Array(backgroundTasks.enumerated()), id: \.offset) { _, task in
                                Text(task.model.isEmpty ? task.title : "\(task.title) · \(task.model)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 12)
                    }
                    if let s = chat.status {
                        HStack(spacing: 8) {
                            ThinkingOrb(size: 16)
                            Text(s).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16).id("status")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { drag in
                if drag.translation.height > 12 { followLatest = false }
                // Swipe left, like iMessage, to see every message's time.
                let sideways = drag.translation.width < -40 && abs(drag.translation.width) > abs(drag.translation.height) * 1.5
                if sideways != revealTimes { withAnimation(.snappy) { revealTimes = sideways } }
            }.onEnded { _ in
                if revealTimes { withAnimation(.snappy) { revealTimes = false } }
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
            .onAppear { if followLatest { land(proxy) } }
            .task(id: chat.items.isEmpty) { if !chat.items.isEmpty, followLatest { land(proxy) } }
            // A long transcript arriving all at once can leave a lazy list parked below its content (a blank
            // screen until you scroll). Land on the newest message once the first page is in, then again after
            // the rows have measured themselves.
            .task(id: chat.items.isEmpty) {
                guard !chat.items.isEmpty, followLatest else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("bottom", anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(450))
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button {
                        followLatest = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down").font(.footnote.weight(.semibold))
                            .padding(.horizontal, HMDesign.medium).frame(minHeight: HMDesign.touch)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HMDesign.accent)
                    .accessibilityLabel("Jump to latest message")
                    .padding(.trailing, 12).padding(.bottom, 6)
                }
            }
            .overlay { if chat.isLoading { ProgressView("Loading messages…") } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !chat.pins.isEmpty {
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
            ToolbarItem(placement: .topBarTrailing) {
                // One dot. Tap it for the gateway's state, Reload chat and Check again.
                ConnectionBadge(compact: true, reloadDisabled: chat.isLoading || chat.isRunning) {
                    await chat.load(quiet: true)
                    landTick &+= 1
                }
            }
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
                    if let error = chat.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
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
        .task(id: chat.sessionId) { await chat.loadPins() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onReceive(NotificationCenter.default.publisher(for: .hermesOpenPath)) { note in
            guard let path = note.object as? String, let sid = chat.sessionId else { return }
            Task { await openPath(path, session: sid) }
        }
        .quickLookPreview($pathPreview)
        .onReceive(NotificationCenter.default.publisher(for: .hermesForeground)) { _ in
            // Anything waiting to go tries again right away, then backs off quietly.
            chat.outboxWake()
            // Back from the background: show what happened while away, then land on it.
            guard !chat.isRunning else { return }
            Task { await chat.load(quiet: true); landTick &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesCopied)) { note in
            let text = note.object as? String ?? "Copied"
            withAnimation(.snappy) { toast = text }
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                if toast == text { withAnimation(.snappy) { toast = nil } }
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
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
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
                        guard let preview = await image.byPreparingThumbnail(ofSize: CGSize(width: 1600, height: 1600)) else { throw ChatMedia.Failure.unreadable }
                        try appendMedia([ChatMedia.jpeg(preview, name: "Camera")], account: account)
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
                if chat.served?.fallbackActive == true {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Answered by a fallback model")
                }
                Text(runtimeLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).imageScale(.small).accessibilityHidden(true)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// "Opus 5.5 · High". The provider and raw id live in the model sheet, one tap away.
    private var runtimeLabel: String {
        if chat.savingRuntime { return "Saving model…" }
        let c = chat.choice
        let who = ModelName.short(c.model ?? bot?.model ?? "Default model")
        if chat.isRunning, chat.runtimeNotice != nil { return "Next · " + who }
        var parts = [who]
        if let effort = c.effort.flatMap({ Effort(rawValue: $0)?.label }) { parts.append(effort) }
        // Real money only: a plan-covered chat shows no price here (the model sheet has the detail).
        if let usd = chat.served?.cost?.usd, usd >= 0.01 { parts.append(CostSummary.money(usd)) }
        return parts.joined(separator: " · ")
    }

    private var backgroundTasks: [(title: String, model: String)] {
        guard let session = chat.sessionId else { return [] }
        return (app.status.payload?["agents"].array ?? []).compactMap { row in
            guard row["kind"].string == "subagent", row["parent_session_id"].string == session else { return nil }
            return (row["title"].string ?? row["name"].string ?? "Background task", row["model"].string ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: HMDesign.small) {
            BotAvatar(id: chat.profile, name: bot?.name ?? chat.profile, size: 64).accessibilityHidden(true)
            Text(bot?.name ?? chat.profile).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let b = bot?.blurb, !b.isEmpty {
                Text(b).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Text("Write a message to start the conversation.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showRuntime = true } label: {
                VStack(spacing: 2) {
                    Label(runtimeLabel, systemImage: "cpu").font(HMDesign.metadata)
                    Text("Tap to pick the model and effort").font(.caption2).foregroundStyle(.secondary)
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
        ComposerField(text: $chat.draft, placeholder: "Message \(bot?.name ?? "Hermes") · / for commands",
                      expanded: expanded, onPasteText: chat.absorbPaste, onPasteImage: importPastedImage)
    }

    @ViewBuilder private var draftShelf: some View {
        if let quote = chat.pastedTexts.first(where: \.isQuote) {
            QuoteChip(text: quote.text) { chat.removePastedText(quote.id) }
                .padding(.horizontal, 12)
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
                            if let data = Data(base64Encoded: asset.base64), let image = UIImage(data: data) {
                                previewedImage = image
                            }
                        }) {
                            if chat.draftAttachments.indices.contains(index) { chat.draftAttachments.remove(at: index) }
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
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
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
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: HMDesign.panelRadius))
                .padding(.horizontal, HMDesign.medium)
            }
            if let scope = projectScope {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Include \(scope.title) context with next message", isOn: $includeProjectContext)
                        .font(.subheadline)
                        .disabled(chat.isRunning)
                    Text(ProjectContext.disclosure).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            if let filter = SlashCommand.filter(in: chat.draft), chat.draftAttachments.isEmpty, !chat.isRunning {
                SlashMenu(commands: chat.slashCommands, skills: chat.skillDetails, filter: filter) { name in
                    chat.draft = "/" + name + " "
                }
            }
            if let q = chat.question { QuestionCard(chat: chat, question: q) }
            if chat.queue?.paused == true { QueuePausedBanner(chat: chat) }
            if !chat.outgoing.isEmpty { OutboxTray(chat: chat) }
            draftShelf
            if chat.isRunning, let notice = chat.runtimeNotice {
                Text(notice).font(HMDesign.metadata).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Expand composer")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if keyboardUp {
                            Button { Self.hideKeyboard() } label: {
                                Image(systemName: "keyboard.chevron.compact.down").font(.caption)
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Hide keyboard")
                        }
                    }
                    .padding(.horizontal, HMDesign.micro)
                if chat.isRunning {
                    Button { Task { await chat.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
                            .hmTouchTarget()
                    }
                    .accessibilityLabel("Stop reply")
                    // While Hermes replies, Send queues the message for right after this reply.
                    // Touch and hold to guide the current reply instead.
                    Button { followUp("queue") } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "clock.fill").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white, HMDesign.accent)
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
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title).hmTouchTarget()
                    }
                    .disabled(preparingMedia || chat.savingRuntime || chat.slashBusy || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
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
                    Text("Send queues it").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.subheadline.weight(.medium))
                .disabled(!chat.acceptsFollowUp || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                .padding(.horizontal, 16).padding(.bottom, 5)
            }
        }
        .padding(.top, HMDesign.micro)
        .background(HMDesign.bar)
        .overlay(alignment: .top) { Divider() }
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
        if replace, case let (quote?, body) = ReplyQuote.split(text) {
            // Editing a sent reply: its quote goes back into the chip, the words into the box.
            chat.setReplyQuote(quote)
            chat.draft = body
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
        followLatest = false
        Task {
            guard await chat.reveal(pin) else {
                chat.error = "That pinned message is no longer in this chat's history. Its text is kept in Pinned."
                return
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(pin.itemID, anchor: .center) }
            highlighted = pin.itemID
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == pin.itemID { withAnimation { highlighted = nil } }
        }
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
                                   uploadLimit: mediaCapabilities?.maxUploadBytes)
    }

    private func appendMedia(_ assets: [SendAttachment], account: String?) {
        guard !Task.isCancelled, let account, account == app.inboxAccount else { return }
        let proposed = chat.draftAttachments + assets
        if let problem = issue(for: proposed) { chat.error = problem; return }
        chat.draftAttachments = proposed
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
        for item in photos {
            do {
                let data = try await MediaImport.imageData(from: item)
                if Task.isCancelled { return }
                assets.append(try await Task.detached(priority: .userInitiated) { try ChatMedia.image(from: data) }.value)
            } catch { if !Task.isCancelled { chat.error = error.localizedDescription } }
        }
        appendMedia(assets, account: account)
        if skipped > 0 { chat.error = "Videos go one per message, so \(skipped == 1 ? "the video was" : "\(skipped) videos were") left out." }
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
                    return
                }
                pickedVideo = file
                chooseVideo = true
            } else {
                let data = try await MediaImport.imageData(from: item)
                if Task.isCancelled { return }
                let asset = try await Task.detached(priority: .userInitiated) { try ChatMedia.image(from: data) }.value
                appendMedia([asset], account: account)
            }
        } catch { if !Task.isCancelled { chat.error = error.localizedDescription } }
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
                guard let preview = await image.byPreparingThumbnail(ofSize: CGSize(width: 2048, height: 2048)) else {
                    throw ChatMedia.Failure.unreadable
                }
                try Task.checkCancellation()
                let asset = try ChatMedia.pasted(preview)
                appendMedia([asset], account: account)
            } catch {
                if !Task.isCancelled { chat.error = error.localizedDescription }
            }
        }
    }

    /// Files keeps the original bytes and type; only images reuse the photo pipeline. The
    /// security-scoped URL is read inside the scope, and base64 happens off the main actor.
    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError { return }
            chat.error = error.localizedDescription
            return
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let slots = max(0, ChatMedia.maxAttachments - chat.draftAttachments.count)
            guard urls.count <= slots else { chat.error = "Choose up to \(slots) more attachments for this message."; return }
            let account = app.inboxAccount
            let cap = mediaCapabilities?.maxFileBytes ?? 4 * 1024 * 1024
            preparingMedia = true
            Task {
                defer { preparingMedia = false }
                var added: [SendAttachment] = []
                var left = cap - chat.draftAttachments.reduce(0) { $0 + $1.byteCount }
                for url in urls {
                    if Task.isCancelled { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? UTType(filenameExtension: url.pathExtension)
                        if type?.conforms(to: .movie) == true {
                            guard urls.count == 1 else { chat.error = "Choose a video on its own to review the clip or frames."; return }
                            let snapshot = try await Task.detached { try MediaStaging.stage(url) }.value
                            guard !Task.isCancelled, account == app.inboxAccount else { try? FileManager.default.removeItem(at: snapshot); return }
                            discardVideo()
                            pickedVideo = snapshot
                            chooseVideo = true
                            return
                        }
                        let uploadMax = mediaCapabilities?.maxUploadBytes
                        let asset = try await Task.detached(priority: .userInitiated) {
                            try FileImport.attachment(from: url, maxBytes: cap, uploadMax: uploadMax)
                        }.value
                        guard account == app.inboxAccount else { return }
                        guard chat.draftAttachments.count < ChatMedia.maxAttachments,
                              !chat.draftAttachments.contains(where: { $0.mime == "video/mp4" }) else { return }
                        guard asset.mime != "image/jpeg" || imagesAvailable else { chat.error = "This bot cannot receive images."; return }
                        if !asset.isUpload {
                            guard asset.byteCount <= left else { throw FileImport.Failure.tooLarge(cap) }
                            left -= asset.byteCount
                        }
                        added.append(asset)
                    } catch {
                        if !Task.isCancelled { chat.error = error.localizedDescription }
                        return
                    }
                }
                appendMedia(added, account: account)
            }
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
                let file = try await Task.detached(priority: .userInitiated) { try ChatMedia.original(from: url, uploadMax: uploadMax) }.value
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
        let files = chat.draftAttachments
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

    private func send() {
        if runModelCommand() { return }
        let attachments = chat.draftAttachments
        let text = chat.combinedDraft
        if let problem = issue(for: attachments) {
            chat.error = problem
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
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
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
    var focusOnAppearance = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if focusOnAppearance, window != nil {
            focusOnAppearance = false
            becomeFirstResponder()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return isEditable }
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
        placeholderLabel.textColor = .placeholderText
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
        if let pasted = UIPasteboard.general.string, PasteSplit.collapse(pasted) {
            onPasteText?(pasted)
            if let selection = selectedTextRange, !selection.isEmpty { replace(selection, withText: "") }
            return
        }
        super.paste(sender)
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
        ShareLink(item: item.text)
    }

    /// Long pastes fold to their first lines so one message never fills the screen.
    private var replySplit: (quote: String?, body: String) { ReplyQuote.split(item.text) }
    private var userIsLong: Bool { item.text.count > 700 || item.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 14 }
    private var userText: String {
        guard userIsLong, !showFull else { return item.text }
        let head = item.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n")
        return String(head.prefix(600)) + "…"
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
                        Label(note, systemImage: "folder.badge.gearshape").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !item.text.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            if pinned { pinMark }
                            VStack(alignment: .leading, spacing: 8) {
                            if let q = replySplit.quote { QuoteCard(text: q) }
                            Text(replySplit.quote == nil ? userText : replySplit.body)
                                .padding(.horizontal, HMDesign.gutter).padding(.vertical, HMDesign.medium)
                                .foregroundStyle(.primary)
                                .background(HMDesign.selectedFill, in: RoundedRectangle(cornerRadius: HMDesign.messageRadius))
                                .overlay(RoundedRectangle(cornerRadius: HMDesign.messageRadius)
                                    .strokeBorder(HMDesign.accent, lineWidth: highlighted ? 2 : 0))
                            }
                                .contextMenu { messageMenu }
                        }
                    }
                    if userIsLong {
                        Button(showFull ? "Show less" : "Show full message") { withAnimation(.snappy) { showFull.toggle() } }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(minHeight: HMDesign.touch)
                    }
                    TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .trailing)
                    let note = item.annotation.flatMap { $0.isEmpty ? nil : $0 }
                    if note != nil || (showTime && item.timestamp != nil) {
                        HStack(spacing: 4) {
                            if let note { Text(note) }
                            if note != nil, showTime, item.timestamp != nil { Text("·") }
                            if showTime, let ts = item.timestamp { Text(Date(timeIntervalSince1970: ts), style: .time) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .modifier(SwipeToQuote { onCompose?(quoted, false) })
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .assistant:
            // Replies run full width without a bubble (as in T3 and the desktop app): more of the
            // conversation fits on screen, and code blocks get the whole line.
            VStack(alignment: .leading, spacing: 6) {
                if !item.text.isEmpty {
                    MarkdownText(text: item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(highlighted ? HMDesign.selectedFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) { if pinned { pinMark.offset(x: 2, y: -2) } }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contextMenu { messageMenu }
                }
                TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .leading)
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
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Share reply")
                                Spacer(minLength: 0)
                                if let ts = item.timestamp {
                                    Text(Date(timeIntervalSince1970: ts), style: .time).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if let f = item.footer {
                            Label(f, systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Answered by \(f)")
                        }
                    }
                    .padding(.leading, HMDesign.micro)
                }
                if showTime, !(showActions && !item.text.isEmpty), let ts = item.timestamp {
                    Text(Date(timeIntervalSince1970: ts), style: .time)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .modifier(SwipeToQuote { onCompose?(quoted, false) })
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .control:
            // Their words, not a gray system card. The tag says whether it was queued or used to guide the reply.
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    if !item.text.isEmpty {
                        Text(item.text).textSelection(.enabled)
                            .padding(.horizontal, HMDesign.gutter).padding(.vertical, HMDesign.medium)
                            .foregroundStyle(.primary)
                            .background(HMDesign.selectedFill, in: RoundedRectangle(cornerRadius: HMDesign.messageRadius))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: (item.footer ?? "").hasPrefix("Guided") ? "arrow.turn.up.right" : "clock")
                        Text(item.footer ?? "Sent")
                        if let ts = item.timestamp { Text(Date(timeIntervalSince1970: ts), style: .time) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        case .tools:
            DisclosureGroup(isExpanded: $toolsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if item.activities.isEmpty {
                        ForEach(Array(item.tools.enumerated()), id: \.offset) { _, tool in
                            Text(tool.replacingOccurrences(of: "_", with: " ")).font(.caption.monospaced())
                        }
                    } else {
                        ForEach(item.activities) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: row.state == "failed" ? "xmark.circle.fill" : ToolLanguage.icon(row.name))
                                    .font(.caption).frame(width: 16)
                                    .foregroundStyle(row.state == "failed" ? Color.red : Color.secondary)
                                    .symbolEffect(.pulse, isActive: row.state == "running" && !reduceMotion)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ToolLanguage.title(row))
                                        .font(.caption)
                                        .foregroundStyle(row.state == "failed" ? Color.red : Color.primary)
                                    if !row.result.isEmpty {
                                        Text(row.result).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(ToolLanguage.title(row) + (row.state == "failed" ? ", failed" : row.state == "running" ? ", running" : ""))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(Self.toolLabel(item), systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
        case .activity where !item.entries.isEmpty:
            ActivityCard(item: item, expanded: $activityExpanded)
                .padding(.horizontal, 12)
        case .activity:
            DisclosureGroup(isExpanded: $activityExpanded) {
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label(item.text, systemImage: item.failed ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(item.failed ? Color.red : Color.secondary)
                    .strikethrough(item.failed, color: .red)
            }
            .padding(.horizontal, 18)
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(.tertiarySystemFill).opacity(0.6), in: Capsule())
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
                Section { Text(req.description) }
                if !req.command.isEmpty {
                    Section("Command") { Text(req.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle") }
                Section {
                    ForEach(req.choices, id: \.self) { c in
                        Button(role: c == "deny" ? .destructive : nil) { answer(c) } label: { Text(label(c)) }
                    }
                }
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

    static func title(_ row: ToolActivity) -> String {
        let preview = row.preview
        switch row.name {
        case "skill_view": return preview.isEmpty ? "Loaded a skill" : "Loaded skill · \(preview)"
        case "terminal", "execute_code": return preview.isEmpty ? "Ran a command" : "Ran · \(preview)"
        case "read_file", "search_files", "list_files": return preview.isEmpty ? "Explored files" : "Explored · \(preview)"
        case "web_search", "web_extract": return preview.isEmpty ? "Searched" : "Searched · \(preview)"
        case "delegate_task": return preview.isEmpty ? "Delegated a task" : "Delegated · \(preview)"
        case "tool_search": return "Looked up tools"
        default:
            let spoken = row.name.replacingOccurrences(of: "_", with: " ")
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
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                    if !skillHits.isEmpty {
                        Text("Skills").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 4)
                        ForEach(skillHits) { skill in
                            Button { pick(skill.name) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("/" + skill.name).font(.subheadline)
                                    if !skill.description.isEmpty {
                                        Text(skill.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
        }
    }
}

private struct TranscriptImages: View {
    let refs: [ChatMediaRef]
    let profile: String
    let session: String?
    var alignment: HorizontalAlignment = .leading
    @State private var preview: UIImage?

    var body: some View {
        if !refs.isEmpty, session != nil {
            VStack(alignment: alignment, spacing: 6) {
                ForEach(refs, id: \.digest) { ref in
                    if ref.kind == "image" {
                        TranscriptImage(profile: profile, session: session ?? "", digest: ref.digest, name: ref.name) {
                            preview = $0
                        }
                    } else {
                        TranscriptFile(ref: ref, profile: profile, session: session ?? "")
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview { FullImagePreview(image: preview) }
            }
        }
    }
}

private struct TranscriptImage: View {
    let profile: String
    let session: String
    let digest: String
    let name: String
    let open: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Button { open(image) } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            } else if failed {
                Label(name, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 44, height: 44)
            }
        }
        .task {
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
                        Text(pins.count == 1 ? "Pinned message" : "Pinned message \(cursor + 1) of \(pins.count)")
                            .font(.caption.weight(.semibold)).foregroundStyle(HMDesign.accent)
                        Text(pin.excerpt).font(.footnote).lineLimit(1).foregroundStyle(.primary)
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
        .background(HMDesign.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                                .foregroundStyle(.secondary)
                                Text(pin.text).font(.subheadline).lineLimit(6).foregroundStyle(.primary)
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
                }
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

    private var worst: String {
        if item.entries.contains(where: \.failed) { return "failed" }
        if item.entries.contains(where: { $0.status == "stopped" || $0.status == "warning" }) { return "stopped" }
        return "ok"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusGlyph(status: worst)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).lineLimit(expanded ? nil : 2)
                        if let ts = item.timestamp {
                            Text(Date(timeIntervalSince1970: ts), style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
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
                Text(entry.meta).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(worst == "failed" ? Color.red.opacity(0.35) : Color(.separator).opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private struct EntryRow: View {
        let entry: ActivityEntry
        let expanded: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusGlyph(status: entry.status, small: true)
                    Image(systemName: entry.isProcess ? "terminal" : "person.2").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.label)
                        .font(entry.isProcess ? .footnote.monospaced() : .footnote)
                        .lineLimit(expanded ? 4 : 1)
                    Spacer(minLength: 4)
                    if !expanded, !entry.meta.isEmpty {
                        Text(entry.meta).font(.caption2).foregroundStyle(entry.failed ? Color.red : Color.secondary).lineLimit(1)
                    }
                }
                if expanded {
                    if !entry.meta.isEmpty { Text(entry.meta).font(.caption).foregroundStyle(entry.failed ? Color.red : Color.secondary) }
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
        case "failed": ("xmark.octagon.fill", .red)
        case "stopped", "warning": ("stop.circle.fill", .orange)
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
                        .foregroundStyle(failed == nil ? Color.secondary : Color.red).lineLimit(1)
                }
                Spacer(minLength: 6)
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: 300, alignment: .leading)
            .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                                        Text(prompt.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) { prompts.removeAll { $0.id == prompt.id }; SavedPrompt.save(prompts) } label: { Label("Delete", systemImage: "trash") }
                                Button { editing = prompt } label: { Label("Edit", systemImage: "pencil") }.tint(HMDesign.accent)
                            }
                        }
                        .onMove { from, to in prompts.move(fromOffsets: from, toOffset: to); SavedPrompt.save(prompts) }
                        Button { editing = SavedPrompt(title: "", text: "", sendNow: true) } label: { Label("New saved prompt", systemImage: "plus") }
                    } footer: {
                        Text("A paper plane sends right away. A pencil puts the text in the message box to edit first. Swipe to edit or delete.")
                    }
                } else if side == .commands {
                    ForEach(grouped, id: \.0) { group, rows in
                        Section(group) {
                            ForEach(rows) { command in
                                Button { choose(command.name, skill: false) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("/" + command.name).font(.body.monospaced().weight(.semibold))
                                            if !command.hint.isEmpty {
                                                Text(command.hint).font(.caption.monospaced()).foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(command.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                } else {
                    if trimmed.isEmpty, category == nil, !recent.isEmpty {
                        Section("Recent") { ForEach(recent) { skillRow($0) } }
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
                        }
                    }
                    Section(category.map { "\($0) · \(skillHits.count)" } ?? "\(skillHits.count) skills") {
                        ForEach(skillHits) { skillRow($0) }
                    }
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
                        Text(skill.category).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)").font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? HMDesign.accent.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? HMDesign.accent : .primary)
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
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
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
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
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
        .foregroundStyle(.secondary)
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
        .animation(.spring(duration: 0.3), value: chat.outgoing)
    }

    private func status(_ item: Outgoing, position: Int) -> (String, String, Color) {
        switch item.phase {
        case .needsYou(let problem):
            return ("exclamationmark.triangle.fill", "Didn't send: \(problem). Tap to edit.", HMDesign.warning)
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
                Text(caption).font(.caption).foregroundStyle(item.problem == nil ? Color.secondary : tint)
                if let note = item.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if item.files > 0 {
                Label("\(item.files)", systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
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
        !(item.mode == "steer" && item.attempts > 0 && item.problem == nil)
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
                .font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.warning)
            Text("The reply to “\(String((chat.queue?.lost?.text ?? "your message").prefix(80)))” was cut off. "
                 + "\(waiting) message\(waiting == 1 ? " is" : "s are") waiting behind it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { working = true; Task { await chat.continueQueue(); working = false } } label: {
                    Text(working ? "Continuing…" : "Continue").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).disabled(working)
                if let lost = chat.queue?.lost?.text, !lost.isEmpty {
                    Button("Copy cut-off message") { Clipboard.copy(lost, what: "Copied") }.font(.subheadline)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                }
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

/// Hermes asked something mid-reply. Its choices are one tap; anything typed and sent is the answer too.
struct QuestionCard: View {
    @Bindable var chat: ChatModel
    let question: ClarifyRequest
    @State private var picked = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hermes is asking", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(HMDesign.accent)
            Text(question.question).font(.subheadline).textSelection(.enabled)
            if !question.choices.isEmpty {
                // Stacked, full width: choices are often paths or sentences, and each is an easy tap.
                VStack(alignment: .leading, spacing: 6) {
                        ForEach(question.choices, id: \.self) { choice in
                            Button {
                                if question.multiSelect {
                                    if picked.contains(choice) { picked.remove(choice) } else { picked.insert(choice) }
                                } else {
                                    Task { _ = await chat.answerQuestion(choice) }
                                }
                            } label: {
                                HStack {
                                    Text(choice).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: question.multiSelect ? (picked.contains(choice) ? "checkmark.circle.fill" : "circle")
                                                                           : "arrow.up.circle")
                                        .foregroundStyle(HMDesign.accent)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .background(picked.contains(choice) ? HMDesign.accent.opacity(0.25) : HMDesign.panel,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(chat.answering)
                        }
                }
                if question.multiSelect {
                    Button("Send \(picked.count) choice\(picked.count == 1 ? "" : "s")") {
                        let answer = question.choices.filter(picked.contains).joined(separator: ", ")
                        Task { _ = await chat.answerQuestion(answer) }
                    }
                    .buttonStyle(.borderedProminent).disabled(picked.isEmpty || chat.answering)
                }
            }
            Text("Or type your answer below and send.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: question.id)
    }
}

/// The message you're replying to, above the message box: accent bar, two lines, remove button.
struct QuoteChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(HMDesign.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Label("Replying to", systemImage: "arrowshape.turn.up.left.fill")
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
