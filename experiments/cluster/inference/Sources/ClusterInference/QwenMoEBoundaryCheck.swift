import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Execute the real private Qwen35SparseMoeBlock via its public UnaryLayer
/// conformance. Its router and gated shared-expert combination stay unchanged.
func checkQwenMoEBoundary() throws {
    for bf16 in [false, true] {
        for normalize in [false, true] { try checkQwenMoEBoundary(normalize: normalize, bf16: bf16) }
    }
}

private func checkQwenMoEBoundary(normalize: Bool, bf16: Bool) throws {
    _qwen35MTPEnabled = false
    MLXRandom.seed(811)
    let text: [String: Any] = [
        "model_type": "qwen3_5_text", "hidden_size": 128, "num_hidden_layers": 1,
        "intermediate_size": 256, "num_attention_heads": 4, "num_key_value_heads": 2,
        "head_dim": 64, "full_attention_interval": 1, "vocab_size": 512,
        "num_experts": 4, "num_experts_per_tok": 2, "moe_intermediate_size": 320,
        "shared_expert_intermediate_size": 256, "norm_topk_prob": normalize,
        "mtp_num_hidden_layers": 0,
    ]
    let data = try JSONSerialization.data(withJSONObject: text)
    func construct() throws -> Module {
        let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
        let block = try moeModule(model, "model.layers.0.mlp")
        quantize(model: block, groupSize: 64, bits: 4)
        return block
    }
    let original = try construct()
    if bf16 {
        let converted = original.parameters().flattened().map { name, value in
            (name, [.float32, .float16].contains(value.dtype) ? value.asType(.bfloat16) : value)
        }
        try original.update(parameters: ModuleParameters.unflattened(converted), verify: [.all])
    }
    let dtype: DType = bf16 ? .bfloat16 : .float32
    let metadataTypes = Set(original.parameters().flattened().filter { !$0.0.hasSuffix(".weight") }
        .map { String(describing: $0.1.dtype) }).sorted()
    guard metadataTypes == [String(describing: dtype)] else {
        throw ProbeError("Qwen MoE fixture did not exercise the requested parameter dtype")
    }
    guard let actualBlock = original as? UnaryLayer,
        let sourceExperts = try moeModule(original, "switch_mlp") as? SwitchGLU,
        let shared = try moeModule(original, "shared_expert") as? UnaryLayer
    else { throw ProbeError("Cannot access actual Qwen MoE block boundary") }
    let parameters = original.parameters()
    let denseWeights = try FFNWeights(module: moeModule(original, "shared_expert"), path: "shared_expert")
    let intervals = [0..<128, 128..<320]
    let partials = try intervals.map { try QuantizedExpertPartial(source: sourceExperts, interval: $0, activation: .silu) }
    let router = try captureMoELinear(original, key: "gate")
    let sharedGate = try captureMoELinear(original, key: "shared_expert_gate")
    var localBlocks: [any UnaryLayer] = []
    var localRouters: [MoELinearCapture] = []
    var localSharedGates: [MoELinearCapture] = []
    for rank in 0..<2 {
        let block = try construct()
        try block.update(parameters: parameters, verify: [.all])
        try block.update(modules: ModuleChildren(values: [
            "switch_mlp": .value(partials[rank].localSwitchGLU),
        ]), verify: [.noUnusedKeys])
        try installDenseMoEPartial(moeModule(block, "shared_expert"), source: denseWeights, rank: rank)
        localRouters.append(try captureMoELinear(block, key: "gate"))
        localSharedGates.append(try captureMoELinear(block, key: "shared_expert_gate"))
        guard let actual = block as? UnaryLayer else { throw ProbeError("Qwen local block lost its actual implementation") }
        localBlocks.append(actual)
        block.freeze(); eval(block)
    }
    original.freeze(); eval(original)
    for rows in [1, 33] {
        let x = MLXRandom.normal([1, rows, 128]).asType(dtype)
        let reference = actualBlock(x)
        eval(reference)
        guard let logits = router.recorded, let gateLogits = sharedGate.recorded else {
            throw ProbeError("Actual Qwen routing/shared gate did not execute")
        }
        guard reference.dtype == dtype, logits.dtype == dtype, gateLogits.dtype == dtype else {
            throw ProbeError("Qwen block/router/shared gate did not preserve the requested dtype")
        }
        let route = try moeRouteOracle(logits: logits, topK: 2, normalizeQwen: normalize)
        let flatX = x.reshaped(rows, 128)
        let routed = sourceExperts.callAndWeightedReduce(flatX, route.ids, weights: route.scores,
            fuseSortedReduction: false, isProductionPrefill: false).reshaped(1, rows, 128)
        let sharedOutput = shared(x)
        let boundary = routed + sigmoid(gateLogits) * sharedOutput
        let boundaryParity = try moeBoundaryError(reference, boundary,
            label: "Qwen actual gated-shared boundary rows=\(rows) normalized=\(normalize)", requireExact: bf16)
        let localOutputs = localBlocks.map { $0(x) }
        eval(localOutputs)
        for rank in 0..<2 {
            guard partials[rank].plan.numExperts == 4, let localLogits = localRouters[rank].recorded,
                let localGate = localSharedGates[rank].recorded else { throw ProbeError("Qwen rank lost global experts/router") }
            try moeExactRouterMatch(logits, localLogits)
            try moeExactRouterMatch(gateLogits, localGate)
            let localRoute = try moeRouteOracle(logits: localLogits, topK: 2, normalizeQwen: normalize)
            guard localRoute.expertIDs == route.expertIDs, localRoute.routeScores == route.routeScores else {
                throw ProbeError("Qwen rank changed oracle-derived global IDs or scores")
            }
        }
        let blockParity = try moeBoundaryError(reference, localOutputs[0] + localOutputs[1],
            label: "Qwen partitioned MoE blocks rows=\(rows) normalized=\(normalize)")
        let routedPieces = try partials.map { try $0(flatX, expertIDs: route.ids, routingWeights: route.scores) }
        let routedParity = try moeBoundaryError(routed.reshaped(rows, 128), routedPieces[0] + routedPieces[1],
            label: "Qwen weighted routed partials rows=\(rows) normalized=\(normalize)")
        let omittedGateError = abs(reference.asType(.float32) - (routed + sharedOutput).asType(.float32)).max().item(Float.self)
        guard omittedGateError.isFinite, omittedGateError > 0.0001,
            route.expertIDs.allSatisfy({ $0 < 4 }) else { throw ProbeError("Qwen fixture did not exercise shared gating/global IDs") }
        struct Result: Encodable {
            let kind: String
            let rows: Int
            let normalizeTopK: Bool
            let expertCount = 4
            let topK = 2
            let intermediateIntervals = [[0, 128], [128, 320]]
            let sharedIntermediateIntervals = [[0, 128], [128, 256]]
            let actualPrivateBlockExecuted = true
            let actualRouterLogitsExactlyReplicated = true
            let routingIDsAndScores: String
            let routingScoreDiagnostics: GDNErrorSummary?
            let routingSelectionBoundaryTies: Int
            let globalExpertIDsSeen: [UInt32]
            let boundaryParity: GDNErrorSummary
            let partitionedBlockParity: GDNErrorSummary
            let routedPartialParity: GDNErrorSummary
            let omittingSharedGateMaximumError: Float
            let activationDType: String
            let routerLogitDType: String
            let routingWeightDType: String
            let quantizationMetadataDTypes: [String]
            let numericalQualification: String
            let correctnessOnly = true
            let distributedExecution = false
        }
        try emitJSON(Result(kind: bf16 ? "qwen_moe_boundary_diagnostics" : "qwen_moe_boundary_parity",
            rows: rows, normalizeTopK: normalize, routingIDsAndScores: route.method,
            routingScoreDiagnostics: route.roundedCPUScoreDiagnostics,
            routingSelectionBoundaryTies: route.selectionBoundaryTies,
            globalExpertIDsSeen: Set(route.expertIDs).sorted(), boundaryParity: boundaryParity,
            partitionedBlockParity: blockParity, routedPartialParity: routedParity,
            omittingSharedGateMaximumError: omittedGateError, activationDType: String(describing: dtype),
            routerLogitDType: String(describing: logits.dtype), routingWeightDType: String(describing: route.scores.dtype),
            quantizationMetadataDTypes: metadataTypes,
            numericalQualification: bf16 ? "exact-unsplit-boundary; partition-budget-pending" : "strict-float32"))
    }
}
