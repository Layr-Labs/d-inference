import Foundation
import MLX

/// Process-wide KV-cache reservation budget shared by all loaded model
/// schedulers. MLX active/cache counters are global, so per-scheduler token
/// budgets can otherwise admit requests against the same apparent headroom.
public actor GlobalKVCacheBudget {
    private let safetyFactor: Double
    private let reserveBytes: UInt64
    private let memorySnapshot: @Sendable () -> (total: UInt64, active: UInt64, cache: UInt64)
    private var reservations: [String: UInt64] = [:]

    public init(reserveBytes: UInt64 = 0, safetyFactor: Double = 0.7) {
        self.reserveBytes = reserveBytes
        self.safetyFactor = Self.clampedSafetyFactor(safetyFactor)
        self.memorySnapshot = {
            (
                total: ProcessInfo.processInfo.physicalMemory,
                active: UInt64(Memory.activeMemory),
                cache: UInt64(Memory.cacheMemory)
            )
        }
    }

    init(
        reserveBytes: UInt64 = 0,
        safetyFactor: Double = 0.7,
        memorySnapshot: @escaping @Sendable () -> (total: UInt64, active: UInt64, cache: UInt64)
    ) {
        self.reserveBytes = reserveBytes
        self.safetyFactor = Self.clampedSafetyFactor(safetyFactor)
        self.memorySnapshot = memorySnapshot
    }

    public func reserve(requestID: String, kvBytesPerToken: Int, tokenCount: Int) -> Bool {
        guard kvBytesPerToken > 0, tokenCount > 0 else { return false }
        guard reservations[requestID] == nil else { return false }
        let (bytesNeeded, overflow) = UInt64(kvBytesPerToken).multipliedReportingOverflow(by: UInt64(tokenCount))
        if overflow { return false }
        let available = availableReservationBytes()
        if bytesNeeded > available { return false }
        reservations[requestID] = bytesNeeded
        return true
    }

    public func release(requestID: String) {
        reservations.removeValue(forKey: requestID)
    }

    /// Atomically shrink an existing reservation to a smaller byte count,
    /// freeing the difference. `reserve`/`release` cannot express a shrink:
    /// `reserve` refuses when an entry already exists for the id, and a
    /// release-then-reserve is non-atomic — a concurrent submit could grab the
    /// freed headroom in between, making the re-reserve spuriously fail and
    /// stranding the request with NO reservation. This only ever lowers the
    /// reserved bytes (never grows, never fails), so it is safe to call on the
    /// fallback path where a planned restore did not materialize and the request
    /// must drop back to its cold-prefill footprint. No-op if the id is unknown.
    public func reduceReservation(requestID: String, kvBytesPerToken: Int, tokenCount: Int) {
        guard let current = reservations[requestID], kvBytesPerToken > 0, tokenCount > 0 else { return }
        let (bytes, overflow) = UInt64(kvBytesPerToken).multipliedReportingOverflow(by: UInt64(tokenCount))
        let newBytes = overflow ? UInt64.max : bytes
        if newBytes < current { reservations[requestID] = newBytes }   // only ever shrink; frees the difference; never fails
    }

    /// Total KV bytes currently promised to in-flight requests. The model-load
    /// gate subtracts this so a new model's weights can't be loaded into memory
    /// already reserved for a request that is mid-decode (those bytes may not
    /// yet show up in MLX.active/cache, so the load gate would otherwise treat
    /// promised memory as free and risk an OOM).
    public func outstandingReservedBytes() -> UInt64 {
        reservations.values.reduce(UInt64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
    }

    private func availableReservationBytes() -> UInt64 {
        let (total, active, cache) = memorySnapshot()
        let usedBeforeReservations = Self.saturatingAdd(active, cache, reserveBytes)
        let usable = total > usedBeforeReservations ? total - usedBeforeReservations : 0
        let capped = Double(usable) * safetyFactor
        let reservationCap = capped >= Double(UInt64.max) ? UInt64.max : UInt64(capped)
        let reserved = reservations.values.reduce(UInt64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
        return reservationCap > reserved ? reservationCap - reserved : 0
    }

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return UInt64.max }
            total = sum
        }
        return total
    }

    private static func clampedSafetyFactor(_ value: Double) -> Double {
        guard value.isFinite else { return 0.7 }
        return min(1.0, max(0.0, value))
    }
}
