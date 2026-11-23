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
    @FocusState private var composerFocused: Bool
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
                    } label: { Label("Latest", systemImage: "arrow.down") }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
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
                ConnectionBadge()
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
        .onChange(of: chat.draft) { old, new in
            // A huge paste leaves the composer and rides as a removable chip (T3-style).
            if let paste = PasteSplit.insertion(old: old, new: new) {
                chat.absorbPaste(paste)
                chat.draft = old
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .any(of: [.images, .videos]))
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
                        if account == app.inboxAccount { chat.draftAttachments.append(try ChatMedia.jpeg(preview, name: "Camera")) }
                    } catch { chat.error = error.localizedDescription }
                }
            }.ignoresSafeArea()
        }
        .confirmationDialog("How should Hermes receive this video?", isPresented: $chooseVideo) {
            if mediaCapabilities?.video == true, chat.draftAttachments.isEmpty {
                Button("Send clip for Hermes video analysis") { prepareClip() }
            }
            Button("Choose from up to 3 frames") { prepareFrames() }
            Button("Cancel", role: .cancel) { discardVideo() }
        } message: { Text(mediaCapabilities?.video == true ? "A clip includes audio and may be processed by the gateway’s video provider. Frames are still images you can review before sending." : "This gateway accepts still images. Review and remove frames before sending. Frames contain no audio.") }
        .onDisappear { discardVideo() }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .sensoryFeedback(.success, trigger: chat.completedTick)
        .sensoryFeedback(.error, trigger: chat.failedTick)
        .task { await chat.load() }
        .task(id: chat.profile) { mediaCapabilities = try? await API.shared.mediaCapabilities(profile: chat.profile) }
        .task(id: scenePhase) { if scenePhase == .active { await poll() } }
        .refreshable { await chat.load() }
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
        !chat.isRunning && (imagesAvailable || filesAvailable)
    }

    private var attachmentLimitReached: Bool {
        chat.draftAttachments.count >= 4 || chat.draftAttachments.contains { $0.mime == "video/mp4" }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let e = chat.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.footnote)
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
            if !chat.pastedTexts.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.pastedTexts) { chunk in
                            PasteChip(text: chunk.text) { chat.removePastedText(chunk.id) }
                        }
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden)
            }
            if !chat.draftAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(chat.draftAttachments.enumerated()), id: \.offset) { index, asset in
                            AttachmentChip(attachment: asset) {
                                if chat.draftAttachments.indices.contains(index) { chat.draftAttachments.remove(at: index) }
                            }
                        }
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if canAttach {
                    Menu {
                        if imagesAvailable {
                            Button { showPicker = true } label: { Label("Photo or video", systemImage: "photo.on.rectangle") }
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
                TextField("Message \(bot?.name ?? "Hermes")", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                if chat.isRunning {
                    Button { Task { await chat.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(preparingMedia || chat.savingRuntime || (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty && chat.pastedTexts.isEmpty))
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

    private func importMedia(_ item: PhotosPickerItem) async {
        preparingMedia = true
        defer { preparingMedia = false; pickerItem = nil }
        do {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                discardVideo()
                pickedVideo = try await MediaImport.videoFile(from: item)
                chooseVideo = true
            } else {
                let data = try await MediaImport.imageData(from: item)
                if Task.isCancelled { return }
                let asset = try await Task.detached(priority: .userInitiated) { try ChatMedia.image(from: data) }.value
                if !Task.isCancelled { chat.draftAttachments.append(asset) }
            }
        } catch { if !Task.isCancelled { chat.error = error.localizedDescription } }
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
                let original = chat.draftAttachments
                var added: [SendAttachment] = []
                var left = cap - original.reduce(0) { $0 + $1.byteCount }
                for url in urls {
                    if Task.isCancelled { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? UTType(filenameExtension: url.pathExtension)
                        if type?.conforms(to: .movie) == true {
                            guard urls.count == 1 else { chat.error = "Choose a video on its own to review the clip or frames."; return }
                            let snapshot = try await Task.detached { try MediaStaging.stage(url) }.value
                            guard account == app.inboxAccount else { try? FileManager.default.removeItem(at: snapshot); return }
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
                guard chat.draftAttachments == original, account == app.inboxAccount else { return }
                chat.draftAttachments.append(contentsOf: added)
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
                if account == app.inboxAccount { chat.draftAttachments = [clip] }
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
                if account == app.inboxAccount { chat.draftAttachments += frames }
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
        let text = chat.combinedDraft
        let attachments = chat.draftAttachments
        let budget = mediaCapabilities?.maxFileBytes ?? 4 * 1024 * 1024
        guard attachments.reduce(0, { $0 + $1.byteCount }) <= budget else {
            chat.error = "The attachments exceed this bot’s limit. Remove an attachment and try again."
            return
        }
        chat.draft = ""
        chat.pastedTexts = []
        followLatest = true
        sendTick += 1
        let context = ProjectContext.chosen(scope: projectScope?.projectID, optedIn: includeProjectContext && !chat.isRunning)
        includeProjectContext = false  // ask every send
        Task {
            await chat.send(text, projectContext: context, attachments: attachments)
            app.adopt(chat, draftKey: draftKey)
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

/// A collapsed long paste, removable before send.
struct PasteChip: View {
    let text: String
    let remove: () -> Void
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard").font(.caption)
                Text("Pasted text · \(text.count.formatted()) characters").font(.caption2).lineLimit(1)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove pasted text, \(text.count) characters")
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
