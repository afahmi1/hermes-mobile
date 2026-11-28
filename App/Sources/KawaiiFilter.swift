import Foundation

/// Presentation only: keep the original gateway text so the preference can change during a reply.
enum KawaiiFilter {
    static let key = "hm.kawaiiFaces"

    // Hermes Agent, agent/display.py: KawaiiSpinner.KAWAII_WAITING / KAWAII_THINKING.
    private static let stock = [
        "(｡◕‿◕｡)", "(◕‿◕✿)", "٩(◕‿◕｡)۶", "(✿◠‿◠)", "( ˘▽˘)っ", "♪(´ε` )", "(◕ᴗ◕✿)", "ヾ(＾∇＾)", "(≧◡≦)", "(★ω★)",
        "(｡•́︿•̀｡)", "(◔_◔)", "(¬‿¬)", "( •_•)>⌐■-■", "(⌐■_■)", "(´･_･`)", "◉_◉", "(°ロ°)", "( ˘⌣˘)♡", "ヽ(>∀<☆)☆",
        "٩(๑❛ᴗ❛๑)۶", "(⊙_⊙)", "(¬_¬)", "( ͡° ͜ʖ ͡°)", "ಠ_ಠ",
    ]

    // Skins can use other faces. Require a face-like alphabet and at least two distinctive
    // glyphs (or a compact ASCII eye/mouth/eye), not just a run of punctuation or math operators.
    private static let marks = "｡･・。．；︿﹏‿⌣ᴗᵕᴥ◡◠◕◔◉⊙⦿•●○°˚˘´｀`¯¬ಥಠ益Ддロωεʖ∀▽∇△≧≦＾￣눈╹๑❛❜★☆✧✿♡♥＞＜゜しっつᗜᵔ˙꒳≖◜◝ꈍꇴꌂʕʔ"
    private static let distinctive = Set(marks.unicodeScalars)
    private static let mouths = Set("_‿⌣ᴗᵕᴥ︿﹏ωДдロ益εʖ∀▽∇△ᗜ꒳".unicodeScalars)
    private static let skinExceptions: Set<String> = [
        "(^_^)", "(>_<)", "(T_T)", "(;_;)", "(o_o)", "(O_O)", "(-_-)",
        "^_^", ">_<", "T_T", ";_;", "o_o", "O_O", "-_-", #"¯\_(ツ)_/¯"#,
    ]

    private static let candidates: NSRegularExpression = {
        // Protect fenced and inline code first, including an unfinished streamed fence.
        let code = #"(?m:^[ \t]{0,3}(`{3,}|~{3,})[^\r\n]*(?:\r?\n|\z)[\s\S]*?(?:^[ \t]{0,3}\1[ \t]*(?=\r?$)|\z))|(`+)[^\r\n]*?\2(?!`)"#
        let exact = stock.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let inner = "[" + marks + #"\p{M}0OoTtUuXxWwvV^_<>=;:,.'*\-]"#
        let arms = #"[ヽヾ٩۶ノシ丿っつづ彡งʕʔ♪☆♡✧]"#
        let ascii = #"(?:\^_\^|>_<|T_T|;_;|o_o|O_O|-_-)"#
        let custom = #"¯\\_\(ツ\)_/¯|"# + "(?:\(arms){0,3}[（(༼]\\h*\(inner)(?:\\h*\(inner)){1,15}\\h*[）)༽]\(arms){0,3}|\(inner){2,16}|\(ascii))"
        // Standalone tokens, not fragments of identifiers, paths, or Markdown link targets.
        let left = #"(?<![^\s·,;:!?])"#
        let right = #"(?=$|[\s·,;:]|[.!?…]+(?=$|\s))"#
        return try! NSRegularExpression(pattern: code + "|" + left + "(?:(" + exact + ")|(" + custom + "))" + right)
    }()

    static func strip(_ text: String) -> String {
        let original = text as NSString
        let hits = candidates.matches(in: text, range: NSRange(location: 0, length: original.length)).filter { hit in
            if hit.range(at: 3).location != NSNotFound { return true }
            guard hit.range(at: 4).location != NSNotFound else { return false }
            let s = original.substring(with: hit.range).trimmingCharacters(in: .whitespaces)
            if skinExceptions.contains(s) { return true }
            // Disallow letters/digits from the fallback unless the cluster is mostly symbols.
            let scalars = s.unicodeScalars
            let features = scalars.filter { distinctive.contains($0) }
            let plain = scalars.filter { CharacterSet.alphanumerics.contains($0) && !distinctive.contains($0) }
            return features.count >= 2 && features.count > plain.count && scalars.contains(where: mouths.contains)
        }
        guard !hits.isEmpty else { return text }

        let result = NSMutableString(string: text)
        func horizontal(_ c: unichar) -> Bool { c == 32 || c == 9 }
        func newline(_ c: unichar) -> Bool { c == 10 || c == 13 }
        for hit in hits.reversed() {
            var lo = hit.range.location
            var hi = NSMaxRange(hit.range)
            while lo > 0 && horizontal(result.character(at: lo - 1)) { lo -= 1 }
            while hi < result.length && horizontal(result.character(at: hi)) { hi += 1 }
            let hasLeft = lo > 0 && !newline(result.character(at: lo - 1))
            let hasRight = hi < result.length && !newline(result.character(at: hi))
            let hasSpace = lo < hit.range.location || hi > NSMaxRange(hit.range)
            let beforePunctuation = hasRight && ".,;:!?…”.'’".utf16.contains(result.character(at: hi))
            result.replaceCharacters(in: NSRange(location: lo, length: hi - lo),
                                     with: hasLeft && hasRight && hasSpace && !beforePunctuation ? " " : "")
        }
        let filtered = result as String
        // Don't flatten line breaks or Markdown indentation/hard breaks within the thinking stream.
        if filtered.allSatisfy(\.isWhitespace) { return "" }
        return filtered.contains(where: \.isNewline) ? filtered : filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
