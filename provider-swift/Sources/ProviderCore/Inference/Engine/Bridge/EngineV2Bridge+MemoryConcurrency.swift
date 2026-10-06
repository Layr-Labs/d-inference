// Native MiMo admission: keep useful KV space after fixed request workspace.
import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// Native engines reserve fixed MTP/prefill workspace per request. A grant
    /// shrink must reduce concurrency before reserving every possible future
    /// workspace in the heartbeat. Otherwise a loaded model advertises zero
    /// tokens even when one or more requests still fit.
    func memoryLimitedConcurrency(configured: Int, capacityBytes: Int? = nil) -> Int {
        guard tracksNativeShutdown else { return configured }
        return Self.nativeMemoryConcurrencyLimit(configured: configured,
            capacityBytes: capacityBytes ?? nativeAdmissionCapacityBytes(),
            requestOverheadBytes: maximumRequestOverheadBytes())
    }

    /// Scalar portion shared by live reporting/admission and policy tests.
    nonisolated static func nativeMemoryConcurrencyLimit(
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
    func nativeAdmissionCapacityBytes() -> Int {
        guard let native = ownedEngine as? EngineV2 else { return 0 }
        let snapshot = native.capacity()
        var capacity = min(snapshot.kvBytesCapacity, native.admissibleKVBytesCapacity)
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
