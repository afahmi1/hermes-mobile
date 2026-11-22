/// State for a single turn. The bridge retains numbered events across connections.
struct StreamRecovery {
    private(set) var lastSequence: Int?
    private(set) var failures = 0
    static let attemptLimit = 6

    func hasGap(before sequence: Int?) -> Bool {
        guard let sequence else { return false }
        return sequence > (lastSequence ?? -1) + 1
    }

    mutating func accept(_ sequence: Int?) -> Bool {
        if let sequence {
            if hasGap(before: sequence) || sequence <= (lastSequence ?? -1) { return false }
            lastSequence = sequence
        }
        failures = 0
        return true
    }

    /// Equal jitter avoids a tight loop after an empty stream and spreads reconnects.
    mutating func retryDelay() -> Double? {
        failures += 1
        guard failures < Self.attemptLimit else { return nil }
        let ceiling = Double(min(1 << failures, 8))
        return Double.random(in: (ceiling / 2)...ceiling)
    }
}
