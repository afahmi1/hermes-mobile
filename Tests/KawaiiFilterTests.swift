import Foundation

@main
struct KawaiiFilterTests {
    static func main() {
        func check(_ input: String, _ expected: String) {
            let output = KawaiiFilter.strip(input)
            precondition(output.utf8.elementsEqual(expected.utf8), "\(input.debugDescription) became \(output.debugDescription), expected \(expected.debugDescription)")
            precondition(KawaiiFilter.strip(output).utf8.elementsEqual(output.utf8), "not idempotent: \(output.debugDescription)")
        }
        // Keep this independent of the implementation: stock Hermes faces must match exactly.
        let stock = [
            "(｡◕‿◕｡)", "(◕‿◕✿)", "٩(◕‿◕｡)۶", "(✿◠‿◠)", "( ˘▽˘)っ", "♪(´ε` )", "(◕ᴗ◕✿)", "ヾ(＾∇＾)", "(≧◡≦)", "(★ω★)",
            "(｡•́︿•̀｡)", "(◔_◔)", "(¬‿¬)", "( •_•)>⌐■-■", "(⌐■_■)", "(´･_･`)", "◉_◉", "(°ロ°)", "( ˘⌣˘)♡", "ヽ(>∀<☆)☆",
            "٩(๑❛ᴗ❛๑)۶", "(⊙_⊙)", "(¬_¬)", "( ͡° ͜ʖ ͡°)", "ಠ_ಠ",
        ]
        for face in stock {
            check("\(face) pondering...", "pondering...")
            check("Ran · \(face) web_search", "Ran · web_search")
            check("\(face)", "")
        }
        let custom = ["(◠‿◠)", "◕_◕", "（；´д｀）", "ヽ(>▽<✧)✧", "٩(๑❜ᴗ❜๑)۶", "(＾ω＾)っ", "༼ つ ◕_◕ ༽つ", "ʕ•ᴥ•ʔ", "(^_^)", ">_<", #"¯\_(ツ)_/¯"#]
        for face in custom { check("  \(face)   Checking paths  ", "Checking paths") }
        check("First  (◔_◔)  ಠ_ಠ   second ◉_◉.", "First second.")
        check("(◔_◔) (¬‿¬)", "")
        check("(◔_◔)\n(◉_◉)\n", "")
        check("Thinking (◔_◔)  through (a+b)\n(≧◡≦) then f(x).", "Thinking through (a+b)\nthen f(x).")
        check("Opening `echo (◔_◔)`  (◉_◉) now", "Opening `echo (◔_◔)` now")
        check("(◔_◔) Checked  \n```swift\nlet face = \"(◔_◔)\"\n```\n  - Next  ",
              "Checked  \n```swift\nlet face = \"(◔_◔)\"\n```\n  - Next  ")
        check("```txt\n(◔_◔) in a streamed fence", "```txt\n(◔_◔) in a streamed fence")
        let unchanged = [
            "", "  No   faces here.  ", "Hello (thanks) ...?!; --", "[()] (??) (*) :-) :) `fn()`", "Does it work? Yes.",
            "f(x) = (a+b) * (c - d)", "(-1) (a≧b) (x > 0) -> O(n)", "(▽ + ▽) > (∇x)", "let value = f(x) // (works)",
            "• one · two ★ ☆ ○ ◎", "•• ☆★ ✨ 🐟", "Use degrees (°F) or (°C)", "今日は、いい天気。 (テスト)",
            #"let face = "(◔_◔)""#,
            "~/cache/(ಠ_ಠ)/notes.md", "/path/(◔_◔).txt", "f(ಠ_ಠ)", "ಠ_ಠ.txt", "[docs](./(◔_◔).md)",
            "**bold**  \n  - item with [link](./a_b.md)\n\n> quote\n", "`(¬‿¬)` or ``(◔_◔)``", "\n~~~text\n(｡◕‿◕｡)\n~~~\n",
        ]
        for text in unchanged { check(text, text) }
        print("KawaiiFilter: \(stock.count) Hermes faces, \(custom.count) skin variants, mixed streams and \(unchanged.count) byte-preservation cases passed")
    }
}
