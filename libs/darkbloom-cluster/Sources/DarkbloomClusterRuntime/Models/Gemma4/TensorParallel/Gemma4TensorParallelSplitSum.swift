import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The single-process oracle of Gemma 4's row-parallel projections. Each
/// rank's part reads that rank's stored input columns of the whole input,
/// zero outside the rank's own channels (as the rank's zero-padded channels
/// are), through its column slice of the quantized weight with the input
/// widened to FP32 (the arithmetic a rank's partial uses); the two partials
/// are added in FP32 and rounded once. Installed over a whole model, it is
/// the `splitSum` oracle of the decomposition.
enum Gemma4TensorParallelSplitSum {
    struct Part: Equatable {
        /// Input columns the rank stores.
        let stored: Range<Int>
        /// Input columns the rank owns; the rest of `stored` reads zero.
        let channels: Range<Int>
    }

    /// Replaces every row-parallel projection of the whole `model`; returns
    /// the parts' arrays, for evaluation with the model's parameters.
    static func install(in model: Gemma4Model, plan: Gemma4TensorParallelPlan) throws -> [MLXArray] {
        let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var replacements: [(String, Module)] = []
        var arrays: [MLXArray] = []
        let dense = try (0 ..< plan.size).map { rank -> Part in
            let split = try plan.denseSplit(rank: rank)
            return Part(stored: split.storedColumns, channels: split.channels)
        }
        let experts = try (0 ..< plan.size).map { rank -> Part in
            let split = try plan.expertSplit(rank: rank)
            return Part(stored: split.storedColumns, channels: split.channels)
        }
        for layer in 0 ..< plan.layerCount {
            let base = "language_model.model.layers.\(layer)."
            let width = plan.queryHeadsPerRank * plan.headDim(layer: layer)
            let attention = (0 ..< plan.size).map { Part(stored: ($0 * width) ..< (($0 + 1) * width),
                                                          channels: ($0 * width) ..< (($0 + 1) * width)) }
            guard let output = leaves[base + "self_attn.o_proj"] as? QuantizedLinear,
                  let down = leaves[base + "mlp.down_proj"] as? QuantizedLinear,
                  let expertDown = leaves[base + "experts.switch_glu.down_proj"] as? QuantizedSwitchLinear else {
                throw ProbeError("Gemma split-sum oracle: layer \(layer) lacks a quantized row-parallel projection")
            }
            let attentionOracle = try Gemma4SplitSumLinear(output, parts: attention)
            let denseOracle = try Gemma4SplitSumLinear(down, parts: dense)
            let expertOracle = try Gemma4SplitSumSwitchLinear(expertDown, parts: experts)
            replacements += [(base + "self_attn.o_proj", attentionOracle), (base + "mlp.down_proj", denseOracle),
                             (base + "experts.switch_glu.down_proj", expertOracle)]
            arrays += attentionOracle.partArrays + denseOracle.partArrays + expertOracle.partArrays
        }
        try model.update(modules: ModuleChildren.unflattened(replacements), verify: .none)
        return arrays
    }

    /// `x`'s last-axis columns `part.stored`, every column outside
    /// `part.channels` zero.
    static func block(_ x: MLXArray, _ part: Part) -> MLXArray {
        let core = x[.ellipsis, part.channels]
        let before = part.channels.lowerBound - part.stored.lowerBound
        let after = part.stored.upperBound - part.channels.upperBound
        guard before > 0 || after > 0 else { return core }
        func zeros(_ count: Int) -> MLXArray {
            var shape = x.shape
            shape[shape.count - 1] = count
            return MLXArray.zeros(shape, dtype: x.dtype)
        }
        return concatenated((before > 0 ? [zeros(before)] : []) + [core] + (after > 0 ? [zeros(after)] : []), axis: -1)
    }

    /// Stored input columns `columns` of packed `[..., out, in / perWord]`
    /// words and `[..., out, in / group]` scales or offsets, copied row-major.
    static func columns(_ value: MLXArray, _ columns: Range<Int>, divisor: Int) throws -> MLXArray {
        guard columns.lowerBound % divisor == 0, columns.upperBound % divisor == 0,
              columns.upperBound / divisor <= value.dim(-1) else {
            throw ProbeError("Gemma split-sum oracle: columns \(columns) split a packed word or group")
        }
        return contiguous(value[.ellipsis, (columns.lowerBound / divisor) ..< (columns.upperBound / divisor)])
    }
}

/// A dense row-parallel projection's oracle (`o_proj`, the dense MLP's
/// `down_proj`).
final class Gemma4SplitSumLinear: QuantizedLinear {
    private final class Parts {
        let modules: [QuantizedLinear]
        let parts: [Gemma4TensorParallelSplitSum.Part]
        init(_ modules: [QuantizedLinear], _ parts: [Gemma4TensorParallelSplitSum.Part]) {
            self.modules = modules; self.parts = parts
        }
    }

    private let split: Parts

    init(_ source: QuantizedLinear, parts: [Gemma4TensorParallelSplitSum.Part]) throws {
        guard source.bias == nil, source.mode == .affine, let offsets = source.biases else {
            throw ProbeError("Gemma split-sum oracle: an affine projection without bias is required")
        }
        let modules = try parts.map { part in
            QuantizedLinear(
                weight: try Gemma4TensorParallelSplitSum.columns(source.weight, part.stored, divisor: 32 / source.bits),
                bias: nil,
                scales: try Gemma4TensorParallelSplitSum.columns(source.scales, part.stored, divisor: source.groupSize),
                biases: try Gemma4TensorParallelSplitSum.columns(offsets, part.stored, divisor: source.groupSize),
                groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        }
        split = Parts(modules, parts)
        super.init(weight: source.weight, bias: nil, scales: source.scales, biases: offsets,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        freeze()
    }

    var partArrays: [MLXArray] { split.modules.flatMap { [$0.weight, $0.scales] + ($0.biases.map { [$0] } ?? []) } }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        var sum: MLXArray?
        for (module, part) in zip(split.modules, split.parts) {
            let partial = Gemma4TensorParallelProjection.partial(module, Gemma4TensorParallelSplitSum.block(x, part))
            sum = sum.map { $0 + partial } ?? partial
        }
        return sum!.asType(x.dtype)
    }
}

/// The routed experts' down projection oracle: every selected expert's row
/// summed over both ranks' parts in FP32 and rounded before the owning
/// SwitchGLU restores route order and weights it, as the packed collective
/// does on two ranks.
final class Gemma4SplitSumSwitchLinear: QuantizedSwitchLinear, SwitchLinearPartialSum {
    private final class Parts {
        let modules: [QuantizedSwitchLinear]
        let parts: [Gemma4TensorParallelSplitSum.Part]
        init(_ modules: [QuantizedSwitchLinear], _ parts: [Gemma4TensorParallelSplitSum.Part]) {
            self.modules = modules; self.parts = parts
        }
    }

    private let split: Parts

    init(_ source: QuantizedSwitchLinear, parts: [Gemma4TensorParallelSplitSum.Part]) throws {
        guard type(of: source) == QuantizedSwitchLinear.self, source.mode == .affine,
              !source.parameters().flattened().contains(where: { $0.0 == "bias" }),
              let offsets = source.biases, source.globalScales == nil else {
            throw ProbeError("Gemma split-sum oracle: an affine expert bank without bias is required")
        }
        let modules = try parts.map { part in
            try QuantizedSwitchLinear(
                inputDims: part.stored.count, outputDims: source.shape.outputDims, numExperts: source.shape.numExperts,
                weight: try Gemma4TensorParallelSplitSum.columns(source.weight, part.stored, divisor: 32 / source.bits),
                scales: try Gemma4TensorParallelSplitSum.columns(source.scales, part.stored, divisor: source.groupSize),
                biases: try Gemma4TensorParallelSplitSum.columns(offsets, part.stored, divisor: source.groupSize),
                groupSize: source.groupSize, bits: source.bits)
        }
        split = Parts(modules, parts)
        try super.init(inputDims: source.shape.inputDims, outputDims: source.shape.outputDims,
                       numExperts: source.shape.numExperts, weight: source.weight, scales: source.scales,
                       biases: offsets, groupSize: source.groupSize, bits: source.bits)
    }

    var partArrays: [MLXArray] { split.modules.flatMap { [$0.weight, $0.scales] + ($0.biases.map { [$0] } ?? []) } }

    override func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool = false) -> MLXArray {
        var sum: MLXArray?
        for (module, part) in zip(split.modules, split.parts) {
            let block = Gemma4TensorParallelSplitSum.block(x, part).asType(.float32)
            let partial = module(block, indices, sortedIndices: sortedIndices)
            sum = sum.map { $0 + partial } ?? partial
        }
        return sum!.asType(x.dtype)
    }
}
