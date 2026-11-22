@main
enum StreamRecoveryTests {
    static func main() {
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
        print("Stream replay, progress, jitter bounds and retry exhaustion passed")
    }
}
