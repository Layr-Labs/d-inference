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

    nonisolated let processLedger: ProcessMemoryLedger
    nonisolated let physicalMemoryBytes: UInt64
    nonisolated let loadReserveBytes: UInt64
    private var policyEpoch: UInt64 = 1
    /// Owner push epochs reject stale serving-set reserve changes.
    private var lastActivationReserveEpoch: UInt64 = 0
    private let clockNow: @Sendable () -> ContinuousClock.Instant

    /// Reservation age is diagnostic only. The owning request or load releases
    /// its charge after its actual resources retire; elapsed time is no proof.
    struct Reservation: Sendable {
        var state: ProcessMemoryLedger.OwnerState
        var bytes: UInt64 { state.chargedBytes }
        let createdAt: ContinuousClock.Instant
    }

    private var reservations: [String: Reservation] = [:]
    var pendingLoads: [ProcessMemoryLedger.Owner: PendingLoadRecord] = [:]
    var pendingLoadIDs: [String: ProcessMemoryLedger.Owner] = [:]

    // MARK: - Sustained-rejection diagnostics

    private var rejectionStreakStart: ContinuousClock.Instant?
    private var lastRejectionAt: ContinuousClock.Instant?
    private var lastAuditAt: ContinuousClock.Instant?
    private let sustainedRejectionAuditThreshold: Duration
    private let rejectionStreakContinuityWindow: Duration
    private let auditMinInterval: Duration
    private let emitAuditEvent: @Sendable (TelemetrySeverity, String, [String: AnyCodableValue]) -> Void

    /// Audit continuous rejection after two minutes; sparse requests restart
    /// the streak and progress clears it. Audits never release reservations.
    static let defaultSustainedRejectionAuditThreshold: Duration = .seconds(120)
    static let defaultRejectionStreakContinuityWindow: Duration = .seconds(30)
    static let defaultAuditMinInterval: Duration = .seconds(60)

    /// The reclaimable-pool flush runs in this reclaimer, off the budget actor.
    /// The admission paths only ever signal it (non-blocking); the blocking GPU
    /// sync happens on the reclaimer's executor, so the budget actor is never
    /// blocked on a GPU synchronize — the invariant this design exists to
    /// guarantee.
    private let reclaimer: KVPoolReclaimer
    static let defaultSelfHealMinInterval: Duration = KVPoolReclaimer.defaultMinInterval

    /// Swift initializes this once, on first use. Keep constructors free of MLX
    /// access so callers can bind the immutable runtime metallib before serving.
    /// The ledger invokes this before its lock; native owners warm it even earlier,
    /// before their Admission exists. Later calls do no allocator initialization.
    private static let allocatorReady: Void = { _ = Memory.snapshot() }()

    public init(
        capFraction: Double? = nil,
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0
    ) {
        self.sustainedRejectionAuditThreshold = Self.defaultSustainedRejectionAuditThreshold
        self.rejectionStreakContinuityWindow = Self.defaultRejectionStreakContinuityWindow
        self.clockNow = { .now }
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
            let mlx = Memory.snapshot()
            return MemorySnapshot(
                total: ProcessInfo.processInfo.physicalMemory,
                active: UInt64(max(0, mlx.activeMemory)),
                cache: UInt64(max(0, mlx.cacheMemory)),
                // Real OS-free RAM; `.max` falls back to the MLX-only view.
                systemAvailable: SystemMemory.availableBytes() ?? .max)
        }
        let total = ProcessInfo.processInfo.physicalMemory
        self.physicalMemoryBytes = total
        self.loadReserveBytes = UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: total, configReserveBytes: configReserveBytes, capFraction: capFraction)
        self.processLedger = Self.makeLedger(
            total: total, capFraction: capFraction, activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes,
            prepareUsage: { _ = Self.allocatorReady }, snapshot: snapshot)
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
        auditMinInterval: Duration = GlobalKVCacheBudget.defaultAuditMinInterval,
        clockNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        emitAuditEvent: @escaping @Sendable (TelemetrySeverity, String, [String: AnyCodableValue]) -> Void = { _, _, _ in }
    ) {
        let total = memorySnapshot().total
        self.physicalMemoryBytes = total
        self.loadReserveBytes = UnifiedMemoryCap.loadReserveBytes(
            physicalBytes: total, configReserveBytes: configReserveBytes, capFraction: capFraction)
        self.processLedger = Self.makeLedger(
            total: total, capFraction: capFraction, activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes, snapshot: memorySnapshot)
        self.sustainedRejectionAuditThreshold = sustainedRejectionAuditThreshold
        self.rejectionStreakContinuityWindow = rejectionStreakContinuityWindow
        self.clockNow = clockNow
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

    /// Replace the activation reserve this budget carves out of the cap.
    /// Called by the owner when its advertised serving set changes (a
    /// prefetch-verified build was advertised, or a superseded build dropped)
    /// with the freshly resolved
    /// `UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs:)` — the
    /// raise must land BEFORE the added model becomes loadable so a decode
    /// step of the new model can never run against the smaller reserve.
    /// Passing nil restores the flat default resolution.
    ///
    /// `epoch`: the owner's monotonic push sequence, stamped under the
    /// owner's actor isolation. Cross-actor jobs from different tasks are
    /// not FIFO, so two concurrent set mutations can deliver their pushes
    /// out of order — a stale value landing last would leave the budget
    /// admitting against a reserve the serving set no longer resolves to.
    /// A push whose epoch is not newer than the last applied one is
    /// DISCARDED. nil (tests/simple callers) applies unconditionally and
    /// leaves the recorded epoch untouched.
    public func setActivationReserveBytes(_ bytes: UInt64?, epoch: UInt64? = nil) {
        if let epoch {
            guard epoch > lastActivationReserveEpoch else { return }
            lastActivationReserveEpoch = epoch
        }
        policyEpoch += 1
        let previous = processLedger.policySnapshot()
        processLedger.updatePolicy(.init(
            epoch: policyEpoch, capBytes: previous.capBytes,
            reserveBytes: bytes ?? UnifiedMemoryCap.resolvedActivationReserveBytes()))
    }

    public func reserve(requestID: String, kvBytesPerToken: Int, tokenCount: Int) -> Bool {
        guard kvBytesPerToken > 0, tokenCount > 0 else { return false }
        guard !reservationExists(requestID) else { return false }
        let (bytesNeeded, overflow) = UInt64(kvBytesPerToken).multipliedReportingOverflow(by: UInt64(tokenCount))
        if overflow { return false }
        return commit(requestID: requestID, bytes: bytesNeeded)
    }

    public func release(requestID: String) {
        guard let reservation = reservations.removeValue(forKey: requestID) else { return }
        // Legacy host/request owners have no materialized coverage. The native
        // engine owner is separate and retires exclusively through its lease.
        do {
            _ = try processLedger.replaceCharge(
                owner: reservation.state.owner, expectedRevision: reservation.state.revision,
                expectedPolicyEpoch: 0, chargedBytes: 0)
            _ = processLedger.retire(reservation.state.owner)
        } catch {
            // Preserve correlation if an ownership invariant failed; never erase
            // the only diagnostic record of a still-charged owner.
            reservations[requestID] = reservation
            return
        }
        recordReservationProgress()
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
        guard !reservationExists(requestID) else { return false }
        return commit(requestID: requestID, bytes: bytes)
    }

    /// Atomically resize an existing raw-byte reservation after encrypted file
    /// estimates have been rehydrated into exact MLX arrays.
    public func resizeReservationBytes(requestID: String, bytes: UInt64) -> Bool {
        guard bytes > 0, var current = reservations[requestID] else { return false }
        do {
            current.state = try processLedger.replaceCharge(
                owner: current.state.owner, expectedRevision: current.state.revision,
                expectedPolicyEpoch: processLedger.policySnapshot().epoch, chargedBytes: bytes)
        } catch {
            if bytes > current.bytes { recordReservationRefusal(bytes: bytes - current.bytes) }
            return false
        }
        reservations[requestID] = current
        recordReservationProgress()
        return true
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
            _ = resizeReservationBytes(requestID: requestID, bytes: newBytes)
        }
    }

    /// Total owned C, including materialized native backing. Admission readers
    /// must use memoryHeadroomSnapshot().unmaterializedCommittedBytes instead.
    public func outstandingReservedBytes() -> UInt64 {
        processLedger.snapshot().chargedBytes
    }

    private func commit(requestID: String, bytes: UInt64) -> Bool {
        let owner = processLedger.createOwner()
        do {
            let accepted = try processLedger.replaceCharge(
                owner: owner.owner, expectedRevision: owner.revision,
                expectedPolicyEpoch: processLedger.policySnapshot().epoch, chargedBytes: bytes)
            reservations[requestID] = Reservation(state: accepted, createdAt: clockNow())
        } catch {
            _ = processLedger.retire(owner.owner)
            recordReservationRefusal(bytes: bytes)
            return false
        }
        recordReservationProgress()
        return true
    }

    func recordReservationProgress() {
        rejectionStreakStart = nil
        lastRejectionAt = nil
    }

    func reservationExists(_ requestID: String) -> Bool {
        reservations[requestID] != nil || pendingLoadIDs[requestID] != nil
    }

    func reservationClockNow() -> ContinuousClock.Instant { clockNow() }

    func recordReservationRefusal(bytes: UInt64) {
        let available = processLedger.snapshot().remainingBytes
        if bytes > available { reclaimer.scheduleReclaim(shortfall: bytes - available) }
        recordCommitRejection()
    }

    // MARK: - Sustained-rejection diagnostics

    /// Rate-limited diagnosis of continuous capacity rejection. A long decode
    /// or load can legitimately retain the entire budget while new arrivals
    /// fail. Log its ownership; only its actual release can refund the charge.
    private func recordCommitRejection() {
        let now = clockNow()
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

        let headroom = memoryHeadroomSnapshot()
        let requestRows = reservations.map { id, reservation in
            "\(id)=\(reservation.bytes)B age=\(Int((now - reservation.createdAt).components.seconds))s"
        }
        let loadRows = pendingLoads.values.map { reservation in
            "\(reservation.requestID)=\(reservation.state.chargedBytes)B "
                + "age=\(Int((now - reservation.createdAt).components.seconds))s"
        }
        let table = (requestRows + loadRows).sorted().joined(separator: ", ")
        let streakSeconds = Int((now - streakStart).components.seconds)
        emitAuditEvent(
            .error,
            "kv budget: every reservation rejected for \(streakSeconds)s — auditing reservation table",
            [
                "operation": .string("kv_budget_sustained_rejection"),
                "streak_seconds": .int(streakSeconds),
                "reservation_count": .int(headroom.ownerCount),
                "reserved_bytes": .string(String(headroom.totalOwnedBytes)),
                "mlx_active_bytes": .string(String(headroom.activeBytes)),
                "mlx_cache_bytes": .string(String(headroom.cacheBytes)),
                "system_available_bytes": .string(String(headroom.systemAvailableBytes)),
                "reservations": .string(table),
            ])
    }

    /// Trigger a proactive, rate-limited, threshold-gated background sweep of the
    /// reclaimable MLX pool so admission headroom stays healthy under sustained
    /// load without any inline flush, and freed KV/activation buffers are
    /// returned to the OS instead of accumulating below the cache limit.
    /// Non-blocking and `nonisolated` (it touches no actor state — only the
    /// immutable reclaimer). Driven periodically by ProviderLoop's
    /// capacity-refresh tick and StandaloneServer's sweep task.
    public nonisolated func proactiveReclaimSweep() {
        reclaimer.scheduleSweep()
    }

    /// Heartbeat-facing cumulative reclaim counters. The snapshot is lock-backed
    /// and never hops the reclaimer actor, so a GPU synchronize already running
    /// there cannot delay capacity reporting or request admission.
    nonisolated func cacheReclaimerTelemetrySnapshot() -> KVPoolReclaimer.TelemetrySnapshot {
        reclaimer.telemetrySnapshot()
    }

    nonisolated func makeEngineMemoryOwner() -> EngineProcessMemoryOwner {
        EngineProcessMemoryOwner(ledger: processLedger)
    }

    private static func makeLedger(
        total: UInt64, capFraction: Double?, activationReserveBytes: UInt64?,
        configReserveBytes: UInt64, prepareUsage: @escaping @Sendable () -> Void = {},
        snapshot: @escaping @Sendable () -> MemorySnapshot
    ) -> ProcessMemoryLedger {
        let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: total, capFraction: capFraction)
        let operatorCap = total > configReserveBytes ? total - configReserveBytes : 0
        return ProcessMemoryLedger(
            policy: .init(
                epoch: 1, capBytes: min(cap, operatorCap),
                reserveBytes: activationReserveBytes ?? UnifiedMemoryCap.resolvedActivationReserveBytes()),
            prepareUsage: prepareUsage,
            readUsage: {
                let current = snapshot()
                return .init(
                    activeBytes: current.active, cacheBytes: current.cache,
                    systemAvailableBytes: current.systemAvailable)
            })
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
    func reservationIDsForTesting() -> [String] {
        Array(reservations.keys) + Array(pendingLoadIDs.keys)
    }
}
