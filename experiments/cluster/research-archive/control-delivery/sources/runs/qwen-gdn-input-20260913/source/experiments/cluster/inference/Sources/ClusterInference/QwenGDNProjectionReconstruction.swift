import Foundation
import MLX
import MLXLLM
import MLXNN

/// These are the original named QuantizedLinear children, including the views
/// installed by native GDN fusion. No replacement input-projection class is used.
struct GDNProjectionInputs {
    static let names = ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"]
    let paths: [String]
    let projections: [QuantizedLinear]
    let plan: QwenGDNPartition

    var fusedWidth: Int { 2 * plan.keyWidth + 2 * plan.valueWidth + 2 * plan.valueHeads }

    init(loaded: LoadedModel, plan: QwenGDNPartition) throws {
        let prefix = loaded.model is Qwen35Model ? "language_model." : ""
        let parentPath = prefix + "model.layers.0.linear_attn"
        let modules = Dictionary(uniqueKeysWithValues: loaded.model.namedModules())
        guard let parent = modules[parentPath],
              String(describing: type(of: parent)) == "Qwen35GatedDeltaNet",
              parent.trainableParameters().flattened().isEmpty else {
            throw ProbeError("GDN input diagnostic requires the original frozen first recurrent layer")
        }
        let paths = Self.names.map { parentPath + "." + $0 }
        let projections = try paths.enumerated().map { index, path -> QuantizedLinear in
            guard let linear = modules[path] as? QuantizedLinear,
                  ObjectIdentifier(type(of: linear)) == ObjectIdentifier(QuantizedLinear.self),
                  linear.trainableParameters().flattened().isEmpty,
                  linear.mode == .affine, linear.bits == 4, linear.groupSize == 64,
                  linear.bias == nil, linear.weight.dtype == .uint32, linear.weight.ndim == 2,
                  let biases = linear.biases,
                  linear.scales.dtype == biases.dtype,
                  [DType.float16, .bfloat16, .float32].contains(linear.scales.dtype) else {
                throw ProbeError("GDN fusion requires original frozen affine W4/G64 QuantizedLinear inputs")
            }
            for (suffix, array) in [("weight", linear.weight), ("scales", linear.scales), ("biases", biases)] {
                for rank in 0..<2 {
                    _ = try plan.selection(relativeName: Self.names[index] + "." + suffix,
                                           shape: array.shape, rank: rank).resultShape(array.shape)
                }
            }
            return linear
        }
        // Current fixtures/artifacts have uniform metadata dtype. Reject mixed
        // concatenation promotion instead of silently broadening this diagnosis.
        guard Set(projections.map { String(describing: $0.scales.dtype) }).count == 1 else {
            throw ProbeError("GDN input diagnostic requires a uniform affine metadata dtype")
        }
        self.paths = paths; self.projections = projections; self.plan = plan
    }

    func sourceRecords(check: () throws -> Void) throws -> [GDNProjectionSource] {
        try projections.enumerated().map { index, linear in
            GDNProjectionSource(name: Self.names[index], modulePath: paths[index],
                inputWidth: plan.hiddenSize, outputRows: linear.shape.0,
                weight: try GDNProjectionTensorIdentity(linear.weight, check: check),
                scales: try GDNProjectionTensorIdentity(linear.scales, check: check),
                biases: try GDNProjectionTensorIdentity(linear.biases!, check: check))
        }
    }

    private func selection(index: Int, suffix: String, array: MLXArray, rank: Int?) throws -> TensorSelection {
        guard let rank else { return .all }
        return try plan.selection(relativeName: Self.names[index] + "." + suffix,
                                  shape: array.shape, rank: rank)
    }

    private func components(rank: Int?) -> [GDNProjectionComponent] {
        let names = ["q", "k", "v", "z", "b", "a"]
        let widths = [plan.keyWidth, plan.keyWidth, plan.valueWidth,
                      plan.valueWidth, plan.valueHeads, plan.valueHeads]
        var sourceOffset = 0, localOffset = 0
        return zip(names, widths).map { name, width in
            let count = rank == nil ? width : width / 2
            let start = sourceOffset + (rank ?? 0) * count
            defer { sourceOffset += width; localOffset += count }
            return GDNProjectionComponent(name: name, sourceRows: [start, start + count],
                                           localRows: [localOffset, localOffset + count])
        }
    }

    /// Reconstructs the exact fused shape and affine operator. The production
    /// private fused output is not captured; only its input came from the model.
    func evaluate(input: MLXArray, rank: Int?, check: () throws -> Void) throws -> GDNProjectionEvaluation {
        guard rank == nil || (0..<2).contains(rank!), input.ndim == 3,
              input.shape[0] == 1, (1...32).contains(input.shape[1]),
              input.shape[2] == plan.hiddenSize, fusedWidth <= 32768 else {
            throw ProbeError("GDN projection reconstruction exceeds the agreed shape/rank bounds")
        }
        var weights: [MLXArray] = [], scales: [MLXArray] = [], biases: [MLXArray] = []
        var selections: [GDNProjectionSelection] = []
        for (index, linear) in projections.enumerated() {
            let weightSelection = try selection(index: index, suffix: "weight", array: linear.weight, rank: rank)
            let ranges: [[Int]]
            switch weightSelection {
            case .all: ranges = [[0, linear.shape.0]]
            case .axis(let axis, let rows):
                guard axis == 0 else { throw ProbeError("GDN input reconstruction must preserve the full input width") }
                ranges = rows.map { [$0.lowerBound, $0.upperBound] }
            }
            selections.append(GDNProjectionSelection(name: Self.names[index], ranges: ranges))
            func selected(_ source: MLXArray, _ suffix: String) throws -> MLXArray {
                let choice = try selection(index: index, suffix: suffix, array: source, rank: rank)
                if rank == nil { return source }
                return try copySelectedTensor(source, selection: choice)
            }
            weights.append(try selected(linear.weight, "weight"))
            scales.append(try selected(linear.scales, "scales"))
            biases.append(try selected(linear.biases!, "biases"))
            try check()
        }
        // Native fusion concatenates these four source projections in this order.
        let weight = concatenated(weights, axis: 0)
        let scale = concatenated(scales, axis: 0)
        let offset = concatenated(biases, axis: 0)
        eval(weight, scale, offset)
        try check()
        let width = rank == nil ? fusedWidth : fusedWidth / 2
        guard weight.shape == [width, plan.hiddenSize / 8],
              scale.shape == [width, plan.hiddenSize / 64], offset.shape == scale.shape,
              weight.dtype == .uint32, scale.dtype == projections[0].scales.dtype,
              offset.dtype == scale.dtype else {
            throw ProbeError("GDN reconstructed fusion changed packed shape or metadata dtype")
        }
        let fused = QuantizedLinear(weight: weight, scales: scale, biases: offset,
                                    groupSize: 64, bits: 4, mode: .affine)
        fused.freeze()
        let output = fused(input)
        eval(output)
        try check()
        guard output.shape == [1, input.shape[1], width], output.dtype == input.dtype else {
            throw ProbeError("GDN reconstructed projection changed activation shape/dtype")
        }
        return GDNProjectionEvaluation(rank: rank,
            output: try GDNProjectionValues(output, maximumValues: 32 * 32768, check: check),
            selections: selections, selectionSHA256: sha256(try canonicalJSONData(selections)),
            fusedWeight: try GDNProjectionTensorIdentity(weight, check: check),
            fusedScales: try GDNProjectionTensorIdentity(scale, check: check),
            fusedBiases: try GDNProjectionTensorIdentity(offset, check: check),
            components: components(rank: rank))
    }
}
