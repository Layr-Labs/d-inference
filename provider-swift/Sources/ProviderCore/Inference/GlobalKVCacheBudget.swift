import Foundation
import MLX

/// Process-wide KV-cache reservation budget shared by all loaded model
/// schedulers. MLX active/cache counters are global, so per-scheduler token
/// budgets can otherwise admit requests against the same apparent headroom.
public actor GlobalKVCacheBudget {
    /// The four memory figures an admission decision needs: physical total, MLX's
    /// own active + cache, and the OS's real free RAM (the cross-process view).
    public struct MemorySnapshot: Sendable {
        public var total: UInt64
        public var active: UInt64
        public var cache: UInt64
        public var systemAvailable: UInt64
    }

    /// Cap fraction and activation reserve are nil → ``UnifiedMemoryCap``
    /// defaults (0.90 / env / 3 GiB floor). Held as overrides so tests can pin
    /// them; production uses the defaults so this budget and the load gate share
    /// one policy.
    private let capFraction: Double?
    private let activationReserveBytes: UInt64?
    /// Operator-configured reserve (`memory_reserve_gb`, in bytes). Held back by
    /// the live KV gate just as the load gate holds it back, so runtime KV can't
    /// grow into memory the operator reserved. 0 = no extra reserve (cap only).
    private let configReserveBytes: UInt64
    private let memorySnapshot: @Sendable () -> MemorySnapshot
    private let clearCache: @Sendable () -> Void
    private var reservations: [String: UInt64] = [:]
    /// Minimum reclaimable MLX pool worth flushing on the admission self-heal.
    /// Below this, a flush frees too little to change an admission decision, so the
    /// heal is skipped — the case when active memory (not the pool) is what's full.
    private static let minReclaimableForHealBytes: UInt64 = 256 * 1024 * 1024

    public init(
        capFraction: Double? = nil,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0
    ) {
        self.capFraction = capFraction
        self.activationReserveBytes = activationReserveBytes
        self.configReserveBytes = configReserveBytes
        // Fence async GPU completion before freeing buffers, matching the engine's
        // own reclaim paths (avoids the IOKit completeMemory race seen on M4).
        self.clearCache = {
            MLX.Stream().synchronize()
            MLX.Memory.clearCache()
        }
        self.memorySnapshot = {
            MemorySnapshot(
                total: ProcessInfo.processInfo.physicalMemory,
                active: UInt64(Memory.activeMemory),
                cache: UInt64(Memory.cacheMemory),
                // Real OS-free RAM; `.max` falls back to the MLX-only view.
                systemAvailable: SystemMemory.availableBytes() ?? .max)
        }
    }

    init(
        capFraction: Double? = nil,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        memorySnapshot: @escaping @Sendable () -> MemorySnapshot,
        clearCache: @escaping @Sendable () -> Void = {}
    ) {
        self.capFraction = capFraction
        self.activationReserveBytes = activationReserveBytes
        self.configReserveBytes = configReserveBytes
        self.memorySnapshot = memorySnapshot
        self.clearCache = clearCache
    }

    public func reserve(requestID: String, kvBytesPerToken: Int, tokenCount: Int) -> Bool {
        guard kvBytesPerToken > 0, tokenCount > 0 else { return false }
        guard reservations[requestID] == nil else { return false }
        let (bytesNeeded, overflow) = UInt64(kvBytesPerToken).multipliedReportingOverflow(by: UInt64(tokenCount))
        if overflow { return false }
        return commit(requestID: requestID, bytes: bytesNeeded)
    }

    public func release(requestID: String) {
        reservations.removeValue(forKey: requestID)
    }

    /// Reserve an arbitrary BYTE amount against the same live cap headroom KV
    /// uses. For non-KV unified-memory consumers that the cap would otherwise be
    /// blind to — notably VLM media decode (CIImage rasters + Swift Data pixel
    /// buffers live in the same unified RAM as MLX arrays but are NOT counted by
    /// MLX.GPU.active/cache). Reserving here makes those bytes share the 90% cap:
    /// the decode is admitted only if it fits alongside resident weights + KV +
    /// activations, and rejected (caller surfaces 429/retry) otherwise. Returns
    /// false if it won't fit or the id is already reserved. Pair with `release`.
    public func reserveBytes(requestID: String, bytes: UInt64) -> Bool {
        guard bytes > 0 else { return false }
        guard reservations[requestID] == nil else { return false }
        return commit(requestID: requestID, bytes: bytes)
    }

    /// Reserve a loading model's WEIGHT footprint for the duration of its load,
    /// unconditionally. A model's weights are not yet visible in MLX active/cache
    /// while `loadModelContainer` is still allocating them, so a KV reservation
    /// granted on an ALREADY-loaded model during that window would compute its
    /// headroom blind to the incoming weights and could push total usage past the
    /// cap — a transient OOM on the normal serve-while-load path. Reserving the
    /// footprint here makes those in-flight weights visible to `reserve` /
    /// `reserveBytes`, so concurrent KV can only claim `headroom − weights`.
    ///
    /// Unconditional (never fails): the load gate has already admitted the model,
    /// so this is bookkeeping for the load that WILL happen, not a second gate.
    /// It reserves only the weight estimate, so concurrent KV that still fits
    /// underneath is admitted; only reservations that would over-commit are
    /// rejected (caller surfaces 429/retry). Released once the weights are
    /// resident (and thus reflected in `mlxUsed`). Pair with `release`.
    public func reservePendingLoad(requestID: String, bytes: UInt64) {
        guard bytes > 0 else { return }
        reservations[requestID] = bytes
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

    /// Reserve `bytes` against current live headroom. The headroom math counts the
    /// reclaimable MLX pool as used, so on a near-miss we flush that pool and
    /// resample once before denying — otherwise we'd reject a request the box can
    /// actually serve. Caller has validated `bytes > 0` and no existing reservation.
    private func commit(requestID: String, bytes: UInt64) -> Bool {
        var available = availableReservationBytes()
        if bytes > available {
            if selfHealClear() { available = availableReservationBytes() }
            if bytes > available { return false }
        }
        reservations[requestID] = bytes
        return true
    }

    /// One-shot reclaim for the admission self-heal. Returns true if it actually
    /// flushed the pool (so the caller should resample). Skips the flush when the
    /// reclaimable pool is already small — e.g. when active memory (not the pool)
    /// is what's full, so a flush frees nothing — to avoid thrashing the pool (and
    /// stalling on its GPU sync) on every rejected admission under sustained load.
    private func selfHealClear() -> Bool {
        guard memorySnapshot().cache >= Self.minReclaimableForHealBytes else { return false }
        clearCache()
        return true
    }

    private func availableReservationBytes() -> UInt64 {
        let snap = memorySnapshot()
        let mlxUsed = Self.saturatingAdd(snap.active, snap.cache)
        // Bytes still committable to KV under the 90% unified-memory cap, given
        // current MLX usage (which already reflects ALL co-resident models'
        // weights + KV), clamped to real OS-free RAM and net of the activation
        // reserve. This replaces the old `(free − reserve) × 0.7` formula: the
        // single cap + activation reserve are the only knobs, so this gate, the
        // per-scheduler live token budget, and the load gate no longer apply
        // three different, competing discounts.
        let reservationCap = UnifiedMemoryCap.liveKVHeadroomBytes(
            physicalBytes: snap.total,
            mlxUsedBytes: mlxUsed,
            systemAvailableBytes: snap.systemAvailable,
            activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes,
            capFraction: capFraction)
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

}
