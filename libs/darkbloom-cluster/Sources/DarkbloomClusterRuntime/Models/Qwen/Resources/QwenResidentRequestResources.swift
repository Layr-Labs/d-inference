import Foundation
import IOKit.ps
import MLX

struct QwenResidentRequestAllowance {
    let stateBytes: Int
    let fusionBytes: Int
    let reservedBytes: Int
    /// One prefill frame's attention transient at this request's context
    /// (`QwenResidentPrefillTransient`), included in `reservedBytes`.
    var transientBytes = 0
    /// Prompt plus output tokens this allowance was derived for; 0 when unknown.
    var contextTokens = 0
    /// This request's record at the host memory gate, and its first sample.
    let watch = QwenDenseStageLoadWatch("Resident request")

    /// Actual allocator bounds applied per named array. The original F32 state
    /// formula is retained; weights are already resident and charged by active
    /// memory. Fusion permits old parameters and their new banks concurrently.
    /// A Prism Hadamard pack fuses nothing; its first forward instead leaves
    /// one F32 copy of every packed projection's F16 scales and biases beside
    /// them, and `fusionBytes` is the allowance for those copies.
    /// This named ledger excludes unknown workspace/whole-process peak claims.
    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
                       rank: Int, maximumTokens: Int, chunkSize: Int,
                       bound: (Int) throws -> Int) throws -> Self {
        guard plan.stages.count == 2, (0...1).contains(rank) else {
            throw ProbeError("Resident request allowance requires an admitted two-stage Plan")
        }
        // The ceiling is the admitted model's own; no model borrows another's.
        let ceilings = try QwenResidentResourceCeilings(model: profile.model)
        let g = profile.geometry
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        guard b.conservativeStateAndBoundaryBytes <= ceilings.namedStateByteCeiling else {
            throw ProbeError("Resident request exceeds the model's named-state byte ceiling")
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
        let pack = profile.model.pack
        if pack == .prismHadamard {
            fused = try QwenPrismHadamardConstants.widenedBytes(profile: profile, plan: plan, rank: rank).map {
                try allowance($0, 1)
            }
        }
        // A Plan without an interval (Nemotron) has no fused recurrent projections.
        for layer in plan.stages[rank].sourceRange where plan.interval > 0 && (layer + 1) % plan.interval != 0
            && pack.fusesGatedDeltaInputProjections {
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
        // The attention transient of one prefill frame at this context: what
        // the owner's planner and prefill guard price beside the KV (oMLX
        // U#3651), so a context the gate admits is one the frame can run in.
        // From the stage's own layer kinds: a Plan without an interval (Nemotron,
        // interval 0) names its attention blocks `attention`.
        let stageHasAttention = plan.stages[rank].layers.contains { ["full_attention", "attention"].contains($0.kind) }
        let transientLogical = try QwenResidentPrefillTransient.bytes(geometry: g, stageHasAttention: stageHasAttention,
            chunkTokens: chunkSize, contextTokens: maximumTokens)
        let transient = transientLogical == 0 ? 0 : try allowance(transientLogical, 1)
        return .init(stateBytes: state, fusionBytes: fusion, reservedBytes: try sum([state, fusion, transient]),
            transientBytes: transient, contextTokens: maximumTokens)
    }

    /// `onLoadedStage`: a request's reservation on a stage that is already loaded. It asks for what the request
    /// needs plus the loading headroom, not for the entry floor a load asks for: on a 36 GB M4 Max in use, 1.6 GiB
    /// was admissible against a 2.25 GiB floor and every request was refused with 503 while the rank stayed loaded,
    /// though a short request needs a few MiB of it (2026-10-16). Pressure and swap still refuse it (`decide`).
    func requireLive(additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0, onLoadedStage: Bool = false) throws {
        guard additionalNativeBytes >= 0, additionalHostBytes >= 0 else {
            throw ProbeError("Invalid additional resident allowance")
        }
        if onLoadedStage { try QwenResidentResourceEnvironment.requirePower() } else { try QwenResidentResourceEnvironment.require() }
        let os = try QwenDenseStageLoadResources.observeOS()
        let needed = try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalNativeBytes, additionalHostBytes,
            QwenDenseStageLoadPolicy.loadingHeadroomBytes])
        let free = onLoadedStage ? needed : max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes, needed)
        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            reservedBytes, additionalNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        do {
            guard try watch.admits(os, bytes: free, floor: onLoadedStage ? QwenDenseStageLoadPolicy.loadingHeadroomBytes : nil),
                  Memory.memoryLimit >= allocator else {
                throw ProbeError("Resident request exceeds the allocator limit")
            }
        } catch {
            // Name the context the refusal was for: the gate's own sentence
            // names the bytes; the operator needs the tokens to act on it.
            guard contextTokens > 0 else { throw error }
            throw ProbeError("A request of \(contextTokens) context tokens (prompt plus output) on this rank: \(error)")
        }
    }
}

enum QwenResidentResourceEnvironment {
    static func require() throws {
        try requirePower()
        _ = try QwenDenseStageLoadResources.requireInitial()
    }

    /// AC power, normal power mode and a nominal or fair thermal state: the
    /// environment part of `require`, without the entry check's 6 GiB of
    /// admissible memory. A request that was admitted and is running asks for
    /// what it still needs instead (`requireContinuing`); asking it for the
    /// entry floor counted its own allocations against it.
    static func requirePower() throws {
        guard let unmanaged = IOPSCopyPowerSourcesInfo() else { throw ProbeError("Cannot observe resident power source") }
        let info = unmanaged.takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let thermal = ProcessInfo.processInfo.thermalState
        guard source == kIOPSACPowerValue, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermal == .nominal || thermal == .fair else {
            throw ProbeError("Resident execution requires AC, normal power mode and nominal/fair thermal state")
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
