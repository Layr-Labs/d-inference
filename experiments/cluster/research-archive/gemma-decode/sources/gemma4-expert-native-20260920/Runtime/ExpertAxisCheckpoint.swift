import Foundation
import MLX
import MLXNN

/// Uses the existing verified descriptor lifetime and aligned selected reader.
/// Full artifact verification precedes any selected leaf or router execution.
final class ExpertAxisCheckpoint {
    let checkpoint: VerifiedCheckpoint
    let tensors: [String: TensorDescriptor]
    let layer: Int
    let geometry: ExpertAxisGeometry
    let prefix: String

    init(directory: URL, layer: Int, check: () throws -> Void) throws {
        guard (0..<30).contains(layer) else { throw ProbeError("Gemma expert layer must be0..<30") }
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576)
        guard sha256(config) == Gemma4ArtifactMetadata.configurationSHA256 else {
            throw ProbeError("Gemma expert checkpoint configuration differs")
        }
        _ = try Gemma4TextMetadata.decode(config)
        try check()
        let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: Gemma4ArtifactMetadata.artifactAggregateSHA256,
            maximumPayloadBytes: 15_641_239_295,
            expectedManifestSHA256: Gemma4ArtifactMetadata.manifestSHA256)
        try check()
        let tensors = try tensorDescriptors(checkpoint: checkpoint)
        guard tensors.count == 1697 else { throw ProbeError("Gemma complete source tensor count differs") }
        let geometry = try ExpertAxisGeometry(hidden: 2816, intermediate: 704, experts: 128, metadataDType: .bfloat16)
        let prefix = "language_model.model.layers.\(layer)."
        for name in ExpertAxisGeometry.names {
            guard let tensor = tensors[prefix + "experts.switch_glu." + name],
                  tensor.shape == (try geometry.shape(name)), tensor.dtype == geometry.dtype(name) else {
                throw ProbeError("Gemma exact expert leaf differs: \(name)")
            }
        }
        for file in checkpoint.files.values { try file.bypassPayloadCache() }
        self.checkpoint = checkpoint; self.tensors = tensors; self.layer = layer
        self.geometry = geometry; self.prefix = prefix
    }

    func readExpert(_ name: String, selection: TensorSelection) throws -> MLXArray {
        guard let tensor = tensors[prefix + "experts.switch_glu." + name],
              tensor.shape == (try geometry.shape(name)), tensor.dtype == geometry.dtype(name) else {
            throw ProbeError("Expert selected read is outside the admitted leaf map")
        }
        guard case .axis(let axis, _) = selection, axis == 0 else {
            throw ProbeError("Expert selected read must preserve full projection dimensions")
        }
        let result = try tensor.read(selection)
        guard result.copiedBytes == result.array.nbytes else { throw ProbeError("Expert selected bytes differ") }
        return result.array
    }

    func unchanged() throws { for file in checkpoint.files.values { try file.checkUnchanged() } }

    func router(check: () throws -> Void) throws -> ExpertAxisRouterReplay {
        func read(_ suffix: String, _ shape: [Int], _ dtype: DType) throws -> MLXArray {
            guard let tensor = tensors[prefix + suffix], tensor.shape == shape, tensor.dtype == dtype else {
                throw ProbeError("Gemma router/norm leaf differs: \(suffix)")
            }
            try check(); let value = try tensor.read(.all).array
            eval(value); try check(); return value
        }
        let weight = try read("router.proj.weight", [128, 704], .uint32)
        let scales = try read("router.proj.scales", [128, 44], .bfloat16)
        let biases = try read("router.proj.biases", [128, 44], .bfloat16)
        let routerScale = try read("router.scale", [2816], .bfloat16)
        let expertScale = try read("router.per_expert_scale", [128], .bfloat16)
        let inputNorm = try read("pre_feedforward_layernorm_2.weight", [2816], .bfloat16)
        let outputNorm = try read("post_feedforward_layernorm_2.weight", [2816], .bfloat16)
        return .init(projection: QuantizedLinear(weight: weight, scales: scales, biases: biases,
            groupSize: 64, bits: 8, mode: .affine), routerScale: routerScale,
            expertScale: expertScale, inputNorm: inputNorm, outputNorm: outputNorm)
    }
}

/// Exact stock Gemma router operators, exposed only as a qualification replay.
/// This is not an intercepted private router or a new generation model.
struct ExpertAxisRouterReplay {
    let projection: QuantizedLinear
    let routerScale: MLXArray, expertScale: MLXArray, inputNorm: MLXArray, outputNorm: MLXArray

    func route(_ residual: MLXArray) -> (input: MLXArray, ids: MLXArray, weights: MLXArray) {
        let normalized = MLXFast.rmsNorm(residual, weight: routerScale * pow(Float(2816), -0.5), eps: 1e-6)
        let scores = projection(normalized)
        let kth = 128 - 8
        let ids = MLX.argPartition(scores, kth: kth, axis: -1)[.ellipsis, kth...]
        let selected = MLX.takeAlong(scores, ids, axis: -1)
        let weights = MLX.softmax(selected, axis: -1, precise: true) * expertScale[ids]
        return (MLXFast.rmsNorm(residual, weight: inputNorm, eps: 1e-6), ids, weights)
    }
    func postNorm(_ sparse: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(sparse, weight: outputNorm, eps: 1e-6)
    }
}
