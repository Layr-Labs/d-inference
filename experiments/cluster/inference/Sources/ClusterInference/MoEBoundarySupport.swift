import Foundation
import MLX
import MLXNN

final class MoELinearCapture: QuantizedLinear {
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

/// A local correctness oracle: inject a previously measured peer partial at
/// exactly the actual decoder's branch-normalization call site. No transport.
final class MoENormCapture: RMSNorm {
    var input: MLXArray?
    var output: MLXArray?
    var peerPartial: MLXArray?

    init(_ source: RMSNorm) throws {
        super.init(dimensions: source.weight.size, eps: source.eps)
        try update(parameters: source.parameters(), verify: [.all])
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        input = x
        let normalized = super.callAsFunction(peerPartial.map { x + $0 } ?? x)
        output = normalized
        return normalized
    }
}

func moeModule(_ root: Module, _ path: String) throws -> Module {
    guard let found = root.namedModules().first(where: { $0.0 == path })?.1 else {
        throw ProbeError("Missing MoE boundary module \(path)")
    }
    return found
}

func captureMoELinear(_ parent: Module, key: String) throws -> MoELinearCapture {
    guard let source = try moeModule(parent, key) as? QuantizedLinear else {
        throw ProbeError("Expected quantized router/shared gate \(key)")
    }
    let capture = MoELinearCapture(source)
    try parent.update(modules: ModuleChildren(values: [key: .value(capture)]), verify: [.noUnusedKeys])
    return capture
}

func captureMoENorm(_ parent: Module, key: String) throws -> MoENormCapture {
    guard let source = try moeModule(parent, key) as? RMSNorm else {
        throw ProbeError("Expected MoE branch normalization \(key)")
    }
    let capture = try MoENormCapture(source)
    try parent.update(modules: ModuleChildren(values: [key: .value(capture)]), verify: [.noUnusedKeys])
    return capture
}

func installDenseMoEPartial(_ module: Module, source: FFNWeights, rank: Int) throws {
    let shard = try source.shard(rank: rank)
    try module.update(modules: ModuleChildren(values: [
        "gate_proj": .value(shard.gate), "up_proj": .value(shard.up), "down_proj": .value(shard.down),
    ]), verify: [.noUnusedKeys])
}

struct MoERouteOracle {
    let ids: MLXArray
    let scores: MLXArray
    let expertIDs: [UInt32]
    let routeScores: [Float]
    let method: String
    let roundedCPUScoreDiagnostics: GDNErrorSummary?
    let selectionBoundaryTies: Int
}

/// The private block does not expose final IDs/weights. Derive them independently
/// from captured actual logits on CPU, then compare the resulting weighted
/// boundary with the actual block. No claim that private IDs were intercepted.
func moeRouteOracle(logits: MLXArray, topK: Int, normalizeQwen: Bool?, expertScales: [Float]? = nil,
                    expertScaleTensor: MLXArray? = nil) throws
    -> MoERouteOracle
{
    if logits.dtype == .bfloat16 {
        return try moeBF16RouteReplay(logits: logits, topK: topK,
            normalizeQwen: normalizeQwen, expertScales: expertScaleTensor)
    }
    guard logits.dtype == .float32, logits.ndim >= 2 else { throw ProbeError("MoE boundary fixture requires F32 router logits") }
    let experts = logits.dim(-1), rows = logits.size / experts
    guard topK > 0, topK <= experts, expertScales == nil || expertScales!.count == experts else {
        throw ProbeError("Invalid MoE routing oracle geometry")
    }
    let values = logits.asArray(Float.self)
    var ids: [UInt32] = [], scores: [Float] = []
    for row in 0..<rows {
        let offset = row * experts
        let ordered = (0..<experts).sorted { values[offset + $0] > values[offset + $1] }
        // Avoid ambiguous router-tie semantics in this boundary fixture.
        guard values[offset + ordered[topK - 1]].isFinite,
            topK == experts || values[offset + ordered[topK - 1]] != values[offset + ordered[topK]]
        else { throw ProbeError("Router fixture contains nonfinite scores or a top-K boundary tie") }
        let selected = Array(ordered.prefix(topK))
        let maximum = Double(values[offset + ordered[0]])
        let numerator = selected.map { exp(Double(values[offset + $0]) - maximum) }
        let denominator: Double
        if normalizeQwen == false {
            denominator = (0..<experts).reduce(0) { $0 + exp(Double(values[offset + $1]) - maximum) }
        } else { denominator = numerator.reduce(0, +) }
        for (position, expert) in selected.enumerated() {
            ids.append(UInt32(expert))
            scores.append(Float(numerator[position] / denominator) * (expertScales?[expert] ?? 1))
        }
    }
    return MoERouteOracle(ids: MLXArray(ids).reshaped(rows, topK),
        scores: MLXArray(scores).reshaped(rows, topK), expertIDs: ids, routeScores: scores,
        method: "CPU oracle from captured actual logits; private route outputs not intercepted",
        roundedCPUScoreDiagnostics: nil, selectionBoundaryTies: 0)
}

/// Stock routing only: these four-expert fixtures cannot select the private
/// production-specialized router. Precise MLX softmax accumulates in Float32
/// but returns BF16; preserve that rounding before Qwen normalization and
/// Gemma's learned-scale multiplication. This replays public ops at the source
/// boundary, not a capture of the private route's returned IDs or weights.
private func moeBF16RouteReplay(logits: MLXArray, topK: Int, normalizeQwen: Bool?, expertScales: MLXArray?) throws
    -> MoERouteOracle
{
    guard logits.ndim >= 2, logits.dim(-1) == 4, topK == 2 else {
        throw ProbeError("BF16 routing replay is scoped to the four-expert/top-two stock fixture")
    }
    let rows = logits.size / 4, flat = logits.reshaped(rows, 4)
    let selectionValues = normalizeQwen == nil ? flat : MLX.softmax(flat, axis: -1, precise: true)
    let ids = MLX.argPartition(selectionValues, kth: 2, axis: -1)[0..., 2...]
    var scores = MLX.takeAlong(selectionValues, ids, axis: -1)
    if let normalizeQwen {
        if normalizeQwen { scores = scores / scores.sum(axis: -1, keepDims: true) }
    } else {
        guard let expertScales, expertScales.shape == [4], expertScales.dtype == .bfloat16 else {
            throw ProbeError("Gemma BF16 route replay requires its actual BF16 per-expert-scale tensor")
        }
        scores = MLX.softmax(scores, axis: -1, precise: true) * expertScales[ids]
    }
    guard selectionValues.dtype == .bfloat16, scores.dtype == .bfloat16 else {
        throw ProbeError("BF16 route replay unexpectedly promoted selection values or weights")
    }
    let selectedIDs = ids.asArray(UInt32.self)
    let raw = flat.asType(.float32).asArray(Float.self)
    let selectedValues = selectionValues.asType(.float32).asArray(Float.self)
    guard raw.allSatisfy(\.isFinite), selectedIDs.allSatisfy({ $0 < 4 }) else {
        throw ProbeError("BF16 route replay produced invalid scores or global IDs")
    }
    let scaleValues = expertScales?.asType(.float32).asArray(Float.self) ?? [Float](repeating: 1, count: 4)
    guard scaleValues.allSatisfy(\.isFinite) else { throw ProbeError("Nonfinite learned expert scale") }
    func rounded(_ value: Float) -> Float {
        let bits = value.bitPattern
        return Float(bitPattern: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) & 0xffff0000)
    }
    func softmax(_ values: [Float]) -> [Float] {
        let maximum = Double(values.max()!)
        let numerators = values.map { exp(Double($0) - maximum) }
        let denominator = numerators.reduce(0, +)
        return numerators.map { rounded(Float($0 / denominator)) }
    }
    var cpu: [Float] = [], ties = 0
    for row in 0..<rows {
        let order = Array(selectedValues[(row * 4)..<(row * 4 + 4)]).sorted(by: >)
        if order[1] == order[2] { ties += 1 }
        let chosen = (0..<2).map { Int(selectedIDs[row * 2 + $0]) }
        let logits = Array(raw[(row * 4)..<(row * 4 + 4)])
        if let normalizeQwen {
            let probabilities = softmax(logits)
            var weights = chosen.map { probabilities[$0] }
            if normalizeQwen {
                let denominator = rounded(weights.reduce(0, +))
                weights = weights.map { rounded($0 / denominator) }
            }
            cpu += weights
        } else {
            let weights = softmax(chosen.map { logits[$0] })
            cpu += zip(chosen, weights).map { rounded($0.1 * scaleValues[$0.0]) }
        }
    }
    var cpuMetrics = GDNErrorAccumulator()
    try cpuMetrics.add(scores, MLXArray(cpu).reshaped(rows, 2).asType(.bfloat16))
    return MoERouteOracle(ids: ids, scores: scores, expertIDs: selectedIDs,
        routeScores: scores.asType(.float32).asArray(Float.self),
        method: "stock public-MLX routing replay with BF16 stage rounding; private outputs not intercepted",
        roundedCPUScoreDiagnostics: cpuMetrics.summary(bf16Scale: true), selectionBoundaryTies: ties)
}

func moeExactRouterMatch(_ reference: MLXArray, _ candidate: MLXArray) throws {
    guard reference.shape == candidate.shape, reference.dtype == candidate.dtype,
        reference.asData().data == candidate.asData().data else {
        throw ProbeError("Partitioning changed replicated router logits")
    }
}

func moeBoundaryError(_ reference: MLXArray, _ candidate: MLXArray, label: String,
                      requireExact: Bool = false) throws -> GDNErrorSummary {
    guard [.float32, .bfloat16].contains(reference.dtype), candidate.dtype == reference.dtype else {
        throw ProbeError("\(label) changed or used an unsupported arithmetic dtype")
    }
    var metrics = GDNErrorAccumulator()
    try metrics.add(reference, candidate)
    let result = metrics.summary(bf16Scale: reference.dtype == .bfloat16)
    struct Diagnostic: Encodable {
        let kind = "moe_boundary_numeric_diagnostic"
        let label: String
        let dtype: String
        let requireExact: Bool
        let numericalQualification: String
        let numericalPassed: Bool?
        let observed: GDNErrorSummary
    }
    if reference.dtype == .bfloat16 {
        try emitJSON(Diagnostic(label: label, dtype: "bfloat16", requireExact: requireExact,
            numericalQualification: requireExact ? "exact-unsplit-boundary" : "partition-budget-pending",
            numericalPassed: requireExact ? result.maximumAbsoluteError == 0 : nil,
            observed: result))
    }
    let passed = requireExact ? result.maximumAbsoluteError == 0
        : reference.dtype == .bfloat16 || (result.maximumAbsoluteError <= 0.0001 && result.relativeRMS <= 0.0001)
    guard passed else {
        throw ProbeError("\(label) failed: max=\(result.maximumAbsoluteError), RMS=\(result.relativeRMS)")
    }
    return result
}
