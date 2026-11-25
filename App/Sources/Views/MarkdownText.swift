import SwiftUI
import UIKit

// MARK: - Copy

extension Notification.Name {
    /// Posted after any copy, so the chat screen can flash a small "Copied" pill.
    static let hermesCopied = Notification.Name("hermesCopied")
}

enum Clipboard {
    static func copy(_ text: String, what: String = "Copied") {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        NotificationCenter.default.post(name: .hermesCopied, object: what)
    }
}

// MARK: - Inline

enum InlineMarkdown {
    static let copyScheme = "hermes-copy"

    /// Inline Markdown with `code` spans styled as chips that copy themselves when tapped.
    static func attributed(_ s: String, codeTint: Color = .accentColor) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            let code = String(out[run.range].characters)
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#")
            if let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed),
               let url = URL(string: "\(copyScheme)://inline?t=\(encoded)") {
                out[run.range].link = url
            }
            out[run.range].font = .system(.subheadline, design: .monospaced)
            out[run.range].backgroundColor = Color(.tertiarySystemFill)
            out[run.range].foregroundColor = codeTint
            out[run.range].underlineStyle = nil
        }
        return out
    }

    static func copiedText(_ url: URL) -> String? {
        guard url.scheme == copyScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == "t" }?.value
    }

    /// Plain text of inline Markdown (for copy-as-text and accessibility).
    static func plain(_ s: String) -> String { String(attributed(s).characters) }
}

// MARK: - View

/// A Hermes reply: headings, lists, quotes, tables and code blocks with a language label and a Copy button.
/// Inline `code` copies on tap. The whole message can still be selected from its menu (Select Text).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: HMDesign.medium) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let code = InlineMarkdown.copiedText(url) {
                Clipboard.copy(code)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(InlineMarkdown.attributed(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(InlineMarkdown.attributed(s))
                .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(item.marker.hasSuffix(".") ? .body.monospacedDigit() : .body)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(InlineMarkdown.attributed(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(InlineMarkdown.attributed(s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let body, let closed, let file):
            CodeBlockView(language: language, code: body, streaming: !closed, file: file)
        case .callout(let kind, let s):
            CalloutView(kind: kind, text: s)
        case .table(let rows):
            TableBlockView(rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// A fenced code block. Header: a file name when the fence names one, else the language ("Bash", "C++"), then
/// Wrap and Copy. Long-press the code for Copy as Markdown. Long blocks fold, so a 400-line log never buries the chat.
struct CodeBlockView: View {
    let language: String
    let code: String
    var streaming = false
    var foldAfter = 24
    var title: String?
    var file: String?
    @State private var copied = false
    @State private var expanded = false
    @State private var wrap = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }
    private var label: String { file ?? title ?? MarkdownBlock.languageName(language) }
    private var fenced: String { "```" + language + "\n" + code + "\n```" }

    var body: some View {
        let folded = !expanded && lines.count > foldAfter + 4
        let shown = folded ? lines.prefix(foldAfter).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: HMDesign.micro))
            layout {
                HStack(spacing: HMDesign.micro) {
                    Label(label, systemImage: file != nil ? "doc.text" : "chevron.left.forwardslash.chevron.right")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                    if streaming { ProgressView().controlSize(.mini).accessibilityLabel("Receiving code") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, HMDesign.medium)
                HStack(spacing: 0) {
                    Button { withAnimation(reduceMotion ? nil : .snappy) { wrap.toggle() } } label: {
                        Image(systemName: "text.alignleft").font(.footnote).hmTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(wrap ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(wrap ? "Stop wrapping lines" : "Wrap lines")
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, HMDesign.small).hmTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Color.primary : Color.accentColor)
                    .disabled(streaming)
                    .accessibilityLabel(copied ? "Copied" : "Copy \(label)")
                }
            }
            .padding(.top, typeSize.isAccessibilitySize ? HMDesign.small : 0)
            .background(Color(uiColor: .tertiarySystemFill))
            Group {
                if wrap {
                    Text(shown).font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(shown).font(.system(.footnote, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(12)
                    }
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { Clipboard.copy(fenced, what: "Copied as Markdown") } label: { Label("Copy as Markdown", systemImage: "text.badge.checkmark") }
                Button { wrap.toggle() } label: { Label(wrap ? "Don't Wrap Lines" : "Wrap Lines", systemImage: "text.alignleft") }
                ShareLink(item: code)
            }
            if lines.count > foldAfter + 4 {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: HMDesign.touch)
                .background(Color(.tertiarySystemFill).opacity(0.6))
            }
        }
        .background(HMDesign.panel)
        .clipShape(RoundedRectangle(cornerRadius: HMDesign.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: HMDesign.panelRadius).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
    }

    private func copy() {
        // A trailing newline is noise in a terminal paste.
        var text = code
        while text.hasSuffix("\n") { text.removeLast() }
        Clipboard.copy(text, what: "Copied code")
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.snappy) { copied = false }
        }
    }
}

/// `> [!NOTE]` and friends: a tinted box with an icon, like GitHub alerts.
struct CalloutView: View {
    let kind: String
    let text: String

    private var style: (title: String, icon: String, color: Color) {
        switch kind {
        case "tip": ("Tip", "lightbulb.fill", .green)
        case "important": ("Important", "exclamationmark.bubble.fill", .purple)
        case "warning": ("Warning", "exclamationmark.triangle.fill", .orange)
        case "caution": ("Caution", "octagon.fill", .red)
        default: ("Note", "info.circle.fill", .blue)
        }
    }

    var body: some View {
        let s = style
        VStack(alignment: .leading, spacing: 4) {
            Label(s.title, systemImage: s.icon)
                .font(.subheadline.weight(.semibold))
                .labelStyle(CalloutLabelStyle(color: s.color))
            if !text.isEmpty {
                Text(InlineMarkdown.attributed(text)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HMDesign.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(s.color.opacity(0.08), in: RoundedRectangle(cornerRadius: HMDesign.panelRadius))
    }

    private struct CalloutLabelStyle: LabelStyle {
        let color: Color

        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: HMDesign.small) {
                configuration.icon.foregroundStyle(color)
                configuration.title.foregroundStyle(.primary)
            }
        }
    }
}

/// A Markdown table as a small scrollable grid, with Copy (as Markdown, so it pastes into notes intact).
struct TableBlockView: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(0..<width, id: \.self) { column in
                                Text(InlineMarkdown.attributed(column < row.count ? row[column] : ""))
                                    .font(index == 0 ? .footnote.weight(.semibold) : .footnote)
                                    .fixedSize()
                            }
                        }
                        if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            Button {
                Clipboard.copy(rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n"), what: "Copied table")
            } label: { Label("Copy table", systemImage: "doc.on.doc").font(.caption).hmTouchTarget() }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}

/// The whole message in a selectable text view: pick any span and copy it, like Telegram's Select.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, 12)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Copy all") { Clipboard.copy(text); dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = [.link]
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
