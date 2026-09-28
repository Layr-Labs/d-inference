import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Activation is a caller-owned model contract; neither the router nor the
/// checkpoint's family name implicitly selects it.
enum ExpertActivation: String, Codable {
    case silu, geluTanh = "gelu-tanh"

    func makeSwitchGLU(inputDims: Int, hiddenDims: Int, numExperts: Int,
                       fusedGateUp: Bool) -> SwitchGLU {
        switch self {
        case .silu:
            return SwitchGLU(inputDims: inputDims, hiddenDims: hiddenDims,
                numExperts: numExperts, fuseGateUp: fusedGateUp)
        case .geluTanh:
            return SwitchGLU(inputDims: inputDims, hiddenDims: hiddenDims,
                numExperts: numExperts, activation: safeGeluApproximate,
                fuseGateUp: fusedGateUp)
        }
    }
}

/// Every rank retains the global expert axis and owns an explicit inner-width
/// interval. Unequal intervals are necessary for Gemma's eleven G64 groups.
/// The enclosing model plan owns complete/nonoverlapping coverage across ranks.
struct ExpertPartitionPlan {
    let inputDims: Int
    let intermediateDims: Int
    let numExperts: Int
    let interval: Range<Int>
    let activation: ExpertActivation
    let fusedGateUp: Bool
    let projectionBits: [String: Int]
    let groupSize = 64
    var localIntermediateDims: Int { interval.count }
    var parameterNames: [String] {
        projectionBits.keys.sorted().flatMap { projection in
            ["weight", "scales", "biases"].map { projection + "." + $0 }
        }
    }

    init(inputDims: Int, intermediateDims: Int, numExperts: Int, interval: Range<Int>,
         activation: ExpertActivation, fusedGateUp: Bool, projectionBits: [String: Int]) throws {
        guard inputDims > 0, inputDims <= 1_048_576, inputDims % 64 == 0,
            intermediateDims > 0, intermediateDims <= 1_048_576, intermediateDims % 64 == 0,
            numExperts > 0, numExperts <= 1_048_576,
            interval.lowerBound >= 0, interval.upperBound <= intermediateDims,
            !interval.isEmpty, interval.lowerBound % 64 == 0, interval.upperBound % 64 == 0 else {
            throw ProbeError("Expert partition requires positive dimensions and whole G64 inner groups")
        }
        let projections = fusedGateUp ? ["gate_up_proj", "down_proj"]
            : ["gate_proj", "up_proj", "down_proj"]
        guard Set(projectionBits.keys) == Set(projections),
            projectionBits.values.allSatisfy({ $0 == 4 || $0 == 8 }) else {
            throw ProbeError("Expert projections require explicit W4/W8 policies; fused gate/up shares one policy")
        }
        self.inputDims = inputDims; self.intermediateDims = intermediateDims
        self.numExperts = numExperts; self.interval = interval; self.activation = activation
        self.fusedGateUp = fusedGateUp; self.projectionBits = projectionBits
    }

    func sourceShape(name: String) throws -> [Int] {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count == 2, let bits = projectionBits[parts[0]],
            ["weight", "scales", "biases"].contains(parts[1]) else {
            throw ProbeError("Unknown expert tensor or unsupported ordinary bias: \(name)")
        }
        let packing = parts[1] == "weight" ? 32 / bits : groupSize
        if parts[0] == "down_proj" { return [numExperts, inputDims, intermediateDims / packing] }
        return [numExperts, intermediateDims * (parts[0] == "gate_up_proj" ? 2 : 1), inputDims / packing]
    }

    func selection(name: String, shape: [Int]) throws -> TensorSelection {
        guard shape == (try sourceShape(name: name)) else {
            throw ProbeError("Expert source tensor shape does not match its quantization policy: \(name)")
        }
        let parts = name.split(separator: ".").map(String.init)
        if parts[0] == "down_proj" {
            let packing = parts[1] == "weight" ? 32 / projectionBits[parts[0]]! : groupSize
            return .axis(2, [(interval.lowerBound / packing)..<(interval.upperBound / packing)])
        }
        if parts[0] == "gate_up_proj" {
            // Gather the matching slice of BOTH halves, preserving [gate, up].
            return .axis(1, [interval,
                (intermediateDims + interval.lowerBound)..<(intermediateDims + interval.upperBound)])
        }
        return .axis(1, [interval])
    }
}

/// A routed local partial, before allreduce, normalization, shared branches or
/// residual addition. Computation remains in the pinned public SwitchGLU.
final class QuantizedExpertPartial: Module {
    let plan: ExpertPartitionPlan
    let localSwitchGLU: SwitchGLU

    /// The reader receives relative checkpoint names and physical selections;
    /// a future verified TensorDescriptor reader can supply bytes without ever
    /// constructing the full expert bank. Returned arrays must own compact storage.
    init(plan: ExpertPartitionPlan,
         loadTensor: (String, TensorSelection) throws -> MLXArray) throws {
        self.plan = plan
        let local = plan.activation.makeSwitchGLU(inputDims: plan.inputDims,
            hiddenDims: plan.localIntermediateDims, numExperts: plan.numExperts,
            fusedGateUp: plan.fusedGateUp)
        quantize(model: local) { path, _ in
            guard let bits = plan.projectionBits[path] else { return nil }
            return (groupSize: 64, bits: bits, mode: .affine)
        }
        let expected = Dictionary(uniqueKeysWithValues: local.parameters().flattened().map { ($0.0, $0.1.shape) })
        guard Set(expected.keys) == Set(plan.parameterNames) else {
            throw ProbeError("Constructed expert module does not match the declared projection policies")
        }
        for name in plan.parameterNames {
            let sourceShape = try plan.sourceShape(name: name)
            let selection = try plan.selection(name: name, shape: sourceShape)
            let array = try loadTensor(name, selection)
            let legalDType = name.hasSuffix(".weight") ? array.dtype == .uint32
                : [.float32, .float16, .bfloat16].contains(array.dtype)
            guard legalDType, array.shape == expected[name],
                array.shape == (try selection.resultShape(sourceShape)) else {
                throw ProbeError("Expert reader returned an incompatible tensor: \(name)")
            }
            eval(array)
            let bound = try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)
            guard let buffer = try array.evaluatedBufferInfo() else {
                throw ProbeError("Expert reader returned unevaluated storage: \(name)")
            }
            guard buffer.dataOffset == 0, buffer.isUnique,
                buffer.isRowContiguous, buffer.dataElements == array.size,
                buffer.allocatedBytes >= array.nbytes,
                buffer.allocatedBytes <= bound else {
                throw ProbeError("Expert reader returned non-owned or noncompact storage: \(name), "
                    + "selection=\(selection.signature), shape=\(array.shape), dtype=\(array.dtype), "
                    + "bytes=\(array.nbytes), bound=\(bound), allocated=\(buffer.allocatedBytes), "
                    + "offset=\(buffer.dataOffset), elements=\(buffer.dataElements)/\(array.size), "
                    + "rowContiguous=\(buffer.isRowContiguous), unique=\(buffer.isUnique)")
            }
            try local.update(parameters: ModuleParameters.unflattened([name: array]),
                verify: [.noUnusedKeys, .shapeMismatch])
        }
        local.freeze(); eval(local)
        localSwitchGLU = local
        super.init()
    }

    /// Synthetic/reference convenience. Real loading should use the reader seam
    /// above after verifying checkpoint identity and per-projection policy.
    convenience init(source: SwitchGLU, interval: Range<Int>, activation: ExpertActivation) throws {
        let parameters = Dictionary(uniqueKeysWithValues: source.parameters().flattened())
        let fused = source.hasFusedGateUp
        let projections = fused ? ["gate_up_proj", "down_proj"] : ["gate_proj", "up_proj", "down_proj"]
        let modules = Dictionary(uniqueKeysWithValues: source.namedModules())
        var bits: [String: Int] = [:]
        for path in projections {
            guard let projection = modules[path] as? QuantizedSwitchLinear,
                projection.mode == .affine, projection.groupSize == 64,
                projection.bits == 4 || projection.bits == 8 else {
                throw ProbeError("Source expert projection is not affine W4/W8 G64: \(path)")
            }
            bits[path] = projection.bits
        }
        guard let down = parameters["down_proj.weight"], down.ndim == 3,
            let gate = parameters[(fused ? "gate_up_proj" : "gate_proj") + ".weight"], gate.ndim == 3,
            !fused || gate.dim(1) % 2 == 0 else {
            throw ProbeError("Source expert bank requires rank-three gate/up/down tensors")
        }
        let plan = try ExpertPartitionPlan(inputDims: down.dim(1),
            intermediateDims: gate.dim(1) / (fused ? 2 : 1), numExperts: down.dim(0),
            interval: interval, activation: activation, fusedGateUp: fused, projectionBits: bits)
        guard Set(parameters.keys) == Set(plan.parameterNames) else {
            throw ProbeError("Source expert bank has missing tensors or unsupported output biases")
        }
        for (name, array) in parameters { _ = try plan.selection(name: name, shape: array.shape) }
        try self.init(plan: plan) { name, selection in
            try copySelectedTensor(parameters[name]!, selection: selection)
        }
    }

    /// Caller guarantees global IDs are in [0,numExperts) and routing values are
    /// finite. Those are router invariants; this hot path performs no host reads.
    /// It preserves supplied scores (including Gemma per-expert scaling) verbatim.
    func callAsFunction(_ x: MLXArray, expertIDs: MLXArray, routingWeights: MLXArray) throws -> MLXArray {
        guard x.ndim == 2, x.dim(0) > 0, x.dim(1) == plan.inputDims,
            [.float32, .float16, .bfloat16].contains(x.dtype),
            expertIDs.ndim == 2, expertIDs.dtype == .uint32,
            expertIDs.dim(0) == x.dim(0), expertIDs.dim(1) > 0,
            expertIDs.dim(1) <= plan.numExperts, routingWeights.shape == expertIDs.shape,
            [.float32, .float16, .bfloat16].contains(routingWeights.dtype) else {
            throw ProbeError("Expert partial requires [rows,hidden], global uint32 IDs and matching routing scores")
        }
        return localSwitchGLU.callAndWeightedReduce(x, expertIDs, weights: routingWeights,
            fuseSortedReduction: false, isProductionPrefill: false)
    }
}
