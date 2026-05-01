import Foundation

/// Tracks provider-observed coordinator WebSocket transport quality.
/// All methods are synchronous and lock-backed so ping/write callbacks can
/// update from arbitrary URLSession queues without actor hops.
public final class NetworkQualityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRTTMs: Double = 0
    private var latestJitterMs: Double = 0
    private var previousRTTMs: Double?
    private var reconnects: UInt64 = 0
    private var writeFailures: UInt64 = 0
    private var latestWriteLatencyMs: Double = 0

    public init() {}

    public func recordPong(rttMs: Double) {
        let bounded = max(0, rttMs)
        lock.withLock {
            if let previousRTTMs {
                latestJitterMs = abs(bounded - previousRTTMs)
            }
            previousRTTMs = bounded
            latestRTTMs = bounded
        }
    }

    public func recordReconnect() {
        lock.withLock { reconnects &+= 1 }
    }

    public func recordWriteFailure() {
        lock.withLock { writeFailures &+= 1 }
    }

    public func recordWriteLatency(ms: Double) {
        lock.withLock { latestWriteLatencyMs = max(0, ms) }
    }

    public func snapshot() -> NetworkQuality {
        lock.withLock {
            NetworkQuality(
                rttMs: latestRTTMs,
                jitterMs: latestJitterMs,
                reconnectCount: reconnects,
                websocketWriteFailures: writeFailures,
                lastWriteLatencyMs: latestWriteLatencyMs
            )
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
