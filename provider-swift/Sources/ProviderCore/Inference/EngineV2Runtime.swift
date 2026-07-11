// Copyright © 2026 Eigen Labs.
//
// Process-wide registry of active `EngineV2Bridge` instances (one per
// v2-served model). This is the single seam the existing `ProviderLoop`
// plumbing hooks into:
//
//   * `ProviderLoop+Capacity.updateAggregateCapacity` folds
//     `capacitySummary()` slots into the existing heartbeat wire shape.
//   * `ProviderLoop+Cancellation.handleCancellation` fans the coordinator
//     request-id out through `cancel(requestId:)` → `CBv2Engine.cancel`.
//
// Both hooks guard on `ProviderLoop.hasEngineV2Slots` before hopping here,
// so a provider with no loaded model avoids the actor hop.

import Foundation

public actor EngineV2Runtime {
    public static let shared = EngineV2Runtime()

    /// modelId → bridge. There is one bridge per resident model.
    private var bridges: [String: EngineV2Bridge] = [:]

    /// Test instrumentation: total `capacitySummary()` + `cancel(requestId:)`
    /// invocations. Lets tests prove the zero-slot production paths never
    /// consult the runtime.
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

    /// Fleet-level inputs for the heartbeat budget safety clamp. Runtime
    /// re-slicing updates each engine grant as models load and unload; the
    /// heartbeat caller snapshots current residency here so reporting can
    /// fail closed if live memory drifts between re-slices.
    public struct FleetKVContext: Sendable {
        /// Sum of resident model weights across all slots, including each
        /// bridge's own model.
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
    /// deterministic. Empty when no models are loaded.
    ///
    /// When `fleetKV` is supplied, each bridge's reported
    /// `activeTokenBudgetMax` is clamped to the sizing function's CURRENT
    /// answer for that engine: its current re-sliced grant capped by the live
    /// fleet budget after the other slots' claims. nil preserves the current
    /// engine figures without the additional safety clamp.
    public func capacitySummary(fleetKV: FleetKVContext? = nil) async -> CapacitySummary {
        consultCount += 1
        guard !bridges.isEmpty else { return .empty }
        // Snapshot every bridge's current admission grant, physical total
        // claim, and prefix-cache budget first: bridge i's clamp subtracts
        // the OTHER bridges' physical claims, so all must be read before
        // any slot is built.
        //
        // Prefix-cache accounting (T-041): a RAM-tier bridge's engine grant is
        // reduced by its cache budget, but the cache's bytes
        // are still claimed under the fleet KV budget. The clamp therefore
        // subtracts each OTHER slot's TOTAL claim (grant + cache budget) AND
        // this bridge's OWN cache budget — so the reported max keeps the
        // reduction as fleet reality changes, and the coordinator is never
        // told about bytes any prefix cache will consume.
        var grants: [String: Int] = [:]
        var totalClaims: [String: Int] = [:]
        var prefixBudgets: [String: Int] = [:]
        if fleetKV != nil {
            for (modelId, bridge) in bridges {
                grants[modelId] = await bridge.engineKVBytesCapacity()
                totalClaims[modelId] = await bridge.slotKVBytesClaim()
                prefixBudgets[modelId] = bridge.prefixCacheBudgetBytes
            }
        }
        var slots: [BackendSlotCapacity] = []
        var activeRequests = 0
        for modelId in bridges.keys.sorted() {
            guard let bridge = bridges[modelId] else { continue }
            var clamp: Int?
            if let fleetKV, let grant = grants[modelId] {
                var otherClaims = totalClaims
                    .filter { $0.key != modelId }
                    .map(\.value)
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
    /// no loaded bridge knows the id.
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
