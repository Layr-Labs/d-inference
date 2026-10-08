import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

/// The fixed measured policy is intentionally absent until the exact codec/native
/// staging probe and outer owner resource join have been reviewed.
enum CollectiveProtectedResourcePolicy {
    case unqualified

    func requireQualified() throws {
        throw ProbeError("Protected native staging has no qualified memory profile")
    }
}

/// Observations needed by admission, not an assertion that these logical host
/// counts bound Foundation capacities or CryptoKit workspace.
struct CollectiveProtectedOperationBounds {
    let plaintextBytes: Int
    let recordBytes: Int
    let logicalHostObjectsBytes: Int
    let nativeFrameAllocationBytes: Int
    let nativePlaintextAllocationBytes: Int

    init(shape: [Int], dtype: DType, maximumPlaintextBytes: Int, maximumFrameBytes: Int) throws {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype, maximumBytes: maximumPlaintextBytes)
        let framing = try ClusterRecordTransferAccounting(length: .exact(geometry.byteCount),
            maximumTransportFrameBytes: maximumFrameBytes)
        plaintextBytes = geometry.byteCount; recordBytes = framing.maximumSealedRecordBytes
        logicalHostObjectsBytes = try [geometry.byteCount,
            framing.maximumSealedRecordBytes, framing.maximumSealedRecordBytes,
            framing.codecCiphertextAndTagLogicalBytes].reduce(0) { total, bytes in
                let value = total.addingReportingOverflow(bytes)
                guard bytes >= 0, !value.overflow else { throw ProbeError("Protected staging byte count overflow") }
                return value.partialValue
            }
        nativeFrameAllocationBytes = try Memory.allocationFootprintUpperBound(byteCount: framing.maximumSealedRecordBytes)
        nativePlaintextAllocationBytes = try Memory.allocationFootprintUpperBound(byteCount: geometry.byteCount)
    }
}

/// Key freshness/coordinator admission is external. No initializer or caller
/// boolean can mark this unmeasured resource policy as qualified.
struct CollectiveProtectionConfiguration {
    let sessionKey: SymmetricKey
    let binding: ClusterRecordBinding
    let limits: ClusterRecordLimits
    let maximumFrameBytes: Int
    let resourcePolicy: CollectiveProtectedResourcePolicy

    func requireBinding(epoch: UUID, planSHA256: String) throws {
        guard binding.epoch == epoch, binding.planSHA256 == (try collectiveRecordDigest(planSHA256)) else {
            throw ProbeError("Protected native construction differs from the admitted epoch/Plan")
        }
        try resourcePolicy.requireQualified()
    }
}

/// Required probe observations; these fields do not confer admission.
/// OS lifetime high-water captures temporaries inside seal/open. Do not replace
/// it with before/after footprint samples or subtract two historical maxima.
struct CollectiveProtectedResourceMeasurement: Encodable {
    let schema = "collective_protected_resource_measurement_v1"
    let codecSourceSHA256: String
    let nativeStagingSourceSHA256: String
    let nativeTailSourceSHA256: String
    let runtimeBuildSHA256: String
    let hardwareModel: String
    let osBuild: String
    let sdkBuild: String
    let suite: String
    let allocatorPolicy: String
    let scenario: String
    let plaintextByteCounts: [Int]
    let nativeShapes: [[Int]]
    let nativeDTypes: [String]
    let direction: String
    let repetitions: Int
    let baselineNativeActiveBytes: Int
    let peakNativeActiveBytes: Int
    let peakNativeCachedBytes: Int
    let finalNativeActiveBytes: Int
    let baselinePhysicalFootprintBytes: UInt64
    let lifetimeMaximumPhysicalFootprintBeforeBytes: UInt64
    let lifetimeMaximumPhysicalFootprintAfterBytes: UInt64
    let finalPhysicalFootprintBytes: UInt64
    let completedRecords: UInt64
    let refusedRecords: UInt64
    let publishedArrays: UInt64
    let plaintextDigestMatched: Bool
    let rawReceiptSHA256: String
}
