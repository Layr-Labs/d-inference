// Runtime KV grants; fixed-reference pool diagnostics are kept separately.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

/// Difference between a fixed paged pool and its requested fair share.
/// Growing the grant cannot add pages; shrinking it cannot reclaim them.
/// Both deltas are zero when the grant matches the physical pool.
public struct PagedPoolResizeShortfall: Sendable, Equatable {
    /// Committed physical pool bytes (`CBv2CapacitySnapshot
    /// .kvBytesBackendCapacity`); always > 0 — an UNKNOWN pool yields no
    /// shortfall at all rather than a fabricated one.
    public let poolBytes: Int
    /// The logical fair share the re-slicer last asked this slot to hold,
    /// recorded BEFORE the physical clamp.
    public let requestedBytes: Int

    /// Awarded grant the construction-fixed pool cannot serve.
    public var deferredGrowthBytes: Int { max(0, requestedBytes - poolBytes) }
    /// Physical KV held past the current fair share; unreclaimable without
    /// an unload/rebuild of the slot's engine.
    public var strandedBytes: Int { max(0, poolBytes - requestedBytes) }
    /// The pool and the fair share agree — nothing to resize.
    public var isExact: Bool { poolBytes == requestedBytes }
}

extension EngineV2Bridge {
    /// Segmented storage follows the admitted slot grant. Native admission
    /// retains live owners across shrink and reserves growth before allocation.
    /// Only an explicit fixed-reference paged pool needs a physical clamp.
    public func updateKVBytesCapacity(_ bytes: Int) {
        let requested = max(0, bytes)
        guard let engine = ownedEngine else { return }
        guard kvBackendKind == .paged else {
            engine.updateKVBytesCapacity(requested)
            return
        }
        lastRequestedKVBytesCapacity = requested
        let capacity = engine.capacity()
        if capacity.pagedStorage != nil {
            engine.updateKVBytesCapacity(requested)
            return
        }
        // `kvBytesBackendCapacity == 0` means UNKNOWN, never "no pool" — the
        // `CBv2CapacitySnapshot` contract says so in as many words. Clamping
        // to it would pin this slot's admission ledger at ZERO for the rest
        // of its life: the loaded-but-unserveable black hole the post-load
        // guard exists to prevent, reached through a legal contract state.
        // An unknown pool therefore does not bind, exactly as
        // `backendSlotCapacity` already refuses to bind the heartbeat.
        let physical = capacity.kvBytesBackendCapacity
        guard physical > 0 else {
            engine.updateKVBytesCapacity(requested)
            return
        }
        engine.updateKVBytesCapacity(min(requested, physical))
        publishPagedPoolResizeShortfall(
            PagedPoolResizeShortfall(poolBytes: physical, requestedBytes: requested))
    }

    /// Record the slot's cold-start load time for heartbeat reporting
    /// (`model_load_time_ms`).
    public func recordModelLoadTime(ms: Int64) {
        modelLoadTimeMs = max(0, ms)
    }

    /// Backend admission ceiling for segmented/contiguous storage, or physical
    /// capacity for a fixed-reference pool. Segmented residency is reported by
    /// `pagedStorage.committedBytes`; an empty pool can have a large ceiling.
    /// Input to the post-build serveable-KV guard.
    public func kvBackendPoolBytes() -> UInt64 {
        UInt64(max(0, capacitySnapshot().kvBytesBackendCapacity))
    }

    /// What this slot's construction-fixed paged pool could not do for the
    /// re-slicer's most recent grant. nil on segmented/contiguous slots, on a paged
    /// slot whose pool capacity is UNKNOWN, and before the first re-slice
    /// (a freshly-built slot's ceiling IS its pool).
    public func pagedPoolResizeShortfall() -> PagedPoolResizeShortfall? {
        guard kvBackendKind == .paged, let requested = lastRequestedKVBytesCapacity else {
            return nil
        }
        let capacity = capacitySnapshot()
        guard capacity.pagedStorage == nil else { return nil }
        let pool = capacity.kvBytesBackendCapacity
        guard pool > 0 else { return nil }
        return PagedPoolResizeShortfall(poolBytes: pool, requestedBytes: requested)
    }

    /// Publish changes in raw pool/grant bytes, never an occupancy ratio.
    /// WARN while a shortfall exists and INFO when the grant becomes exact.
    /// All three byte fields are mirrored in the telemetry wire allowlists.
    private func publishPagedPoolResizeShortfall(_ shortfall: PagedPoolResizeShortfall) {
        guard shortfall != lastPagedShortfallEmitted else { return }
        // Nothing to report when a slot has been exact all along.
        if shortfall.isExact, lastPagedShortfallEmitted == nil { return }
        lastPagedShortfallEmitted = shortfall
        let reason: String
        if shortfall.deferredGrowthBytes > 0 {
            reason = "deferred_grow"
        } else if shortfall.strandedBytes > 0 {
            reason = "unreclaimed_shrink"
        } else {
            reason = "exact"
        }
        emit(
            EngineHealthEvent.make(
                severity: shortfall.isExact ? .info : .warn,
                message: shortfall.isExact
                    ? "engine_v2: paged pool matches the re-sliced grant"
                    : "engine_v2: paged pool cannot follow the re-sliced grant "
                        + "(pool \(shortfall.poolBytes) B vs grant \(shortfall.requestedBytes) B)",
                operation: "paged_pool_resize_clamped",
                model: modelId,
                // Literal "paged": this event only exists for a paged pool, so
                // it is a fact about the code path, not a read of this slot.
                kvBackend: EngineV2KVBackendKind.paged.rawValue,
                extra: [
                    "reason": .string(reason),
                    "pool_bytes": .int(shortfall.poolBytes),
                    "pool_deferred_growth_bytes": .int(shortfall.deferredGrowthBytes),
                    "pool_stranded_bytes": .int(shortfall.strandedBytes),
                ]))
    }
}
