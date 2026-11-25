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
    @State private var pickerItem: PhotosPickerItem?
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let saved = chat.cachedAt {
                        Text("Saved on this iPhone \(saved, style: .relative) ago")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if chat.hasOlder && !chat.isRunning {
                        Button(chat.loadingOlder ? "Loading earlier messages…" : "Load earlier messages") {
                            followLatest = false
                            let anchor = chat.items.first?.id
                            Task {
                                await chat.loadOlder()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                        .font(.footnote).disabled(chat.loadingOlder)
                    }
                    if chat.items.isEmpty && !chat.isLoading {
                        emptyState.padding(.top, 60)
                    }
                    let days = Self.dayStarts(chat.items)
                    let lastReply = chat.isRunning ? nil : chat.items.last(where: { $0.kind == .assistant && !$0.streaming })?.id
                    ForEach(chat.items) { item in
                        if let day = days[item.id] { DaySeparator(date: day) }
                        MessageRow(item: item, profile: chat.profile, session: chat.sessionId,
                                   pinned: chat.isPinned(item), highlighted: highlighted == item.id,
                                   onPin: chat.pinsAvailable && chat.sessionId != nil && MessagePin.messageID(for: item) != nil
                                        ? { Task { await chat.togglePin(item) } } : nil,
                                   onCompose: { text, replace in compose(text, replace: replace) },
                                   showActions: item.id == lastReply)
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
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 12)
                    }
                    if let s = chat.status {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
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
            })
            .onChange(of: chat.textRevision) { _, _ in
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.items.last?.id) { _, _ in
                if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button {
                        followLatest = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        Label("Latest", systemImage: "arrow.down").font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Jump to latest message")
                    .padding(.trailing, 12).padding(.bottom, 6)
                }
            }
            .overlay { if chat.isLoading { ProgressView() } }
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
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showRuntime = true } label: { titleBlock }
                    .buttonStyle(.plain)
                    .accessibilityHint("Change model, provider and effort")
                    .disabled(chat.savingRuntime)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button { Task { await chat.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(chat.isLoading || chat.isRunning)
                        .accessibilityLabel("Reload chat")
                    ConnectionBadge(compact: true)
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
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: imagesAvailable ? .any(of: [.images, .videos]) : .videos)
        .task(id: pickerItem) { if let pickerItem { await importMedia(pickerItem) } }
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
            if mediaCapabilities?.video == true, chat.draftAttachments.isEmpty {
                Button("Send clip for Hermes video analysis") { prepareClip() }
            }
            if imagesAvailable { Button("Choose from up to 3 frames") { prepareFrames() } }
            Button("Cancel", role: .cancel) { discardVideo() }
        } message: { Text(mediaCapabilities?.video == true ? "A clip includes audio and may be processed by the gateway’s video provider. Frames are still images you can review before sending." : "This gateway accepts still images. Review and remove frames before sending. Frames contain no audio.") }
        .onDisappear { discardVideo() }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .sensoryFeedback(.success, trigger: chat.completedTick)
        .sensoryFeedback(.error, trigger: chat.failedTick)
        .task { await chat.load() }
        .task { await chat.loadPalette() }
        .task(id: chat.sessionId) { await chat.loadPins() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
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
        .sheet(isPresented: $showCommands) {
            CommandsSheet(commands: chat.slashCommands, skills: chat.skillCommands) { name in
                chat.draft = "/" + name + " "
            }
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

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(bot?.name ?? chat.profile).font(.headline).lineLimit(1)
            HStack(spacing: 3) {
                Text(runtimeLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var runtimeLabel: String {
        if chat.savingRuntime { return "Saving model…" }
        let c = chat.choice
        let model = c.model ?? bot?.model ?? "default"
        let provider = c.provider ?? bot?.provider ?? ""
        let who = provider.isEmpty ? model : "\(model) · \(provider)"
        if chat.isRunning, chat.runtimeNotice != nil { return "Next · " + who }
        let effort = c.effort.flatMap { Effort(rawValue: $0)?.label } ?? "default effort"
        return c.isDefault ? "\(who) · bot default" : "\(who) · \(effort)"
    }

    private var backgroundTasks: [(title: String, model: String)] {
        guard let session = chat.sessionId else { return [] }
        return (app.status.payload?["agents"].array ?? []).compactMap { row in
            guard row["kind"].string == "subagent", row["parent_session_id"].string == session else { return nil }
            return (row["title"].string ?? row["name"].string ?? "Background task", row["model"].string ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            BotAvatar(id: chat.profile, name: bot?.name ?? chat.profile, size: 64)
            Text(bot?.name ?? chat.profile).font(.title2.bold())
            if let b = bot?.blurb, !b.isEmpty {
                Text(b).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Button { showRuntime = true } label: { Label(runtimeLabel, systemImage: "cpu").font(.footnote) }
                .buttonStyle(.bordered).padding(.top, 6)
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
        chat.draftAttachments.count >= 4 || chat.draftAttachments.contains { $0.mime == "video/mp4" }
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
        if !chat.pastedTexts.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(chat.pastedTexts) { chunk in
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
        VStack(spacing: 6) {
            if let e = chat.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e).font(.footnote)
                        if chat.hasUnconfirmedSend {
                            Button("Move back to composer") { Task { await chat.cancelUnconfirmedSend() } }
                                .font(.footnote.weight(.semibold))
                                .frame(minHeight: 44, alignment: .leading)
                                .accessibilityHint("Stops waiting for confirmation and returns the message for editing")
                        }
                    }
                    Spacer()
                    Button { chat.error = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Dismiss error")
                }
                .padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
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
                SlashMenu(commands: chat.slashCommands, skills: chat.skillCommands, filter: filter) { name in
                    chat.draft = "/" + name + " "
                }
            }
            draftShelf
            modelChip
            HStack(alignment: .bottom, spacing: 6) {
                VStack(spacing: 0) {
                    // Every command and skill, browsable. Typing "/" still filters them inline.
                    Button { showCommands = true } label: {
                        Image(systemName: "command")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 38, height: 22)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("All commands and skills")
                if canAttach {
                    Menu {
                        if imagesAvailable || mediaCapabilities?.video == true {
                            Button { showPicker = true } label: { Label(imagesAvailable ? "Photo or video" : "Video", systemImage: "photo.on.rectangle") }
                        }
                        if imagesAvailable {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button { openCamera() } label: { Label("Take photo", systemImage: "camera") }
                            }
                        }
                        if filesAvailable {
                            Button { showFilePicker = true } label: { Label("Choose file", systemImage: "doc") }
                        }
                    } label: {
                        if preparingMedia { ProgressView() }
                        else { Image(systemName: "plus.circle").font(.title2) }
                    }
                    .frame(width: 38, height: 38)
                    .disabled(attachmentLimitReached || preparingMedia)
                    .accessibilityLabel("Add photo, video or file")
                }
                }
                // No separate "/" button: typing "/" in the field opens the command and skill menu.
                composerField(expanded: false)
                .padding(.leading, 12).padding(.trailing, longDraft ? 30 : 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
                .overlay(alignment: .topTrailing) {
                    // Expand only when there is something long to edit; short drafts keep the width.
                    if longDraft {
                        Button { showFullComposer = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 30, height: 30).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Expand composer")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)

                if keyboardUp {
                    Button { Self.hideKeyboard() } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 34, height: 38).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Hide keyboard")
                }
                if chat.isRunning {
                    Button { Task { await chat.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .disabled(preparingMedia || chat.savingRuntime || chat.slashBusy || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            // Send next / Guide only once there is something to send: an empty row costs a line of chat.
            if chat.isRunning, !chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftAttachments.isEmpty {
                HStack(spacing: 20) {
                    Button { followUp("queue") } label: { Label("Send next", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    Button { followUp("steer") } label: { Label("Guide this reply", systemImage: "arrow.turn.up.right") }
                    Spacer()
                }
                .font(.subheadline.weight(.medium))
                .disabled(!chat.acceptsFollowUp || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                .padding(.horizontal, 16).padding(.bottom, 5)
            }
        }
        .padding(.top, 4)
        .background(.bar)
    }

    private var longDraft: Bool {
        chat.combinedDraft.count > 140 || chat.draft.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= 2
    }

    static func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Quote prepends to the draft; Edit replaces it (asking nothing: the old draft is one Undo away in the field).
    private func compose(_ text: String, replace: Bool) {
        chat.draft = replace || chat.draft.isEmpty ? text : text + chat.draft
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    /// Scrolls to a pinned message, loading earlier pages if needed, and flashes it.
    private func jump(to pin: MessagePin, proxy: ScrollViewProxy) {
        followLatest = false
        Task {
            guard await chat.reveal(pin) else {
                chat.error = "That pinned message is no longer in this chat's history. Its text is kept in Pinned."
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(pin.itemID, anchor: .center) }
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
                                   videoLimit: mediaCapabilities?.maxVideoBytes ?? 4 * 1024 * 1024)
    }

    private func appendMedia(_ assets: [SendAttachment], account: String?) {
        guard !Task.isCancelled, let account, account == app.inboxAccount else { return }
        let proposed = chat.draftAttachments + assets
        if let problem = issue(for: proposed) { chat.error = problem; return }
        chat.draftAttachments = proposed
    }

    private func importMedia(_ item: PhotosPickerItem) async {
        let account = app.inboxAccount
        preparingMedia = true
        defer { preparingMedia = false; pickerItem = nil }
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
        guard chat.draftAttachments.count < 4 else {
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
            let slots = max(0, 4 - chat.draftAttachments.count)
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
                        let asset = try await Task.detached(priority: .userInitiated) {
                            try FileImport.attachment(from: url, maxBytes: cap)
                        }.value
                        guard account == app.inboxAccount else { return }
                        guard chat.draftAttachments.count < 4,
                              !chat.draftAttachments.contains(where: { $0.mime == "video/mp4" }) else { return }
                        guard asset.mime != "image/jpeg" || imagesAvailable else { chat.error = "This bot cannot receive images."; return }
                        guard asset.byteCount <= left else { throw FileImport.Failure.tooLarge(cap) }
                        left -= asset.byteCount
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
                let clip = try await ChatMedia.clip(from: url, maxBytes: caps.maxVideoBytes)
                appendMedia([clip], account: account)
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
                let frames = try await ChatMedia.frames(from: url, count: min(3, 4 - chat.draftAttachments.count))
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
    private var modelChip: some View {
        HStack {
            Menu {
                ForEach(menuModels, id: \.self) { c in
                    Button {
                        var next = c
                        next.effort = chat.choice.effort
                        Task { await chat.apply(next) }
                    } label: {
                        if isCurrent(c) { Label(shortModel(c.model ?? ""), systemImage: "checkmark") } else { Text(shortModel(c.model ?? "")) }
                    }
                }
                Button { Task { await chat.apply(.botDefault) } } label: {
                    if chat.choice.isDefault { Label("Bot default", systemImage: "checkmark") } else { Text("Bot default") }
                }
                if !chat.choice.isDefault, chat.choice.model != nil {
                    Menu("Effort") {
                        ForEach(Effort.allCases) { e in
                            Button {
                                var next = chat.choice
                                next.effort = e.rawValue
                                Task { await chat.apply(next) }
                            } label: {
                                if chat.choice.effort == e.rawValue { Label(e.label, systemImage: "checkmark") } else { Text(e.label) }
                            }
                        }
                    }
                }
                Button { showRuntime = true } label: { Label("All models…", systemImage: "ellipsis.circle") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2)
                    Text(chat.savingRuntime ? "Saving…" : chipLabel).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .frame(minHeight: 44)
            }
            .disabled(chat.savingRuntime)
            .accessibilityLabel("Switch model")
            .accessibilityValue(chipLabel)
            if chat.isRunning, let n = chat.runtimeNotice {
                Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    /// Handles `/model` and `/effort` lines. They are never sent to the agent. Returns true when
    /// the draft is such a command (the draft is cleared once it has been applied).
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
            if await chat.followUp(text, mode: mode, attachments: files), chat.draft == draftAtSend, chat.pastedTexts == pastedAtSend {
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
    @State private var showFull = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var quoted: String {
        let clipped = item.text.count > 600 ? String(item.text.prefix(600)) + "…" : item.text
        return clipped.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
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
    private var userIsLong: Bool { item.text.count > 700 || item.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 14 }
    private var userText: String {
        guard userIsLong, !showFull else { return item.text }
        let head = item.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(10).joined(separator: "\n")
        return String(head.prefix(600)) + "…"
    }

    private var pinMark: some View {
        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
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
                            Text(userText)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .foregroundStyle(.white)
                                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(Color.orange, lineWidth: highlighted ? 2.5 : 0))
                                .contextMenu { messageMenu }
                        }
                    }
                    if userIsLong {
                        Button(showFull ? "Show less" : "Show full message") { withAnimation(.snappy) { showFull.toggle() } }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .assistant:
            // Replies run full width without a bubble (as in T3 and the desktop app): more of the
            // conversation fits on screen, and code blocks get the whole line.
            VStack(alignment: .leading, spacing: 6) {
                if !item.text.isEmpty {
                    MarkdownText(text: item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(highlighted ? Color.orange.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) { if pinned { pinMark.offset(x: 2, y: -2) } }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contextMenu { messageMenu }
                }
                TranscriptImages(refs: item.media, profile: profile, session: session, alignment: .leading)
                if showActions || item.footer != nil {
                    HStack(spacing: 2) {
                        if showActions, !item.text.isEmpty {
                            ActionIcon(symbol: "doc.on.doc", label: "Copy reply") { Clipboard.copy(MarkdownBlock.plainText(item.text)) }
                            if let onPin {
                                ActionIcon(symbol: pinned ? "pin.slash" : "pin", label: pinned ? "Unpin" : "Pin", action: onPin)
                            }
                            if let onCompose {
                                ActionIcon(symbol: "text.quote", label: "Reply with quote") { onCompose(quoted, false) }
                            }
                            ShareLink(item: item.text) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 13)).frame(width: 32, height: 28)
                            }
                            .foregroundStyle(.secondary)
                        }
                        if let f = item.footer {
                            Label(f, systemImage: "cpu").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                .padding(.leading, showActions ? 6 : 0)
                                .accessibilityLabel("Answered by \(f)")
                        }
                        if showActions, let ts = item.timestamp {
                            Text(Date(timeIntervalSince1970: ts), style: .time).font(.caption2).foregroundStyle(.tertiary)
                                .padding(.leading, 6)
                        }
                    }
                    .padding(.leading, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
        case .control:
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text).textSelection(.enabled)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.up.right")
                    Text(item.footer ?? "Received")
                    if let ts = item.timestamp { Text(Date(timeIntervalSince1970: ts), style: .time) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 14)
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
                Label(item.activities.isEmpty
                      ? "\(item.tools.count) tool call\(item.tools.count == 1 ? "" : "s")"
                      : ToolLanguage.summary(item.activities),
                      systemImage: "wrench.and.screwdriver")
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
            Text(item.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
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

    static func summary(_ rows: [ToolActivity]) -> String {
        var ran = 0, explored = 0, searched = 0, delegated = 0, skills = 0, other = 0
        for row in rows {
            switch row.name {
            case "terminal", "execute_code": ran += 1
            case "read_file", "search_files", "list_files": explored += 1
            case "web_search", "web_extract": searched += 1
            case "delegate_task": delegated += 1
            case "skill_view": skills += 1
            default: other += 1
            }
        }
        var parts: [String] = []
        if skills > 0 { parts.append(skills == 1 ? "Loaded a skill" : "Loaded \(skills) skills") }
        if explored > 0 { parts.append(explored == 1 ? "Explored files" : "Explored \(explored) places") }
        if ran > 0 { parts.append(ran == 1 ? "Ran 1 command" : "Ran \(ran) commands") }
        if searched > 0 { parts.append(searched == 1 ? "Searched" : "Searched \(searched) times") }
        if delegated > 0 { parts.append(delegated == 1 ? "Delegated a task" : "Delegated \(delegated) tasks") }
        if other > 0 { parts.append(other == 1 ? "1 other action" : "\(other) other actions") }
        var text = parts.isEmpty ? "\(rows.count) tool calls" : parts.joined(separator: ", ")
        let failed = rows.filter { $0.state == "failed" }.count
        if failed > 0 { text += failed == 1 ? " · 1 failed" : " · \(failed) failed" }
        if rows.contains(where: { $0.state == "running" }) { text += " · still running" }
        return text
    }
}

private struct SlashMenu: View {
    let commands: [SlashCommand]
    let skills: [String]
    let filter: String
    let pick: (String) -> Void

    var body: some View {
        // Every match, not the first eight: the list scrolls. (A cap hid /learn behind the alphabet.)
        let shown = commands.filter { filter.isEmpty || $0.name.hasPrefix(filter) }
        let skillHits = skills.filter { filter.isEmpty || $0.hasPrefix(filter) }.prefix(filter.isEmpty ? 12 : 40)
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
                        ForEach(Array(skillHits), id: \.self) { name in
                            Button { pick(name) } label: {
                                Text("/" + name).font(.subheadline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
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
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        Text(pin.excerpt).font(.footnote).lineLimit(1).foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pinned message \(cursor + 1) of \(pins.count): \(pin.excerpt)")
            .accessibilityHint("Jumps to it, then shows the next pin")
            Button(action: list) {
                Image(systemName: "list.bullet").frame(width: 44, height: 36)
            }
            .accessibilityLabel("All pinned messages")
        }
        .padding(.leading, 14).padding(.vertical, 6)
        .background(.bar)
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
                    .fill(window + slot == current ? Color.orange : Color.orange.opacity(0.3))
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        case "ok": ("checkmark.circle.fill", .green)
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
                    .font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
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
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
struct CommandsSheet: View {
    let commands: [SlashCommand]
    let skills: [String]
    let pick: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(String, [SlashCommand])] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

    private var skillHits: [String] {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return skills.filter { q.isEmpty || $0.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { category, rows in
                    Section(category) {
                        ForEach(rows) { command in
                            Button { pick(command.name); dismiss() } label: {
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
                if !skillHits.isEmpty {
                    Section("Skills · \(skillHits.count)") {
                        ForEach(skillHits, id: \.self) { name in
                            Button { pick(name); dismiss() } label: {
                                Text("/" + name).font(.callout.monospaced())
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .overlay {
                if grouped.isEmpty && skillHits.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a command or skill")
            .navigationTitle("Commands · \(commands.count + skills.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The small "Copied" pill that confirms any copy in the chat.
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
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 32, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }
}
