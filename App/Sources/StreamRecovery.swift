import Foundation
import Network

/// State for a single turn. The bridge retains numbered events across connections.
struct StreamRecovery {
    private(set) var lastSequence: Int?
    private(set) var epoch: String?
    private(set) var failures = 0
    static let attemptLimit = 6

    func hasGap(before sequence: Int?) -> Bool {
        guard let sequence else { return false }
        return sequence > (lastSequence ?? -1) + 1
    }

    mutating func accept(_ sequence: Int?, epoch observedEpoch: String? = nil) -> Bool {
        if let epoch, epoch != observedEpoch { return false }
        if let sequence {
            if hasGap(before: sequence) || sequence <= (lastSequence ?? -1) { return false }
            lastSequence = sequence
        }
        epoch = observedEpoch
        failures = 0
        return true
    }

    /// Only a validated server checkpoint can move the consumer across a gap.
    mutating func restore(checkpoint sequence: Int, epoch: String?) {
        self.epoch = epoch
        lastSequence = sequence >= 0 ? sequence : nil
        failures = 0
    }

    /// Equal jitter avoids a tight loop after an empty stream and spreads reconnects.
    mutating func retryDelay() -> Double? {
        failures += 1
        guard failures < Self.attemptLimit else { return nil }
        let ceiling = Double(min(1 << failures, 8))
        return Double.random(in: (ceiling / 2)...ceiling)
    }
}


struct StreamRouteChanged: Error {}

/// A path change tells an active reader when to retry. Gateway health still comes from the
/// authenticated bridge. The first NWPath sample establishes the baseline.
struct StreamRoute: Equatable {
    let reachable: Bool
    let interfaces: Set<String>

    func wakesReader(after previous: StreamRoute?) -> Bool {
        guard let previous, reachable else { return false }
        return !previous.reachable || previous.interfaces != interfaces
    }
}

final class StreamRoutes: @unchecked Sendable {
    static let shared = StreamRoutes()
    private let lock = NSLock()
    private let monitor: NWPathMonitor?
    private var route: StreamRoute?
    private var revision: UInt64 = 0
    private var observers = [UUID: AsyncStream<Void>.Continuation]()

    init(monitor: NWPathMonitor? = NWPathMonitor()) {
        self.monitor = monitor
        guard let monitor else { return }
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
            (.other, "other"), (.loopback, "loopback")
        ]
        monitor.pathUpdateHandler = { [weak self] path in
            let names = types.compactMap { type, name in path.usesInterfaceType(type) ? name : nil }
            self?.update(StreamRoute(reachable: path.status == .satisfied, interfaces: Set(names)))
        }
        monitor.start(queue: DispatchQueue(label: "Hermes.StreamRoutes"))
    }

    var state: (revision: UInt64, offline: Bool) {
        lock.withLock { (revision, route?.reachable == false) }
    }

    func update(_ next: StreamRoute) {
        let listeners: [AsyncStream<Void>.Continuation] = lock.withLock {
            let wake = next.wakesReader(after: route)
            route = next
            guard wake else { return [] }
            revision &+= 1
            let listeners = Array(observers.values)
            observers.removeAll()
            return listeners
        }
        for listener in listeners { listener.yield(()); listener.finish() }
    }

    /// Wake every waiting reader now: the app just came back and its sockets were reset.
    func nudge() {
        let listeners: [AsyncStream<Void>.Continuation] = lock.withLock {
            revision &+= 1
            let listeners = Array(observers.values)
            observers.removeAll()
            return listeners
        }
        for listener in listeners { listener.yield(()); listener.finish() }
    }

    /// Registration checks the revision under the same lock used by NWPathMonitor. A transition
    /// between a network error and the retry wait therefore wakes immediately.
    func changes(after previous: UInt64) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let changed = lock.withLock {
                guard previous == revision else { return true }
                observers[id] = continuation
                return false
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.observers.removeValue(forKey: id) }
            }
            if changed { continuation.yield(()); continuation.finish() }
        }
    }

    func waitForRetry(after previous: UInt64, seconds: Double?) async {
        let updates = changes(after: previous)
        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask { for await _ in updates { break } }
            if let seconds { tasks.addTask { try? await Task.sleep(for: .seconds(seconds)) } }
            await tasks.next()
            tasks.cancelAll()
        }
    }
}
