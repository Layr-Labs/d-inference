// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 — weight-sharing Qwen target extraction for VLM slots.
//
// Gemma 4 is deliberately absent: its MLXVLM wrapper directly owns the
// `Gemma4TextModel` served by CBv2. Only `MLXVLM.Qwen35MoE` needs a separate
// MLXLLM target over the same immutable weight arrays.
//
//   1. decode the checkpoint with the matching MLXLLM config type and
//      construct a lazy skeleton
//      (nothing is materialized — MLXArray init is lazy until eval);
//   2. re-apply the checkpoint's quantization STRUCTURE to the skeleton the
//      exact way `loadWeights` did for the wrapper (scales-presence gate +
//      the same per-layer table from `BaseConfiguration`, whose keys live in
//      the checkpoint's `language_model.`-prefixed key space);
//   3. retain only the wrapper's live `language_model.*` target tree, run the
//      target sanitizer, and
//      `update(parameters:verify:[.all])` — missing/extra/mis-shaped keys
//      all THROW, which the engine factory catches as the standard
//      `engine_v2_refusal` ERROR + load failure (never silent wrongness);
//   4. run a tiny forward through BOTH the wrapper's text path and the
//      extracted model and require cross-containment of each side's greedy
//      argmax in the other side's top-5, plus a bounded max |Δlogit| — a
//      load-time backstop against catastrophic extraction bugs (see
//      `assertForwardParity`; Qwen uses a fixed-probe containment guard with
//      a scale-relative logit bound; env
//      `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK=0` skips).
//
// The result is a SEPARATE module instance (own norms/rope/layer objects)
// sharing only the immutable parameter arrays — zero extra weight memory,
// and no module-level mutable state shared with the wrapper, which is what
// makes the Qwen3.5-mrope class of cross-path state corruption structurally
// impossible here. Concurrency: the legacy vision forward (wrapper) and v2
// text forward (extracted model) may interleave on the same arrays; both
// are read-only over the parameters (forward passes never mutate weights)
// and each path owns its private KV caches.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

/// Failure modes of Qwen VLM text-model extraction. Every case lands in
/// `EngineV2Factory.makeBridge`'s catch → ERROR `engine_v2_refusal`
/// telemetry + load refusal. The messages are operator-facing (they ride
/// the telemetry `error` field), so they say exactly what to look at.
enum EngineV2VLMTextExtractionError: Error, CustomStringConvertible {
    /// The loaded module is not a VLM wrapper this extraction understands.
    case unsupportedWrapper(String)
    /// The slot factory could not hand us the model directory (needed for
    /// `config.json`).
    case missingModelDirectory
    /// `config.json` was unreadable or had no decodable `text_config`.
    case invalidConfig(String)
    /// The checkpoint has quantized weights but no `quantization` block in
    /// `config.json` to derive the skeleton's quantization structure from.
    case missingQuantizationConfig
    /// The load-time forward parity gate failed: the extracted text model
    /// disagrees with the wrapper's own text path on the same weights.
    case parityMismatch(String)

    var description: String {
        switch self {
        case .unsupportedWrapper(let type):
            return "engine_v2 vlm extraction: unsupported VLM wrapper \(type)"
        case .missingModelDirectory:
            return "engine_v2 vlm extraction: model directory unavailable for config.json"
        case .invalidConfig(let detail):
            return "engine_v2 vlm extraction: config.json unusable (\(detail))"
        case .missingQuantizationConfig:
            return "engine_v2 vlm extraction: quantized weights but no quantization block in config.json"
        case .parityMismatch(let detail):
            return "engine_v2 vlm extraction: wrapper/extracted forward parity failed (\(detail))"
        }
    }
}

/// Weight-sharing extraction of the CBv2-adapted MLXLLM Qwen target from a
/// loaded `MLXVLM.Qwen35MoE` wrapper. Pure functions; no state.
enum EngineV2VLMTextExtraction {

    enum Family: String, Sendable {
        case qwen35MoE
    }

    /// Env kill switch for the load-time forward parity gate ("0"/"false"/
    /// "no"/"off" disables). Default ON — the check is one tiny prefill at
    /// model-load time and is the backstop against silent architecture
    /// drift between MLXVLM's inline text model and MLXLLM's.
    static let parityCheckFlag = "DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK"

    /// Checkpoint key-space prefix of the wrapper's language model. Both the
    /// parameter tree and the per-layer quantization table use it.
    private static let languageModelPrefix = "language_model."

    /// Result of one extraction: the CBv2-adapted text model (sharing the
    /// wrapper's weight arrays) plus the parity probe's max |Δlogit| for the
    /// slot factory's log line (nil when the parity gate was disabled).
    struct Extraction {
        let servingModel: any LanguageModel
        let family: Family
        let parityMaxAbsLogitDiff: Float?

    }

    /// Build an MLXLLM `Qwen35MoEModel` over the weight arrays of a loaded
    /// MLXVLM `Qwen35MoE` wrapper. See the file header for the full mechanism.
    ///
    /// - Parameters:
    ///   - model: the slot's loaded module (must be `MLXVLM.Qwen35MoE`).
    ///   - modelDirectory: the checkpoint directory (for `config.json`).
    ///   - environment: env snapshot (parity-gate kill switch).
    static func extractTextModel(
        from model: any LanguageModel,
        modelDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Extraction {
        guard let wrapper = model as? MLXVLM.Qwen35MoE else {
            throw EngineV2VLMTextExtractionError.unsupportedWrapper(
                String(describing: type(of: model)))
        }
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig(
                "read \(configURL.path): \(error)")
        }
        // Quantization table: `BaseConfiguration` holds the checkpoint-wide
        // default plus the per-layer overrides, keyed in the checkpoint's
        // `language_model.`-prefixed key space.
        let baseConfig = try? JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)

        return try extractQwen35MoE(
            wrapper: wrapper,
            configData: configData,
            perLayerQuantization: baseConfig?.perLayerQuantization,
            environment: environment)
    }

    private static func extractQwen35MoE(
        wrapper: MLXVLM.Qwen35MoE,
        configData: Data,
        perLayerQuantization: BaseConfiguration.PerLayerQuantization?,
        environment: [String: String]
    ) throws -> Extraction {
        // The combined artifact may declare and carry inline `mtp.*` tensors.
        // This module is the serving TARGET only: force the MLXLLM skeleton's
        // optional inline head off independently of the process-global MTP
        // loader flag. Assistant ownership stays with ProviderCore's separate
        // partition/load path.
        let targetConfig = try decodeQwenConfiguration(configData: configData)
        let skeleton = Qwen35MoEModel(targetConfig)
        let targetWeights = reKeyedQwenTargetWeights(
            flattenedWeights: wrapper.parameters().flattened(), sanitizer: skeleton)
        try applyQuantizationStructure(
            skeleton: skeleton,
            weights: targetWeights,
            family: .qwen35MoE,
            perLayerQuantization: perLayerQuantization)
        try skeleton.update(
            parameters: ModuleParameters.unflattened(targetWeights), verify: [.all])

        let parityDiff = try runParityGateIfEnabled(environment: environment) {
            try assertQwenForwardParity(
                wrapper: wrapper,
                extracted: skeleton,
                vocabSize: skeleton.vocabularySize)
        }
        return Extraction(
            servingModel: skeleton,
            family: .qwen35MoE,
            parityMaxAbsLogitDiff: parityDiff)
    }

    private static func runParityGateIfEnabled(
        environment: [String: String],
        _ check: () throws -> Float
    ) throws -> Float? {
        guard parityCheckEnabled(environment: environment) else { return nil }
        defer {
            MLX.Stream().synchronize()
            MLX.Memory.clearCache()
        }
        return try check()
    }

    // MARK: - Steps

    /// Decode the top-level Qwen target configuration using MLXLLM's type,
    /// after disabling the optional inline MTP module in a copied JSON object.
    /// The checkpoint and loaded wrapper are never mutated.
    static func decodeQwenConfiguration(configData: Data) throws -> MLXLLM.Qwen35Configuration {
        var root = try configurationObject(configData: configData)
        if var textConfig = root["text_config"] as? [String: Any] {
            textConfig["mtp_num_hidden_layers"] = 0
            root["text_config"] = textConfig
        } else {
            root["mtp_num_hidden_layers"] = 0
        }
        do {
            let targetData = try JSONSerialization.data(withJSONObject: root)
            return try JSONDecoder.json5().decode(
                MLXLLM.Qwen35Configuration.self, from: targetData)
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig("decode Qwen target config: \(error)")
        }
    }

    /// Config-only Qwen text decode for sizing. Uses MLXLLM's text config
    /// type directly and never constructs a module skeleton.
    static func decodeQwenTextConfiguration(configData: Data) throws -> Qwen35TextConfiguration {
        let root = try configurationObject(configData: configData)
        let textJSON = (root["text_config"] as? [String: Any]) ?? root
        do {
            let textData = try JSONSerialization.data(withJSONObject: textJSON)
            return try JSONDecoder.json5().decode(Qwen35TextConfiguration.self, from: textData)
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig("decode Qwen text_config: \(error)")
        }
    }

    private static func configurationObject(configData: Data) throws -> [String: Any] {
        do {
            guard
                let parsed = try JSONSerialization.jsonObject(with: configData)
                    as? [String: Any]
            else {
                throw EngineV2VLMTextExtractionError.invalidConfig("config.json is not an object")
            }
            return parsed
        } catch let error as EngineV2VLMTextExtractionError {
            throw error
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig("parse config.json: \(error)")
        }
    }

    /// Select only the live target arrays from Qwen's wrapper parameter tree.
    /// `mtp.*` is top-level and therefore excluded; vision parameters are
    /// under `vision_tower.*` and excluded too. The MLXLLM Qwen target keeps
    /// the same `language_model.*` namespace, so no second prefix transform is
    /// needed. Dictionary assignment retains the same lazy MLXArray handles.
    static func reKeyedQwenTargetWeights(
        flattenedWeights: [(String, MLXArray)], sanitizer: Qwen35MoEModel
    ) -> [String: MLXArray] {
        var targetWeights: [String: MLXArray] = [:]
        targetWeights.reserveCapacity(flattenedWeights.count)
        for (key, value) in flattenedWeights where key.hasPrefix(languageModelPrefix) {
            targetWeights[key] = value
        }
        return sanitizer.sanitize(weights: targetWeights)
    }

    /// Mirror `loadWeights`' quantization pass onto the skeleton: a module is
    /// quantized iff the (re-keyed, live) weights carry `<path>.scales`, with
    /// (groupSize, bits, mode) resolved from the checkpoint's per-layer table
    /// under the module's `language_model.`-prefixed checkpoint key — the
    /// exact lookup the wrapper's own load performed, so the two module trees
    /// can never disagree on quantization structure. All arrays involved stay
    /// lazy; `update(parameters:)` replaces them before anything evaluates.
    static func applyQuantizationStructure<Model: Module>(
        skeleton: Model,
        weights: [String: MLXArray],
        family: Family,
        perLayerQuantization: BaseConfiguration.PerLayerQuantization?
    ) throws {
        let hasQuantizedWeights = weights.keys.contains { $0.hasSuffix(".scales") }
        guard hasQuantizedWeights else { return }
        guard let perLayerQuantization else {
            throw EngineV2VLMTextExtractionError.missingQuantizationConfig
        }
        quantize(model: skeleton) { path, _ in
            guard weights["\(path).scales"] != nil else { return nil }
            return quantization(
                targetPath: path,
                family: family,
                perLayerQuantization: perLayerQuantization)?.asTuple
        }
    }

    /// Resolve the checkpoint quantization table in the Qwen wrapper's
    /// unchanged `language_model.*` key space.
    static func quantization(
        targetPath: String,
        family: Family,
        perLayerQuantization: BaseConfiguration.PerLayerQuantization
    ) -> BaseConfiguration.Quantization? {
        _ = family
        return perLayerQuantization.quantization(layer: targetPath)
    }

    // MARK: - Parity gate

    static func parityCheckEnabled(environment: [String: String]) -> Bool {
        guard
            let raw = environment[parityCheckFlag]?
                .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty
        else { return true }
        return !["0", "false", "no", "off"].contains(raw)
    }

    /// Top-k window for the bidirectional argmax-containment check.
    static let parityTopK = 5
    /// Qwen text-only mRoPE uses three identical position axes, so the
    /// wrapper and MLXLLM target should be substantially closer than the
    /// known Gemma implementation split. Keep the top-k catastrophe guard,
    /// and scale the magnitude bound to the wrapper's fixed-probe logits
    /// because Qwen has no final-logit softcap.
    private static func assertQwenForwardParity(
        wrapper: MLXVLM.Qwen35MoE,
        extracted: Qwen35MoEModel,
        vocabSize: Int
    ) throws -> Float {
        let probeTokens = [1, 17, 29, 43, 61].map {
            min($0, max(0, vocabSize - 1))
        }
        let inputs = MLXArray(probeTokens.map(Int32.init)).expandedDimensions(axis: 0)
        let wrapperLogits = wrapper(inputs, cache: nil).asType(.float32)
        let extractedLogits = extracted(inputs, cache: nil).asType(.float32)
        let wrapperMaxMagnitude = MLX.abs(wrapperLogits).max()
        eval(wrapperMaxMagnitude)
        let maxAbsDiffLimit = max(
            2,
            wrapperMaxMagnitude.item(Float.self) * 0.25)
        return try assertParity(
            wrapperLogits: wrapperLogits,
            extractedLogits: extractedLogits,
            positions: probeTokens.count,
            maxAbsDiffLimit: maxAbsDiffLimit)
    }

    private static func assertParity(
        wrapperLogits: MLXArray,
        extractedLogits: MLXArray,
        positions: Int,
        maxAbsDiffLimit: Float
    ) throws -> Float {

        let k = parityTopK
        // Top-k token ids per position, [1, L, k] (unordered within k).
        let wrapperTopK = argPartition(-wrapperLogits, kth: k - 1, axis: -1)[.ellipsis, ..<k]
        let extractedTopK = argPartition(-extractedLogits, kth: k - 1, axis: -1)[.ellipsis, ..<k]
        let wrapperArgmax = argMax(wrapperLogits, axis: -1)
        let extractedArgmax = argMax(extractedLogits, axis: -1)
        let maxAbsDiff = MLX.abs(wrapperLogits - extractedLogits).max()
        eval(wrapperTopK, extractedTopK, wrapperArgmax, extractedArgmax, maxAbsDiff)

        let wrapperIds = wrapperArgmax.asArray(Int32.self)
        let extractedIds = extractedArgmax.asArray(Int32.self)
        let wrapperTop = wrapperTopK.asArray(Int32.self)  // row-major [L × k]
        let extractedTop = extractedTopK.asArray(Int32.self)
        let diff = maxAbsDiff.item(Float.self)

        for position in 0 ..< positions {
            let window = position * k ..< (position + 1) * k
            let wrapperWindow = Set(wrapperTop[window])
            let extractedWindow = Set(extractedTop[window])
            guard extractedWindow.contains(wrapperIds[position]),
                wrapperWindow.contains(extractedIds[position])
            else {
                throw EngineV2VLMTextExtractionError.parityMismatch(
                    "top-\(k) containment failed at position \(position): "
                        + "wrapper argmax \(wrapperIds[position]) vs extracted top-\(k) "
                        + "\(extractedWindow.sorted()); extracted argmax "
                        + "\(extractedIds[position]) vs wrapper top-\(k) "
                        + "\(wrapperWindow.sorted()); maxAbsLogitDiff=\(diff)")
            }
        }
        guard diff <= maxAbsDiffLimit else {
            throw EngineV2VLMTextExtractionError.parityMismatch(
                "max |Δlogit| \(diff) exceeds \(maxAbsDiffLimit) "
                    + "(argmax containment held — distributions drifted)")
        }
        return diff
    }
}
