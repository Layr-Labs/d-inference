import Foundation
import MLX
import MLXLMCommon

struct Gemma4ShortCorrectnessOutput {
    let data: Data
    let resources: Gemma4ShortResourceReceipt
}

/// Root-run qualification only, inside the existing dedicated native process,
/// device lease, resource watcher and parent lifetime. No serving API is added.
func withRegisteredGemma4ShortCorrectness(
    directory: URL, artifact: Gemma4ArtifactMetadata, target: Gemma4ForwardTarget,
    request: QwenLayerStageGenerationRequest, residualDType: DType, deadline: UInt64,
    probeInput: ((CBv2NativeKVTypeProbe.Phase, Int) throws -> MLXArray)? = nil,
    observeProbeOutput: ((CBv2NativeKVTypeProbe.Phase, MLXArray) throws -> Void)? = nil,
    check: () throws -> Void, body: (Gemma4OwnedForwardSession) throws -> Data
) throws -> Gemma4ShortCorrectnessOutput {
    try withoutActuallyEscaping(check) { borrowedCheck in
        try MLX.withError { native in
            func outerCheck() throws { try native.check(); try borrowedCheck(); try native.check() }
            do {
                try outerCheck()
                // Keep the existing native defaults and arithmetic, but reject
                // overrides that would invalidate this bounded initial scope.
                let environment = ProcessInfo.processInfo.environment
                _ = try QwenLongPrefillArithmeticEnvironment.admit(environment)
                for name in ["MLX_QUANTIZED_CONSTANT_CACHE", "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
                    "MLX_GATHER_QMM_EXPERT_SLICES", "MLX_COMPILED_DECODE",
                    "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
                    "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"] {
                    guard environment[name] == nil else { throw ProbeError("Gemma initial correctness requires default " + name) }
                }
                try QwenResidentResourceEnvironment.require(); try outerCheck()
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                    setCacheLimit: { Memory.cacheLimit = $0 }, check: outerCheck)
                Memory.clearCache(); try outerCheck()
                let plan = try Gemma4LayerStagePlan(artifact: artifact, cut: Gemma4ShortResourceBudget.candidateCut)
                let owner = try Gemma4ShortResourceOwner(plan: plan, target: target,
                    request: request, residualDType: residualDType, deadline: deadline)
                func checked() throws { try outerCheck(); try owner.check(); try outerCheck() }
                let data = try withRegisteredGemma4Forward(directory: directory, artifact: artifact,
                    cut: Gemma4ShortResourceBudget.candidateCut, target: target, request: request, residualDType: residualDType,
                    admitConstruction: owner.construction, admitPrepared: owner.prepared, beforeTensor: owner.beforeTensor,
                    afterTensor: owner.afterTensor, admitLoadedProbe: owner.loaded,
                    admitRequest: owner.request, probeInput: probeInput, observeProbeOutput: observeProbeOutput,
                    check: checked, body: { session in
                        let value = try body(session)
                        guard value.count <= 1_048_576 else { throw ProbeError("Gemma correctness result exceeds bounded metadata output") }
                        return value
                    })
                try outerCheck()
                return .init(data: data, resources: try owner.completed())
            } catch { try native.check(); throw error }
        }
    }
}
