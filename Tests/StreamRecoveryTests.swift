@main
enum StreamRecoveryTests {
    // Enumerate short histories including stalled links and an epoch change whose
    // new sequence numbers overlap the old reader's. Each branch starts with a
    // copy of the exact client state. A rejected event cannot acknowledge progress.
    static func explore(_ reader: StreamRecovery, cursor: Int, epoch: String?, depth: Int) -> Int {
        guard depth > 0 else { return 1 }
        var count = 0
        for action in 0..<6 {
            var next = reader
            var expected = cursor
            var nextEpoch = epoch
            switch action {
            case 0, 1, 2:
                let sequence = [cursor + 1, cursor, cursor + 2][action]
                let accepted = next.accept(sequence, epoch: epoch)
                precondition(accepted == (sequence == cursor + 1))
                if accepted { expected = sequence }
            case 3:
                _ = next.retryDelay()
            case 4:
                nextEpoch = epoch == "a" ? "b" : "a"
                expected = 0
                next.restore(checkpoint: expected, epoch: nextEpoch)
            default:
                let other = epoch == "a" ? "b" : "a"
                let accepted = next.accept(cursor + 1, epoch: other)
                precondition(accepted == (epoch == nil))
                if accepted { expected += 1; nextEpoch = other }
            }
            precondition((next.lastSequence ?? -1) == expected && next.epoch == nextEpoch)
            count += explore(next, cursor: expected, epoch: nextEpoch, depth: depth - 1)
        }
        return count
    }

    static func main() async {
        let paths = explore(StreamRecovery(), cursor: -1, epoch: nil, depth: 6)
        precondition(paths == 46_656)
        print("Verified \(paths) six-step replay histories")
        var state = StreamRecovery()
        precondition(state.accept(0))
        precondition(state.retryDelay() != nil)
        precondition(!state.accept(0) && state.failures == 1)
        precondition(state.hasGap(before: 3) && !state.accept(3) && state.lastSequence == 0)
        precondition(state.accept(1) && state.lastSequence == 1 && state.failures == 0)
        precondition(!state.accept(0) && state.lastSequence == 1)
        for cap in [2.0, 4, 8, 8, 8] {
            guard let delay = state.retryDelay() else { fatalError("premature exhaustion") }
            precondition((cap / 2 ... cap).contains(delay))
        }
        precondition(state.retryDelay() == nil)
        precondition(state.accept(nil) && state.lastSequence == 1 && state.failures == 0)
        state.restore(checkpoint: 20, epoch: "previous")
        precondition(!state.accept(21, epoch: "restored"))
        state.restore(checkpoint: 4, epoch: "restored")
        precondition(state.accept(5, epoch: "restored") && state.lastSequence == 5)
        let wifi = StreamRoute(reachable: true, interfaces: ["wifi"])
        let cell = StreamRoute(reachable: true, interfaces: ["cellular"])
        let offline = StreamRoute(reachable: false, interfaces: [])
        precondition(!wifi.wakesReader(after: nil) && !wifi.wakesReader(after: wifi))
        precondition(cell.wakesReader(after: wifi) && wifi.wakesReader(after: offline))
        precondition(!offline.wakesReader(after: cell))
        let routes = StreamRoutes(monitor: nil)
        routes.update(wifi)
        let gen = routes.state.revision
        routes.update(offline)
        precondition(routes.state.offline)
        let observer = routes.changes(after: gen)
        routes.update(cell)
        var iterator = observer.makeAsyncIterator()
        let woke = await iterator.next() != nil
        precondition(woke && !routes.state.offline && routes.state.revision != gen)
        // A route restored between a failed request and installing its retry wait must wake it too.
        await routes.waitForRetry(after: gen, seconds: nil)
        let cancelled = Task { await routes.waitForRetry(after: routes.state.revision, seconds: nil) }
        cancelled.cancel()
        await cancelled.value
        await routes.waitForRetry(after: routes.state.revision, seconds: 0.001)
        print("Stream replay, progress, jitter bounds and retry exhaustion passed")
    }
}
