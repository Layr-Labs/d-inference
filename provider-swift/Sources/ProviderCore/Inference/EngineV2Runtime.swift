// Copyright © 2026 Eigen Labs.
//
// Process-wide registry of active `EngineV2Bridge` instances (one per
// v2-served model). This is the single seam the existing `ProviderLoop`
// plumbing hooks into:
//
//   * `ProviderLoop+Capacity.updateAggregateCapacity` folds
//     `capacitySummary()` slots into the SAME heartbeat payload as legacy
//     scheduler slots (no protocol change).
//   * `ProviderLoop+Cancellation.handleCancellation` fans the coordinator
//     request-id out through `cancel(requestId:)` → `CBv2Engine.cancel`.
//
// Both hooks guard on `ProviderLoop.hasEngineV2Slots` BEFORE hopping here,
// so when the v2 engine is off they cost zero — no actor hop, no
// allocations — and flag-off behavior stays byte-identical.

import Foundation

public actor EngineV2Runtime {
    public static let shared = EngineV2Runtime()

    /// modelId → bridge. One bridge per v2-served model, mirroring the
    /// one-scheduler-per-model shape of the legacy registry.
    private var bridges: [String: EngineV2Bridge] = [:]

    /// Test instrumentation: total `capacitySummary()` + `cancel(requestId:)`
    /// invocations. Lets tests prove the flag-off production paths never
    /// consult the runtime (the zero-overhead guard).
    private(set) var consultCount = 0

    /// Public init so tests can build isolated instances; production code
    /// uses `.shared`.
    public init() {}

    // MARK: - Registration (model lifecycle)

    public func register(modelId: String, bridge: EngineV2Bridge) {
        bridges[modelId] = bridge
    }

    /// Remove and return the bridge for `modelId` (caller drives
    /// `bridge.shutdown()` — unregistering must not silently drop
    /// in-flight requests).
    @discardableResult
    public func unregister(modelId: String) -> EngineV2Bridge? {
        bridges.removeValue(forKey: modelId)
    }

    public func bridge(forModel modelId: String) -> EngineV2Bridge? {
        bridges[modelId]
    }

    // MARK: - Heartbeat capacity

    public struct CapacitySummary: Sendable {
        public let slots: [BackendSlotCapacity]
        public let activeRequests: Int

        public static let empty = CapacitySummary(slots: [], activeRequests: 0)
    }

    /// Fleet-level inputs for the heartbeat budget CLAMP (round-3 PR#499
    /// P2). v2 admission ceilings are construction-fixed, so a model loaded
    /// LATER (especially a legacy/non-allowlisted slot) leaves existing
    /// bridges advertising a stale `activeTokenBudgetMax`. The heartbeat
    /// caller (`ProviderLoop.updateAggregateCapacity`) snapshots the CURRENT
    /// fleet residency here so each bridge's reported max can be recomputed
    /// from live inputs (`EngineV2KVSizing.liveEngineKVBytesBudget`).
    public struct FleetKVContext: Sendable {
        /// Σ resident model weights across ALL slots (v2 AND legacy),
        /// including each bridge's own model.
        public let totalResidentWeightBytes: UInt64
        /// Operator `memory_reserve_gb`, in bytes (see `EngineV2KVSizing`).
        public let configReserveBytes: UInt64
        /// Injectable for tests; the machine's real memory in production.
        public let physicalBytes: UInt64

        public init(
            totalResidentWeightBytes: UInt64,
            configReserveBytes: UInt64 = 0,
            physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
        ) {
            self.totalResidentWeightBytes = totalResidentWeightBytes
            self.configReserveBytes = configReserveBytes
            self.physicalBytes = physicalBytes
        }
    }

    /// Per-model heartbeat slots + aggregate active count for every
    /// registered bridge. Sorted by model id so heartbeat payloads are
    /// deterministic. Empty when v2 is off.
    ///
    /// When `fleetKV` is supplied, each bridge's reported
    /// `activeTokenBudgetMax` is clamped to the sizing function's CURRENT
    /// answer for that engine — its construction grant capped by the live
    /// fleet budget with the OTHER v2 engines' grants subtracted (the same
    /// derivation `makeEngineV2BridgeForSlot` used at sizing time), so
    /// Σ(reported budgets) tracks fleet reality as later models load. nil
    /// preserves the raw construction-time figures.
    public func capacitySummary(fleetKV: FleetKVContext? = nil) async -> CapacitySummary {
        consultCount += 1
        guard !bridges.isEmpty else { return .empty }
        // Snapshot every bridge's construction grant + prefix-cache budget
        // first: bridge i's clamp subtracts the OTHER bridges' figures, so
        // all must be read before any slot is built.
        //
        // Prefix-cache accounting (T-041): a bridge's engine grant was
        // REDUCED by its cache budget at construction, but the cache's bytes
        // are still claimed under the fleet KV budget. The clamp therefore
        // subtracts each OTHER slot's TOTAL claim (grant + cache budget) AND
        // this bridge's OWN cache budget — so the reported max keeps the
        // reduction as fleet reality changes, and the coordinator is never
        // told about bytes any prefix cache will consume.
        var grants: [String: Int] = [:]
        var prefixBudgets: [String: Int] = [:]
        if fleetKV != nil {
            for (modelId, bridge) in bridges {
                grants[modelId] = await bridge.engineKVBytesCapacity()
                prefixBudgets[modelId] = bridge.prefixCacheBudgetBytes
            }
        }
        var slots: [BackendSlotCapacity] = []
        var activeRequests = 0
        for modelId in bridges.keys.sorted() {
            guard let bridge = bridges[modelId] else { continue }
            var clamp: Int?
            if let fleetKV, let grant = grants[modelId] {
                var otherClaims = grants.filter { $0.key != modelId }.map {
                    // Overflow-safe like `slotKVBytesClaim()`: saturate
                    // rather than trap on absurd inputs.
                    let (sum, overflow) = $0.value
                        .addingReportingOverflow(prefixBudgets[$0.key] ?? 0)
                    return overflow ? Int.max : sum
                }
                // Own cache budget: carved out of the fleet budget but not
                // visible in the engine's own (already-reduced) grant, so it
                // rides the subtraction list like a co-resident claim.
                if let ownPrefix = prefixBudgets[modelId], ownPrefix > 0 {
                    otherClaims.append(ownPrefix)
                }
                clamp = EngineV2KVSizing.liveEngineKVBytesBudget(
                    grantedKVBytesCapacity: grant,
                    totalResidentWeightBytes: fleetKV.totalResidentWeightBytes,
                    otherEngineKVCapacities: otherClaims,
                    configReserveBytes: fleetKV.configReserveBytes,
                    physicalBytes: fleetKV.physicalBytes)
            }
            slots.append(await bridge.backendSlotCapacity(kvBytesBudgetClamp: clamp))
            activeRequests += await bridge.activeRequestCount()
        }
        return CapacitySummary(slots: slots, activeRequests: activeRequests)
    }

    // MARK: - Cancellation fan-out

    /// Forward a coordinator request-id cancellation to whichever bridge
    /// owns it. Returns true when a bridge accepted the cancel; false when
    /// no v2 bridge knows the id (the legacy path owns it).
    ///
    /// O(n) BY DESIGN (hardening review): n is the number of v2-SERVED
    /// MODELS — bounded by the provider's `max_model_slots` (single digits;
    /// production default ≤ 3) — not the number of requests, and each probe
    /// is a dictionary hit inside the owning bridge. Cancellation is a rare,
    /// non-hot event (client disconnects). A request-id → bridge index would
    /// make this O(1) but adds per-request cross-actor register/unregister
    /// traffic on the hot submit/finish paths of every bridge — strictly
    /// more work overall than scanning ≤ 3 entries here.
    @discardableResult
    public func cancel(requestId: String) async -> Bool {
        consultCount += 1
        for bridge in bridges.values {
            if await bridge.cancelIfOwned(requestId: requestId) {
                return true
            }
        }
        return false
    }
}
