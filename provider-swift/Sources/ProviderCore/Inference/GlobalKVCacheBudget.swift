import Foundation
import MLX

/// Process-wide KV-cache reservation budget shared by all loaded model
/// schedulers. MLX active/cache counters are global, so per-scheduler token
/// budgets can otherwise admit requests against the same apparent headroom.
public actor GlobalKVCacheBudget {
    private let safetyFactor: Double
    private let reserveBytes: UInt64
    private var reservations: [String: UInt64] = [:]

    public init(reserveBytes: UInt64 = 0, safetyFactor: Double = 0.7) {
        self.reserveBytes = reserveBytes
        self.safetyFactor = safetyFactor
    }

    public func reserve(requestID: String, kvBytesPerToken: Int, tokenCount: Int) -> Bool {
        guard kvBytesPerToken > 0, tokenCount > 0 else { return false }
        let bytesNeeded = UInt64(kvBytesPerToken) * UInt64(tokenCount)
        let available = availableReservationBytes()
        if bytesNeeded > available { return false }
        reservations[requestID] = bytesNeeded
        return true
    }

    public func release(requestID: String) {
        reservations.removeValue(forKey: requestID)
    }

    private func availableReservationBytes() -> UInt64 {
        let total = ProcessInfo.processInfo.physicalMemory
        let active = UInt64(MLX.GPU.activeMemory)
        let cache = UInt64(MLX.GPU.cacheMemory)
        let reserved = reservations.values.reduce(UInt64(0), +)
        let used = active + cache + reserveBytes + reserved
        let usable = total > used ? total - used : 0
        return UInt64(Double(usable) * safetyFactor)
    }
}
