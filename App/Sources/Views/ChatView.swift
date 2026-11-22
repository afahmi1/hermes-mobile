import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let ref: ChatRef

    var body: some View {
        ChatScreen(chat: app.chat(for: ref), draftKey: ref.id)
    }
}

struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    let draftKey: String
    @State private var draft = ""
    @State private var showRuntime = false
    @State private var sendTick = 0
    @FocusState private var composerFocused: Bool

    private var bot: Bot? { app.bot(chat.profile) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chat.hasOlder && !chat.isRunning {
                        Button(chat.loadingOlder ? "Loading earlier messages…" : "Load earlier messages") {
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
            .onChange(of: chat.items.last?.text) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.items.last?.id) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
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
            }
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionBadge()
            }
        }
        .sheet(isPresented: $showRuntime) {
            RuntimeSheet(profile: chat.profile, bot: bot, current: chat.choice, served: chat.served,
                         sessionId: chat.sessionId) { choice in
                Task { await chat.apply(choice) }
            }
        }
        .sheet(item: $chat.approval) { req in
            ApprovalSheet(req: req) { answer in Task { await chat.answer(req, choice: answer) } }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
        .task(id: chat.followUpNotice) {
            guard chat.followUpNotice != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { chat.followUpNotice = nil }
        }
        .sensoryFeedback(.success, trigger: chat.completedTick)
        .sensoryFeedback(.error, trigger: chat.failedTick)
        .task { await chat.load() }
        .task { await poll() }
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
        let c = chat.choice
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

    private var composer: some View {
        VStack(spacing: 6) {
            if let e = chat.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.footnote)
                    Spacer()
                    Button { chat.error = nil } label: { Image(systemName: "xmark").font(.caption) }
                }
                .padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
            }
            if let note = chat.followUpNotice {
                Text(note).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(bot?.name ?? "Hermes")", text: $draft, axis: .vertical)
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
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            if chat.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 20) {
                    Button { followUp("queue") } label: { Label("Queue next", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    Button { followUp("steer") } label: { Label("Steer now", systemImage: "arrow.turn.up.right") }
                    Spacer()
                }
                .font(.subheadline.weight(.medium)).disabled(!chat.acceptsFollowUp)
                .padding(.horizontal, 16).padding(.bottom, 5)
            }
        }
        .padding(.top, 6)
        .background(.bar)
    }

    private func followUp(_ mode: String) {
        let text = draft
        Task {
            if await chat.followUp(text, mode: mode), draft == text { draft = "" }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        sendTick += 1
        Task {
            await chat.send(text)
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

struct MessageRow: View {
    @State private var toolsExpanded = false
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    let answer: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(req.description) }
                if !req.command.isEmpty {
                    Section("Command") { Text(req.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
                Section {
                    ForEach(req.choices, id: \.self) { c in
                        Button(role: c == "deny" ? .destructive : nil) { answer(c); dismiss() } label: { Text(label(c)) }
                    }
                }
            }
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
