import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func job(_ name: String, next: Double? = nil, paused: Bool = false, streak: Int = 0, status: String = "ok") -> JV {
    var d: [String: Any] = ["name": name, "paused": paused, "failure_streak": streak, "last_status": status]
    if let next {
        d["next_run_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(next))
    }
    return JV(d)
}

private func names(_ jobs: [JV]) -> [String] { jobs.map { $0["name"].string ?? "?" } }

@MainActor
func run() async {
    // Failing first, then overdue, then soonest next run.
    let mixed = [job("later", next: 3600), job("overdue", next: -600), job("soon", next: 60),
                 job("failing-late", next: 7200, streak: 2, status: "failed"), job("failing-soon", next: 30, status: "error")]
    check(names(StatusJobs.top(mixed, now: now)) == ["failing-soon", "failing-late", "overdue", "soon", "later"],
          "order: \(names(StatusJobs.top(mixed, now: now)))")

    // The limit applies after ranking, so the most relevant jobs survive it.
    let many = (0..<9).map { job("j\($0)", next: Double(9 - $0) * 100) } + [job("bad", next: 99_999, streak: 1, status: "failed")]
    let five = StatusJobs.top(many, now: now)
    check(five.count == 5 && names(five).first == "bad", "limit keeps the failing job: \(names(five))")
    check(names(five).dropFirst() == ["j8", "j7", "j6", "j5"], "then soonest: \(names(five))")
    check(StatusJobs.top(many, limit: 2, now: now).count == 2, "custom limit")
    check(StatusJobs.top(many, limit: 0, now: now).isEmpty && StatusJobs.top(many, limit: -3, now: now).isEmpty, "zero or negative limit")

    // A paused job shows only when it is failing.
    let paused = [job("quiet", next: 10, paused: true), job("broken", paused: true, streak: 3, status: "failed"), job("live", next: 500)]
    check(names(StatusJobs.top(paused, now: now)) == ["broken", "live"], "paused: \(names(StatusJobs.top(paused, now: now)))")
    check(names(StatusJobs.ranked(paused, now: now)) == ["broken", "live", "quiet"], "ranked keeps paused last: \(names(StatusJobs.ranked(paused, now: now)))")

    // Ties keep the order the Mac sent; a job with no next run sorts after those with one.
    let ties = [job("a", next: 100), job("b", next: 100), job("none"), job("c", next: 100)]
    check(names(StatusJobs.top(ties, now: now)) == ["a", "b", "c", "none"], "ties: \(names(StatusJobs.top(ties, now: now)))")
    let failTies = [job("x", streak: 1, status: "failed"), job("y", streak: 5, status: "failed")]
    check(names(StatusJobs.top(failTies, now: now)) == ["x", "y"], "failing ties keep input order")

    // Empty and short input.
    check(StatusJobs.top([], now: now).isEmpty && StatusJobs.ranked([], now: now).isEmpty, "empty input")
    check(StatusJobs.top([job("only")], now: now).count == 1, "single job")
    check(StatusJobs.isFailing(job("f", status: "error")) && !StatusJobs.isFailing(job("ok")), "failing detection")

    print("Status job ranking tests passed")
}

@main
enum StatusJobsTests {
    static func main() async { await run() }
}
