import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

private struct CapturedGemmaMoE {
    let layer: Gemma4DecoderLayer
    let router: MoELinearCapture
    let preDense: MoENormCapture
    let preSparse: MoENormCapture
    let postDense: MoENormCapture
    let postSparse: MoENormCapture
    let postCombined: MoENormCapture

    init(_ layer: Gemma4DecoderLayer) throws {
        self.layer = layer
        router = try captureMoELinear(moeModule(layer, "router"), key: "proj")
        preDense = try captureMoENorm(layer, key: "pre_feedforward_layernorm")
        preSparse = try captureMoENorm(layer, key: "pre_feedforward_layernorm_2")
        postDense = try captureMoENorm(layer, key: "post_feedforward_layernorm_1")
        postSparse = try captureMoENorm(layer, key: "post_feedforward_layernorm_2")
        postCombined = try captureMoENorm(layer, key: "post_feedforward_layernorm")
        layer.freeze(); eval(layer)
    }

    func forward(_ input: MLXArray) -> MLXArray {
        let output = layer(input, mask: .causal, cache: nil).0
        eval(output)
        return output
    }
}

/// Local peer-partial injection exercises both real decoder normalization
/// boundaries. This is actual block correctness, not distributed execution.
func checkGemmaMoEBoundary() throws {
    for bf16 in [false, true] { try checkGemmaMoEBoundary(bf16: bf16) }
}

private func checkGemmaMoEBoundary(bf16: Bool) throws {
    MLXRandom.seed(919)
    let text: [String: Any] = [
        "model_type": "gemma4_text", "hidden_size": 128, "num_hidden_layers": 1,
        "intermediate_size": 256, "num_attention_heads": 4, "num_key_value_heads": 2,
        "head_dim": 64, "global_head_dim": 64, "num_kv_shared_layers": 0,
        "hidden_size_per_layer_input": 0, "layer_types": ["full_attention"],
        "vocab_size": 512, "enable_moe_block": true, "num_experts": 4,
        "top_k_experts": 2, "moe_intermediate_size": 704, "use_double_wide_mlp": false,
        "max_position_embeddings": 2048,
    ]
    let data = try JSONSerialization.data(withJSONObject: text)
    let configuration = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
    func construct() -> Gemma4DecoderLayer {
        let layer = Gemma4DecoderLayer(configuration, layerIdx: 0)
        quantize(model: layer, groupSize: 64, bits: 4)
        return layer
    }
    let original = construct()
    let expertScales: [Float] = [0.7, 1.1, 1.6, 0.9]
    var parameters = Dictionary(uniqueKeysWithValues: original.parameters().flattened())
    parameters["router.per_expert_scale"] = MLXArray(expertScales)
    parameters["router.scale"] = MLXArray((0..<128).map { 0.8 + Float($0) * 0.4 / 127 })
    parameters["post_feedforward_layernorm_1.weight"] = MLXArray((0..<128).map { 0.7 + Float($0) * 0.6 / 127 })
    parameters["post_feedforward_layernorm_2.weight"] = MLXArray((0..<128).map { 1.3 - Float($0) * 0.6 / 127 })
    if bf16 {
        parameters = parameters.mapValues { [.float32, .float16].contains($0.dtype) ? $0.asType(.bfloat16) : $0 }
    }
    try original.update(parameters: ModuleParameters.unflattened(parameters), verify: [.all])
    let dtype: DType = bf16 ? .bfloat16 : .float32
    let metadataTypes = Set(parameters.filter { $0.key.hasSuffix(".scales") || $0.key.hasSuffix(".biases") }
        .map { String(describing: $0.value.dtype) }).sorted()
    guard metadataTypes == [String(describing: dtype)], let scaleTensor = parameters["router.per_expert_scale"],
        scaleTensor.dtype == dtype else { throw ProbeError("Gemma fixture did not exercise the requested parameter dtype") }
    let actualExpertScales = scaleTensor.asType(.float32).asArray(Float.self)
    guard let experts = try moeModule(original, "experts.switch_glu") as? SwitchGLU else {
        throw ProbeError("Missing actual Gemma GeGLU expert module")
    }
    let denseWeights = try FFNWeights(module: moeModule(original, "mlp"), path: "mlp")
    let partials = try [0..<320, 320..<704].map {
        try QuantizedExpertPartial(source: experts, interval: $0, activation: .geluTanh)
    }
    let baseline = try CapturedGemmaMoE(original)
    var ranks: [CapturedGemmaMoE] = []
    for rank in 0..<2 {
        let layer = construct()
        try layer.update(parameters: ModuleParameters.unflattened(parameters), verify: [.all])
        try moeModule(layer, "experts").update(modules: ModuleChildren(values: [
            "switch_glu": .value(partials[rank].localSwitchGLU),
        ]), verify: [.noUnusedKeys])
        try installDenseMoEPartial(moeModule(layer, "mlp"), source: denseWeights, rank: rank)
        ranks.append(try CapturedGemmaMoE(layer))
    }
    for rows in [1, 33] {
        let x = MLXRandom.normal([1, rows, 128]).asType(dtype)
        let reference = baseline.forward(x)
        guard let logits = baseline.router.recorded, let expertInput = baseline.preSparse.output,
            let denseReference = baseline.postDense.input, let sparseReference = baseline.postSparse.input,
            let combinedReference = baseline.postCombined.input
        else { throw ProbeError("Gemma actual branch captures did not execute") }
        guard [reference, logits, expertInput, denseReference, sparseReference, combinedReference]
            .allSatisfy({ $0.dtype == dtype }) else {
            throw ProbeError("Gemma decoder/router/branches did not preserve the requested dtype")
        }
        let route = try moeRouteOracle(logits: logits, topK: 2, normalizeQwen: nil,
            expertScales: expertScales, expertScaleTensor: scaleTensor)
        let flatExpertInput = expertInput.reshaped(rows, 128)
        let routed = experts.callAndWeightedReduce(flatExpertInput, route.ids, weights: route.scores,
            fuseSortedReduction: false, isProductionPrefill: false).reshaped(1, rows, 128)
        let routingBoundaryParity = try moeBoundaryError(sparseReference, routed,
            label: "Gemma actual per-expert-scaled routing boundary rows=\(rows)", requireExact: bf16)
        for rank in 0..<2 {
            ranks[rank].postDense.peerPartial = nil; ranks[rank].postSparse.peerPartial = nil
            _ = ranks[rank].forward(x)
            guard partials[rank].plan.numExperts == 4, let localLogits = ranks[rank].router.recorded else {
                throw ProbeError("Gemma rank lost the global expert/router contract")
            }
            try moeExactRouterMatch(logits, localLogits)
            let localRoute = try moeRouteOracle(logits: localLogits, topK: 2,
                normalizeQwen: nil, expertScales: expertScales, expertScaleTensor: scaleTensor)
            guard localRoute.expertIDs == route.expertIDs, localRoute.routeScores == route.routeScores else {
                throw ProbeError("Gemma rank changed oracle-derived global IDs or scores")
            }
        }
        let densePieces = try ranks.map { capture -> MLXArray in
            guard let value = capture.postDense.input else { throw ProbeError("Missing Gemma dense partial") }
            return value
        }
        let sparsePieces = try ranks.map { capture -> MLXArray in
            guard let value = capture.postSparse.input else { throw ProbeError("Missing Gemma routed partial") }
            return value
        }
        let denseParity = try moeBoundaryError(denseReference, densePieces[0] + densePieces[1],
            label: "Gemma dense reduction before branch norm rows=\(rows)")
        let sparseParity = try moeBoundaryError(sparseReference, sparsePieces[0] + sparsePieces[1],
            label: "Gemma routed reduction before branch norm rows=\(rows)")
        let oraclePieces = try partials.map {
            try $0(flatExpertInput, expertIDs: route.ids, routingWeights: route.scores).reshaped(1, rows, 128)
        }
        for rank in 0..<2 {
            _ = try moeBoundaryError(sparsePieces[rank], oraclePieces[rank],
                label: "Gemma actual local expert partial rows=\(rows) rank=\(rank)", requireExact: bf16)
        }
        var layerParity: [GDNErrorSummary] = []
        for rank in 0..<2 {
            ranks[rank].postDense.peerPartial = densePieces[1 - rank]
            ranks[rank].postSparse.peerPartial = sparsePieces[1 - rank]
            let candidate = ranks[rank].forward(x)
            layerParity.append(try moeBoundaryError(reference, candidate,
                label: "Gemma decoder with two separate peer reductions rows=\(rows) rank=\(rank)"))
        }
        let premature = baseline.postDense(denseReference + sparseReference)
        let prematureError = abs(combinedReference.asType(.float32) - premature.asType(.float32)).max().item(Float.self)
        guard prematureError.isFinite, prematureError > 0.01 else {
            throw ProbeError("Gemma fixture did not distinguish separate branch normalizations")
        }
        let counterexample = try gemmaBranchNormalizationCounterexample()
        struct Result: Encodable {
            let kind: String
            let rows: Int
            let expertCount = 4
            let topK = 2
            let routedIntervals = [[0, 320], [320, 704]]
            let denseIntervals = [[0, 128], [128, 256]]
            let actualDecoderExecuted = true
            let reductionSites = ["post_feedforward_layernorm_1 input", "post_feedforward_layernorm_2 input"]
            let reductionMethod = "local replay with captured peer partials at actual RMSNorm call sites"
            let actualRouterLogitsExactlyReplicated = true
            let routingIDsAndScores: String
            let routingScoreDiagnostics: GDNErrorSummary?
            let routingSelectionBoundaryTies: Int
            let globalExpertIDsSeen: [UInt32]
            let perExpertScales: [Float]
            let routingBoundaryParity: GDNErrorSummary
            let denseBranchParity: GDNErrorSummary
            let routedBranchParity: GDNErrorSummary
            let decoderParity: [GDNErrorSummary]
            let prematureBranchCombineMaximumError: Float
            let concreteNormalizationCounterexample: GemmaNormCounterexample
            let activationDType: String
            let routerLogitDType: String
            let routingWeightDType: String
            let perExpertScaleDType: String
            let quantizationMetadataDTypes: [String]
            let numericalQualification: String
            let correctnessOnly = true
            let distributedExecution = false
        }
        try emitJSON(Result(kind: bf16 ? "gemma_moe_boundary_diagnostics" : "gemma_moe_boundary_parity",
            rows: rows, routingIDsAndScores: route.method, routingScoreDiagnostics: route.roundedCPUScoreDiagnostics,
            routingSelectionBoundaryTies: route.selectionBoundaryTies,
            globalExpertIDsSeen: Set(route.expertIDs).sorted(), perExpertScales: actualExpertScales,
            routingBoundaryParity: routingBoundaryParity, denseBranchParity: denseParity, routedBranchParity: sparseParity,
            decoderParity: layerParity, prematureBranchCombineMaximumError: prematureError,
            concreteNormalizationCounterexample: counterexample, activationDType: String(describing: dtype),
            routerLogitDType: String(describing: logits.dtype), routingWeightDType: String(describing: route.scores.dtype),
            perExpertScaleDType: String(describing: scaleTensor.dtype), quantizationMetadataDTypes: metadataTypes,
            numericalQualification: bf16 ? "exact-unsplit-boundary; partition-budget-pending" : "strict-float32"))
    }
}

struct GemmaNormCounterexample: Encodable {
    let denseInput = [Float(3), 0]
    let sparseInput = [Float(0), 1]
    let separateNormalization: [Float]
    let normalizeAfterCombining: [Float]
    let maximumAbsoluteDifference: Float
}

private func gemmaBranchNormalizationCounterexample() throws -> GemmaNormCounterexample {
    let norm = RMSNorm(dimensions: 2, eps: 1e-6)
    let dense = MLXArray([Float(3), 0]).reshaped(1, 2)
    let sparse = MLXArray([Float(0), 1]).reshaped(1, 2)
    let correct = norm(dense) + norm(sparse)
    let incorrect = norm(dense + sparse)
    let delta = abs(correct - incorrect).max().item(Float.self)
    guard delta > 0.9 else { throw ProbeError("Gemma normalization counterexample unexpectedly commuted") }
    return GemmaNormCounterexample(separateNormalization: correct.asArray(Float.self),
        normalizeAfterCombining: incorrect.asArray(Float.self), maximumAbsoluteDifference: delta)
}
