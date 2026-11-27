import SwiftUI

/// One release's What's new. Newest first; a version without its own list shows the newest below it.
struct WhatsNewRelease: Identifiable, Equatable {
    let version: String
    let items: [WhatsNewItem]
    var id: String { version }
}

/// A feature: an SF Symbol, a short name, one sentence.
struct WhatsNewItem: Identifiable, Equatable {
    let symbol: String
    let title: String
    let detail: String
    var id: String { title }
}

/// What's new, shown once over the chat list on the first open after an update, and any time from Settings.
enum WhatsNew {
    static let seenKey = "hm.whatsNew.seen"

    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.0", items: [
            WhatsNewItem(symbol: "text.quote", title: "Reply to several messages at once",
                         detail: "Tap Reply on each one. A pill stacks up with its own answer, and the newest one's answer is the box. Delete a pill and your words stay."),
            WhatsNewItem(symbol: "dollarsign.circle", title: "What this chat actually cost",
                         detail: "The model sheet says what's answering, what you paid, and which plan covered the rest, model by model. The provider and model lists stay folded until you ask."),
            WhatsNewItem(symbol: "circle.grid.2x2", title: "Bots you can tell apart",
                         detail: "In Thermocline, each bot gets its own color. Choose Every bot, or Per chat + bot for a small badge on the chat's letter."),
            WhatsNewItem(symbol: "circle.dotted", title: "A new look for Thermocline",
                         detail: "The thinking orb spins like it does in Classic. Dark has deeper blues and a faint glow."),
            WhatsNewItem(symbol: "bell.badge", title: "Notifications that tell the truth",
                         detail: "A reply in a chat you aren't looking at notifies even while the app is open. Long-press a notification to reply. When the app is about to sleep mid-reply, it says Hermes is still working."),
            WhatsNewItem(symbol: "bell", title: "A faster handoff when the app sleeps",
                         detail: "When the app goes to sleep mid-reply, it hands off to your Mac faster and more reliably."),
            WhatsNewItem(symbol: "photo.on.rectangle", title: "Images where Hermes mentioned them",
                         detail: "A file path in a reply shows the picture, right there. Several pictures become a row you swipe through, and small ones stay small."),
            WhatsNewItem(symbol: "text.cursor", title: "Select any text in a reply",
                         detail: "Long-press and drag across paragraphs. Copy as Markdown, or Reply with quote, from the selection."),
            WhatsNewItem(symbol: "sparkles", title: "Thinking, out loud",
                         detail: "The status line rotates through something better than \"thinking\". Tap it to read what Hermes is actually thinking, and every step shows when it ran."),
            WhatsNewItem(symbol: "arrow.uturn.backward", title: "Take a message back",
                         detail: "Move back to message box is instant and brings your images with it. Guide this reply now works on a message already on your Mac."),
            WhatsNewItem(symbol: "person.2", title: "Subagents you can tap",
                         detail: "A subagent shows what it was asked, its model, provider, steps and how long it worked."),
            WhatsNewItem(symbol: "arrow.clockwise", title: "Try again when limits reset",
                         detail: "A reply that failed because a limit was hit can retry itself when the limit resets."),
        ]),
    ]

    /// The list for this version: the newest one at or below it.
    static func release(for version: String, in releases: [WhatsNewRelease] = releases) -> WhatsNewRelease? {
        releases
            .filter { version.compare($0.version, options: .numeric) != .orderedAscending }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    static var current: WhatsNewRelease? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return release(for: version)
    }

    /// Due on this launch unless it's a first run (onboarding covers that) or this list already showed.
    static func due(defaults: UserDefaults = .standard) -> WhatsNewRelease? {
        guard let release = current else { return nil }
        // A first run has never seen a list: onboarding covers it, so mark this one seen instead of showing it.
        if defaults.object(forKey: seenKey) == nil, defaults.string(forKey: "server") == nil {
            markSeen(release, defaults: defaults)
            return nil
        }
        return defaults.string(forKey: seenKey) == release.version ? nil : release
    }

    static func markSeen(_ release: WhatsNewRelease, defaults: UserDefaults = .standard) {
        defaults.set(release.version, forKey: seenKey)
    }
}

/// The sheet: a title, the newest release's items, older releases collapsed below, Continue pinned at the bottom.
struct WhatsNewSheet: View {
    let release: WhatsNewRelease
    @Environment(\.dismiss) private var dismiss
    @State private var olderOpen = false

    private var older: [WhatsNewRelease] {
        WhatsNew.releases.filter { $0.version.compare(release.version, options: .numeric) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What's new in Hermes")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(HMDesign.ink)
                    .padding(.top, 36)
                    .padding(.bottom, 6)
                Text(release.version)
                    .font(.subheadline)
                    .foregroundStyle(HMDesign.text2)
                    .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 28) {
                    ForEach(release.items) { item in
                        WhatsNewRow(item: item)
                    }
                }

                if !older.isEmpty {
                    Button {
                        withAnimation(.snappy) { olderOpen.toggle() }
                    } label: {
                        HStack {
                            Text("Earlier releases").font(.subheadline.weight(.semibold)).foregroundStyle(HMDesign.ink)
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(olderOpen ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 36)
                    if olderOpen {
                        ForEach(older) { past in
                            Text(past.version)
                                .font(.caption.weight(.semibold)).foregroundStyle(HMDesign.text2)
                                .padding(.top, 22)
                            VStack(alignment: .leading, spacing: 22) {
                                ForEach(past.items) { item in WhatsNewRow(item: item) }
                            }
                            .padding(.top, 14)
                        }
                    }
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Continue") { dismiss() }
                .buttonStyle(HMButtonStyle(kind: .primary))
                .frame(maxWidth: 500)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(HMDesign.canvas)
        }
        .background(HMDesign.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(HMDesign.canvas)
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HMDesign.accent)
                .frame(width: 36, height: 36)
                .background(HMDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(HMDesign.ink)
                Text(item.detail).font(.system(size: 15)).foregroundStyle(HMDesign.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
