import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

@MainActor
func run() async {
    // These vectors are the same ones Tests/test_push.py computes with hashlib: the phone's local notification id
    // and the bridge's apns-collapse-id must be identical or the two notifications stack instead of replacing.
    let plain = ReplyDestination(account: "acc", profile: "bot", session: "ses")
    check(plain.identifier == "3:acc3:bot3:ses", "identifier \(plain.identifier)")
    check(plain.collapseID == "3b1043bc7d2eb559cf842dd27e8ac766", "collapse id \(plain.collapseID)")
    let accented = ReplyDestination(account: "é", profile: "b", session: "s")
    check(accented.identifier == "2:é1:b1:s", "byte counts: \(accented.identifier)")
    check(accented.collapseID == "c6ebd2da4a683766293d4142060abb68", "accented collapse id \(accented.collapseID)")
    let real = ReplyDestination(account: String(repeating: "9f", count: 32), profile: "frostbyte", session: "20260101_000000_abcdef")
    check(real.collapseID.utf8.count <= 64 && real.collapseID.utf8.count == 32, "fits the APNs limit")
    check(real.collapseID != ReplyDestination(account: real.account, profile: real.profile, session: "other").collapseID, "chats differ")

    // A tap opens the chat named by the notification's userInfo. The bridge's push payload carries the same keys
    // at its top level (bridge_push.payload); its --push-test payload has none and must open nothing.
    let push: [AnyHashable: Any] = ["aps": ["alert": ["title": "Frost"]], "account": real.account,
                                    "profile": "frostbyte", "session": real.session]
    check(ReplyDestination(userInfo: push) == real, "a push opens its chat")
    check(ReplyDestination(userInfo: real.userInfo) == real, "a local notification round-trips")
    check(ReplyDestination(userInfo: ["aps": ["alert": ["title": "Prometheus"]]]) == nil, "the test push opens no chat")
    check(ReplyDestination(userInfo: ["account": "a", "profile": "", "session": "s"]) == nil, "an empty field opens nothing")
    check(ReplyDestination(userInfo: ["account": "a", "profile": 7, "session": "s"]) == nil, "a wrong type opens nothing")

    // In the foreground only the chat on screen keeps its notifications to itself.
    let other = ReplyDestination(account: real.account, profile: "frostbyte", session: "another-chat")
    check(!ForegroundPolicy.shows(real, visibleChat: real), "the chat on screen gets no banner")
    check(ForegroundPolicy.shows(other, visibleChat: real), "another chat's reply shows while you read this one")
    check(ForegroundPolicy.shows(real, visibleChat: nil), "no chat on screen (inbox, Status): shown")
    check(ForegroundPolicy.shows(nil, visibleChat: real), "a push without a chat (--push-test): shown")
    let elsewhere = ReplyDestination(account: "another-gateway", profile: "frostbyte", session: real.session)
    check(ForegroundPolicy.shows(elsewhere, visibleChat: real), "the same chat id on another gateway is another chat")
    check(ForegroundPolicy.shows(real, visibleChat: real, away: true), "a reply to the last visible chat still shows while away")

    // What each notification says. Generic events use the bridge's words (bridge_push.COPY).
    check(ReplyEvent.question.title(bot: "Frost") == "Frost has a question", "question title")
    check(ReplyEvent.question.fallback == "Open the chat to answer.", "question body")
    check(ReplyEvent.approval.title(bot: "Frost") == "Frost needs your approval", "approval title")
    check(ReplyEvent.failure.title(bot: "Frost") == "Frost could not finish", "failure title")
    check(ReplyEvent.reply.title(bot: "Frost") == "Frost", "a quick reply is just the bot's name")
    check(ReplyEvent.reply.title(bot: "Frost", worked: 125) == "Frost finished · 2 min", "a long reply says how long")
    check(ReplyEvent.reply.fallback == "Your reply is ready.", "reply body")
    check(ReplyEvent.reply.endsRun && ReplyEvent.failure.endsRun, "outcomes end the run")
    check(!ReplyEvent.question.endsRun && !ReplyEvent.approval.endsRun, "prompts leave the run going")

    // A chat that leaves the screen after another appeared must not clear the newcomer's claim.
    let notifier = ReplyNotifier.shared
    notifier.watch(real)
    notifier.watch(other)
    notifier.unwatch(real)
    check(notifier.visibleChat == other, "the chat that appeared last stays visible")
    notifier.unwatch(other)
    check(notifier.visibleChat == nil, "leaving clears it")
    print("Reply destination, foreground policy and notification copy tests passed")
}

@main
enum ReplyDestinationTests {
    static func main() async { await run() }
}
