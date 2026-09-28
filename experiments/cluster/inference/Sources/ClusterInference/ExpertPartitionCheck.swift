import Foundation
import MLX
import MLXLMCommon
import MLXNN

private struct ExpertParityCase {
    let label: String
    let activation: ExpertActivation
    let intermediate: Int
    let cut: Int
    let fused: Bool
    let bits: [String: Int]
    let bf16: Bool
    let bf16Metadata: Bool
}

struct ExpertPartitionCheckResult: Encodable {
    let kind = "quantized_expert_partition_parity"
    let label: String
    let activation: String
    let activationDType: String
    let quantizationMetadataDTypes: [String]
    let inputDims: Int
    let intermediateDims: Int
    let numExperts: Int
    let intervals: [[Int]]
    let fusedGateUp: Bool
    let projectionBits: [String: Int]
    let assignmentCounts: [Int]
    let routingPatterns: [String]
    let comparedOutputValues: Int
    let maximumAbsoluteError: Double
    let relativeRMSError: Double
    let absoluteTolerance: Double
    let relativeRMSTolerance: Double
    let sourceTensorBytes: Int
    let localTensorBytes: [Int]
    let rejectedInvalidContracts: Int
    let publicUnsplitSwitchGLUOracle = true
    let routingWeightsPreservedWithoutRenormalization = true
    let genericPinnedGatherAndWeightedReduction = true
    let correctnessOnly = true
    let exactCheckpointExecuted = false
}

/// Root owns invocation and build. All tensors are bounded synthetic fixtures;
/// no external model, distributed group, SSH, or artifact download is involved.
func checkExpertPartition() throws {
    let cases = [
        ExpertParityCase(label: "silu-split-w4", activation: .silu,
            intermediate: 512, cut: 256, fused: false,
            bits: ["gate_proj": 4, "up_proj": 4, "down_proj": 4], bf16: false, bf16Metadata: false),
        ExpertParityCase(label: "silu-fused-mixed", activation: .silu,
            intermediate: 512, cut: 256, fused: true,
            bits: ["gate_up_proj": 4, "down_proj": 8], bf16: false, bf16Metadata: false),
        ExpertParityCase(label: "gemma-width-split-w8", activation: .geluTanh,
            intermediate: 704, cut: 320, fused: false,
            bits: ["gate_proj": 8, "up_proj": 8, "down_proj": 8], bf16: false, bf16Metadata: false),
        ExpertParityCase(label: "gemma-width-split-mixed-bf16", activation: .geluTanh,
            intermediate: 704, cut: 320, fused: false,
            bits: ["gate_proj": 8, "up_proj": 4, "down_proj": 8], bf16: true, bf16Metadata: true),
        ExpertParityCase(label: "gemma-width-fused-w4-bf16", activation: .geluTanh,
            intermediate: 704, cut: 320, fused: true,
            bits: ["gate_up_proj": 4, "down_proj": 4], bf16: true, bf16Metadata: false),
        ExpertParityCase(label: "silu-fused-w8", activation: .silu,
            intermediate: 512, cut: 256, fused: true,
            bits: ["gate_up_proj": 8, "down_proj": 8], bf16: false, bf16Metadata: false),
    ]
    let rejected = try checkInvalidExpertContracts()
    for item in cases { try emitJSON(checkExpertPartition(item, rejected: rejected)) }
}

private func checkExpertPartition(_ item: ExpertParityCase, rejected: Int) throws -> ExpertPartitionCheckResult {
    MLXRandom.seed(3_571)
    let input = 128, experts = 16
    let source = item.activation.makeSwitchGLU(inputDims: input,
        hiddenDims: item.intermediate, numExperts: experts, fusedGateUp: item.fused)
    quantize(model: source) { path, _ in
        item.bits[path].map { (groupSize: 64, bits: $0, mode: QuantizationMode.affine) }
    }
    if item.bf16Metadata {
        let parameters = source.parameters().flattened().map { name, value in
            let metadata = name.hasSuffix(".scales") || name.hasSuffix(".biases")
            return (name, metadata ? value.asType(.bfloat16) : value)
        }
        try source.update(parameters: ModuleParameters.unflattened(parameters), verify: [.all])
    }
    source.freeze(); eval(source)
    let metadataTypes = Set(source.parameters().flattened().compactMap { name, value -> String? in
        name.hasSuffix(".scales") || name.hasSuffix(".biases") ? String(describing: value.dtype) : nil
    }).sorted()
    guard metadataTypes == [String(describing: item.bf16Metadata ? DType.bfloat16 : .float32)] else {
        throw ProbeError("Expert fixture did not exercise the requested parameter metadata dtype")
    }
    let intervals = [0..<item.cut, item.cut..<item.intermediate]
    let partials = try intervals.map { try QuantizedExpertPartial(source: source,
        interval: $0, activation: item.activation) }
    let sourceBytes = source.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
    let localBytes = partials.map { $0.localSwitchGLU.parameters().flattened().reduce(0) { $0 + $1.1.nbytes } }
    guard localBytes.reduce(0, +) == sourceBytes,
        localBytes[0] * item.intermediate == sourceBytes * intervals[0].count,
        localBytes[1] * item.intermediate == sourceBytes * intervals[1].count else {
        throw ProbeError("Expert intervals did not preserve every source weight/scale/offset byte exactly once")
    }
    let dtype: DType = item.bf16 ? .bfloat16 : .float32
    let absolute = item.bf16 ? 0.008 : 0.00005
    let relative = item.bf16 ? 0.02 : 0.0001
    let shapes = [(1, 1), (7, 8), (8, 8), (9, 8), (63, 1), (64, 1), (65, 1)]
    let patterns = ["balanced-unsorted-global-ids", "skewed-high-global-ids"]
    var maximum = 0.0, squareError = 0.0, squareReference = 0.0, count = 0
    for (rows, topK) in shapes {
        let x = MLXRandom.normal([rows, input]).asType(dtype)
        for pattern in patterns {
            // Skew intentionally targets the high global expert IDs. Both inner
            // shards must retain those IDs; treating rank as expert ownership fails.
            let ids = (0..<rows).flatMap { row in
                (0..<topK).map { slot in
                    UInt32(pattern.hasPrefix("skewed") ? experts - 1 - slot : (row * 7 + slot * 3) % experts)
                }
            }
            let scores = (0..<rows).flatMap { row in
                (0..<topK).map { slot -> Float in
                    let base = Float(slot + 1) / Float(topK * (topK + 1) / 2)
                    // Non-unit sums model learned per-expert scale; the primitive
                    // must not normalize scores or invent a router softmax.
                    return base * (0.7 + Float(row % 5) * 0.2)
                }
            }
            let indices = MLXArray(ids).reshaped(rows, topK)
            let weights = MLXArray(scores).reshaped(rows, topK).asType(dtype)
            // Independent reference calls public full-width expert projection,
            // then the pinned weighted sum directly, without a partition plan.
            let reference = weightedExpertSum(source(x, indices), weights)
            let pieces = try partials.map { try $0(x, expertIDs: indices, routingWeights: weights) }
            let candidate = pieces[0] + pieces[1]
            eval(reference, candidate)
            guard reference.shape == [rows, input], candidate.shape == reference.shape,
                reference.dtype == candidate.dtype else { throw ProbeError("Expert partial output shape/dtype mismatch") }
            let a = reference.asType(.float32).asArray(Float.self)
            let b = candidate.asType(.float32).asArray(Float.self)
            var localMax = 0.0, localError = 0.0, localReference = 0.0
            for (expected, actual) in zip(a, b) {
                guard expected.isFinite, actual.isFinite else { throw ProbeError("Nonfinite expert partial output") }
                let delta = Double(expected) - Double(actual)
                localMax = max(localMax, abs(delta)); localError += delta * delta
                localReference += Double(expected) * Double(expected)
            }
            let localRMS = sqrt(localError / max(localReference, 1e-30))
            guard localMax <= absolute, localRMS <= relative else {
                throw ProbeError("Expert partition parity failed: \(item.label), assignments=\(rows * topK), \(pattern), max=\(localMax), RMS=\(localRMS)")
            }
            maximum = max(maximum, localMax); squareError += localError
            squareReference += localReference; count += a.count
        }
    }
    return ExpertPartitionCheckResult(label: item.label, activation: item.activation.rawValue,
        activationDType: String(describing: dtype), quantizationMetadataDTypes: metadataTypes, inputDims: input,
        intermediateDims: item.intermediate, numExperts: experts,
        intervals: intervals.map { [$0.lowerBound, $0.upperBound] },
        fusedGateUp: item.fused, projectionBits: item.bits,
        assignmentCounts: Array(Set(shapes.map { $0.0 * $0.1 })).sorted(), routingPatterns: patterns,
        comparedOutputValues: count, maximumAbsoluteError: maximum,
        relativeRMSError: sqrt(squareError / max(squareReference, 1e-30)),
        absoluteTolerance: absolute, relativeRMSTolerance: relative,
        sourceTensorBytes: sourceBytes, localTensorBytes: localBytes,
        rejectedInvalidContracts: rejected)
}

private func checkInvalidExpertContracts() throws -> Int {
    var rejected = 0
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Invalid expert partition contract was accepted")
    }
    let policies = ["gate_proj": 4, "up_proj": 4, "down_proj": 4]
    func plan(input: Int = 128, intermediate: Int = 704, interval: Range<Int> = 0..<320,
              fused: Bool = false, bits: [String: Int]? = nil) throws -> ExpertPartitionPlan {
        try ExpertPartitionPlan(inputDims: input, intermediateDims: intermediate,
            numExperts: 2, interval: interval, activation: .silu,
            fusedGateUp: fused, projectionBits: bits ?? policies)
    }
    try reject { _ = try plan(interval: 0..<352) }
    try reject { _ = try plan(interval: 32..<352) }
    try reject { _ = try plan(interval: 640..<768) }
    try reject { _ = try plan(interval: 64..<64) }
    try reject { _ = try plan(input: 96) }
    try reject { _ = try plan(intermediate: 700) }
    try reject { _ = try plan(bits: ["gate_proj": 3, "up_proj": 4, "down_proj": 4]) }
    try reject { _ = try plan(bits: ["gate_proj": 4, "down_proj": 4]) }
    try reject { _ = try plan(fused: true) }
    let legal = try plan()
    try reject { _ = try legal.selection(name: "gate_proj.weight", shape: [2, 705, 16]) }
    try reject { _ = try legal.sourceShape(name: "gate_proj.bias") }
    try reject { _ = try legal.sourceShape(name: "router.weight") }
    try reject {
        _ = try QuantizedExpertPartial(plan: legal) { _, _ in MLXArray.zeros([1]) }
    }
    let biased = SwitchGLU(inputDims: 128, hiddenDims: 128, numExperts: 2, bias: true)
    quantize(model: biased, groupSize: 64, bits: 4)
    try reject { _ = try QuantizedExpertPartial(source: biased, interval: 0..<64, activation: .silu) }
    let wrongGroup = SwitchGLU(inputDims: 128, hiddenDims: 128, numExperts: 2)
    quantize(model: wrongGroup, groupSize: 32, bits: 4)
    try reject { _ = try QuantizedExpertPartial(source: wrongGroup, interval: 0..<64, activation: .silu) }
    return rejected
}
