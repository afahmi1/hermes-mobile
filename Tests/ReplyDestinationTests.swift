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
    print("Reply destination identifier and collapse id tests passed")
}

@main
enum ReplyDestinationTests {
    static func main() async { await run() }
}
