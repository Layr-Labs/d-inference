import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

/// Ordinary protected serving remains closed. This additional case is only the
/// explicitly selected, source/evidence-bound short 9B experiment.
enum CollectiveProtectedResourcePolicy {
    case unqualified
    case qwen9bShortExperiment

    func requireQualified() throws {
        switch self {
        case .unqualified: throw ProbeError("Protected native staging has no qualified memory profile")
        case .qwen9bShortExperiment: try QwenProtectedResources.requireLive()
        }
    }
    func requireOperation(shape: [Int], dtype: DType) throws {
        try QwenProtectedArrayGeometry.require(shape: shape, dtype: dtype)
        try requireQualified()
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

/// A retains and consumes its own secret. The legacy key initializer is kept
/// for the separately gated codec allocation fixture, never for native startup.
struct CollectiveProtectionConfiguration {
    private enum Source { case key(SymmetricKey), authority(ClusterNativeRecordAuthority) }
    private let source: Source
    let binding: ClusterRecordBinding
    let limits: ClusterRecordLimits
    let maximumFrameBytes: Int
    let resourcePolicy: CollectiveProtectedResourcePolicy
    private let recordBudget: QwenProtectedRecordBudget?

    init(sessionKey: SymmetricKey, binding: ClusterRecordBinding, limits: ClusterRecordLimits,
         maximumFrameBytes: Int, resourcePolicy: CollectiveProtectedResourcePolicy) {
        source = .key(sessionKey); self.binding = binding; self.limits = limits; recordBudget = nil
        self.maximumFrameBytes = maximumFrameBytes; self.resourcePolicy = resourcePolicy
    }
    init(authority: ClusterNativeRecordAuthority, binding: ClusterRecordBinding,
         limits: ClusterRecordLimits, maximumFrameBytes: Int, recordBudget: QwenProtectedRecordBudget) {
        source = .authority(authority); self.binding = binding; self.limits = limits; self.recordBudget = recordBudget
        self.maximumFrameBytes = maximumFrameBytes; resourcePolicy = .qwen9bShortExperiment
    }
    func makeTransport(io: CollectiveRecordByteIO) throws -> ClusterAuthenticatedRecordTransport {
        switch source {
        case .key(let key):
            // Supplying public fields and an arbitrary key is never an admission.
            guard case .unqualified = resourcePolicy else { throw ProbeError("Experimental transport requires the native authority") }
            return try .init(sessionKey: key, binding: binding, limits: limits, io: io)
        case .authority(let authority): return try authority.makeRecordTransport(io: io)
        }
    }
    func requireCredit(status: ClusterRecordTransportStatus, sending: Bool, plaintextBytes: Int) throws {
        guard let recordBudget else { throw ProbeError("Protected native credit was not reserved") }
        try recordBudget.requireCredit(status: status, sending: sending, plaintextBytes: plaintextBytes)
    }
    func invalidate() { if case .authority(let authority) = source { authority.invalidate() } }
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
