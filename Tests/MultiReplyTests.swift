import Foundation

/// Replying to several messages in one: pills in order, each with its words; removing a pill keeps the words.
@main
struct MultiReplyTests {
    @MainActor static func main() async throws {
        let chat = ChatModel(profile: "default", sessionId: nil, app: AppModel())
        chat.setReplyQuote("first message")
        chat.draft = "answer one"
        chat.setReplyQuote("second message")
        precondition(chat.draft.isEmpty, "the box starts the next answer")
        chat.draft = "answer two"
        chat.setReplyQuote("third message")
        chat.draft = "answer three"
        chat.setReplyQuote("second message")  // the same quote twice is ignored
        let wire = chat.combinedDraft
        precondition(wire == "> first message\n\nanswer one\n\n> second message\n\nanswer two\n\n> third message\n\nanswer three", wire)

        // Sent bubble: three quote cards with their answers.
        let segs = ReplyQuote.segments(wire)
        precondition(segs.map(\.quote) == ["first message", "second message", "third message"])
        precondition(segs.map(\.body) == ["answer one", "answer two", "answer three"])
        precondition(ReplyQuote.segments("hi\n> q\nbody").map(\.quote) == [nil, "q"])

        // Remove the middle pill: its words stay in place, unquoted.
        let middle = chat.pastedTexts.filter(\.isQuote)[1].id
        chat.removeReplyQuote(middle)
        precondition(chat.combinedDraft == "> first message\n\nanswer one\n\nanswer two\n\n> third message\n\nanswer three", chat.combinedDraft)
        // Remove the newest: the box now carries the previous words then its own.
        let newest = chat.pastedTexts.filter(\.isQuote).last!.id
        chat.removeReplyQuote(newest)
        precondition(chat.combinedDraft == "> first message\n\nanswer one\n\nanswer two\n\nanswer three", chat.combinedDraft)

        // Edit as New Message brings every quote back as a pill.
        let other = ChatModel(profile: "default", sessionId: nil, app: AppModel())
        precondition(other.restoreReplies(from: wire))
        precondition(other.combinedDraft == wire, other.combinedDraft)
        precondition(other.draft == "answer three")
        precondition(!other.restoreReplies(from: "no quotes here"))

        // Saved drafts with answers round-trip.
        let data = try JSONEncoder().encode(other.pastedTexts)
        let back = try JSONDecoder().decode([PastedText].self, from: data)
        precondition(back.map(\.answer) == other.pastedTexts.map(\.answer))
        print("Multi-reply composer, removal, sent segments and edit round trip passed")
    }
}
