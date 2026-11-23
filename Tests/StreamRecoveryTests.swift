@main
enum StreamRecoveryTests {
    static func main() async {
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
