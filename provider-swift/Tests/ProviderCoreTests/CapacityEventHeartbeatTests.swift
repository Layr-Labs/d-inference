// Event-triggered heartbeat policy (routing v2, Phase 1): materiality
// detection against the last published payload, the 2/s rate cap with
// trailing-edge coalescing (driven with a synthetic clock — the throttle is
// a pure state machine), and per-connection capacity_seq monotonicity.

import Foundation
import Testing
@testable import ProviderCore

private func slot(
    model: String = "org/model-a",
    state: String = "running",
    numRunning: UInt32 = 1,
    numWaiting: UInt32 = 0,
    used: Int64 = 1000,
    max: Int64 = 9000,
    queued: Int64 = 0
) -> BackendSlotCapacity {
    BackendSlotCapacity(
        model: model,
        state: state,
        numRunning: numRunning,
        numWaiting: numWaiting,
        activeTokens: 0,
        maxTokensPotential: 0,
        activeTokenBudgetUsed: used,
        activeTokenBudgetMax: max,
        queuedTokenBudget: queued)
}

private func capacity(_ slots: [BackendSlotCapacity]) -> BackendCapacity {
    BackendCapacity(
        slots: slots,
        gpuMemoryActiveGb: 1,
        gpuMemoryPeakGb: 1,
        gpuMemoryCacheGb: 0,
        totalMemoryGb: 64)
}

// MARK: - Materiality

@Test func firstRebuildAndSlotRosterChangesAreMaterial() {
    let current = capacity([slot()])
    // Nothing published yet.
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: nil, current: current))
    // Model loaded (roster grew).
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: capacity([]),
        current: current))
    // Model unloaded/evicted (roster shrank).
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: capacity([slot(), slot(model: "org/model-b")]),
        current: current))
    // Identical payload: nothing to push.
    #expect(!CapacityHeartbeatMateriality.isMaterial(previous: current, current: current))
}

@Test func admissionCompletionAndHealthTransitionsAreMaterial() {
    let base = capacity([slot(numRunning: 1)])
    // Request admitted / completed: numRunning moved.
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(numRunning: 2)])))
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(numRunning: 0)])))
    // Queue depth moved.
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(numWaiting: 1)])))
    // Slot crashed / entered recovery reload.
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(state: "crashed")])))
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(state: "reloading")])))
}

@Test func tokenBudgetShiftsUseFloorAndFractionThresholds() {
    // Available budget = max − used − queued = 8000.
    let base = capacity([slot(used: 1000, max: 9000)])
    // Large budget (available 100k): the 1024-token floor is the binding
    // threshold (10% would be 10k).
    let big = capacity([slot(used: 0, max: 100_000)])
    #expect(!CapacityHeartbeatMateriality.isMaterial(
        previous: big, current: capacity([slot(used: 1023, max: 100_000)])))
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: big, current: capacity([slot(used: 1024, max: 100_000)])))

    // Small budget: the 10% fraction binds below the 1024 floor.
    // available 5000 → 10% = 500.
    let small = capacity([slot(used: 4000, max: 9000)])
    #expect(!CapacityHeartbeatMateriality.isMaterial(
        previous: small, current: capacity([slot(used: 4499, max: 9000)])))
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: small, current: capacity([slot(used: 4500, max: 9000)])))

    // Queued budget counts against availability the same way.
    #expect(CapacityHeartbeatMateriality.isMaterial(
        previous: base, current: capacity([slot(used: 1000, max: 9000, queued: 2048)])))
}

@Test func opposingPerSlotBudgetShiftsNeverCancel() {
    // Model A loses 50k tokens while model B gains 50k: the aggregate is
    // unchanged, but A's coordinator ledger is now stale-optimistic by 50k —
    // exactly the staleness event heartbeats exist to push out. Material.
    let before = capacity([
        slot(model: "org/model-a", used: 10_000, max: 100_000),
        slot(model: "org/model-b", used: 60_000, max: 100_000),
    ])
    let after = capacity([
        slot(model: "org/model-a", used: 60_000, max: 100_000),
        slot(model: "org/model-b", used: 10_000, max: 100_000),
    ])
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: after))
}

@Test func multiSlotRosterBelowAllThresholdsStaysNonMaterial() {
    // Two slots each drift well under both the 1024-token floor and the 10%
    // fraction, and the aggregate drift (300 + 200 = 500) stays under both
    // too: no heartbeat.
    let before = capacity([
        slot(model: "org/model-a", used: 10_000, max: 100_000),
        slot(model: "org/model-b", used: 20_000, max: 100_000),
    ])
    let after = capacity([
        slot(model: "org/model-a", used: 10_300, max: 100_000),
        slot(model: "org/model-b", used: 20_200, max: 100_000),
    ])
    #expect(!CapacityHeartbeatMateriality.isMaterial(previous: before, current: after))
}

@Test func distributedSubThresholdDriftsStillTripTheAggregateFloor() {
    // Three slots each shift 400 tokens — below the per-slot floor and
    // fraction — but the fleet total moves 1200 ≥ the 1024 floor: the
    // aggregate check retains this signal on top of the per-slot rule.
    let before = capacity([
        slot(model: "org/model-a", used: 10_000, max: 100_000),
        slot(model: "org/model-b", used: 10_000, max: 100_000),
        slot(model: "org/model-c", used: 10_000, max: 100_000),
    ])
    let after = capacity([
        slot(model: "org/model-a", used: 10_400, max: 100_000),
        slot(model: "org/model-b", used: 10_400, max: 100_000),
        slot(model: "org/model-c", used: 10_400, max: 100_000),
    ])
    #expect(CapacityHeartbeatMateriality.isMaterial(previous: before, current: after))
}

// MARK: - Throttle (deterministic clock)

@Test func throttleSendsImmediatelyOutsideCapWindow() {
    var throttle = CapacityHeartbeatThrottle()
    let t0 = ContinuousClock.Instant.now
    let first = throttle.noteMaterialChange(now: t0)
    #expect(first == .sendNow)
    // Past the window: immediate again.
    let second = throttle.noteMaterialChange(now: t0.advanced(by: .milliseconds(500)))
    #expect(second == .sendNow)
}

@Test func throttleCoalescesInsideCapWindowAndGuaranteesTrailingSend() {
    var throttle = CapacityHeartbeatThrottle()
    let t0 = ContinuousClock.Instant.now
    let immediate = throttle.noteMaterialChange(now: t0)
    #expect(immediate == .sendNow)

    // 200ms later: inside the window → exactly one trailing send scheduled
    // at window end (300ms out).
    let t1 = t0.advanced(by: .milliseconds(200))
    let scheduled = throttle.noteMaterialChange(now: t1)
    #expect(scheduled == .scheduled(after: .milliseconds(300)))

    // Further changes inside the window coalesce into that one send.
    let t2 = t0.advanced(by: .milliseconds(300))
    let coalescedA = throttle.noteMaterialChange(now: t2)
    let coalescedB = throttle.noteMaterialChange(now: t2)
    #expect(coalescedA == .coalesced)
    #expect(coalescedB == .coalesced)

    // The trailing timer fires: the send must happen (never dropped) and is
    // accounted against the cap.
    let t3 = t0.advanced(by: .milliseconds(500))
    let fired = throttle.takeScheduledSend(now: t3)
    #expect(fired)
    // Duplicate service of the same verdict is refused.
    let refired = throttle.takeScheduledSend(now: t3)
    #expect(!refired)

    // The trailing send restarted the cap window: an immediate change is
    // throttled again.
    let t4 = t3.advanced(by: .milliseconds(100))
    let rethrottled = throttle.noteMaterialChange(now: t4)
    #expect(rethrottled == .scheduled(after: .milliseconds(400)))
}

@Test func throttleEnforcesTwoPerSecond() {
    var throttle = CapacityHeartbeatThrottle()
    let t0 = ContinuousClock.Instant.now
    var sends = 0
    // A change every 50ms for one second: 2 immediate+trailing pairs max.
    var scheduledAt: ContinuousClock.Instant?
    for i in 0..<20 {
        let now = t0.advanced(by: .milliseconds(50 * i))
        if let due = scheduledAt, now >= due {
            if throttle.takeScheduledSend(now: due) { sends += 1 }
            scheduledAt = nil
        }
        switch throttle.noteMaterialChange(now: now) {
        case .sendNow:
            sends += 1
        case .scheduled(let after):
            scheduledAt = now.advanced(by: after)
        case .coalesced:
            break
        }
    }
    if let due = scheduledAt {
        if throttle.takeScheduledSend(now: due) { sends += 1 }
    }
    // 1s of continuous churn at a 500ms min interval: ≤ 3 sends land inside
    // the window [t0, t0+1s] (t0, t0+500ms, t0+1s) — never one per change.
    #expect(sends <= 3)
    #expect(sends >= 2)
}

// MARK: - capacity_seq monotonicity (per connection)

@Test func stampAndPublishAdvancesSeqMonotonicallyAndResetsPerConnection() {
    let state = ProviderState()
    let payload = capacity([slot()])

    // Nil capacity (startup, nothing rebuilt yet): no stamp, no seq burn.
    #expect(state.stampAndPublishHeartbeatCapacity(nil) == nil)
    #expect(state.publishedCapacity == nil)

    let first = state.stampAndPublishHeartbeatCapacity(payload)
    let second = state.stampAndPublishHeartbeatCapacity(payload)
    let third = state.stampAndPublishHeartbeatCapacity(payload)
    #expect(first?.capacitySeq == 1)
    #expect(second?.capacitySeq == 2)
    #expect(third?.capacitySeq == 3)
    // The published snapshot is exactly the last stamped payload.
    #expect(state.publishedCapacity?.capacitySeq == 3)

    // Reconnect: seq restarts at 1 and the stale snapshot is dropped.
    state.resetCapacitySession()
    #expect(state.publishedCapacity == nil)
    #expect(state.stampAndPublishHeartbeatCapacity(payload)?.capacitySeq == 1)
}
