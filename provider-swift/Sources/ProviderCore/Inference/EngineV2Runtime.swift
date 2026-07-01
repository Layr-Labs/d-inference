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
// Both hooks are no-ops (empty registry, zero allocations beyond the actor
// hop) when the v2 engine is off, so flag-off behavior stays byte-identical.

import Foundation

public actor EngineV2Runtime {
    public static let shared = EngineV2Runtime()

    /// modelId → bridge. One bridge per v2-served model, mirroring the
    /// one-scheduler-per-model shape of the legacy registry.
    private var bridges: [String: EngineV2Bridge] = [:]

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

    /// Per-model heartbeat slots + aggregate active count for every
    /// registered bridge. Sorted by model id so heartbeat payloads are
    /// deterministic. Empty when v2 is off.
    public func capacitySummary() async -> CapacitySummary {
        guard !bridges.isEmpty else { return .empty }
        var slots: [BackendSlotCapacity] = []
        var activeRequests = 0
        for modelId in bridges.keys.sorted() {
            guard let bridge = bridges[modelId] else { continue }
            slots.append(await bridge.backendSlotCapacity())
            activeRequests += await bridge.activeRequestCount()
        }
        return CapacitySummary(slots: slots, activeRequests: activeRequests)
    }

    // MARK: - Cancellation fan-out

    /// Forward a coordinator request-id cancellation to whichever bridge
    /// owns it. Returns true when a bridge accepted the cancel; false when
    /// no v2 bridge knows the id (the legacy path owns it).
    @discardableResult
    public func cancel(requestId: String) async -> Bool {
        for bridge in bridges.values {
            if await bridge.cancelIfOwned(requestId: requestId) {
                return true
            }
        }
        return false
    }
}
