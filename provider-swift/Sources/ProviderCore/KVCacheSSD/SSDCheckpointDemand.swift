import Foundation

/// Bounded, volatile demand for opaque complete-checkpoint tags. It contains no
/// prompt text or tokens; tags already bind the model identity and cache scope.
/// A repeat is a write-priority hint, never authentication or a cache hit.
final class SSDCheckpointDemand: @unchecked Sendable {
    static let repeatReserveFraction = 0.1

    private let lock = NSLock()
    private let limit: Int
    private let ttlSeconds: Int64
    private var lastSeen: [Data: Int64] = [:]

    init(limit: Int = 4096, ttlSeconds: Int64) {
        self.limit = max(1, limit)
        self.ttlSeconds = max(1, ttlSeconds)
    }

    func observe(_ tag: Data, now: Int64) -> Bool {
        lock.withLock {
            let repeated: Bool
            if let previous = lastSeen[tag] {
                let (age, overflow) = now.subtractingReportingOverflow(previous)
                repeated = !overflow && age >= 0 && age < ttlSeconds
            } else {
                repeated = false
            }
            if lastSeen[tag] == nil, lastSeen.count >= limit,
                let oldest = lastSeen.min(by: { $0.value < $1.value })?.key {
                lastSeen.removeValue(forKey: oldest)
            }
            lastSeen[tag] = now
            return repeated
        }
    }

    var count: Int { lock.withLock { lastSeen.count } }
}
