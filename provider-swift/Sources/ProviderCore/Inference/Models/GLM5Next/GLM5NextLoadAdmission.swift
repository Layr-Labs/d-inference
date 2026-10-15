import Foundation
import MLXLLM
import ProviderCoreFoundation

/// Keep the ordinary disk × 1.2 LOAD basis and ADD the native construction
/// scratch, rather than substituting measured residency or lowering headroom.
struct GLM5NextLoadQuotation: Sendable {
    let genericWeightAllowanceBytes: UInt64
    let nativeTransientBytes: UInt64
    let tokenizerAllowanceBytes: UInt64
    let requiredWeightBytes: UInt64
    let textBytes: UInt64
    let visionBytes: UInt64
    let mtpBytes: UInt64
    var estimatedWeightsGb: Double { Double(requiredWeightBytes) / 1_073_741_824 }

    init(
        manifest: ModelManifest, inventory: GLM5NextWeightInventory,
        tokenizerManifest: ModelManifest
    ) throws {
        guard manifest.totalSizeBytes > 0 else { throw GLM5NextManagedLoadError.invalidManifest }
        let disk = UInt64(manifest.totalSizeBytes)
        // ceil(6 * disk / 5), calculated without floating-point under-rounding.
        genericWeightAllowanceBytes = try Self.add(
            disk, try Self.add(disk / 5, disk % 5 == 0 ? 0 : 1))
        textBytes = UInt64(inventory.bytes(in: .text))
        visionBytes = UInt64(inventory.bytes(in: .vision))
        mtpBytes = UInt64(inventory.bytes(in: .mtp))
        var banks: [String: UInt64] = [:]
        var largest: UInt64 = 0
        for entry in inventory.entries.values {
            largest = max(largest, UInt64(entry.bytes))
            if entry.tensor.name.contains(".mlp.experts.") {
                banks[entry.nativeName] = try Self.add(
                    banks[entry.nativeName, default: 0], UInt64(entry.bytes))
            }
        }
        // Matches or exceeds GLM5NextArtifactResources: source Data + owned
        // tensor, old expert bank, vision layout/constructor copies and metadata.
        var scratch = try Self.add(largest, largest)
        scratch = try Self.add(scratch, banks.values.max() ?? 0)
        scratch = try Self.add(scratch, try Self.add(visionBytes, visionBytes))
        nativeTransientBytes = try Self.add(scratch, (256 << 20) + (1 << 20))
        let tokenizerBytes = try tokenizerManifest.files.filter {
            !$0.path.hasSuffix(".safetensors")
        }
        .reduce(UInt64(0)) { try Self.add($0, UInt64($1.sizeBytes)) }
        let expanded = tokenizerBytes.multipliedReportingOverflow(by: 8)
        guard !expanded.overflow else { throw GLM5NextManagedLoadError.admission }
        tokenizerAllowanceBytes = max(64 << 20, expanded.partialValue)
        requiredWeightBytes = try Self.add(
            genericWeightAllowanceBytes,
            try Self.add(nativeTransientBytes, tokenizerAllowanceBytes))
    }

    func requiredToLoadGb(activationReserveBytes: UInt64) -> Double {
        ModelLoadAdmission.requiredToLoadGb(
            weightsGb: estimatedWeightsGb,
            headroomGb: Double(
                UnifiedMemoryCap.loadHeadroomBytes(
                    activationReserveBytes:
                        max(activationReserveBytes, UnifiedMemoryCap.defaultActivationReserveBytes))
            ) / 1_073_741_824)
    }

    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let sum = a.addingReportingOverflow(b)
        guard !sum.overflow else { throw GLM5NextManagedLoadError.admission }
        return sum.partialValue
    }
}

extension GlobalKVCacheBudget {
    /// Validate the actual generation-bound permit held by the outer ordinary
    /// load funnel; a Boolean or an unrelated reservation cannot authorize GLM.
    func validateGLM5NextPendingLoad(
        _ lease: PendingModelLoadLease, modelID: String,
        quotation: GLM5NextLoadQuotation
    ) -> Bool {
        guard let current = pendingLoads[lease.owner],
            current.requestID == "pending-load:\(modelID)",
            current.minimumKVBytes >= UnifiedMemoryCap.minimumLoadKVBytes,
            current.state.chargedBytes >= quotation.requiredWeightBytes,
            current.state.chargedBytes - quotation.requiredWeightBytes >= current.minimumKVBytes,
            processLedger.policySnapshot().reserveBytes
                >= UnifiedMemoryCap.defaultActivationReserveBytes
        else {
            return false
        }
        return recheckPendingLoad(lease)
    }
}
