// Keep useful KV space after fixed request workspace.
import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The fixed charge, not native shutdown tracking, determines whether an
    /// ordinary engine needs this limit. Unknown overhead must fail closed;
    /// zero-overhead ordinary engines retain their existing serving width.
    var usesMemoryLimitedConcurrency: Bool {
        ownedEngine is EngineV2
            && (tracksNativeShutdown || maximumRequestOverheadBytes() != 0)
    }

    /// Engines reserve fixed recurrent/MTP/prefill workspace per request. A grant
    /// shrink must reduce concurrency before reserving every possible future
    /// workspace in the heartbeat. Otherwise a loaded model advertises zero
    /// tokens even when one or more requests still fit.
    func memoryLimitedConcurrency(configured: Int, capacityBytes: Int? = nil) -> Int {
        guard usesMemoryLimitedConcurrency else { return configured }
        return Self.fixedWorkspaceConcurrencyLimit(configured: configured,
            capacityBytes: capacityBytes ?? admissionCapacityBytes(),
            requestOverheadBytes: maximumRequestOverheadBytes())
    }

    /// Scalar portion shared by live reporting/admission and policy tests.
    nonisolated static func fixedWorkspaceConcurrencyLimit(
        configured: Int, capacityBytes: Int, requestOverheadBytes: Int?
    ) -> Int {
        guard configured > 0, let overhead = requestOverheadBytes, overhead >= 0 else { return 0 }
        let minimumKV = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        guard capacityBytes >= minimumKV else { return 0 }
        guard overhead > 0 else { return configured }
        return min(configured, (capacityBytes - minimumKV) / overhead)
    }

    /// The admission ledger's ceiling is smaller than the raw KV grant by its
    /// watermark. Also honor a fixed backend pool that cannot grow with it.
    func admissionCapacityBytes() -> Int {
        guard let engine = ownedEngine as? EngineV2 else { return 0 }
        let snapshot = engine.capacity()
        var capacity = min(snapshot.kvBytesCapacity, engine.admissibleKVBytesCapacity)
        if snapshot.kvBytesBackendCapacity > 0 {
            capacity = min(capacity, snapshot.kvBytesBackendCapacity)
        }
        return max(0, capacity)
    }

    /// Total slot grant needed for one request's workspace and minimum KV.
    /// The cache carve is outside the engine grant and is added exactly once.
    /// Int.max means no serviceable grant can be proven.
    func minimumServiceableGrantBytes() -> Int {
        let minimumKV = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        guard usesMemoryLimitedConcurrency else { return minimumKV }
        guard maxConcurrentRequests > 0, let overhead = maximumRequestOverheadBytes(),
            let engine = ownedEngine as? EngineV2 else { return Int.max }
        // Both reads occur without suspension under the bridge's resize owner.
        // Occupied request bytes are not subtracted from the admission ceiling.
        let snapshot = engine.capacity()
        let engineFloor: Int
        if tracksNativeShutdown {
            // The native execution profile retains its validated 5% policy.
            engineFloor = Self.minimumNativeGrantBytes(fixedRequestBytes: overhead)
        } else {
            guard let admissionWatermarkFraction else { return Int.max }
            engineFloor = Self.minimumOrdinaryGrantBytes(
                fixedRequestBytes: overhead,
                capacityBytes: snapshot.kvBytesCapacity,
                admissibleCapacityBytes: engine.admissibleKVBytesCapacity,
                watermarkFraction: admissionWatermarkFraction)
        }
        guard engineFloor < Int.max else { return Int.max }
        if kvBackendKind == .paged, snapshot.pagedStorage == nil,
            snapshot.kvBytesBackendCapacity > 0,
            engineFloor > snapshot.kvBytesBackendCapacity {
            return Int.max
        }
        // Pinned entries can outlive a cache-budget shrink. Its construction
        // bound covers both the resized budget and those retained entries.
        let carve = engine.hybridPrefixCache?.config.maximumBytes ?? 0
        let (total, overflow) = engineFloor.addingReportingOverflow(carve)
        return carve < 0 || overflow ? Int.max : total
    }

    /// Preserve the actual watermark, not an effective ratio that would scale
    /// a fixed external reserve down when a slot shrinks. A saturated ceiling
    /// cannot reveal that reserve and therefore cannot prove a future floor.
    nonisolated static func minimumOrdinaryGrantBytes(
        fixedRequestBytes: Int, capacityBytes: Int, admissibleCapacityBytes: Int,
        watermarkFraction: Double
    ) -> Int {
        guard fixedRequestBytes >= 0, capacityBytes > 0, admissibleCapacityBytes > 0,
            watermarkFraction.isFinite, watermarkFraction >= 0, watermarkFraction < 1
        else { return Int.max }
        let watermark = Int(Double(capacityBytes) * watermarkFraction)
        let watermarkedCapacity = capacityBytes - watermark
        guard admissibleCapacityBytes <= watermarkedCapacity else { return Int.max }
        let externalReserve = watermarkedCapacity - admissibleCapacityBytes
        let (requestAndKV, requestOverflow) = fixedRequestBytes.addingReportingOverflow(
            Int(UnifiedMemoryCap.minimumLoadKVBytes))
        let (required, reserveOverflow) = requestAndKV.addingReportingOverflow(externalReserve)
        guard !requestOverflow, !reserveOverflow else { return Int.max }
        guard watermarkFraction > 0 else { return required }
        guard Int.max - Int(Double(Int.max) * watermarkFraction) >= required else { return Int.max }

        // Match the SDK's integer truncation at every boundary, without a
        // floating-point inverse rounding below the required byte ceiling.
        var lower = required
        var upper = Int.max
        while lower < upper {
            let candidate = lower + (upper - lower) / 2
            if candidate - Int(Double(candidate) * watermarkFraction) >= required {
                upper = candidate
            } else {
                lower = candidate + 1
            }
        }
        return lower
    }

    /// Native publication remains owned by its transaction. Ordinary slot
    /// assembly must not publish a bridge that already has zero serving width.
    func requireServiceableOrdinaryGrant() throws {
        guard usesMemoryLimitedConcurrency, !tracksNativeShutdown else { return }
        guard effectiveServingConcurrency > 0 else { throw EngineV2ProductionError.noKVHeadroom }
    }

    nonisolated static func minimumNativeGrantBytes(fixedRequestBytes: Int) -> Int {
        guard fixedRequestBytes >= 0 else { return Int.max }
        let denominator = 100 - MiMoV26AdmissionGeometry.admissionWatermarkPercent
        let (required, addOverflow) = fixedRequestBytes.addingReportingOverflow(
            Int(UnifiedMemoryCap.minimumLoadKVBytes))
        let (scaled, multiplyOverflow) = required.multipliedReportingOverflow(by: 100)
        let (rounded, roundOverflow) = scaled.addingReportingOverflow(denominator - 1)
        guard !addOverflow, !multiplyOverflow, !roundOverflow else { return Int.max }
        return rounded / denominator
    }
}
