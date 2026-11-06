import Foundation
import IOKit.ps
import MLX

struct QwenResidentRequestAllowance {
    let stateBytes: Int
    let fusionBytes: Int
    let reservedBytes: Int

    /// Actual allocator bounds applied per named array. The original F32 state
    /// formula is retained; weights are already resident and charged by active
    /// memory. Fusion permits old parameters and their new banks concurrently.
    /// This named ledger excludes unknown workspace/whole-process peak claims.
    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       rank: Int, maximumTokens: Int, chunkSize: Int,
                       bound: (Int) throws -> Int) throws -> Self {
        guard plan.stages.count == 2, (0...1).contains(rank) else {
            throw ProbeError("Resident request allowance requires the admitted 9B stage")
        }
        let resources = try QwenDenseRegisteredResourceProfile(profile: profile)
        let g = profile.geometry
        let b: QwenLongPrefillTensorBudget
        if profile.model == .qwen35NineB {
            // Preserve every prior 9B bound/refusal and the unchanged formula.
            b = try QwenLongPrefillTensorBudget.estimate(geometry: g,
                maximumTokens: maximumTokens, chunkSize: chunkSize)
        } else {
            b = try resources.namedStateBudget(maximumTokens: maximumTokens, chunkSize: chunkSize)
        }
        guard b.conservativeStateAndBoundaryBytes <= resources.namedTensorByteCeiling else {
            throw ProbeError("Resident request exceeds the unchanged named-state byte ceiling")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func allowance(_ bytes: Int, _ count: Int) throws -> Int {
            let rounded = try bound(bytes)
            guard bytes > 0, rounded >= bytes else { throw ProbeError("Resident allocator bound is invalid") }
            return try product([rounded, count])
        }
        // Charge the full model's conservative state to either rank. This is
        // intentionally conservative and does not repurpose an 8K receipt.
        let state = try sum([
            allowance(b.convolutionBytesPerLayer, 3 * b.recurrentLayers),
            allowance(b.ssmBytesPerLayer, 3 * b.recurrentLayers),
            allowance(b.kvCapacityBytesPerAttentionLayer / 2, 2 * b.attentionLayers),
            allowance(4, b.attentionLayers),
            allowance(b.largestSingleHostStateComponentBytes, 1),
            allowance(b.boundaryBytes, 2),
        ])
        let tensors = Dictionary(uniqueKeysWithValues: profile.canonicalTensors.map { ($0.name, $0) })
        var fused = [Int](), logical = [Int]()
        for layer in plan.stages[rank].sourceRange where (layer + 1) % plan.interval != 0 {
            for suffix in ["weight", "scales", "biases"] {
                let parts = try ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].map { projection in
                    let name = "language_model.model.layers.\(layer).linear_attn.\(projection).\(suffix)"
                    guard let tensor = tensors[name] else { throw ProbeError("Missing resident fusion source") }
                    return tensor
                }
                let dtype = suffix == "weight" ? "U32" : "BF16"
                guard let first = parts.first, first.shape.count == 2,
                      parts.allSatisfy({ $0.sourceDType == dtype && $0.shape.count == 2 && $0.shape[1] == first.shape[1] }) else {
                    throw ProbeError("Resident fusion shape/dtype differs")
                }
                let bytes = try product([sum(parts.map { $0.shape[0] }), first.shape[1], suffix == "weight" ? 4 : 2])
                guard bytes == (try sum(parts.map(\.byteCount))) else { throw ProbeError("Resident fusion byte conservation differs") }
                logical.append(bytes); fused.append(try allowance(bytes, 1))
            }
        }
        let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan,
            role: rank == 0 ? .stage0 : .stage1)
        guard try sum(logical) == selected.fusionReplacementBytes else { throw ProbeError("Resident fusion ownership differs") }
        let fusion = try sum(fused)
        return .init(stateBytes: state, fusionBytes: fusion, reservedBytes: try sum([state, fusion]))
    }

    func requireLive(additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0,
                     memoryObserver: QwenResidentMemoryObserver? = nil) throws {
        guard additionalNativeBytes >= 0, additionalHostBytes >= 0 else {
            throw ProbeError("Invalid additional resident allowance")
        }
        try QwenResidentResourceEnvironment.require()
        var memoryPages: QwenResidentMemoryPages?
        let os = try QwenDenseStageLoadResources.requireInitial(
            memoryPages: memoryObserver == nil ? nil : { memoryPages = $0 })
        let free = max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalNativeBytes, additionalHostBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            reservedBytes, additionalNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard os.actualFreeBytes >= free, Memory.memoryLimit >= allocator else {
            throw ProbeError("Resident request exceeds live actual-free or allocator policy")
        }
        if let memoryObserver, let memoryPages { try memoryObserver(os, memoryPages, free, allocator) }
    }
}

enum QwenResidentResourceEnvironment {
    static func require(additionalHostBytes: Int = 0) throws {
        guard let unmanaged = IOPSCopyPowerSourcesInfo() else { throw ProbeError("Cannot observe resident power source") }
        let info = unmanaged.takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let thermal = ProcessInfo.processInfo.thermalState
        guard source == kIOPSACPowerValue, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermal == .nominal || thermal == .fair else {
            throw ProbeError("Resident execution requires AC, normal power mode and nominal/fair thermal state")
        }
        let os = try QwenDenseStageLoadResources.requireInitial()
        if additionalHostBytes != 0 {
            guard additionalHostBytes > 0, os.actualFreeBytes >= max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                try QwenLongPrefillCheckedBytes.sum([additionalHostBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes])) else {
                throw ProbeError("Phase-memory host allocation exceeds live admission")
            }
        }
    }

    static func allocationBound(_ bytes: Int) throws -> Int {
        let value = try Memory.allocationFootprintUpperBound(byteCount: bytes)
        guard value >= bytes, value <= GPU.deviceInfo().maxBufferSize else {
            throw ProbeError("Resident request array exceeds actual device buffer limit")
        }
        return value
    }
}
