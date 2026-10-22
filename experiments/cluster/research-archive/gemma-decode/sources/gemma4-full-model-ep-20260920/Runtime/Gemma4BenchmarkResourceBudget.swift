import Foundation

/// Named allocation requests, not a whole-process/native-workspace peak proof.
/// A bound callback is metadata only; only the closed live owner can admit work.
struct Gemma4BenchmarkResourceBudget {
    static func requireCandidateCut(_ plan: Gemma4LayerStagePlan) throws {
        guard [6,7,8,10].contains(plan.stages[0].sourceLayerEnd),
              plan.stages[1].sourceLayerStart == plan.stages[0].sourceLayerEnd else {
            throw ProbeError("Gemma resident benchmark operational owner requires the explicit cut6/cut7/cut8/cut10 candidate")
        }
    }
    struct ArrayTerm: Encodable { let name: String; let bytes: Int }
    let selected: [Gemma4SelectedTensor]
    let selectedBounds: [Int]
    let namedArrays: [ArrayTerm]
    let namedAllocationBounds: [Int]
    let namedNativeBytes: Int
    let hostEvidenceBytes: Int
    let largestHostTensorBytes: Int
    let largestNativeCopyBytes: Int
    let persistentCastLogicalBytes: Int
    let stateLogicalBytes: Int
    let stateLayers: [LayerAttentionStateLayout.Layer]
    let planSHA256: String
    let requestSHA256: String
    let prefillAllowance: QwenGenerationPrefillAllowance?

    static func derive(plan: Gemma4LayerStagePlan, target: Gemma4ForwardTarget,
        request: QwenLayerStageGenerationRequest, captureEvidence: Bool,
        prefillPolicy: QwenResidentPrefillPolicy = .serial, bound: (Int) throws -> Int
    ) throws -> Self {
        guard [128,256,1024,4096,8192].contains(request.promptCount), [64,128].contains(request.chunkSize), request.outputCount == 16,
              request.stopTokenIDs.isEmpty, request.maximumTokens == request.promptCount + 16,
              request.profile.identifier == "registered_gemma4_26b_forward_validation_v1",
              request.profile.vocabularySize == 262_144, request.profile.hiddenSize == 2816,
              request.profile.maximumPromptTokens == 8192, request.profile.maximumChunkTokens == 512,
              request.profile.maximumOutputTokens == 128, request.profile.maximumContextTokens == 8320,
              ["float16", "bfloat16", "float32"].contains(request.profile.activationDType) else {
            throw ProbeError("Gemma short resource budget requires closed P128…8192/C64-or128/O16/no-stop geometry")
        }
        let selected = try Gemma4ForwardSelection.make(plan: plan, target: target)
        let globals: [Int]
        let ownsHead: Bool
        switch target {
        case .expertParallel:
            throw ProbeError("Gemma EP requires a separately admitted replicated-state and expert-exchange budget")
        case .fullReference: globals = Array(0..<30); ownsHead = true
        case .stage(let rank): globals = plan.stages[rank].layers.map(\.globalIndex); ownsHead = rank == 1
        }
        let sum = QwenLongPrefillCheckedBytes.sum
        let product = QwenLongPrefillCheckedBytes.product
        func rounded(_ bytes: Int) throws -> Int {
            let value = try bound(bytes)
            guard bytes > 0, value >= bytes else { throw ProbeError("Gemma native allocation bound is invalid") }
            return value
        }
        var arrays: [ArrayTerm] = []
        func add(_ name: String, _ shape: [Int], bytes: Int = 4) throws {
            arrays.append(.init(name: name, bytes: try product(shape + [bytes])))
        }
        // The frozen source loader turns F16 into BF16. ConstantArrayCastCache
        // retains one F32 cast per eligible projection parameter and stream.
        // Embedding head conversions are temporary but receive the same charge.
        var casts = 0
        for item in selected where (item.localName.hasSuffix(".scales") || item.localName.hasSuffix(".biases"))
            && item.dtype.requiresFloat32ParameterCast {
            let embedding = item.localName.hasPrefix("language_model.model.embed_tokens.")
            if embedding && !ownsHead { continue }
            let bytes = try product(item.source.layout.shape + [4])
            arrays.append(.init(name: (embedding ? "headCast:" : "constantCast:") + item.localName, bytes: bytes))
            if !embedding { casts = try sum([casts, bytes]) }
        }
        let text = plan.artifact.text, m = request.chunkSize, n = request.maximumTokens
        var state = 0, logicalSnapshot = 0
        var stateLayers: [LayerAttentionStateLayout.Layer] = []
        for global in globals {
            let full = text.layerKinds[global] == .full
            let heads = full ? text.fullKVHeads : text.slidingKVHeads
            let dim = full ? text.fullHeadDimension : text.slidingHeadDimension
            let slots = full ? n : text.slidingWindow
            stateLayers.append(.init(globalIndex: global, kvHeads: heads, headDimension: dim,
                window: full ? nil : text.slidingWindow, element: .float32))
            let prefix = "layer\(global):"
            // Each allocation is rounded independently. F32 is a supported
            // element-size ceiling, not a prediction of the real probe dtype.
            for name in ["keys", "values"] { try add(prefix + name, [slots, heads, dim]) }
            state = try sum([state, product([2, slots, heads, dim, 4])])
            logicalSnapshot = try sum([logicalSnapshot, product([2, min(n, slots), heads, dim, 4])])
            if !full {
                for name in ["oldKeys", "oldValues"] { try add(prefix + name, [slots, heads, dim]) }
                for name in ["chunkKeys", "chunkValues"] { try add(prefix + name, [slots - 1 + m, heads, dim]) }
            }
            for name in ["position", "capturedPosition", "queryPosition"] { try add(prefix + name, [1]) }
            // Charge all selected layers concurrently; no async-eval interval
            // or final-layer narrowing is treated as an allocation discount.
            for name in ["input", "inputNorm", "oProjection", "postAttention", "attentionResidual",
                         "sharedPreNorm", "sharedDown", "sharedPostNorm", "routerNorm", "sparsePreNorm",
                         "weightedReduction", "sparsePostNorm", "branchSum", "postFFNNorm", "residualAdd", "layerScalarOutput"] {
                try add(prefix + name, [m, text.hiddenSize])
            }
            for name in ["qProjection", "qNorm", "qRoPE", "attentionOutput", "attentionOutputCast"] {
                try add(prefix + name, [m, text.queryHeads, dim])
            }
            for name in ["kProjection", "kNorm", "kRoPE", "vNorm"] { try add(prefix + name, [m, heads, dim]) }
            for name in ["attentionKCopy", "attentionVCopy"] { try add(prefix + name, [n, heads, dim]) }
            for name in ["attentionScores", "attentionProbabilities"] { try add(prefix + name, [text.queryHeads, m, n]) }
            try add(prefix + "attentionMask", [m, n], bytes: 1)
            for name in ["sharedGate", "sharedUp", "sharedGELU", "sharedProduct"] { try add(prefix + name, [m, 2112]) }
            try add(prefix + "routerScale", [text.hiddenSize])
            for name in ["routerScores", "routerPartition"] { try add(prefix + name, [m, 128]) }
            for name in ["topKIndices", "topKValues", "topKSoftmax", "expertScaleGather", "topKWeights"] { try add(prefix + name, [m, 8]) }
            for name in ["order", "inverseOrder", "inputGatherIndex", "sortedIndices"] { try add(prefix + name, [m * 8]) }
            for name in ["sortedInput", "expertDown", "unsortedOutput", "weightedProduct"] { try add(prefix + name, [m * 8, text.hiddenSize]) }
            for name in ["expertGate", "expertUp", "expertGELUProduct"] { try add(prefix + name, [m * 8, 704]) }
        }
        // Probe rows and the real request are sequential. Keeping three-token
        // probe allocations in this ledger is conservative, not a second owner.
        for global in globals {
            let full = text.layerKinds[global] == .full
            for name in ["probeKeys", "probeValues"] {
                try add("layer\(global):" + name, [3, full ? text.fullKVHeads : text.slidingKVHeads,
                    full ? text.fullHeadDimension : text.slidingHeadDimension])
            }
        }
        if target == .fullReference || target == .stage(0) {
            try add("inputIDs", [m])
            try add("embeddingGatherWeight", [m, text.hiddenSize / 2], bytes: 1)
            for name in ["embeddingGatherScales", "embeddingGatherBiases"] { try add(name, [m, text.hiddenSize / 64]) }
            try add("embeddingDequantized", [m, text.hiddenSize])
        }
        for name in ["residual", "ownedResidualCopy", "boundaryExport"] { try add(name, [m, text.hiddenSize]) }
        if ownsHead {
            for name in ["logits", "float32Logits", "softcapTemporary", "samplingRow"] { try add(name, [262_144]) }
        }
        let allowance: QwenGenerationPrefillAllowance?
        if prefillPolicy == .oneChunkLookahead {
            guard case .stage(let rank) = target else { throw ProbeError("Gemma lookahead requires a selected stage") }
            allowance = try .derive(rank: rank, promptCount: request.promptCount, chunkSize: m,
                hiddenSize: text.hiddenSize, elementBytes: 4, bound: rounded)
            if allowance!.extraNativeBytes > 0 {
                // Same F32 element ceiling as the retained named-array ledger.
                try add("lookaheadPreparedBoundary", [m, text.hiddenSize])
            }
        } else { allowance = nil }
        let allocations = try selected.map { try rounded($0.source.layout.byteCount) }
        let host = selected.map { $0.source.layout.byteCount }.max()!
        let namedBounds = try arrays.map { try rounded($0.bytes) }
        if let allowance, allowance.extraNativeBytes > 0 {
            guard arrays.last?.name == "lookaheadPreparedBoundary", namedBounds.last == allowance.extraNativeBytes else {
                throw ProbeError("Gemma lookahead named allocation does not match the shared allowance")
            }
        }
        let native = try sum(namedBounds)
        let hostEvidence = try sum([captureEvidence ? logicalSnapshot : 0,
            captureEvidence ? 8 * 262_144 * 4 : 0, 2 * m * text.hiddenSize * 4, 8_388_608,
            allowance?.extraHostBytes ?? 0, Gemma4BenchmarkGuardMetrics.hostAllowanceBytes])
        return .init(selected: selected, selectedBounds: allocations, namedArrays: arrays, namedAllocationBounds: namedBounds,
            namedNativeBytes: native, hostEvidenceBytes: hostEvidence,
            largestHostTensorBytes: host, largestNativeCopyBytes: try rounded(host),
            persistentCastLogicalBytes: casts, stateLogicalBytes: state,
            stateLayers: stateLayers,
            planSHA256: plan.fingerprint, requestSHA256: request.fingerprint, prefillAllowance: allowance)
    }
}
