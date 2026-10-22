import Foundation
import MLXLLM
import ProviderCoreFoundation

/// Exact source bytes plus explicit native construction scratch, tokenizer and
/// the measured residual allowance (`GLM5NextDiscoveryLoadFootprint
/// .residualAllowanceBytes`). Must equal the discovery estimate for the same
/// snapshot; activation and minimum-KV headroom are still added by the gate.
struct GLM5NextLoadQuotation: Sendable {
    let sourceBytes: UInt64
    let nativeTransientBytes: UInt64
    let tokenizerAllowanceBytes: UInt64
    let residualAllowanceBytes: UInt64
    let requiredWeightBytes: UInt64
    let textBytes: UInt64
    let visionBytes: UInt64
    let mtpBytes: UInt64
    var estimatedWeightsGb: Double { Double(requiredWeightBytes) / 1_073_741_824 }

    init(manifest: ModelManifest, inventory: GLM5NextWeightInventory) throws {
        guard manifest.totalSizeBytes > 0 else { throw GLM5NextManagedLoadError.invalidManifest }
        sourceBytes = UInt64(manifest.totalSizeBytes)
        residualAllowanceBytes = GLM5NextDiscoveryLoadFootprint.residualAllowanceBytes(
            sourceBytes: sourceBytes)
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
        let tokenizerBytes = try manifest.files.filter {
            !$0.path.hasSuffix(".safetensors")
        }
        .reduce(UInt64(0)) { try Self.add($0, UInt64($1.sizeBytes)) }
        let expanded = tokenizerBytes.multipliedReportingOverflow(by: 8)
        guard !expanded.overflow else { throw GLM5NextManagedLoadError.admission }
        tokenizerAllowanceBytes = max(64 << 20, expanded.partialValue)
        requiredWeightBytes = try Self.add(
            try Self.add(sourceBytes, residualAllowanceBytes),
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
