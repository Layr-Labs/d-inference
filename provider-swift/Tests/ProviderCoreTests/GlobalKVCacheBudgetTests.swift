import Foundation
import Testing

@testable import ProviderCore

// These exercise GlobalKVCacheBudget against the unified-cap headroom formula
// (UnifiedMemoryCap.liveKVHeadroomBytes): headroom =
//   min(hardCap − mlxUsed, systemAvailable) − activationReserve
// where hardCap = min(capFraction × total, total − 2 GiB floor). Tests pin
// capFraction / activationReserve so the arithmetic is exact; production uses
// the 0.90 / 3 GiB defaults.
//
// NOTE: `total` must exceed the 2 GiB hardCap OS floor or hardCap collapses to 0
// (correct for a sub-2 GiB "machine", but not what these accounting tests model).
// So the memory figures are GiB-scaled; reservation footprints stay byte-sized
// (tokenCount × kvBytesPerToken) and are tiny relative to the headroom, which is
// what each test pins via `systemAvailable`.
private let gib: UInt64 = 1024 * 1024 * 1024

@Test func globalKVCacheBudgetRejectsDuplicateReservationIDs() async {
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
    #expect(!(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1)))

    await budget.release(requestID: "same")
    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
}

@Test func globalKVCacheBudgetRejectsOverflowingReservationSize() async {
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: UInt64.max, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(!(await budget.reserve(requestID: "overflow", kvBytesPerToken: Int.max, tokenCount: Int.max)))
}

/// The cap fraction bounds the total reservable bytes: 0.5 × 8 GiB = 4 GiB cap
/// (the fraction binds, not the 6 GiB floor), so a 3 GiB reservation fits but a
/// further 2 GiB (→5 GiB) does not.
@Test func globalKVCacheBudgetHonorsCapFractionAsTotalReservationCap() async {
    let budget = GlobalKVCacheBudget(capFraction: 0.5, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
    }

    #expect(await budget.reserve(requestID: "first", kvBytesPerToken: 1, tokenCount: Int(3 * gib)))
    #expect(!(await budget.reserve(requestID: "second", kvBytesPerToken: 1, tokenCount: Int(2 * gib))))
}

/// The runtime KV budget must clamp to real OS-available memory, not just the
/// MLX-only view, or it over-admits on a shared box → jetsam OOM.
@Test func globalKVCacheBudgetClampsToOSAvailableWhenItIsTighter() async {
    // cap = 8 GiB (fraction 1.0, but floor 6 GiB binds → 6 GiB), nothing held by
    // MLX → 6 GiB under cap, but the OS reports only 1 GiB available. The budget
    // must bind to the tighter 1 GiB OS view.
    let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: 1 * gib)
    }

    #expect(!(await budget.reserve(requestID: "over-os", kvBytesPerToken: 1, tokenCount: Int(gib + 1))))
    #expect(await budget.reserve(requestID: "at-os", kvBytesPerToken: 1, tokenCount: Int(1 * gib)))
}

/// When MLX's own held memory is the tighter bound, that still wins — the
/// under-cap headroom (cap − mlxUsed) is the smaller of the two views.
@Test func globalKVCacheBudgetUsesMLXViewWhenItIsTighterThanOS() async {
    // 64 GiB box, cap 0.9×64 = 57.6 GiB. MLX already holds 56.6 GiB (resident
    // weights+KV) → only 1 GiB under cap, OS view unlimited.
    let cap = UInt64(Double(64 * gib) * 0.9)
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: cap - gib, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserve(requestID: "over-mlx", kvBytesPerToken: 1, tokenCount: Int(gib + 1))))
    #expect(await budget.reserve(requestID: "at-mlx", kvBytesPerToken: 1, tokenCount: Int(1 * gib)))
}

/// The activation reserve is subtracted from real free memory before any KV may
/// be reserved — it carves out forward-pass working memory under the cap.
@Test func globalKVCacheBudgetSubtractsActivationReserveFromHeadroom() async {
    // 64 GiB box, OS reports 5 GiB free (the binding view), activation reserve
    // 3 GiB → 2 GiB left for KV.
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 3 * gib) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 0, cache: 0, systemAvailable: 5 * gib)
    }
    #expect(!(await budget.reserve(requestID: "over", kvBytesPerToken: 1, tokenCount: Int(2 * gib + 1))))
    #expect(await budget.reserve(requestID: "fits", kvBytesPerToken: 1, tokenCount: Int(2 * gib)))
}

/// Q6 (serve-while-load): a loading model's weights are not in MLX active/cache
/// until `loadModelContainer` finishes allocating them. `reservePendingLoad`
/// makes that footprint visible to KV reservations on ALREADY-loaded models, so
/// a concurrent request can't grant KV headroom that, plus the incoming weights,
/// blows the cap. It reserves only the weights (so KV that still fits underneath
/// is admitted) and is released once the weights are resident.
@Test func pendingLoadReservationBlocksConcurrentKVOverCommit() async {
    // 64 GiB box, cap 0.9 → 57.6 GiB, minus 3 GiB activation = ~54.6 GiB for KV.
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 3 * gib) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 0, cache: 0, systemAvailable: .max)
    }
    // Baseline: a 40 GiB KV reservation fits with nothing else outstanding.
    #expect(await budget.reserveBytes(requestID: "kv-baseline", bytes: 40 * gib))
    await budget.release(requestID: "kv-baseline")

    // A 30 GiB model begins loading; its weights aren't in mlxUsed yet, so we
    // reserve them. Only ~24.6 GiB is now left for KV.
    await budget.reservePendingLoad(requestID: "pending-load:B", bytes: 30 * gib)
    // Without the fix this 40 GiB reservation would be granted (54.6 free) and,
    // plus the 30 GiB load, blow the cap. It must be rejected now.
    #expect(!(await budget.reserveBytes(requestID: "kv-too-big", bytes: 40 * gib)))
    // KV that still fits underneath the pending load is still admitted.
    #expect(await budget.reserveBytes(requestID: "kv-fits", bytes: 20 * gib))
    await budget.release(requestID: "kv-fits")

    // Once the load completes (weights now in mlxUsed), releasing restores the
    // full headroom.
    await budget.release(requestID: "pending-load:B")
    #expect(await budget.reserveBytes(requestID: "kv-after", bytes: 40 * gib))
}

/// The live KV gate must honor an operator `memory_reserve_gb` that exceeds the
/// cap's own implied OS reserve (physical − cap) — otherwise runtime KV grows to
/// the 90% cap and eats the memory the operator reserved (the load gate already
/// holds it back via loadReserveBytes; the live gate must match).
@Test func globalKVCacheBudgetHonorsOperatorReserveAboveCapImplied() async {
    // 32 GiB box, cap 0.9 → 28.8 GiB (cap-implied reserve = 3.2 GiB). A 6 GiB
    // operator reserve exceeds that → effective cap 26 GiB.
    let withReserve = GlobalKVCacheBudget(
        capFraction: 0.9, activationReserveBytes: 0, configReserveBytes: 6 * gib
    ) {
        GlobalKVCacheBudget.MemorySnapshot(total: 32 * gib, active: 0, cache: 0, systemAvailable: .max)
    }
    #expect(!(await withReserve.reserveBytes(requestID: "over-reserve", bytes: 27 * gib)))  // > 26 GiB
    #expect(await withReserve.reserveBytes(requestID: "fits", bytes: 25 * gib))

    // With no operator reserve the same 27 GiB fits under the bare 28.8 GiB cap —
    // proving the reserve, not some other clamp, is what rejected it above.
    let noReserve = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 32 * gib, active: 0, cache: 0, systemAvailable: .max)
    }
    #expect(await noReserve.reserveBytes(requestID: "fits-bare", bytes: 27 * gib))
}

@Test func providerLoopMemoryReserveBytesSaturatesOnOverflow() {
    #expect(ProviderLoop.memoryReserveBytes(forGiB: 4) == 4 * 1024 * 1024 * 1024)
    #expect(ProviderLoop.memoryReserveBytes(forGiB: UInt64.max) == UInt64.max)
}

// MARK: - Sustained-rejection reservation audit (v0.7.3 black-hole hardening)

/// Thread-safe capture sink for the budget's audit telemetry closure.
private final class AuditEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(severity: TelemetrySeverity, message: String, fields: [String: AnyCodableValue])] = []

    func append(_ severity: TelemetrySeverity, _ message: String, _ fields: [String: AnyCodableValue]) {
        lock.lock()
        defer { lock.unlock() }
        events.append((severity, message, fields))
    }

    func operations() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { $0.fields["operation"]?.description }
    }
}

/// Build a budget with tiny audit thresholds: 6 GiB cap headroom, so a leaked
/// 6 GiB reservation makes EVERY later commit fail — the black-hole shape.
/// The continuity window defaults to the production 30 s so the storm-style
/// tests (rejections ~10 ms apart) exercise the same "gaps far under the
/// window sustain the streak" regime production sees.
private func makeAuditBudget(
    log: AuditEventLog,
    staleTTL: Duration = .milliseconds(50),
    continuityWindow: Duration = GlobalKVCacheBudget.defaultRejectionStreakContinuityWindow
) -> GlobalKVCacheBudget {
    GlobalKVCacheBudget(
        capFraction: 1.0,
        activationReserveBytes: 0,
        memorySnapshot: {
            GlobalKVCacheBudget.MemorySnapshot(
                total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
        },
        sustainedRejectionAuditThreshold: .milliseconds(40),
        rejectionStreakContinuityWindow: continuityWindow,
        staleReservationTTL: staleTTL,
        auditMinInterval: .milliseconds(10),
        emitAuditEvent: { severity, message, fields in
            log.append(severity, message, fields)
        }
    )
}

/// The incident shape, generalized: a reservation that never gets released
/// wedges the budget into 100% rejection. After the sustained-rejection
/// threshold, the audit must log the table, drop the stale entry, and the
/// next commit must succeed — permanent black hole → self-healed blip.
@Test func sustainedRejectionAuditDropsStaleReservationAndHeals() async throws {
    let log = AuditEventLog()
    let budget = makeAuditBudget(log: log)

    // The leak: consumes the whole 6 GiB effective cap (8 GiB − 2 GiB floor).
    await budget.reservePendingLoad(requestID: "pending-load:leaked", bytes: 6 * gib)

    // Rejections must persist past BOTH the stale TTL and the audit
    // threshold. Loop instead of one long sleep so the streak has failures
    // on both ends of the threshold window.
    var healed = false
    for _ in 0 ..< 30 {
        if await budget.reserve(requestID: "req-\(UUID().uuidString)", kvBytesPerToken: 1, tokenCount: Int(gib)) {
            healed = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(healed, "budget never healed — the stale reservation was not dropped")
    let ids = await budget.reservationIDsForTesting()
    #expect(!ids.contains("pending-load:leaked"))
    let operations = log.operations()
    #expect(operations.contains("kv_budget_sustained_rejection"))
    #expect(operations.contains("kv_budget_stale_reservation_dropped"))
}

/// Fresh (younger than the TTL) reservations are live work and must survive
/// the audit even during a full-rejection streak — the audit only ever drops
/// entries no plausible request/load lifetime can explain.
@Test func sustainedRejectionAuditKeepsFreshReservations() async throws {
    let log = AuditEventLog()
    // TTL far above the test duration: everything stays "fresh".
    let budget = makeAuditBudget(log: log, staleTTL: .seconds(60))

    await budget.reservePendingLoad(requestID: "pending-load:live", bytes: 6 * gib)

    for _ in 0 ..< 12 {
        _ = await budget.reserve(
            requestID: "req-\(UUID().uuidString)", kvBytesPerToken: 1, tokenCount: Int(gib))
        try await Task.sleep(for: .milliseconds(10))
    }

    // The audit fired (CRITICAL visibility)…
    #expect(log.operations().contains("kv_budget_sustained_rejection"))
    // …but dropped nothing.
    #expect(!log.operations().contains("kv_budget_stale_reservation_dropped"))
    let ids = await budget.reservationIDsForTesting()
    #expect(ids.contains("pending-load:live"))
}

/// Sparse traffic must never age into an audit: two rejections separated by
/// an idle gap longer than the continuity window are NOT a sustained streak,
/// even when their wall-clock span exceeds the audit threshold. Without
/// continuity, the audit would fire on the second rejection and drop the
/// >TTL-old reservation — which here models LIVE work (a multi-10-minute
/// decode or a slow pending load legitimately outlives the 10-min TTL).
@Test func idleGapsBetweenRejectionsNeverAgeIntoAnAudit() async throws {
    let log = AuditEventLog()
    // Continuity window 30 ms, audit threshold 40 ms, stale TTL 30 ms.
    let budget = makeAuditBudget(
        log: log, staleTTL: .milliseconds(30), continuityWindow: .milliseconds(30))

    // A long-running piece of LIVE work whose reservation outlives the TTL.
    await budget.reservePendingLoad(requestID: "pending-load:live-decode", bytes: 6 * gib)
    try await Task.sleep(for: .milliseconds(50))  // now older than the stale TTL

    // Rejection 1 arms the streak; a >window idle gap follows.
    #expect(!(await budget.reserve(requestID: "sparse-1", kvBytesPerToken: 1, tokenCount: Int(gib))))
    try await Task.sleep(for: .milliseconds(100))
    // Rejection 2: wall clock since rejection 1 exceeds the 40 ms threshold,
    // but the gap broke the streak — pre-fix this fired the audit and
    // dropped the live reservation. Rejection 3 lands inside the window but
    // the re-armed streak is only milliseconds old.
    #expect(!(await budget.reserve(requestID: "sparse-2", kvBytesPerToken: 1, tokenCount: Int(gib))))
    #expect(!(await budget.reserve(requestID: "sparse-3", kvBytesPerToken: 1, tokenCount: Int(gib))))

    #expect(log.operations().isEmpty, "audit fired across an idle traffic gap")
    let ids = await budget.reservationIDsForTesting()
    #expect(ids.contains("pending-load:live-decode"), "live work was dropped as stale")
}

/// A release of a REAL reservation proves the table drains (work is
/// terminating normally), so it must reset the rejection streak: a
/// continuous rejection storm interleaved with releases never audits.
@Test func releasesOfRealReservationsResetTheRejectionStreak() async throws {
    let log = AuditEventLog()
    let budget = makeAuditBudget(log: log)

    // The wedge: consumes the whole 6 GiB effective cap.
    await budget.reservePendingLoad(requestID: "pending-load:wedge", bytes: 6 * gib)

    // 12 × 10 ms of continuous rejections (well past the 40 ms threshold),
    // but unrelated in-flight work keeps completing — each release resets
    // the streak, so the audit must never fire.
    for i in 0 ..< 12 {
        _ = await budget.reserve(requestID: "storm-\(i)", kvBytesPerToken: 1, tokenCount: Int(gib))
        await budget.reservePendingLoad(requestID: "tick-\(i)", bytes: 1)
        await budget.release(requestID: "tick-\(i)")
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(log.operations().isEmpty, "audit fired despite reservations draining via release()")
    #expect(await budget.reservationIDsForTesting().contains("pending-load:wedge"))
}

/// The complement: releasing an id that holds NO reservation proves nothing
/// and must NOT reset the streak — otherwise a caller releasing a stale/
/// unknown id on every request would mask a real black hole forever.
@Test func releaseOfUnknownIDDoesNotResetTheStreak() async throws {
    let log = AuditEventLog()
    let budget = makeAuditBudget(log: log)

    await budget.reservePendingLoad(requestID: "pending-load:leaked", bytes: 6 * gib)

    var audited = false
    for i in 0 ..< 30 {
        _ = await budget.reserve(requestID: "storm-\(i)", kvBytesPerToken: 1, tokenCount: Int(gib))
        await budget.release(requestID: "ghost-\(i)")  // never reserved — a no-op
        if log.operations().contains("kv_budget_sustained_rejection") {
            audited = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(audited, "no-op releases suppressed the sustained-rejection audit")
}

/// A successful commit resets the rejection streak: intermittent capacity
/// pressure (rejections interleaved with successes) must never trigger the
/// audit — it is reserved for the every-commit-fails black hole.
@Test func successfulCommitsResetTheRejectionStreak() async throws {
    let log = AuditEventLog()
    let budget = makeAuditBudget(log: log)

    for i in 0 ..< 8 {
        // Too big — rejected (5 GiB headroom left under the 6 GiB cap after
        // the small success below on later iterations).
        _ = await budget.reserve(requestID: "big-\(i)", kvBytesPerToken: 1, tokenCount: Int(7 * gib))
        // Small — succeeds, resetting the streak.
        #expect(await budget.reserve(requestID: "small-\(i)", kvBytesPerToken: 1, tokenCount: 1024))
        await budget.release(requestID: "small-\(i)")
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(log.operations().isEmpty, "audit fired despite interleaved successful commits")
}
