import Foundation
import MLX
import MLXNN

/// The cross-rank sum a tensor-parallel layer needs. `allSum` builds the
/// reduction into the graph (it runs when the graph is evaluated); it never
/// evaluates by itself.
public protocol QwenTensorParallelReduction: AnyObject {
    var rank: Int { get }
    var size: Int { get }
    func allSum(_ value: MLXArray) -> MLXArray
}

/// How a rank waits for its partial before the collective.
public enum QwenTensorParallelReductionTiming: String, Sendable, CaseIterable {
    /// The reduction is one node of the graph; evaluation order is the graph's
    /// (needs `MLX_METAL_FAST_SYNCH=1` to be fast, measured in slice 0).
    case lazy
    /// The owner's Python recipe: evaluate the partial and synchronize the GPU
    /// before every all-sum.
    case explicit
}

/// A row-parallel projection on one rank: its partial output in float32 (the
/// input widened exactly, so the partial is not rounded before the sum), the
/// all-sum of the partials in float32, then one rounding to the activation
/// type. Slice 0 measured this to be bit-exact against the CPU float32 sum on
/// the M3 Ultra and the M5 Max, and the same on both ranks.
final class QwenTensorParallelRowLinear: QuantizedLinear {
    private let reduction: Box
    private let timing: QwenTensorParallelReductionTiming
    private let partialDType: DType

    /// Not a module: keeps the reduction out of the parameter tree.
    final class Box {
        let value: QwenTensorParallelReduction
        init(_ value: QwenTensorParallelReduction) { self.value = value }
    }

    init(_ source: QuantizedLinear, reduction: QwenTensorParallelReduction, timing: QwenTensorParallelReductionTiming,
         partialDType: DType = .float32) {
        self.reduction = Box(reduction)
        self.timing = timing
        self.partialDType = partialDType
        super.init(weight: source.weight, bias: source.bias, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        // float32 (default): the partial is not rounded before the sum. bfloat16
        // (diagnostic): half the bytes on the link, one more rounding.
        let partial = super.callAsFunction(partialDType == .float32 ? x.asType(.float32) : x)
        if timing == .explicit {
            eval(partial)
            Stream.gpu.synchronize()
        }
        return reduction.value.allSum(partial).asType(x.dtype)
    }
}

/// A routed-expert block on one rank: its experts' and shared expert's
/// combined output is this rank's partial (every expert divided by channels,
/// the router replicated), widened to float32, all-summed, rounded once.
final class QwenTensorParallelBlockReduction: Module, UnaryLayer {
    @ModuleInfo(key: "inner") var inner: Module
    private let reduction: QwenTensorParallelRowLinear.Box
    private let timing: QwenTensorParallelReductionTiming
    private let partialDType: DType

    init(_ inner: Module, reduction: QwenTensorParallelReduction, timing: QwenTensorParallelReductionTiming,
         partialDType: DType) {
        self.reduction = QwenTensorParallelRowLinear.Box(reduction)
        self.timing = timing
        self.partialDType = partialDType
        self._inner.wrappedValue = inner
        super.init()
        freeze()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let partial = (inner as! UnaryLayer)(x).asType(partialDType)
        if timing == .explicit {
            eval(partial)
            Stream.gpu.synchronize()
        }
        return reduction.value.allSum(partial).asType(x.dtype)
    }
}

/// Diagnostic only: a rank's shard with no peer. `allSum` returns this rank's
/// partial unchanged, so outputs are wrong by construction; it measures one
/// chip's share of the compute without any collective. Never a TP result.
public final class QwenTensorParallelLocalReduction: QwenTensorParallelReduction {
    public let rank: Int
    public let size: Int
    public init(rank: Int, size: Int) { self.rank = rank; self.size = size }
    public func allSum(_ value: MLXArray) -> MLXArray { value }
}

/// The single-process oracle of a row-parallel projection: the full module's
/// input split into the ranks' input blocks, each block through its own column
/// slice of the quantized weight in float32, the partials added in float32 in
/// rank order, one rounding. The same arithmetic as `QwenTensorParallelRowLinear`
/// on every rank, without a collective.
final class QwenTensorParallelSplitSumLinear: QuantizedLinear {
    private let parts: Parts

    final class Parts {
        let modules: [QuantizedLinear]
        let width: Int
        init(_ modules: [QuantizedLinear], width: Int) { self.modules = modules; self.width = width }
    }

    init(_ source: QuantizedLinear, size: Int) throws {
        let inputs = source.shape.1
        guard size >= 2, inputs % size == 0 else {
            throw ProbeError("Split-sum oracle: input width \(inputs) does not divide into \(size) parts")
        }
        let width = inputs / size
        var modules: [QuantizedLinear] = []
        for part in 0..<size {
            let columns = (part * width) ..< ((part + 1) * width)
            let cut = try QwenTensorParallelSlicer.inputColumns(weight: source.weight, scales: source.scales,
                biases: source.biases, columns: columns, groupSize: source.groupSize, bits: source.bits)
            modules.append(QuantizedLinear(weight: cut.weight, bias: nil, scales: cut.scales, biases: cut.biases,
                groupSize: source.groupSize, bits: source.bits, mode: source.mode))
        }
        guard source.bias == nil else { throw ProbeError("Split-sum oracle: a projection bias is not covered") }
        parts = Parts(modules, width: width)
        super.init(weight: source.weight, bias: source.bias, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
        freeze()
    }

    /// The column-sliced modules, for evaluation after construction.
    var partArrays: [MLXArray] { parts.modules.flatMap { [$0.weight, $0.scales] + ($0.biases.map { [$0] } ?? []) } }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let width = parts.width
        var sum: MLXArray?
        for (index, module) in parts.modules.enumerated() {
            let block = x[.ellipsis, (index * width) ..< ((index + 1) * width)].asType(.float32)
            let partial = module(block)
            sum = sum.map { $0 + partial } ?? partial
        }
        return sum!.asType(x.dtype)
    }
}

/// Exact copies of tensor blocks (gathers, never views: a view would keep the
/// whole checkpoint tensor alive).
enum QwenTensorParallelSlicer {
    static func rows(_ value: MLXArray, _ ranges: [Range<Int>]) throws -> MLXArray {
        guard let first = ranges.first, value.ndim >= 1,
              ranges.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= value.dim(0) && !$0.isEmpty }) else {
            throw ProbeError("Tensor parallel slice: row ranges \(ranges) do not fit \(value.shape)")
        }
        _ = first
        let indices = ranges.flatMap { $0.map { Int32($0) } }
        return take(value, MLXArray(indices), axis: 0)
    }

    static func columns(_ value: MLXArray, _ range: Range<Int>) throws -> MLXArray {
        guard value.ndim == 2, range.lowerBound >= 0, range.upperBound <= value.dim(1), !range.isEmpty else {
            throw ProbeError("Tensor parallel slice: columns \(range) do not fit \(value.shape)")
        }
        return take(value, MLXArray(range.map { Int32($0) }), axis: 1)
    }

    /// Logical input columns of an affine-quantized linear.
    static func inputColumns(weight: MLXArray, scales: MLXArray, biases: MLXArray?, columns: Range<Int>,
                             groupSize: Int, bits: Int) throws
        -> (weight: MLXArray, scales: MLXArray, biases: MLXArray?) {
        let perWord = 32 / bits
        guard columns.lowerBound % groupSize == 0, columns.upperBound % groupSize == 0,
              columns.lowerBound % perWord == 0, columns.upperBound % perWord == 0 else {
            throw ProbeError("Tensor parallel slice: columns \(columns) do not land on quantization groups")
        }
        let words = (columns.lowerBound / perWord) ..< (columns.upperBound / perWord)
        let groups = (columns.lowerBound / groupSize) ..< (columns.upperBound / groupSize)
        return (try self.columns(weight, words), try self.columns(scales, groups),
                try biases.map { try self.columns($0, groups) })
    }

    /// One checkpoint tensor cut for a rank. `leaf` is the key's last
    /// component (`weight`, `scales`, `biases` or a plain parameter name).
    static func cut(_ value: MLXArray, _ cut: QwenTensorParallelPlan.Cut, leaf: String,
                    groupSize: Int, bits: Int) throws -> MLXArray {
        switch cut {
        case .replicate:
            return value
        case .rows(let ranges):
            return try rows(value, ranges)
        case .inputColumns(let logical):
            switch leaf {
            case "weight":
                let perWord = 32 / bits
                guard logical.lowerBound % perWord == 0, logical.upperBound % perWord == 0 else {
                    throw ProbeError("Tensor parallel slice: columns \(logical) split a packed word")
                }
                return try columns(value, (logical.lowerBound / perWord) ..< (logical.upperBound / perWord))
            case "scales", "biases":
                guard logical.lowerBound % groupSize == 0, logical.upperBound % groupSize == 0 else {
                    throw ProbeError("Tensor parallel slice: columns \(logical) split a quantization group")
                }
                return try columns(value, (logical.lowerBound / groupSize) ..< (logical.upperBound / groupSize))
            default:
                throw ProbeError("Tensor parallel slice: input columns of a non-quantized tensor (\(leaf))")
            }
        case .expertRows(let range):
            // [experts, rows, ...]: every expert's rows (weight, scales and biases alike).
            guard value.ndim == 3, range.lowerBound >= 0, range.upperBound <= value.dim(1), !range.isEmpty else {
                throw ProbeError("Tensor parallel slice: expert rows \(range) do not fit \(value.shape)")
            }
            return take(value, MLXArray(range.map { Int32($0) }), axis: 1)
        case .expertInputColumns(let logical):
            guard value.ndim == 3 else { throw ProbeError("Tensor parallel slice: expert input columns of \(value.shape)") }
            let divisor: Int
            switch leaf {
            case "weight": divisor = 32 / bits
            case "scales", "biases": divisor = groupSize
            default: throw ProbeError("Tensor parallel slice: expert input columns of a non-quantized tensor (\(leaf))")
            }
            guard logical.lowerBound % divisor == 0, logical.upperBound % divisor == 0,
                  logical.upperBound / divisor <= value.dim(2) else {
                throw ProbeError("Tensor parallel slice: expert columns \(logical) split a packed word or group")
            }
            return take(value, MLXArray(((logical.lowerBound / divisor) ..< (logical.upperBound / divisor)).map { Int32($0) }), axis: 2)
        }
    }
}
