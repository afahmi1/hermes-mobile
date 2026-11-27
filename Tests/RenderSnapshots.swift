import SwiftUI
import UIKit

// Renders message views to PNGs inside a simulator, for visual review without driving the UI.
// Tests/render-snapshots.sh <booted-sim-udid> <output-dir>

private let reply = """
## Restart the gateway
Run this when no chat is busy. It reloads `config.yaml`, so Telegram stays **off**:

```bash
hermes status --all
```

> [!WARNING]
> Restart only when no chat is busy.

```yaml title=config.yaml
platforms:
  telegram:
    enabled: false
```

Then check the pill:
1. Open **Status**
2. Look for `healthy`
- [x] Telegram disabled
- [ ] Bridge redeployed

> Pins are kept when a chat is archived.

| Step | Where |
|---|---|
| restart | frostbyte |
| verify | phone |
"""

@MainActor
private func activityItem(expanded: Bool) -> ChatItem {
    var item = ChatItem(id: "1", kind: .activity, text: "2 commands finished · 1 failed", timestamp: 1_764_000_000)
    item.entries = [
        ActivityEntry(type: "process", status: "ok", label: "build.py --mesh", exitCode: 0, cwd: "plate B",
                      command: "cd ~/Desktop/3D\\ Printing/Runs/plate\\ B && ~/.venvs/cad/bin/python build.py --mesh",
                      output: "Built 25 meshes\nAll Z preserved"),
        ActivityEntry(type: "process", status: "failed", label: "run-swift.sh", exitCode: 1, cwd: "hermes-mobile-pins",
                      command: "bash Tests/run-swift.sh EE236E6D", output: "Tests/ProjectsTests.swift:78:17: error: extra arguments"),
    ]
    return item
}

@MainActor
private func taskItem() -> ChatItem {
    var item = ChatItem(id: "2", kind: .activity, text: "2 subagent tasks finished", timestamp: 1_764_000_000)
    item.entries = [
        ActivityEntry(type: "task", status: "ok", label: "Render five reprints and verify every Z", duration: "7m25s",
                      apiCalls: 14, model: "gpt-6.2-astra", state: "completed"),
        ActivityEntry(type: "task", status: "failed", label: "Read 7 arXiv papers on design for manufacturing",
                      output: "HTTP 429: rate limit", duration: "8m42s", state: "failed"),
    ]
    return item
}

@MainActor
private func render<V: View>(_ name: String, _ view: V, to dir: URL, dark: Bool = false) {
    let framed = view
        .frame(width: 393)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 3
    guard let image = renderer.uiImage, let data = image.pngData() else {
        print("FAILED to render \(name)")
        return
    }
    try? data.write(to: dir.appendingPathComponent(name + ".png"))
    print("rendered \(name) \(Int(image.size.width))x\(Int(image.size.height))")
}

@main
enum RenderSnapshots {
    @MainActor
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        render("reply", MessageRow(item: ChatItem(id: "9", kind: .assistant, text: reply), pinned: true), to: dir)
        render("reply-dark", MessageRow(item: ChatItem(id: "9", kind: .assistant, text: reply)), to: dir, dark: true)
        render("user", MessageRow(item: ChatItem(id: "8", kind: .user, text: "give me a copy-pasteable restart command"), pinned: true), to: dir)
        render("activity", MessageRow(item: activityItem(expanded: false)), to: dir)
        render("activity-open", ActivityCard(item: activityItem(expanded: true), expanded: .constant(true)).padding(.horizontal, 12), to: dir)
        render("tasks", MessageRow(item: taskItem()), to: dir)
        render("file", VStack(alignment: .leading, spacing: 8) {
            TranscriptFile(ref: ChatMediaRef(name: "message-format.md", digest: String(repeating: "a", count: 64), kind: "file"), profile: "default", session: "s")
            TranscriptFile(ref: ChatMediaRef(name: "Five favorites XL.3mf", digest: String(repeating: "b", count: 64), kind: "file"), profile: "default", session: "s")
        }.padding(.horizontal, 12), to: dir)
        render("pinned-bar", PinnedBar(pins: [
            MessagePin(messageId: 1, role: "assistant", text: "Lease due Dec 1, bring the deposit check", messageAt: nil, pinnedAt: 2),
            MessagePin(messageId: 2, role: "user", text: "remember this", messageAt: nil, pinnedAt: 1)], cursor: 0, jump: {}, list: {}), to: dir)
        render("toast", CopiedToast(text: "Copied code"), to: dir)
        let replyText = ReplyQuote.markdown(ReplyQuote.excerpt("The bridge answers 503 while Hermes restarts, so the phone keeps the archive and sends it again when the gateway is back.")) + "\n\nnice, does that cover pins too?"
        render("user-reply", MessageRow(item: ChatItem(id: "7", kind: .user, text: replyText)), to: dir, dark: true)
        render("quote-chip", QuoteChip(text: "The bridge answers 503 while Hermes restarts, so the phone keeps the archive and sends it again when the gateway is back.", remove: {}).padding(.horizontal, 12), to: dir, dark: true)
        render("question", QuestionCard(chat: ChatModel(profile: "default", sessionId: nil, app: AppModel()), question: ClarifyRequest(id: "q", runId: "r", generation: 1,
            question: "Where should the journal folder live?", choices: ["~/Desktop/journal", "Obsidian vault", "iCloud Drive"], multiSelect: false)), to: dir, dark: true)
    }
}
