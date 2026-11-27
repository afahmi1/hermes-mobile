import SwiftUI
import UIKit

// MARK: - Copy

extension Notification.Name {
    /// Posted after any copy, so the chat screen can flash a small "Copied" pill.
    static let hermesCopied = Notification.Name("hermesCopied")
    /// Posted after the app returns from the background and its connections were reset.
    static let hermesForeground = Notification.Name("hermesForeground")
    /// A file path in a reply was tapped; the chat downloads it through the bridge and opens Quick Look.
    static let hermesOpenPath = Notification.Name("hermesOpenPath")
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
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) && !trimmed.contains(" "), let open = pathLink(trimmed) {
                out[run.range].link = open  // a path chip opens the file; Select Text still copies it
            } else if let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed),
               let url = URL(string: "\(copyScheme)://inline?t=\(encoded)") {
                out[run.range].link = url
            }
            out[run.range].font = HMTheme.isThermocline ? HMType.mono(.subheadline) : .system(.subheadline, design: .monospaced)
            out[run.range].backgroundColor = HMTheme.isThermocline ? Thermocline.surface3 : Color(.tertiarySystemFill)
            out[run.range].foregroundColor = HMTheme.isThermocline ? HMDesign.link : codeTint
            out[run.range].underlineStyle = nil
        }
        for run in out.runs {
            if let link = run.link, link.scheme?.hasPrefix("http") == true { out[run.range].link = phoneURL(link) }
        }
        linkify(&out)
        if HMTheme.isThermocline {
            for run in out.runs where run.link != nil { out[run.range].foregroundColor = HMDesign.link }
        }
        return out
    }

    static let fileScheme = "hermes-file"
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.~/])((?:~|/(?:Users|tmp|private|var|opt|Volumes|home))/[^\s`'"<>()\[\]{}|]+)"#)
    private static let localPattern = try! NSRegularExpression(
        pattern: #"\bhttps?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})?(?:/[^\s`'"<>)\]]*)?"#)

    /// localhost on the Mac means nothing on a phone: point it at the Mac's tailnet name instead. Works when
    /// the dev server listens on all interfaces (vite --host, next -H 0.0.0.0).
    static func phoneURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "0.0.0.0"].contains(host),
              let mac = API.shared.baseURL?.host, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.host = mac
        return parts.url ?? url
    }

    static func pathLink(_ path: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "\(fileScheme)://open?p=\($0)") }
    }

    static func openedPath(_ url: URL) -> String? {
        guard url.scheme == fileScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value
    }

    /// File paths and localhost URLs in plain text become links.
    private static func linkify(_ out: inout AttributedString) {
        let plain = String(out.characters)
        let ns = plain as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func apply(_ range: NSRange, _ url: URL) {
            guard let r = Range(range, in: plain),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { return }
            if out[lower..<upper].runs.contains(where: { $0.link != nil }) { return }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        for m in localPattern.matches(in: plain, range: whole) {
            if let url = URL(string: ns.substring(with: m.range)) { apply(m.range, phoneURL(url)) }
        }
        for m in pathPattern.matches(in: plain, range: whole) {
            var path = ns.substring(with: m.range(at: 1))
            while let last = path.last, ".,:;!?".contains(last) { path.removeLast() }
            if let url = pathLink(path) { apply(NSRange(location: m.range(at: 1).location, length: (path as NSString).length), url) }
        }
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
    /// "Reply with quote" in the selection menu: the selected words.
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.openURL) private var openURL

    /// Prose blocks next to each other render as one native text view, so a long-press selects any range
    /// across paragraphs, lists and headings (like T3). Code, tables and callouts keep their own views.
    private enum Group { case prose([MarkdownBlock]), other(MarkdownBlock) }
    private var groups: [Group] {
        var out: [Group] = []
        for block in MarkdownBlock.parse(text) {
            switch block {
            case .paragraph, .heading, .list, .quote:
                if case .prose(var run)? = out.last { run.append(block); out[out.count - 1] = .prose(run) }
                else { out.append(.prose([block])) }
            default: out.append(.other(block))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HMDesign.medium) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case .prose(let blocks): ProseText(blocks: blocks, onQuote: onQuote)
                case .other(let block): view(for: block)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let code = InlineMarkdown.copiedText(url) {
                Clipboard.copy(code)
                return .handled
            }
            if let path = InlineMarkdown.openedPath(url) {
                NotificationCenter.default.post(name: .hermesOpenPath, object: path)
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
                .font(level == 1 ? .title3.weight(HMTheme.isThermocline ? .semibold : .bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .tracking(HMTheme.isThermocline ? -0.3 : 0)
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(item.marker.hasSuffix(".") ? .body.monospacedDigit() : .body)
                            .foregroundStyle(HMDesign.text2)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(InlineMarkdown.attributed(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(HMDesign.text2.opacity(0.5)).frame(width: 3)
                Text(InlineMarkdown.attributed(s)).foregroundStyle(HMDesign.text2).fixedSize(horizontal: false, vertical: true)
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
                        .font(HMTheme.isThermocline ? HMType.meta.weight(.medium) : .caption.weight(.medium))
                        .foregroundStyle(HMDesign.text2)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                    if streaming { ProgressView().controlSize(.mini).accessibilityLabel("Receiving code") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, HMDesign.medium)
                HStack(spacing: 0) {
                    Button { withAnimation(HMMotion.standard) { wrap.toggle() } } label: {
                        Image(systemName: "text.alignleft").font(.footnote).hmTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(wrap ? HMDesign.accent : HMDesign.text2)
                    .accessibilityLabel(wrap ? "Stop wrapping lines" : "Wrap lines")
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, HMDesign.small).hmTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? HMDesign.ink : HMDesign.accent)
                    .disabled(streaming)
                    .accessibilityLabel(copied ? "Copied" : "Copy \(label)")
                }
            }
            .padding(.top, typeSize.isAccessibilitySize ? HMDesign.small : 0)
            .background(HMTheme.isThermocline ? Thermocline.surface1 : Color(uiColor: .tertiarySystemFill))
            .overlay(alignment: .bottom) {
                if HMTheme.isThermocline { Rectangle().fill(Thermocline.line).frame(height: 0.5) }
            }
            Group {
                if wrap {
                    Text(shown).font(HMTheme.isThermocline ? HMType.data : .system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(shown).font(HMTheme.isThermocline ? HMType.data : .system(.footnote, design: .monospaced))
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
                    withAnimation(HMMotion.standard) { expanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: HMDesign.touch)
                .background(HMTheme.isThermocline ? Thermocline.surface1 : Color(.tertiarySystemFill).opacity(0.6))
            }
        }
        .background(HMTheme.isThermocline ? Thermocline.surface3 : HMDesign.panel)
        .clipShape(RoundedRectangle(cornerRadius: HMDesign.panelRadius, style: HMTheme.isThermocline ? .continuous : .circular))
        .overlay(RoundedRectangle(cornerRadius: HMDesign.panelRadius, style: HMTheme.isThermocline ? .continuous : .circular)
            .strokeBorder(HMTheme.isThermocline ? Thermocline.lineStrong : HMDesign.separator.opacity(0.5), lineWidth: 0.5))
    }

    private func copy() {
        // A trailing newline is noise in a terminal paste.
        var text = code
        while text.hasSuffix("\n") { text.removeLast() }
        Clipboard.copy(text, what: "Copied code")
        withAnimation(HMMotion.standard) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(HMMotion.standard) { copied = false }
        }
    }
}

/// `> [!NOTE]` and friends: a tinted box with an icon, like GitHub alerts.
struct CalloutView: View {
    let kind: String
    let text: String

    private var style: (title: String, icon: String, color: Color) {
        switch kind {
        case "tip": ("Tip", "lightbulb.fill", HMTheme.isThermocline ? HMDesign.success : .green)
        case "important": ("Important", "exclamationmark.bubble.fill", HMDesign.plum)
        case "warning": ("Warning", "exclamationmark.triangle.fill", HMDesign.caution)
        case "caution": ("Caution", "octagon.fill", HMDesign.danger)
        default: ("Note", "info.circle.fill", HMDesign.link)
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
        .background(HMTheme.isThermocline ? HMDesign.panel : s.color.opacity(0.08), in: RoundedRectangle(cornerRadius: HMDesign.panelRadius))
        .overlay(alignment: .leading) {
            if HMTheme.isThermocline {
                Capsule().fill(s.color).frame(width: 2).padding(.vertical, HMDesign.small)
            }
        }
    }

    private struct CalloutLabelStyle: LabelStyle {
        let color: Color

        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: HMDesign.small) {
                configuration.icon.foregroundStyle(color)
                configuration.title.foregroundStyle(HMDesign.ink)
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
            .background(HMDesign.panel, in: RoundedRectangle(cornerRadius: 10))
            Button {
                Clipboard.copy(rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n"), what: "Copied table")
            } label: { Label("Copy table", systemImage: "doc.on.doc").font(.caption).hmTouchTarget() }
            .buttonStyle(.plain).foregroundStyle(HMDesign.text2)
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
                .hmCanvas()
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

// MARK: - Native selectable prose

/// Paragraphs, headings, lists and quotes as one UITextView: real range selection with handles, the system's
/// Copy, plus Copy as Markdown and Reply with quote. Links (paths, inline code chips, URLs) still tap through.
struct ProseText: UIViewRepresentable {
    let blocks: [MarkdownBlock]
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.onQuote = onQuote
        let built = Self.build(blocks)
        context.coordinator.sources = built.sources
        if view.attributedText != built.text { view.attributedText = built.text }
        view.linkTextAttributes = [.foregroundColor: UIColor(HMDesign.link)]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 32
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction?
        var onQuote: ((String) -> Void)?
        /// Each block's character range in the text view and its Markdown source, for Copy as Markdown.
        var sources: [(NSRange, String)] = []

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL?(url) }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let selected = (textView.text as NSString).substring(with: range)
            var extra: [UIMenuElement] = []
            let md = sources.filter { NSIntersectionRange($0.0, range).length > 0 }.map(\.1).joined(separator: "\n\n")
            if !md.isEmpty {
                extra.append(UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.badge.checkmark")) { _ in
                    Clipboard.copy(md, what: "Copied as Markdown")
                })
            }
            if let onQuote, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extra.append(UIAction(title: "Reply with quote", image: UIImage(systemName: "text.quote")) { _ in onQuote(selected) })
            }
            return UIMenu(children: suggestedActions + extra)
        }
    }

    // MARK: building

    static func build(_ blocks: [MarkdownBlock]) -> (text: NSAttributedString, sources: [(NSRange, String)]) {
        let out = NSMutableAttributedString()
        var sources: [(NSRange, String)] = []
        let ink = UIColor(HMDesign.ink), muted = UIColor(HMDesign.text2)
        for (i, block) in blocks.enumerated() {
            let start = out.length
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = i == 0 ? 0 : 10
            para.lineSpacing = 2
            switch block {
            case .paragraph(let s):
                out.append(inline(s, style: .body, color: ink, para: para))
                sources.append((NSRange(location: start, length: out.length - start), s))
            case .heading(let level, let s):
                para.paragraphSpacingBefore = i == 0 ? 0 : (level <= 2 ? 16 : 12)
                let style: UIFont.TextStyle = level == 1 ? .title3 : level == 2 ? .headline : .subheadline
                out.append(inline(s, style: style, color: ink, para: para, bold: true))
                sources.append((NSRange(location: start, length: out.length - start), String(repeating: "#", count: level) + " " + s))
            case .list(let items):
                var md: [String] = []
                for (n, item) in items.enumerated() {
                    let p = NSMutableParagraphStyle()
                    let indent = CGFloat(item.depth) * 16
                    p.firstLineHeadIndent = indent
                    p.headIndent = indent + 20
                    p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                    p.paragraphSpacingBefore = n == 0 ? para.paragraphSpacingBefore : 4
                    p.lineSpacing = 2
                    if n > 0 { out.append(NSAttributedString(string: "\n")) }
                    let marker = item.marker.hasSuffix(".") ? item.marker : "•"
                    out.append(NSAttributedString(string: marker + "\t", attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular),
                        .foregroundColor: muted, .paragraphStyle: p]))
                    out.append(inline(item.text, style: .body, color: ink, para: p))
                    md.append(String(repeating: "  ", count: item.depth) + (item.marker.hasSuffix(".") ? item.marker : "-") + " " + item.text)
                }
                sources.append((NSRange(location: start, length: out.length - start), md.joined(separator: "\n")))
            case .quote(let s):
                para.firstLineHeadIndent = 12
                para.headIndent = 12
                out.append(inline(s, style: .body, color: muted, para: para))
                sources.append((NSRange(location: start, length: out.length - start), "> " + s))
            default:
                break
            }
        }
        return (out, sources)
    }

    /// One block's inline Markdown (bold, italic, code chips, links) in UIKit attributes.
    private static func inline(_ s: String, style: UIFont.TextStyle, color: UIColor, para: NSParagraphStyle,
                               bold: Bool = false) -> NSAttributedString {
        let attributed = InlineMarkdown.attributed(s)
        let base = UIFont.preferredFont(forTextStyle: style)
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            var traits: UIFontDescriptor.SymbolicTraits = bold ? [.traitBold] : []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            var font = base
            if intent.contains(.code) {
                font = UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: .regular)
            } else if !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: d, size: base.pointSize)
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            if intent.contains(.code) { attrs[.backgroundColor] = UIColor.tertiarySystemFill }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
