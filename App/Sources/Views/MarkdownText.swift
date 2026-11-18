import SwiftUI

/// Lightweight Markdown: inline styling via AttributedString, fenced code blocks as scrollable monospace.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(Self.inline(s)).textSelection(.enabled)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(10)
                    }
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private enum Block { case prose(String), code(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                var lines = part.components(separatedBy: "\n")
                if let first = lines.first, !first.contains(" "), first.count < 20 { lines.removeFirst() }  // language tag
                out.append(.code(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else {
                let s = part.trimmingCharacters(in: .newlines)
                if !s.isEmpty { out.append(.prose(s)) }
            }
        }
        return out.isEmpty ? [.prose(text)] : out
    }

    static func inline(_ s: String) -> AttributedString {
        // Headings and bullets read fine as plain lines; tidy the markers.
        let cleaned = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasPrefix("#") { l.removeFirst() }
            if l != line { return "**" + l.trimmingCharacters(in: .whitespaces) + "**" }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return "•  " + line.dropFirst(2) }
            return line
        }.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: cleaned, options: opts)) ?? AttributedString(s)
    }
}
