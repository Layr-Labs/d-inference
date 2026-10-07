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

    /// Load/reserve-raise preflight must preserve room for one native request
    /// plus the existing minimum KV allowance. MiMoV26AdmissionGeometry uses
    /// the standard 5% admission watermark and native compiled decode is off.
    /// Checked integer ceil avoids losing that watermark during re-slicing.
    func minimumServiceableNativeGrantBytes() -> Int {
        let minimumKV = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        guard tracksNativeShutdown else { return minimumKV }
        guard let overhead = maximumRequestOverheadBytes() else { return Int.max }
        return Self.minimumNativeGrantBytes(fixedRequestBytes: overhead)
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
