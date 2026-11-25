import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

@MainActor
func run() async {
    // The bridge's pin list decodes, newest first as sent.
    let list = try! JSONDecoder().decode(PinList.self, from: Data(#"""
    {"pins":[{"message_id":42,"role":"assistant","text":"Lease due Dec 1\nbring deposit","message_at":200.5,"pinned_at":300},
             {"message_id":7,"role":"user","text":"remember this","message_at":null,"pinned_at":250}],"limit":100}
    """#.utf8))
    check(list.pins.map(\.id) == [42, 7], "ids in order")
    check(list.pins[0].itemID == "42" && !list.pins[0].isMine && list.pins[1].isMine, "item ids and roles")
    check(list.pins[0].excerpt == "Lease due Dec 1 bring deposit", "excerpt flattens newlines: \(list.pins[0].excerpt)")
    check(list.pins[1].messageAt == nil && list.limit == 100, "optional fields")
    let long = MessagePin(messageId: 1, role: "user", text: String(repeating: "a", count: 300), messageAt: nil, pinnedAt: 0)
    check(long.excerpt.count == 141 && long.excerpt.hasSuffix("…"), "long excerpt is clipped")

    // Only stored user/assistant messages with text are pinnable.
    check(MessagePin.messageID(for: ChatItem(id: "42", kind: .assistant, text: "hi")) == 42, "stored reply")
    check(MessagePin.messageID(for: ChatItem(id: "9", kind: .user, text: "hello")) == 9, "stored user message")
    check(MessagePin.messageID(for: ChatItem(id: "stream-x", kind: .assistant, text: "hi")) == nil, "live stream row")
    check(MessagePin.messageID(for: ChatItem(id: "42", kind: .assistant, text: "hi", streaming: true)) == nil, "streaming")
    check(MessagePin.messageID(for: ChatItem(id: "42t", kind: .tools, text: "")) == nil, "tool group")
    check(MessagePin.messageID(for: ChatItem(id: "5", kind: .notice, text: "Stopped.")) == nil, "notice")
    check(MessagePin.messageID(for: ChatItem(id: "5", kind: .user, text: "  ")) == nil, "empty text")

    // Session rows carry the pin count when the bridge adds it, and tolerate its absence.
    let rows = try! JSONDecoder().decode([SessionSummary].self, from: Data(#"""
    [{"id":"a","profile":"default","pin_count":3},{"id":"b","profile":"default"},{"id":"c","profile":"default","pin_count":-2}]
    """#.utf8))
    check(rows.map(\.pinnedMessages) == [3, 0, 0], "pin counts: \(rows.map(\.pinnedMessages))")

    print("Pinned message decoding, pinnability and session pin count tests passed")
}

@main
enum PinsTests {
    static func main() async { await run() }
}
