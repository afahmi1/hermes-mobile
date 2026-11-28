import SwiftUI

/// What the status line says while Hermes works. Playful (default): a rotating line in zayd.wtf's voice, a little
/// dark, airy and strange, that changes every few seconds and on every new step. Plain: Hermes's own words.
enum ThinkingWords: String, CaseIterable, Identifiable {
    case playful, plain
    static let key = "hm.thinkingWords"
    static let streamKey = "hm.streamThinking"
    var id: String { rawValue }
    var title: String { self == .playful ? "Playful" : "Plain" }
}

enum ThinkingLines {
    static let all: [String] = [
        "noodling in the dark",
        "asking the void politely",
        "counting stars that already died",
        "listening for the hum under everything",
        "what if we all get lost on purpose",
        "folding the map into a paper moon",
        "tuning the radio between stations",
        "following a moth toward the answer",
        "whispering to the server room",
        "reading tea leaves in the logs",
        "drifting through low orbit",
        "the lights flickered. probably nothing",
        "rearranging constellations",
        "walking the hallway with no end",
        "something is typing back",
        "dreaming in hexadecimal",
        "checking under the bed for bugs",
        "consulting the oracle (it's me)",
        "pulling threads from the fog",
        "humming a song from another timeline",
        "slow-dancing with entropy",
        "waiting for the static to clear",
        "peeking behind the fourth wall",
        "taking the long way through the stars",
        "is the room getting bigger",
        "sketching in candlelight",
        "the cursor blinks back. patient",
        "chasing a signal from deep space",
        "making friends with the ghost in the machine",
        "watering the neurons",
        "remembering something that hasn't happened",
        "staring into the abyss. it waved",
        "untangling the wires of fate",
        "floating, mostly on purpose",
        "a lantern swings in the dark",
        "eavesdropping on the electrons",
        "pacing the edge of the known map",
        "holding my breath underwater",
        "wondering if the moon is listening",
        "brewing something strange",
        "lost in a good way",
        "tracing footprints that lead nowhere",
        "playing chess with a shadow",
        "the clocks melted. keep going",
        "translating dreams into commands",
        "stargazing through the terminal",
        "turning the page in an unwritten book",
        "the void is loading",
        "minding the gap between thoughts",
        "listening to the walls breathe",
        "counting backwards from infinity",
        "a door opened somewhere. stepping through",
        "picking locks in a lucid dream",
        "running on starlight and spite",
        "gathering moonlight in a jar",
        "the signal is faint but sweet",
        "hiding in the margins",
        "pondering the shape of nothing",
        "brushing dust off old secrets",
        "sending a postcard to the future",
        "the fog is thick. walking anyway",
        "half awake in the machine",
        "sorting the stars by vibe",
        "following the white rabbit's logs",
        "spinning yarn out of static",
        "who left this candle burning",
        "the targeting of the slop cannon will be televised",
    ]

    /// Same seed, same line: stable across redraws, changes when the tick or the 9 s window changes.
    static func line(tick: Int, at date: Date, seed: Int) -> String {
        let window = Int(date.timeIntervalSinceReferenceDate / 9)
        var h = UInt64(bitPattern: Int64(seed &* 31 &+ tick &* 977 &+ window &* 7919))
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        return all[Int(h % UInt64(all.count))] + "…"
    }

    /// Hermes's status words that say nothing specific: these get a playful line instead.
    static func isGeneric(_ status: String) -> Bool {
        ["Thinking…", "Working…", "Hermes is still working…", "Sending…", "Reconnecting…"].contains(status)
    }
}

/// The status row under a running reply. Tap it to read Hermes's thinking as it streams.
struct ThinkingStatus: View {
    @Bindable var chat: ChatModel
    let status: String
    @AppStorage(ThinkingWords.key) private var wordsRaw = ThinkingWords.playful.rawValue
    @AppStorage(ThinkingWords.streamKey) private var stream = false
    @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true
    @State private var showThinking = false
    @State private var seed = Int.random(in: 0..<10_000)

    private var preview: String {
        guard stream else { return "" }
        let raw = chat.thinkingText
        let end = raw.lastIndex(where: { !$0.isNewline }).map { raw.index(after: $0) } ?? raw.startIndex
        let lines = raw[..<end]
        let start = lines.lastIndex(where: \.isNewline).map { lines.index(after: $0) } ?? lines.startIndex
        // The sheet keeps the complete stream. Don't repeat its newest status right below the same status row.
        let distinct = String(lines[start...] == status ? lines[..<start] : lines)
        let shown = kawaiiFaces ? distinct : KawaiiFilter.strip(distinct)
        return String(shown.suffix(280)).trimmingCharacters(in: .newlines)
    }

    var body: some View {
        let playful = ThinkingWords(rawValue: wordsRaw) != .plain
        let displayed = kawaiiFaces ? status : KawaiiFilter.strip(status)
        let status = displayed.isEmpty ? "Thinking…" : displayed
        let specific = !ThinkingLines.isGeneric(status)
        let preview = self.preview
        Button { showThinking = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ThinkingIndicator(size: 16, activity: status)
                    if playful {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            ShimmerText(text: ThinkingLines.line(tick: chat.activityTick, at: ctx.date, seed: seed))
                                .id(ThinkingLines.line(tick: chat.activityTick, at: ctx.date, seed: seed))
                                .transition(.opacity)
                        }
                        if specific {
                            Text(status.replacingOccurrences(of: "…", with: "").lowercased())
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    } else {
                        ShimmerText(text: status)
                    }
                    Spacer(minLength: 0)
                    if !chat.thinkingText.isEmpty {
                        Image(systemName: "brain").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.35), value: chat.activityTick)
        .accessibilityHint("Shows Hermes's thinking")
        .sheet(isPresented: $showThinking) { ThinkingSheet(chat: chat) }
    }
}

/// Hermes's reasoning for the current reply, streaming in as it arrives.
struct ThinkingSheet: View {
    @Bindable var chat: ChatModel
    @AppStorage(KawaiiFilter.key) private var kawaiiFaces = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let thinking = kawaiiFaces ? chat.thinkingText : KawaiiFilter.strip(chat.thinkingText)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if thinking.isEmpty {
                            Text("Hermes hasn't shared any thinking for this reply yet. Some models don't stream it; tool steps are in the Worked card.")
                                .font(.subheadline).foregroundStyle(HMDesign.text2)
                        } else {
                            Text(thinking).font(.callout).foregroundStyle(HMDesign.text2).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: thinking.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .hmCanvas()
            .navigationTitle("Thinking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
