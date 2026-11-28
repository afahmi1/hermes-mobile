import Foundation

/// A single 401 must never forget the saved login: only a second 401 after a pause does, a burst of 401s
/// shares one check, and a 503 "busy" (or no network) keeps the person signed in.
@main struct SessionRecheckTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @MainActor static func main() async throws {
        let quick = Duration.milliseconds(20)

        func expired(_ probe: @escaping @Sendable () async throws -> Void) async -> Bool {
            await SessionRecheck(delay: quick).confirmExpired(probe)
        }

        // The second request also says 401: the login really is gone.
        let gone = await expired { throw APIError.http(401, "Sign in again.") }
        precondition(gone)

        // The bridge answered the re-check: it was a momentary 401.
        let answered = await expired { }
        precondition(!answered)

        // A busy bridge (the registry fix answers 503 with retry) or a gateway error never signs out.
        for code in [502, 503, 504, 500, 404] {
            let busy = await expired { throw APIError.http(code, "busy") }
            precondition(!busy, "\(code) signed out")
        }
        // Nor does losing the network, or a client that was swapped out meanwhile.
        let failures: [Error] = [URLError(.timedOut), URLError(.notConnectedToInternet), APIError.notSignedIn, CancellationError()]
        for failure in failures {
            let offline = await expired { throw failure }
            precondition(!offline, "\(failure) signed out")
        }

        // Ten failing requests at once share one re-check, and all get its answer.
        let check = SessionRecheck(delay: .milliseconds(80))
        let probes = Counter()
        let answers = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<10 {
                group.addTask { @MainActor in
                    await check.confirmExpired { probes.bump(); throw APIError.http(401, "") }
                }
            }
            var out: [Bool] = []
            for await answer in group { out.append(answer) }
            return out
        }
        precondition(probes.count == 1, "\(probes.count) re-checks for one burst")
        precondition(answers.count == 10 && answers.allSatisfy { $0 })
        precondition(!check.isChecking)

        // The check waits before asking again, so a bridge that was busy for a moment has time to recover.
        let started = ContinuousClock.now
        _ = await SessionRecheck(delay: .milliseconds(150)).confirmExpired { }
        precondition(ContinuousClock.now - started >= .milliseconds(140), "re-checked without waiting")

        // A later 401, after the first check finished, gets a fresh check rather than a stale answer.
        _ = await check.confirmExpired { probes.bump() }
        precondition(probes.count == 2)

        print("Session re-check: one 401 never signs out, bursts share one check, 503 and offline keep the login")
    }
}
