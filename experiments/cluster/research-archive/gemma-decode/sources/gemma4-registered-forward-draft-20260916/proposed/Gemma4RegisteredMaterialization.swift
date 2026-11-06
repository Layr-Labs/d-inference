import Foundation
import MLX
import MLXNN

struct Gemma4ForwardLoadReceipt: Encodable {
    let artifactSHA256: String
    let configurationSHA256: String
    let planSHA256: String
    let target: String
    let parameterLayoutSHA256: String
    let sourceTensorCount: Int
    let selectedTensorCount: Int
    let loadedTensorBytes: Int
    let largestHostTensorBytes: Int
    let readAccounting: CheckpointAlignedReadAccounting
    let bf16ConversionEnabled = true
    let resourceAdmissionEstablished = false
}

/// Constructible only by the complete verified materializer below. This proves
/// source/storage provenance, not capacity or readiness. It retains no file FD.
struct Gemma4LoadedForwardModel {
    let model: Gemma4ForwardModel
    let plan: Gemma4LayerStagePlan
    let target: Gemma4ForwardTarget
    let receipt: Gemma4ForwardLoadReceipt
    fileprivate init(model: Gemma4ForwardModel, plan: Gemma4LayerStagePlan,
                     target: Gemma4ForwardTarget, receipt: Gemma4ForwardLoadReceipt) {
        self.model = model; self.plan = plan; self.target = target; self.receipt = receipt
    }
}

/// The caller's ordered pre-read gate is mandatory. No resource allowance is
/// inferred from the metadata Plan, and no full-model loadWeights fallback is
/// available. A later registered entry must supply the closed Gemma resource
/// owner; this low-level function does not mint execution authorization.
func materializeRegisteredGemma4(_ prepared: Gemma4PreparedForwardModel,
    beforeTensor: (Gemma4SelectedTensor) throws -> Void,
    check: () throws -> Void
) throws -> Gemma4LoadedForwardModel {
    try withoutActuallyEscaping(check) { borrowedCheck in
        try MLX.withError { native in
            func checked() throws { try native.check(); try borrowedCheck(); try native.check() }
            do {
                try checked()
                let source = prepared.source, module = prepared.model.module
                try source.checkpoint.checkUnchanged()
                try source.checkpoint.bypassTensorPayloadCache()
                var loadedBytes = 0, largestHostBytes = 0
                var accounting = CheckpointAlignedReadAccounting()
                for selected in prepared.selected {
                    try autoreleasepool {
                        try checked(); try beforeTensor(selected); try checked()
                        guard let tensor = source.tensors[selected.source.layout.canonicalName] else {
                            throw ProbeError("Verified Gemma source disappeared")
                        }
                        let read = try tensor.read(.all)
                        var array = read.array
                        try checked()
                        guard array.shape == selected.source.layout.shape,
                              String(describing: array.dtype) == selected.source.layout.sourceDType else {
                            throw ProbeError("Registered Gemma source array differs")
                        }
                        // Registered artifact is already canonical split-expert
                        // storage. No whole-model sanitizer or slicing is needed.
                        if array.dtype == .float16 { array = array.asType(.bfloat16) }
                        eval(array); Stream.gpu.synchronize(); try checked()
                        guard array.nbytes == selected.source.layout.byteCount,
                              read.copiedBytes == array.nbytes,
                              String(describing: array.dtype) == selected.loadedDType,
                              let storage = try array.evaluatedBufferInfo(), storage.isUnique,
                              storage.isRowContiguous, storage.dataOffset == 0,
                              storage.dataElements == array.size, storage.allocatedBytes >= array.nbytes,
                              storage.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)),
                              let part = read.readAccounting, part.selectedBytes == read.copiedBytes else {
                            throw ProbeError("Registered Gemma tensor lacks compact owned storage or exact read accounting")
                        }
                        try module.update(parameters: ModuleParameters.unflattened([selected.localName:array]),
                            verify: [.noUnusedKeys, .shapeMismatch])
                        try checked()
                        loadedBytes = try LayerAttentionStateLayout.sum(loadedBytes, read.copiedBytes)
                        largestHostBytes = max(largestHostBytes, read.copiedBytes)
                        try accounting.merge(part)
                    }
                }
                module.freeze(); try checked()
                let actual = module.parameters().flattened()
                let expectedBytes = try prepared.selected.reduce(0) {
                    try LayerAttentionStateLayout.sum($0, $1.source.layout.byteCount)
                }
                let layout = actual.map { "\($0.0):\($0.1.dtype):\($0.1.shape)" }.sorted().joined(separator: "\n")
                guard actual.count == prepared.selected.count,
                      loadedBytes == expectedBytes, accounting.selectedBytes == expectedBytes,
                      sha256(Data(layout.utf8)) == prepared.parameterLayoutSHA256,
                      module.trainableParameters().flattened().isEmpty else {
                    throw ProbeError("Registered Gemma loaded inventory differs")
                }
                try source.checkpoint.checkUnchanged(); try checked()
                let target: String
                switch prepared.target { case .fullReference: target = "full-reference"; case .stage(let rank): target = "stage-\(rank)" }
                let receipt = Gemma4ForwardLoadReceipt(
                    artifactSHA256: source.checkpoint.aggregate,
                    configurationSHA256: source.checkpoint.configurationSHA256,
                    planSHA256: source.plan.fingerprint, target: target,
                    parameterLayoutSHA256: prepared.parameterLayoutSHA256,
                    sourceTensorCount: source.artifact.sources.count,
                    selectedTensorCount: prepared.selected.count, loadedTensorBytes: loadedBytes,
                    largestHostTensorBytes: largestHostBytes, readAccounting: accounting)
                return .init(model: prepared.model, plan: source.plan, target: prepared.target, receipt: receipt)
            } catch { try native.check(); throw error }
        }
    }
}
