import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Both routes retain the original global decoder configuration. A selected
/// stage never constructs a compact Gemma config or slices an expert tensor.
enum Gemma4ForwardModel {
    case full(Gemma4Model)
    case stage(Gemma4LayerStage)

    var module: Module {
        switch self { case .full(let model): return model; case .stage(let model): return model }
    }
    var kinds: [CBv2LayerKind] {
        switch self {
        case .full(let model): return model.textModel.cbv2LayerKinds
        case .stage(let model): return model.layout.layerKinds
        }
    }
    var globals: [Int] {
        switch self {
        case .full(let model): return Array(model.textModel.cbv2LayerKinds.indices)
        case .stage(let model): return model.layout.globalLayerIndices
        }
    }
    var isIngressStage: Bool {
        if case .stage(let model) = self { return model.layout.rank == 0 }
        return false
    }
    var isResidualConsumer: Bool {
        if case .stage(let model) = self { return model.layout.rank == 1 }
        return false
    }

    func freshCaches() -> [any CBv2AttendingLayerCache] {
        kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
    }

    /// Native graph construction only. The shared state owner evaluates all
    /// cache roots, checks the result, and commits the token frontier afterward.
    func forward(tokens: [Int], residual: MLXArray?, frame: QwenLayerStageFrame,
                 caches: [any CBv2AttendingLayerCache], nativeTypes: [DType]?) throws -> MLXArray {
        switch self {
        case .full(let model):
            guard case nil = residual else { throw ProbeError("Full Gemma rejects residual ingress") }
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
            let legacy = caches.map { $0 as! any KVCache }
            if frame.phase == .prefill {
                return model.textModel.cbv2Prefill(input, inputEmbedding: nil, cache: legacy,
                    requirement: frame.finalPromptChunk ? .lastPositionLogits : .evaluationOnly)
            }
            return model(input, cache: legacy)[0..., -1, 0...]
        case .stage(let model):
            let input: MLXArray
            if model.layout.rank == 0 {
                guard case nil = residual else { throw ProbeError("Ingress Gemma stage rejects residual input") }
                input = try model.inputResidual(tokens: tokens.map(Int32.init))
            } else {
                guard let residual else { throw ProbeError("Final Gemma stage requires an admitted residual") }
                input = residual
            }
            let output = try model.forwardResidual(input, caches: caches,
                phase: frame.phase == .prefill ? .prefill : .decode)
            if let nativeTypes { try output.requireKVDTypes(nativeTypes) }
            if model.layout.rank == 0 { return output.residual }
            if frame.phase == .prefill && !frame.finalPromptChunk {
                return output.residual[0..., -1, 0..<1]
            }
            return try model.finalLogits(output.residual)
        }
    }
}

/// Exact source-to-constructor inventory. No payload is read here, but Gemma
/// construction performs SwitchGLU's small probe and needs native admission.
struct Gemma4PreparedForwardModel {
    let source: Gemma4RegisteredSource
    let target: Gemma4ForwardTarget
    let model: Gemma4ForwardModel
    let selected: [Gemma4SelectedTensor]
    let parameterLayoutSHA256: String

    static func prepare(source: Gemma4RegisteredSource, target: Gemma4ForwardTarget,
                        check: () throws -> Void) throws -> Self {
        try check()
        let configuration = try JSONDecoder().decode(Gemma4Configuration.self,
            from: source.artifact.originalConfiguration)
        let model: Gemma4ForwardModel
        let policy: BaseConfiguration.PerLayerQuantization
        switch target {
        case .fullReference:
            model = .full(Gemma4Model(configuration))
            guard let original = try JSONDecoder().decode(BaseConfiguration.self,
                from: source.artifact.originalConfiguration).perLayerQuantization else {
                throw ProbeError("Registered Gemma lacks original quantization")
            }
            policy = original
        case .stage(let rank):
            guard source.plan.stages.indices.contains(rank) else { throw ProbeError("Unknown Gemma stage") }
            let descriptor = source.plan.stages[rank]
            model = .stage(try Gemma4LayerStage(originalConfiguration: configuration,
                rank: rank, sourceLayerRange: descriptor.sourceLayerRange))
            let table = try JSONSerialization.jsonObject(with: descriptor.localQuantization)
            let bytes = try JSONSerialization.data(withJSONObject: ["model_type":"gemma4", "quantization":table])
            guard let relocated = try JSONDecoder().decode(BaseConfiguration.self, from: bytes).perLayerQuantization else {
                throw ProbeError("Registered Gemma local quantization is missing")
            }
            policy = relocated
        }
        try check()
        let selected = try source.selection(target)
        let packedModules = Set(selected.filter { $0.localName.hasSuffix(".scales") }
            .map { String($0.localName.dropLast(".scales".count)) })
        var resolved: [String: BaseConfiguration.Quantization] = [:]
        for (path, _) in model.module.leafModules().flattened() where packedModules.contains(path) {
            guard let value = policy.quantization(layer: path), value.mode == .affine,
                  [4, 8].contains(value.bits), value.groupSize == 64 else {
                throw ProbeError("Registered Gemma projection policy differs")
            }
            resolved[path] = value
        }
        guard Set(resolved.keys) == packedModules else { throw ProbeError("Gemma quantized module coverage differs") }
        quantize(model: model.module) { path, _ in resolved[path]?.asTuple }
        try check()
        let actual = Dictionary(uniqueKeysWithValues: model.module.parameters().flattened())
        guard Set(actual.keys) == Set(selected.map(\.localName)) else {
            throw ProbeError("Registered Gemma constructor coverage differs from selected source")
        }
        for tensor in selected {
            guard let value = actual[tensor.localName], value.shape == tensor.source.layout.shape,
                  tensor.dtype.acceptsConstructor(nativeName: String(describing: value.dtype)) else {
                throw ProbeError("Registered Gemma constructor packed shape/class differs")
            }
        }
        let layout = selected.map { "\($0.localName):\($0.loadedDType):\($0.source.layout.shape)" }.sorted().joined(separator: "\n")
        return .init(source: source, target: target, model: model, selected: selected,
            parameterLayoutSHA256: sha256(Data(layout.utf8)))
    }
}
