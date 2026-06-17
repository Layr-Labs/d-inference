import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Errors thrown while mapping a parsed ``KVQuantCandidateMode`` to executable
/// generation parameters and caches.
enum KVQuantExecutionError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedMode(String)
    case missingGroupSize(KVQuantCandidateMode)
    case missingStartToken(KVQuantCandidateMode)

    var errorDescription: String? {
        switch self {
        case .unsupportedMode(let mode):
            return "KV quant mode '\(mode)' is not supported by the benchmark gate"
        case .missingGroupSize(let mode):
            return "KV quant mode '\(mode.rawValue)' is missing a required group size"
        case .missingStartToken(let mode):
            return "KV quant mode '\(mode.rawValue)' is missing a required quantization start token"
        }
    }
}

/// The result of mapping a candidate mode to the artifacts needed for execution.
///
/// `parameters` is always used (for both single-pass evaluation and generation).
/// For quantized modes a `cacheFactory` is provided so that the benchmark can
/// create caches whose storage matches the requested quantization semantics.
struct KVQuantExecutionConfig: Sendable {
    let parameters: GenerateParameters
    let cacheFactory: (@Sendable (any LanguageModel) -> [KVCache])?

    init(parameters: GenerateParameters, cacheFactory: (@Sendable (any LanguageModel) -> [KVCache])? = nil) {
        self.parameters = parameters
        self.cacheFactory = cacheFactory
    }

    /// Create a cache array suitable for the configured mode.
    ///
    /// For fp16 this delegates to the model's own cache creation. For quantized
    /// modes the factory preserves the model's per-layer cache class (e.g.
    /// ``RotatingKVCache`` for sliding-window layers) and replaces full layers
    /// with the requested quantized cache.
    func makeCache(using model: any LanguageModel) -> [KVCache] {
        if let cacheFactory = cacheFactory {
            return cacheFactory(model)
        }
        return model.newCache(parameters: parameters)
    }
}

/// Maps parsed ``KVQuantCandidateMode`` values to mlx-swift-lm generation configs
/// and custom ``KVCache`` factories.
enum KVQuantExecution {
    static func config(
        for mode: KVQuantCandidateMode,
        base: GenerateParameters = GenerateParameters()
    ) throws -> KVQuantExecutionConfig {
        var parameters = base

        switch mode {
        case .fp16KV:
            return KVQuantExecutionConfig(parameters: parameters)

        case .bf16KV:
            guard let startToken = mode.startToken else {
                throw KVQuantExecutionError.missingStartToken(mode)
            }
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return BFloat16KVCache(startToken: startToken)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .fullVBF16:
            guard let startToken = mode.startToken else {
                throw KVQuantExecutionError.missingStartToken(mode)
            }
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return VOnlyBFloat16KVCache(startToken: startToken)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .affine4, .affine8:
            guard let groupSize = mode.groupSize else {
                throw KVQuantExecutionError.missingGroupSize(mode)
            }
            guard let bits = mode.bitWidth else {
                throw KVQuantExecutionError.unsupportedMode(mode.rawValue)
            }
            // Use a protocol-safe quantized cache that can serve both the
            // native quantized attention path and the plain update(keys:values:)
            // fallback used by single-forward scoring and Gemma 4 attention.
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return ProtocolSafeQuantizedKVCache(groupSize: groupSize, bits: bits, mode: .affine)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .k8v8g128:
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return ProtocolSafeQuantizedKVCache(groupSize: 128, bits: 8, mode: .affine)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .k8v8g64:
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return ProtocolSafeQuantizedKVCache(groupSize: 64, bits: 8, mode: .affine)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .k8v8g64Dequant:
            let spec = KVQuantCacheSpec(
                bits: 8, groupSize: 64, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return KVQuantizedCache(spec: spec)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .k6v6g64:
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return ProtocolSafeQuantizedKVCache(groupSize: 64, bits: 6, mode: .affine)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .k6v6g64Dequant:
            let spec = KVQuantCacheSpec(
                bits: 6, groupSize: 64, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return KVQuantizedCache(spec: spec)
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .fullVAffine4:
            guard let groupSize = mode.groupSize else {
                throw KVQuantExecutionError.missingGroupSize(mode)
            }
            guard let startToken = mode.startToken else {
                throw KVQuantExecutionError.missingStartToken(mode)
            }
            let bits = mode.bitWidth ?? 4
            let factory: @Sendable (any LanguageModel) -> [KVCache] = { model in
                model.newCache(parameters: nil).map { baseCache in
                    if baseCache is RotatingKVCache {
                        return baseCache.copy()
                    }
                    return VOnlyQuantizedKVCache(
                        groupSize: groupSize,
                        bits: bits,
                        startToken: startToken,
                        mode: .affine
                    )
                }
            }
            return KVQuantExecutionConfig(parameters: parameters, cacheFactory: factory)

        case .fullVTurbo4, .fullKVTurbo4, .turbo4v2:
            throw KVQuantExecutionError.unsupportedMode(mode.rawValue)
        }
    }
}
