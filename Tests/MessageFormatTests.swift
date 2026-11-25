import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

@MainActor
func run() async {
    // Code fences keep their language and exact body; an unclosed fence (still streaming) is code already.
    let reply = """
    # Deploy
    Run this:

    ```bash
    hermes gateway restart
      --yes
    ```

    - first step
    - [x] done step
      wrapped continuation
    1. numbered
    > a quote
    ---
    | a | b |
    |---|---|
    | 1 | 2 |
    """
    let blocks = MarkdownBlock.parse(reply)
    check(blocks.first == .heading(1, "Deploy"), "heading: \(blocks)")
    check(blocks.contains(.code(language: "bash", body: "hermes gateway restart\n  --yes", closed: true)), "code block kept exactly")
    guard case .list(let items)? = blocks.first(where: { if case .list = $0 { return true }; return false }) else {
        fatalError("FAILED: no list in \(blocks)")
    }
    check(items.map(\.marker) == ["•", "☑", "1."], "markers \(items.map(\.marker))")
    check(items[1].text == "done step wrapped continuation", "continuation joins: \(items[1].text)")
    check(blocks.contains(.quote("a quote")), "quote")
    check(blocks.contains(.rule), "rule")
    check(blocks.contains(.table([["a", "b"], ["1", "2"]])), "table")

    let streaming = MarkdownBlock.parse("Here:\n```python\nprint(1)")
    check(streaming.last == .code(language: "python", body: "print(1)", closed: false), "unclosed fence: \(streaming)")
    check(MarkdownBlock.parse("plain words") == [.paragraph("plain words")], "plain paragraph")
    check(MarkdownBlock.parse("#hashtag not a heading") == [.paragraph("#hashtag not a heading")], "hashtag")
    check(MarkdownBlock.parse("~~~\nraw\n~~~") == [.code(language: "", body: "raw", closed: true)], "tilde fence")

    // Fence info: a file name wins over the bare language, in every spelling people use.
    check(MarkdownBlock.fenceInfo("python title=build.py") == ("python", "build.py"), "title=")
    check(MarkdownBlock.fenceInfo("build.py") == ("py", "build.py"), "bare file name")
    check(MarkdownBlock.fenceInfo("ts src/app.ts") == ("ts", "src/app.ts"), "language then path")
    check(MarkdownBlock.fenceInfo("bash") == ("bash", nil), "language only")
    check(MarkdownBlock.languageName("cpp") == "C++" && MarkdownBlock.languageName("") == "Code"
          && MarkdownBlock.languageName("zig") == "Zig", "language names")
    check(MarkdownBlock.parse("```swift file=App.swift\nlet a = 1\n```")
          == [.code(language: "swift", body: "let a = 1", closed: true, file: "App.swift")], "file in parse")

    // GitHub alerts become callouts; an ordinary quote stays a quote.
    check(MarkdownBlock.parse("> [!WARNING]\n> Restart only between turns.")
          == [.callout(kind: "warning", text: "Restart only between turns.")], "callout")
    check(MarkdownBlock.parse("> [!tip] inline tip") == [.callout(kind: "tip", text: "inline tip")], "inline callout")

    // Copy gives clean text: markers gone, code verbatim.
    let plain = MarkdownBlock.plainText("## Steps\nRun **this**:\n```bash\nls -la\n```\n- one\n- `two`")
    check(plain == "Steps\n\nRun this:\n\nls -la\n\n- one\n- two", "plain text: \(plain)")

    // Activity entries decode and summarize the way the card shows them.
    let entries = try! JSONDecoder().decode([ActivityEntry].self, from: Data(#"""
    [{"type":"process","status":"failed","label":"build.py --mesh","cwd":"plate B","exit_code":2,"command":"python build.py","output":"boom"},
     {"type":"task","status":"ok","label":"Render reprints","duration":"7m25s","api_calls":14,"model":"gpt-6.2-astra","state":"completed"},
     {"type":"process","status":"stopped","label":"brute","exit_code":-15}]
    """#.utf8))
    check(entries[0].meta == "in plate B · exit 2" && entries[0].failed, "process meta: \(entries[0].meta)")
    check(entries[1].meta == "gpt-6.2-astra · 14 calls · 7m25s", "task meta: \(entries[1].meta)")
    check(entries[2].meta == "stopped", "stopped meta: \(entries[2].meta)")

    // A stored system row carries its activity through to the transcript item.
    let stored = try! JSONDecoder().decode([StoredMessage].self, from: Data(#"""
    [{"id":5,"role":"system","display_kind":"process_complete","notice":"build.py --mesh failed (exit 2)","content":"Failed · build.py --mesh","ok":false,
      "activity":[{"type":"process","status":"failed","label":"build.py --mesh","exit_code":2}]}]
    """#.utf8))
    let items2 = ChatModel.transcript(stored)
    check(items2.count == 1 && items2[0].kind == .activity && items2[0].entries.count == 1, "activity item: \(items2)")
    check(items2[0].text == "build.py --mesh failed (exit 2)" && items2[0].failed, "activity title and failure")

    let first = HistoryPaging.first(count: 100, hasMore: nil, nextOffset: nil)
    check(first.offset == 100 && first.hasOlder, "a full first page can continue")
    let short = HistoryPaging.first(count: 40, hasMore: nil, nextOffset: nil)
    check(short.offset == 100 && !short.hasOlder, "a short first page with no bridge flag is the end")
    let probed = HistoryPaging.first(count: 40, hasMore: true, nextOffset: 100)
    check(probed.hasOlder && probed.offset == 100, "bridge has_more beats the projected count")
    let cont = HistoryPaging.advance(offset: 100, added: 37, hasMore: nil, nextOffset: nil)
    check(cont.offset == 200 && cont.hasOlder, "a short later page is not the end")
    let done = HistoryPaging.advance(offset: 200, added: 0, hasMore: nil, nextOffset: nil)
    check(!done.hasOlder, "nothing new means history is exhausted")
    let flagged = HistoryPaging.advance(offset: 100, added: 10, hasMore: false, nextOffset: 200)
    check(flagged.offset == 200 && !flagged.hasOlder, "bridge has_more false stops")

    print("Message format parsing, activity entries and transcript activity tests passed")
}

@main
enum MessageFormatTests {
    static func main() async { await run() }
}
