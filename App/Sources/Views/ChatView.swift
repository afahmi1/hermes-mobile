import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

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
                    ForEach(chat.items) { item in
                        MessageRow(item: item).id(item.id)
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
                    ConnectionBadge()
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
        if chat.isRunning, chat.runtimeNotice != nil { return "Next · " + (c.model ?? bot?.model ?? "Bot default") }
        let model = c.model ?? bot?.model ?? "default"
        let effort = c.effort.flatMap { Effort(rawValue: $0)?.label } ?? "default effort"
        return c.isDefault ? "\(model) · bot default" : "\(model) · \(effort)"
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

    private var filesAvailable: Bool { mediaCapabilities?.files == true }

    private var canAttach: Bool {
        !chat.isRunning && (imagesAvailable || filesAvailable || mediaCapabilities?.video == true)
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
        ComposerField(text: $chat.draft, placeholder: "Message \(bot?.name ?? "Hermes")",
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
            draftShelf
            HStack(alignment: .bottom, spacing: 8) {
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
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(attachmentLimitReached || preparingMedia)
                    .accessibilityLabel("Add photo, video or file")
                }
                composerField(expanded: false)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .bottom)

                Button { showFullComposer = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Expand composer")
                if chat.isRunning {
                    Button { Task { await chat.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(.red)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(preparingMedia || chat.savingRuntime || (chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty))
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            if chat.isRunning {
                HStack(spacing: 20) {
                    Button { followUp("queue") } label: { Label("Send next", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    Button { followUp("steer") } label: { Label("Guide this reply", systemImage: "arrow.turn.up.right") }
                    Spacer()
                }
                .font(.subheadline.weight(.medium)).disabled(!chat.acceptsFollowUp || chat.combinedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 16).padding(.bottom, 5)
            }
        }
        .padding(.top, 6)
        .background(.bar)
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
        guard !chat.isRunning else { chat.error = "You can attach images when the current reply finishes."; return }
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

    private func followUp(_ mode: String) {
        let draftAtSend = chat.draft
        let pastedAtSend = chat.pastedTexts
        let text = chat.combinedDraft
        Task {
            if await chat.followUp(text, mode: mode), chat.draft == draftAtSend, chat.pastedTexts == pastedAtSend {
                chat.draft = ""
                chat.pastedTexts = []
            }
        }
    }

    private func send() {
        let attachments = chat.draftAttachments
        let text = chat.combinedDraft
        if let problem = issue(for: attachments) {
            chat.error = problem
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
        let height = min(max(uiView.textHeight(forWidth: width), line), line * 8)
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
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if let note = item.contextNote {
                        Label(note, systemImage: "folder.badge.gearshape").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(item.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if item.streaming { Text(verbatim: item.text).textSelection(.enabled) }
                    else { MarkdownText(text: item.text) }
                }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = item.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        ShareLink(item: item.text)
                    }
                if let f = item.footer {
                    Label(f, systemImage: "cpu").font(.caption2).foregroundStyle(.secondary).padding(.leading, 10)
                        .accessibilityLabel("Answered by \(f)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.trailing, 28)
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.tools.enumerated()), id: \.offset) { _, tool in
                        Text(tool.replacingOccurrences(of: "_", with: " ")).font(.caption.monospaced())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("\(item.tools.count) tool call\(item.tools.count == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
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
