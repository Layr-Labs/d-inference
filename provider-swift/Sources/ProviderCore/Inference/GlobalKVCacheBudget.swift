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

    /// One ledger entry: the promised bytes plus when the promise was made.
    /// The creation instant exists solely for the stale-reservation audit —
    /// a reservation that outlives any plausible request/load lifetime while
    /// the budget rejects everything is, by definition, leaked bookkeeping.
    struct Reservation: Sendable {
        var bytes: UInt64
        let createdAt: ContinuousClock.Instant
    }

    private var reservations: [String: Reservation] = [:]

    // MARK: - Sustained-rejection audit state (v0.7.3 black-hole hardening)
    //
    // The 0.7.2 incident class: the budget's headroom terms wedge (leaked
    // reservation / retained active memory) and EVERY commit fails forever,
    // while the cache-pool reclaimer — the only self-heal that existed —
    // can't help because the binding term isn't the reclaimable pool. These
    // fields turn that permanent black hole into a bounded blip: when every
    // commit has failed for `sustainedRejectionAuditThreshold` straight —
    // as one CONTINUOUS streak (gaps between rejections no longer than
    // `rejectionStreakContinuityWindow`; a wedged box under coordinator
    // routing rejects far more often than that) — the budget logs the FULL
    // reservation table at ERROR severity and drops any reservation older
    // than `staleReservationTTL` with a WARN. Live requests/loads hold
    // their reservations for seconds-to-minutes, so a multi-minute-old
    // reservation during a full-rejection streak is leaked bookkeeping,
    // not live work. The streak resets on any successful commit AND on any
    // release of a real reservation (either proves the system is making
    // progress, so live work must never age into the stale-drop).
    private var rejectionStreakStart: ContinuousClock.Instant?
    private var lastRejectionAt: ContinuousClock.Instant?
    private var lastAuditAt: ContinuousClock.Instant?
    private let sustainedRejectionAuditThreshold: Duration
    private let rejectionStreakContinuityWindow: Duration
    private let staleReservationTTL: Duration
    private let auditMinInterval: Duration
    private let emitAuditEvent: @Sendable (TelemetrySeverity, String, [String: AnyCodableValue]) -> Void

    /// Every commit must have failed for this long before the audit runs.
    /// Well above any transient rejection burst (the coordinator reroutes in
    /// seconds), far below the incident's 40+ minutes of black hole.
    static let defaultSustainedRejectionAuditThreshold: Duration = .seconds(120)
    /// Maximum gap between two consecutive rejections for them to count as
    /// ONE sustained streak; a longer gap RESTARTS the streak at the newer
    /// rejection. Without this, sparse organic traffic (requests minutes
    /// apart, each rejected) would satisfy the 120 s threshold by wall
    /// clock alone and the audit could drop reservations backing LIVE
    /// long-running work — a 32k-token decode at 10 tps holds its
    /// reservation ~50 min, a slow pending model load can exceed 10 min.
    /// 30 s: a genuinely black-holed box under coordinator routing sees
    /// rejections many times per window (routing retries + heartbeat-driven
    /// traffic are seconds apart), so the real incident shape always
    /// sustains the streak, while anything sparser is idle-gapped traffic
    /// the audit must ignore.
    static let defaultRejectionStreakContinuityWindow: Duration = .seconds(30)
    /// A reservation older than this is considered leaked *during a
    /// sustained full-rejection streak*. Requests hold reservations for the
    /// request duration (worst realistic long decode: minutes); pending-load
    /// reservations for the container-allocation window (also minutes).
    static let defaultStaleReservationTTL: Duration = .seconds(600)
    /// Rate limit between audits so a wedged box logs one CRITICAL per
    /// interval, not one per rejected request.
    static let defaultAuditMinInterval: Duration = .seconds(60)

    /// The reclaimable-pool flush runs in this reclaimer, off the budget actor.
    /// The admission paths only ever signal it (non-blocking); the blocking GPU
    /// sync happens on the reclaimer's executor, so the budget actor is never
    /// blocked on a GPU synchronize — the invariant this design exists to
    /// guarantee.
    private let reclaimer: KVPoolReclaimer
    static let defaultSelfHealMinInterval: Duration = KVPoolReclaimer.defaultMinInterval

    public init(
        capFraction: Double? = nil,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0
    ) {
        self.capFraction = capFraction
        self.activationReserveBytes = activationReserveBytes
        self.configReserveBytes = configReserveBytes
        self.sustainedRejectionAuditThreshold = Self.defaultSustainedRejectionAuditThreshold
        self.rejectionStreakContinuityWindow = Self.defaultRejectionStreakContinuityWindow
        self.staleReservationTTL = Self.defaultStaleReservationTTL
        self.auditMinInterval = Self.defaultAuditMinInterval
        self.emitAuditEvent = { severity, message, fields in
            TelemetryClient.shared.emit(
                kind: .engineHealth, severity: severity, message: message, fields: fields)
        }
        // Fence async GPU completion before freeing buffers, matching the engine's
        // own reclaim paths (avoids the IOKit completeMemory race seen on M4).
        let clearCache: @Sendable () -> Void = {
            MLX.Stream().synchronize()
            MLX.Memory.clearCache()
        }
        let snapshot: @Sendable () -> MemorySnapshot = {
            MemorySnapshot(
                total: ProcessInfo.processInfo.physicalMemory,
                active: UInt64(Memory.activeMemory),
                cache: UInt64(Memory.cacheMemory),
                // Real OS-free RAM; `.max` falls back to the MLX-only view.
                systemAvailable: SystemMemory.availableBytes() ?? .max)
        }
        self.memorySnapshot = snapshot
        self.reclaimer = KVPoolReclaimer(
            clearCache: clearCache,
            reclaimableBytes: { snapshot().cache })
    }

    init(
        capFraction: Double? = nil,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        memorySnapshot: @escaping @Sendable () -> MemorySnapshot,
        clearCache: @escaping @Sendable () -> Void = {},
        selfHealMinInterval: Duration = GlobalKVCacheBudget.defaultSelfHealMinInterval,
        reclaimer: KVPoolReclaimer? = nil,
        sustainedRejectionAuditThreshold: Duration = GlobalKVCacheBudget.defaultSustainedRejectionAuditThreshold,
        rejectionStreakContinuityWindow: Duration = GlobalKVCacheBudget.defaultRejectionStreakContinuityWindow,
        staleReservationTTL: Duration = GlobalKVCacheBudget.defaultStaleReservationTTL,
        auditMinInterval: Duration = GlobalKVCacheBudget.defaultAuditMinInterval,
        emitAuditEvent: @escaping @Sendable (TelemetrySeverity, String, [String: AnyCodableValue]) -> Void = { _, _, _ in }
    ) {
        self.capFraction = capFraction
        self.activationReserveBytes = activationReserveBytes
        self.configReserveBytes = configReserveBytes
        self.memorySnapshot = memorySnapshot
        self.sustainedRejectionAuditThreshold = sustainedRejectionAuditThreshold
        self.rejectionStreakContinuityWindow = rejectionStreakContinuityWindow
        self.staleReservationTTL = staleReservationTTL
        self.auditMinInterval = auditMinInterval
        self.emitAuditEvent = emitAuditEvent
        self.reclaimer = reclaimer ?? KVPoolReclaimer(
            clearCache: clearCache,
            reclaimableBytes: { memorySnapshot().cache },
            minInterval: selfHealMinInterval,
            // Tests that don't pin a threshold should never trip the proactive
            // sweep on their tiny synthetic pools — keep the production default.
            proactiveThresholdBytes: KVPoolReclaimer.defaultProactiveThresholdBytes)
    }

    public func reserve(requestID: String, kvBytesPerToken: Int, tokenCount: Int) -> Bool {
        guard kvBytesPerToken > 0, tokenCount > 0 else { return false }
        guard reservations[requestID] == nil else { return false }
        let (bytesNeeded, overflow) = UInt64(kvBytesPerToken).multipliedReportingOverflow(by: UInt64(tokenCount))
        if overflow { return false }
        return commit(requestID: requestID, bytes: bytesNeeded)
    }

    public func release(requestID: String) {
        guard reservations.removeValue(forKey: requestID) != nil else { return }
        // A real reservation just drained — in-flight work is terminating
        // normally, so this is not the reject-everything black hole the
        // audit exists for. Reset the streak so a long-lived LIVE
        // reservation (multi-10-minute decode, slow pending load) can never
        // age into the audit's stale-drop while the table is demonstrably
        // making progress. Unknown ids don't count: they prove nothing.
        rejectionStreakStart = nil
        lastRejectionAt = nil
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

    /// Atomically grow an existing request reservation. Used when SSD staging
    /// reveals native KV width (for example GPT-OSS fp32 full rows) after the
    /// initial nominal token reservation was taken.
    public func increaseReservation(requestID: String, additionalBytes: UInt64) -> Bool {
        guard additionalBytes > 0, var current = reservations[requestID] else {
            return additionalBytes == 0 && reservations[requestID] != nil
        }
        let (newBytes, overflow) = current.bytes.addingReportingOverflow(additionalBytes)
        guard !overflow else { return false }
        let available = availableReservationBytes()
        guard additionalBytes <= available else {
            reclaimer.scheduleReclaim(shortfall: additionalBytes - available)
            recordCommitRejection()
            return false
        }
        current.bytes = newBytes
        reservations[requestID] = current
        rejectionStreakStart = nil
        lastRejectionAt = nil
        return true
    }

    /// Atomically resize an existing raw-byte reservation after encrypted file
    /// estimates have been rehydrated into exact MLX arrays.
    public func resizeReservationBytes(requestID: String, bytes: UInt64) -> Bool {
        guard bytes > 0, var current = reservations[requestID] else { return false }
        if bytes > current.bytes {
            let additional = bytes - current.bytes
            let available = availableReservationBytes()
            guard additional <= available else {
                reclaimer.scheduleReclaim(shortfall: additional - available)
                recordCommitRejection()
                return false
            }
        }
        current.bytes = bytes
        reservations[requestID] = current
        rejectionStreakStart = nil
        lastRejectionAt = nil
        return true
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
        reservations[requestID] = Reservation(bytes: bytes, createdAt: .now)
    }

    /// Atomically replace the in-flight load reservation when target weights
    /// become live but an optional assistant is still pending. Zero removes it.
    public func replacePendingLoadReservation(requestID: String, bytes: UInt64) {
        let previous = reservations[requestID]?.bytes
        if bytes == 0 {
            reservations.removeValue(forKey: requestID)
        } else if let createdAt = reservations[requestID]?.createdAt {
            reservations[requestID] = Reservation(bytes: bytes, createdAt: createdAt)
        } else {
            reservations[requestID] = Reservation(bytes: bytes, createdAt: .now)
        }
        // Removing or shrinking a real pending-load promise proves the ledger
        // is making progress, exactly like `release`. Do not let a rejection
        // streak armed against the larger footprint audit live reservations.
        if let previous, bytes < previous {
            rejectionStreakStart = nil
            lastRejectionAt = nil
        }
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
        if newBytes < current.bytes {
            // Only ever shrink; frees the difference; never fails. Keeps the
            // original creation instant — a shrink is not a new promise.
            reservations[requestID]?.bytes = newBytes
        }
    }

    /// Total KV bytes currently promised to in-flight requests. The model-load
    /// gate subtracts this so a new model's weights can't be loaded into memory
    /// already reserved for a request that is mid-decode (those bytes may not
    /// yet show up in MLX.active/cache, so the load gate would otherwise treat
    /// promised memory as free and risk an OOM).
    public func outstandingReservedBytes() -> UInt64 {
        reservations.values.reduce(UInt64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value.bytes)
            return overflow ? UInt64.max : sum
        }
    }

    /// Reserve `bytes` against the current live headroom. The headroom math counts
    /// the reclaimable MLX pool as used; on a near-miss we signal the off-actor
    /// reclaimer to shrink that pool for future admissions and reject this request
    /// against the current snapshot. We do not flush-and-resample inline: that
    /// would run a blocking GPU sync on this actor and serialize every other
    /// reservation behind it. Rejecting a near-miss is acceptable — the
    /// coordinator and per-provider breaker reroute, and the background reclaim
    /// keeps the pool small so most admissions succeed without ever near-missing.
    /// Caller has validated `bytes > 0` and no existing reservation.
    private func commit(requestID: String, bytes: UInt64) -> Bool {
        let available = availableReservationBytes()
        guard bytes <= available else {
            reclaimer.scheduleReclaim(shortfall: bytes - available)   // non-blocking; flush runs off-actor
            recordCommitRejection()
            return false
        }
        reservations[requestID] = Reservation(bytes: bytes, createdAt: .now)
        rejectionStreakStart = nil
        lastRejectionAt = nil
        return true
    }

    // MARK: - Sustained-rejection reservation audit (v0.7.3)

    /// Called on every failed commit. When EVERY commit has failed for
    /// `sustainedRejectionAuditThreshold` straight — the black-hole signature:
    /// the coordinator keeps routing, the provider keeps rejecting, and the
    /// cache-pool reclaimer isn't helping — log the full reservation table at
    /// ERROR severity and drop any reservation older than
    /// `staleReservationTTL` with a WARN. Live requests hold reservations for
    /// seconds-to-minutes and release them on every terminal path; pending
    /// loads release once weights are resident. A reservation that has
    /// out-lived the TTL *while nothing at all is being admitted* is leaked
    /// bookkeeping, and dropping it converts a permanent reject-everything
    /// wedge into a self-healed blip. Rate-limited to one audit per
    /// `auditMinInterval`.
    ///
    /// "Straight" is enforced two ways (both required, or sparse traffic
    /// could satisfy the threshold by wall clock alone and drop LIVE work):
    ///   * continuity — a gap since the PREVIOUS rejection longer than
    ///     `rejectionStreakContinuityWindow` restarts the streak here;
    ///   * progress — a successful commit (in `commit`) or a real release
    ///     (in `release`) resets the streak entirely.
    private func recordCommitRejection() {
        let now = ContinuousClock.now
        if let previous = lastRejectionAt, now - previous > rejectionStreakContinuityWindow {
            // Idle gap: two rejections minutes apart are sparse traffic, not
            // a black hole — a genuinely wedged box under coordinator
            // routing rejects many times per continuity window.
            rejectionStreakStart = nil
        }
        lastRejectionAt = now
        if rejectionStreakStart == nil {
            rejectionStreakStart = now
            return
        }
        guard let streakStart = rejectionStreakStart,
            now - streakStart >= sustainedRejectionAuditThreshold
        else { return }
        if let last = lastAuditAt, now - last < auditMinInterval { return }
        lastAuditAt = now

        let snap = memorySnapshot()
        let table = reservations
            .map { id, r in
                "\(id)=\(r.bytes)B age=\(Int((now - r.createdAt).components.seconds))s"
            }
            .sorted()
            .joined(separator: ", ")
        let streakSeconds = Int((now - streakStart).components.seconds)
        emitAuditEvent(
            .error,
            "kv budget: every reservation rejected for \(streakSeconds)s — auditing reservation table",
            [
                "operation": .string("kv_budget_sustained_rejection"),
                "streak_seconds": .int(streakSeconds),
                "reservation_count": .int(reservations.count),
                "reserved_bytes": .string(String(outstandingReservedBytes())),
                "mlx_active_bytes": .string(String(snap.active)),
                "mlx_cache_bytes": .string(String(snap.cache)),
                "system_available_bytes": .string(String(snap.systemAvailable)),
                "reservations": .string(table),
            ])

        let staleIDs = reservations.filter { now - $0.value.createdAt >= staleReservationTTL }
        guard !staleIDs.isEmpty else { return }
        for (id, r) in staleIDs {
            reservations.removeValue(forKey: id)
            emitAuditEvent(
                .warn,
                "kv budget: dropped stale reservation during sustained full-rejection",
                [
                    "operation": .string("kv_budget_stale_reservation_dropped"),
                    "request_id": .string(id),
                    "reserved_bytes": .string(String(r.bytes)),
                    "age_seconds": .int(Int((now - r.createdAt).components.seconds)),
                ])
        }
        // Freed headroom — let the next commit start a fresh verdict.
        rejectionStreakStart = nil
    }

    /// Signal the off-actor reclaimer to flush the reclaimable MLX pool for a
    /// shortfall observed by the scheduler's token-budget gate. Non-blocking and
    /// `nonisolated` (it touches no actor state — only the immutable reclaimer),
    /// so the caller doesn't even hop this actor: the GPU sync runs on the
    /// reclaimer, never here (it used to run inline as a blocking synchronize,
    /// which wedged the admission actor). The reclaimer gates on whether the pool
    /// can cover the shortfall and rate-limits, so this is an unconditional
    /// fire-and-forget.
    public nonisolated func reclaimForShortfall(_ shortfall: UInt64) {
        guard shortfall > 0 else { return }
        reclaimer.scheduleReclaim(shortfall: shortfall)
    }

    /// Trigger a proactive, rate-limited, threshold-gated background sweep of the
    /// reclaimable MLX pool so admission headroom stays healthy under sustained
    /// load without any inline flush. Non-blocking and `nonisolated`. Called
    /// periodically by the scheduler watchdog while a model is loaded.
    public nonisolated func proactiveReclaimSweep() {
        reclaimer.scheduleSweep()
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
            let (sum, overflow) = partial.addingReportingOverflow(value.bytes)
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

    // MARK: - Test support

    /// The off-actor reclaimer, so tests can drive `reclaimIfNeeded`/`sweep`
    /// deterministically (they run the injected `clearCache` synchronously on the
    /// reclaimer actor) instead of racing the fire-and-forget signal tasks.
    var reclaimerForTesting: KVPoolReclaimer { reclaimer }

    func rejectionStreakArmedForTesting() -> Bool {
        rejectionStreakStart != nil || lastRejectionAt != nil
    }

    /// Current reservation ids, so tests can assert the ledger is empty (or
    /// holds exactly the expected live entries) after a load/audit sequence.
    func reservationIDsForTesting() -> [String] { Array(reservations.keys) }
}
