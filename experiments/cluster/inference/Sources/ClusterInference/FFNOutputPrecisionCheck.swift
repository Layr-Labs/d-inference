import Cmlx
import Foundation
import MLX
import MLXNN

private struct FFNOutputCheckSnapshot {
    let modules: [String: Module]
    let parameters: [String: MLXArray]
    let bytes: [String: Data]
    let layout: String

    init(_ model: Module) {
        eval(model)
        modules = Dictionary(uniqueKeysWithValues: model.namedModules())
        parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        bytes = parameters.mapValues { $0.asData().data }
        layout = modelParameterLayout(model)
    }

    func verify(_ model: Module, allowDownReplacement: Bool = false) throws {
        let current = Dictionary(uniqueKeysWithValues: model.namedModules())
        let arrays = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        guard Set(current.keys) == Set(modules.keys), Set(arrays.keys) == Set(parameters.keys),
            modelParameterLayout(model) == layout else { throw ProbeError("FFN precision changed model layout") }
        for (name, original) in modules {
            if allowDownReplacement && name.hasSuffix(".mlp.down_proj") {
                guard current[name] is FFNOutputLinear else { throw ProbeError("Missing dense output wrapper") }
            } else if current[name] !== original { throw ProbeError("FFN precision replaced another module: \(name)") }
        }
        for (name, original) in parameters {
            guard let actual = arrays[name], let address = mlx_array_data_uint8(original.ctx),
                mlx_array_data_uint8(actual.ctx) == address, actual.asData().data == bytes[name] else {
                throw ProbeError("FFN precision replaced or changed stored parameter storage: \(name)")
            }
        }
    }
}

private struct FFNOutputPrecisionCheckResult: Encodable {
    let kind = "ffn_output_precision_boundary"
    let incomingDType: String
    let checkedParameterArrays: Int
    let exactProjectionComparisons = 12
    let concreteDenseMLPsPreserved = true
    let storedParameterHandlesBytesAndLayoutPreserved = true
    let duplicateAttachmentRejectedWithoutMutation = true
    let moeAttachmentRejectedWithoutMutation = true
    let realCollectiveExercised = false
    let wholeModelNumericalQualification = false
}

func checkFFNOutputPrecision() throws {
    // This uses existing real model constructors and their packed W4/G64
    // arrays. PrecisionProjectionCheck separately owns the decoded CPU oracle.
    let moe = try loadModel(Options(arguments: ["--synthetic", "--synthetic-profile", "qwen-moe"]))
    let moeBefore = FFNOutputCheckSnapshot(moe.model)
    var rejected = false
    do { try attachFFNOutputPrecision(model: moe.model, layers: moe.layerCount, precision: .float32) }
    catch { rejected = true }
    guard rejected else { throw ProbeError("FFN output precision accepted MoE") }
    try moeBefore.verify(moe.model)

    for dtype in [DType.float32, .bfloat16] {
        let loaded = try loadModel(Options(arguments: ["--synthetic", "--synthetic-profile", "tiny",
                                                       "--synthetic-dtype", String(describing: dtype)]))
        let before = FFNOutputCheckSnapshot(loaded.model)
        let mlps = before.modules.filter { $0.key.hasSuffix(".mlp") }
        guard mlps.count == loaded.layerCount,
            mlps.values.allSatisfy({ String(describing: type(of: $0)) == "Qwen3NextMLP" }),
            let first = mlps.sorted(by: { $0.key < $1.key }).first else {
            throw ProbeError("FFN precision fixture lacks the actual dense Qwen MLPs")
        }
        let source = try FFNWeights(module: first.value, path: first.key).down
        let native = try FFNOutputLinear(source: source, precision: .native)
        let wide = try FFNOutputLinear(source: source, precision: .float32)
        let attentionNative = try AttentionOutputLinear(source: source, precision: .native)
        let attentionWide = try AttentionOutputLinear(source: source, precision: .float32)
        for wrapper in [native, wide] {
            guard wrapper.weight === source.weight, wrapper.scales === source.scales,
                wrapper.biases === source.biases else { throw ProbeError("FFN wrapper changed parameter handles") }
        }
        var comparisons: [(MLXArray, MLXArray)] = []
        for rows in [1, 32, 1] {
            let input = MLXArray((0..<(rows * source.shape.1)).map {
                Float(($0 * 17) % 257 - 128) / 1024
            }).reshaped(rows, source.shape.1).asType(dtype)
            let n = native(input), w = wide(input)
            guard n.dtype == dtype, w.dtype == dtype,
                n.shape == [rows, source.shape.0], w.shape == n.shape else {
                throw ProbeError("FFN projection changed expected output dtype/shape")
            }
            comparisons += [(n, attentionNative(input)), (n, source(input)),
                (w, attentionWide(input)), (w, source(input.asType(.float32)).asType(dtype))]
        }
        // Multiple deferred graphs ensure the wrapper has no cross-forward state.
        for (actual, expected) in comparisons {
            guard actual.asData().data == expected.asData().data,
                actual.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite) else {
                throw ProbeError("FFN output policy differs from its shared or explicit projection expression")
            }
        }
        // A duplicate only in the last layer must not mutate earlier valid
        // layers while discovering that rejection.
        let last = mlps.sorted(by: { $0.key < $1.key }).last!
        let lastDown = try FFNWeights(module: last.value, path: last.key).down
        try last.value.update(modules: ModuleChildren(values: ["down_proj": .value(
            try FFNOutputLinear(source: lastDown, precision: .float32))]), verify: [.noUnusedKeys])
        let partiallyAttached = FFNOutputCheckSnapshot(loaded.model)
        rejected = false
        do { try attachFFNOutputPrecision(model: loaded.model, layers: loaded.layerCount, precision: .float32) }
        catch { rejected = true }
        guard rejected else { throw ProbeError("FFN output precision accepted a duplicate attachment") }
        try partiallyAttached.verify(loaded.model)
        try last.value.update(modules: ModuleChildren(values: ["down_proj": .value(lastDown)]), verify: [.noUnusedKeys])
        try before.verify(loaded.model)
        try attachFFNOutputPrecision(model: loaded.model, layers: loaded.layerCount, precision: .float32)
        try before.verify(loaded.model, allowDownReplacement: true)
        try emitJSON(FFNOutputPrecisionCheckResult(incomingDType: String(describing: dtype),
                                                   checkedParameterArrays: before.parameters.count))
    }
}
