import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Captures the actual private Qwen35GatedDeltaNet through its public child.
/// The pinned model's convolution, normalization, recurrence and cache code run
/// unchanged; no GDN numerics are copied into this oracle.
private final class GDNOutputCapture: QuantizedLinear {
    var recorded: MLXArray?

    init(_ source: QuantizedLinear) {
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let output = super.callAsFunction(input)
        recorded = output
        return output
    }
}

private struct CapturedGDNModel {
    let model: Qwen35TextModel
    let output: GDNOutputCapture
    let cache: [KVCache]
    let recurrent: MambaCache

    init(_ model: Qwen35TextModel) throws {
        guard let gdn = model.namedModules().first(where: { $0.0 == "model.layers.0.linear_attn" })?.1,
            let projection = gdn.namedModules().first(where: { $0.0 == "out_proj" })?.1 as? QuantizedLinear
        else { throw ProbeError("Missing first-layer synthetic GDN output projection") }
        let capture = GDNOutputCapture(projection)
        try gdn.update(modules: ModuleChildren(values: ["out_proj": .value(capture)]), verify: [.noUnusedKeys])
        self.model = model; output = capture
        recurrent = MambaCache(leftPadding: [2, 0])
        // A normal two-layer hybrid model avoids the inner model's faIdx lookup
        // beyond a one-layer cache. Only layer zero's contribution is compared.
        cache = [recurrent, KVCacheSimple()]
        model.freeze()
    }

    func forward(start: Int, length: Int) throws -> MLXArray {
        let tokens = (0..<2).flatMap { batch in
            (start..<(start + length)).map { 3 + (($0 * 17 + batch * 29 + 9) % 509) }
        }
        output.recorded = nil
        let logits = model(MLXArray(tokens).reshaped(2, length), cache: cache)
        eval(logits)
        guard let recorded = output.recorded else { throw ProbeError("GDN capture did not execute") }
        eval(recorded)
        recurrent.advance(length)
        return recorded
    }
}

struct GDNPartitionCheckResult: Encodable {
    let kind = "gdn_partition_parity"
    let activationDType: String
    let weightsRoundedToBF16: Bool
    let projectionControl: String
    let keyHeads: Int
    let valueHeads: Int
    let keyHeadDimension: Int
    let valueHeadDimension: Int
    let chunks: [Int]
    let comparedOutputValues: Int
    let maximumAbsoluteError: Double
    let relativeRMSError: Double
    let maximumConvolutionStateError: Double
    let maximumRecurrentStateError: Double
    let convolutionStateBudget: GDNStateBudgetResult
    let recurrentStateBudget: GDNStateBudgetResult
    let absoluteTolerance: Double
    let relativeRMSTolerance: Double
    let rejectedInvalidContracts: Int
    let actualQwenGDN = true
    let maskedBatchAndChunkedContinuation = true
    let recurrentStateRemainsFloat32 = true
    let correctnessOnly = true
    let numericalBudgetScope = "synthetic-operator-test-only"
}

func checkGDNPartition() throws {
    for (valueHeads, keyDimension, bf16) in [(4, 128, false), (12, 128, false)] {
        try emitJSON(checkGDNPartition(valueHeads: valueHeads, keyDimension: keyDimension, bf16: bf16))
    }
    try emitJSON(checkGDNPartition(valueHeads: 12, keyDimension: 128, bf16: false,
        roundWeightsToBF16: true, projectionControl: "bf16-rounded-weights-float32-arithmetic"))
    try emitJSON(checkGDNPartition(valueHeads: 12, keyDimension: 128, bf16: true,
        chunks: [2] + Array(repeating: 1, count: 12), projectionControl: "small-matrix-continuation"))
    for (valueHeads, keyDimension) in [(12, 128), (8, 192)] {
        try emitJSON(checkGDNPartition(valueHeads: valueHeads, keyDimension: keyDimension, bf16: true))
    }
}

private func checkGDNPartition(valueHeads: Int, keyDimension: Int, bf16: Bool,
    roundWeightsToBF16: Bool = false, chunks: [Int] = [2, 7, 1, 3, 1], projectionControl: String = "native-fused") throws
    -> GDNPartitionCheckResult
{
    _qwen35MTPEnabled = false
    MLXRandom.seed(619)
    let text: [String: Any] = [
        "model_type": "qwen3_5_text", "hidden_size": 128, "num_hidden_layers": 2,
        "intermediate_size": 256, "num_attention_heads": 4, "num_key_value_heads": 2,
        "head_dim": 64, "full_attention_interval": 2, "vocab_size": 512,
        "linear_num_key_heads": 4, "linear_num_value_heads": valueHeads,
        "linear_key_head_dim": keyDimension, "linear_value_head_dim": 128,
        "linear_conv_kernel_dim": 4, "tie_word_embeddings": false,
        "max_position_embeddings": 2048, "mtp_num_hidden_layers": 0,
    ]
    let plan = try QwenGDNPartition(text: text)
    let rejected = try checkGDNRejectedContracts(text: text, plan: plan)
    func construct(_ configuration: [String: Any]) throws -> Qwen35TextModel {
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
        quantize(model: model, groupSize: 64, bits: 4)
        return model
    }
    let prefix = "model.layers.0.linear_attn."
    let original = try construct(text)
    var weights = Dictionary(uniqueKeysWithValues: original.parameters().flattened())
    // Nonuniform values detect incorrect head/vector selection and norm slicing.
    weights[prefix + "norm.weight"] = MLXRandom.uniform(low: 0.7, high: 1.3, [128])
    weights[prefix + "A_log"] = MLXRandom.uniform(low: -0.7, high: 0.7, [valueHeads])
    weights[prefix + "dt_bias"] = MLXRandom.uniform(low: -0.3, high: 0.9, [valueHeads])
    if bf16 { weights = weights.mapValues { $0.dtype == .float32 ? $0.asType(.bfloat16) : $0 } }
    else if roundWeightsToBF16 {
        weights = weights.mapValues { $0.dtype == .float32 ? $0.asType(.bfloat16).asType(.float32) : $0 }
    }
    try original.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
    original.freeze(); eval(original)
    let baseline = try CapturedGDNModel(original)
    var localText = text
    for (key, value) in plan.configurationUpdates { localText[key] = value }
    var shards: [CapturedGDNModel] = []
    for rank in 0..<2 {
        let model = try construct(localText)
        var selected: [String: MLXArray] = [:]
        for (name, value) in weights {
            let selection = try name.hasPrefix(prefix)
                ? plan.selection(relativeName: String(name.dropFirst(prefix.count)), shape: value.shape, rank: rank)
                : TensorSelection.all
            selected[name] = try copySelectedTensor(value, selection: selection)
        }
        try model.update(parameters: ModuleParameters.unflattened(selected), verify: [.all])
        model.freeze(); eval(model)
        shards.append(try CapturedGDNModel(model))
    }

    let activationType: DType = bf16 ? .bfloat16 : .float32
    var count = 0, compared = 0
    var maximum = 0.0, squares = 0.0, referenceSquares = 0.0
    var convMaximum = 0.0, stateMaximum = 0.0
    var convMetrics = GDNErrorAccumulator(), stateMetrics = GDNErrorAccumulator()
    func maximumError(_ reference: MLXArray, _ candidate: MLXArray) throws -> Double {
        guard reference.shape == candidate.shape else { throw ProbeError("GDN cache shape mismatch") }
        let delta = abs(reference.asType(.float32) - candidate.asType(.float32)).max().item(Float.self)
        guard delta.isFinite else { throw ProbeError("Nonfinite GDN cache") }
        return Double(delta)
    }
    for length in chunks {
        let reference = try baseline.forward(start: count, length: length)
        let pieces = try shards.map { try $0.forward(start: count, length: length) }
        let candidate = pieces[0] + pieces[1]
        eval(candidate)
        guard reference.shape == [2, length, plan.hiddenSize], candidate.shape == reference.shape else {
            throw ProbeError("GDN output shape mismatch")
        }
        guard reference.dtype == activationType, candidate.dtype == activationType,
            pieces.allSatisfy({ $0.dtype == activationType })
        else { throw ProbeError("GDN outputs did not preserve the requested activation dtype") }
        for (x, y) in zip(reference.asType(.float32).asArray(Float.self), candidate.asType(.float32).asArray(Float.self)) {
            guard x.isFinite, y.isFinite else { throw ProbeError("Nonfinite GDN output") }
            let delta = Double(x) - Double(y)
            maximum = max(maximum, abs(delta)); squares += delta * delta
            referenceSquares += Double(x) * Double(x); compared += 1
        }
        let full = baseline.recurrent.state
        let local = shards.map { $0.recurrent.state }
        guard full.count == 2, local.allSatisfy({ $0.count == 2 }),
            full[0].shape == [2, 3, plan.convolutionWidth],
            full[0].dtype == activationType,
            full[1].shape == [2, valueHeads, 128, keyDimension],
            full[1].dtype == .float32,
            local.allSatisfy({ $0[0].shape == [2, 3, plan.convolutionWidth / 2]
                && $0[0].dtype == activationType
                && $0[1].shape == [2, valueHeads / 2, 128, keyDimension] && $0[1].dtype == .float32 })
        else { throw ProbeError("GDN convolution or FP32 recurrent state geometry mismatch") }
        // Reassemble Q0,Q1,K0,K1,V0,V1, independently of the tensor selector.
        let convParts = local.map { MLX.split($0[0], indices: [plan.keyWidth / 2, plan.keyWidth], axis: 2) }
        let combinedConv = concatenated((0..<3).flatMap { [convParts[0][$0], convParts[1][$0]] }, axis: 2)
        let combinedState = concatenated(local.map { $0[1] }, axis: 1)
        try convMetrics.add(full[0], combinedConv)
        try stateMetrics.add(full[1], combinedState)
        convMaximum = max(convMaximum, try maximumError(full[0], combinedConv))
        stateMaximum = max(stateMaximum, try maximumError(full[1], combinedState))
        if count == 0 {
            guard abs(full[0][0]).max().item(Float.self) == 0,
                abs(full[1][0]).max().item(Float.self) == 0,
                abs(reference[0]).max().item(Float.self) == 0
            else { throw ProbeError("Fully masked first chunk changed recurrent state or produced output") }
        }
        count += length
    }
    let rms = sqrt(squares / max(referenceSquares, 1e-30))
    let absolute = bf16 ? 0.01 : 0.00005
    let relative = bf16 ? 0.025 : 0.00002
    let convolution = convMetrics.summary(bf16Scale: bf16)
    let recurrent = stateMetrics.summary()
    // The pinned quantized.cpp dispatch is output-width dependent. With
    // B=2,S=7,K=128, full fused N=4120 enters qmm_splitk (two BF16 partial
    // sums), while local N=2060 can use qmv_quad (one final BF16 rounding).
    // Measured controls isolate this effect: BF16 small-matrix continuation
    // has identical conv/SSM state; widening BF16-rounded parameters to FP32
    // also restores ~1e-9 SSM parity. The crossing case differs by one BF16
    // ULP at its largest conv error, with conv/state RMS below 0.5%.
    // Therefore conv gets a relative + peak-ULP budget, and FP32 recurrence
    // gets a relative budget plus the existing absolute ceiling. Neither
    // budget qualifies a real artifact's end-to-end numerical quality.
    let convolutionBudget = GDNStateBudgetResult(observed: convolution,
        absoluteTolerance: bf16 ? 2 * convolution.peakBF16ULPSize! : absolute,
        relativeRMSTolerance: bf16 ? 0.01 : nil, peakBF16ULPTolerance: bf16 ? 2 : nil)
    let recurrentBudget = GDNStateBudgetResult(observed: recurrent,
        absoluteTolerance: absolute, relativeRMSTolerance: bf16 ? 0.01 : nil)
    struct Diagnostics: Encodable {
        let kind = "gdn_partition_diagnostics"
        let activationDType: String
        let projectionControl: String
        let fullFusedProjectionWidth: Int
        let localFusedProjectionWidth: Int
        let matrixRowsByChunk: [Int]
        let convolution: GDNErrorSummary
        let recurrent: GDNErrorSummary
        let convolutionStateBudget: GDNStateBudgetResult
        let recurrentStateBudget: GDNStateBudgetResult
        let correctnessOnly = true
    }
    let fusedWidth = plan.convolutionWidth + plan.valueWidth + 2 * valueHeads
    try emitJSON(Diagnostics(activationDType: String(describing: activationType), projectionControl: projectionControl,
        fullFusedProjectionWidth: fusedWidth, localFusedProjectionWidth: fusedWidth / 2,
        matrixRowsByChunk: chunks.map { $0 * 2 }, convolution: convolution, recurrent: recurrent,
        convolutionStateBudget: convolutionBudget, recurrentStateBudget: recurrentBudget))
    guard maximum <= absolute, rms <= relative, convolutionBudget.passed, recurrentBudget.passed else {
        throw ProbeError("GDN parity failed: max=\(maximum), RMS=\(rms), conv=\(convMaximum), state=\(stateMaximum)")
    }
    return GDNPartitionCheckResult(activationDType: bf16 ? "bfloat16" : "float32",
        weightsRoundedToBF16: bf16 || roundWeightsToBF16, projectionControl: projectionControl,
        keyHeads: plan.keyHeads, valueHeads: valueHeads, keyHeadDimension: keyDimension, valueHeadDimension: 128,
        chunks: chunks, comparedOutputValues: compared, maximumAbsoluteError: maximum, relativeRMSError: rms,
        maximumConvolutionStateError: convMaximum, maximumRecurrentStateError: stateMaximum,
        convolutionStateBudget: convolutionBudget, recurrentStateBudget: recurrentBudget,
        absoluteTolerance: absolute, relativeRMSTolerance: relative, rejectedInvalidContracts: rejected)
}

private func checkGDNRejectedContracts(text: [String: Any], plan: QwenGDNPartition) throws -> Int {
    var cases: [() throws -> Void] = []
    for (key, value) in [("linear_num_key_heads", 3), ("linear_num_value_heads", 6),
                         ("linear_key_head_dim", 33), ("linear_value_head_dim", 1)] {
        var bad = text; bad[key] = value
        cases.append { _ = try QwenGDNPartition(text: bad) }
    }
    cases.append { _ = try plan.selection(relativeName: "norm.weight", shape: [64], rank: 0) }
    cases.append { _ = try plan.selection(relativeName: "out_proj.bias", shape: [128], rank: 0) }
    cases.append { _ = try plan.selection(relativeName: "A_log", shape: [plan.valueHeads], rank: 2) }
    cases.append { _ = try plan.selection(relativeName: "conv1d.weight", shape: [plan.convolutionWidth, 1, 4], rank: 0) }
    for check in cases {
        var rejected = false
        do { try check() } catch { rejected = true }
        guard rejected else { throw ProbeError("GDN partition accepted an invalid contract") }
    }
    return cases.count
}
