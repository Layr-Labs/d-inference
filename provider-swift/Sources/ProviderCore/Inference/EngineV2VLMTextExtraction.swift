// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 — weight-sharing text-model extraction for VLM slots.
//
// Every production Gemma 4 checkpoint ships a vision tower, so the provider
// loads it through `VLMModelFactory` and the resident module is MLXVLM's
// `Gemma4` wrapper — whose language model is a PRIVATE inline duplicate of
// the text architecture ("MLXVLM can't import MLXLLM") with none of the
// CBv2 hooks (`cbv2LayerKinds` / `newCacheV2`). The v2 engine therefore
// could never serve a VLM slot directly, and before v0.7.2 the per-slot
// `isVLM` gate excluded 100% of prod Gemma traffic from engine v2.
//
// This file builds the CBv2-adapted MLXLLM `Gemma4TextModel` OVER THE SAME
// WEIGHT ARRAYS the wrapper already holds:
//
//   1. decode the checkpoint's `config.json` `text_config` with MLXLLM's
//      `Gemma4TextConfiguration` decoder and construct a lazy skeleton
//      (nothing is materialized — MLXArray init is lazy until eval);
//   2. re-apply the checkpoint's quantization STRUCTURE to the skeleton the
//      exact way `loadWeights` did for the wrapper (scales-presence gate +
//      the same per-layer table from `BaseConfiguration`, whose keys live in
//      the checkpoint's `language_model.`-prefixed key space);
//   3. re-key the wrapper's live parameter tree (`language_model.model.X` →
//      `model.X`, `language_model.lm_head.X` → `lm_head.X`), run it through
//      `Gemma4TextModel.sanitize` (drops shared-KV k/v duplicates the
//      wrapper allocates but the MLXLLM model does not), and
//      `update(parameters:verify:[.all])` — missing/extra/mis-shaped keys
//      all THROW, which the engine factory catches as the standard
//      `engine_v2_fallback` WARN + legacy path (never silent wrongness);
//   4. run a tiny forward through BOTH the wrapper's text path and the
//      extracted model and require cross-containment of each side's greedy
//      argmax in the other side's top-5, plus a bounded max |Δlogit| — a
//      load-time backstop against catastrophic extraction bugs (see
//      `assertForwardParity` for why bit-parity is structurally
//      unattainable; env `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK=0` skips).
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

/// Failure modes of VLM text-model extraction. Every case lands in
/// `EngineV2Factory.makeBridgeIfSelected`'s catch → WARN `engine_v2_fallback`
/// telemetry + legacy serving. The messages are operator-facing (they ride
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

/// Weight-sharing extraction of the CBv2-adapted MLXLLM text model from a
/// loaded MLXVLM wrapper. Pure functions; no state.
enum EngineV2VLMTextExtraction {

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
        let model: Gemma4TextModel
        let parityMaxAbsLogitDiff: Float?
    }

    /// Build an MLXLLM `Gemma4TextModel` over the weight arrays of a loaded
    /// MLXVLM `Gemma4` wrapper. See the file header for the full mechanism.
    ///
    /// - Parameters:
    ///   - model: the slot's loaded module (must be `MLXVLM.Gemma4`).
    ///   - modelDirectory: the checkpoint directory (for `config.json`).
    ///   - environment: env snapshot (parity-gate kill switch).
    static func extractTextModel(
        from model: any LanguageModel,
        modelDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Extraction {
        guard let wrapper = model as? MLXVLM.Gemma4 else {
            throw EngineV2VLMTextExtractionError.unsupportedWrapper(
                String(describing: type(of: model)))
        }

        // 1. Text config: decode the checkpoint's `text_config` with the SAME
        //    decoder `LLMModelFactory` would use for a text-only checkpoint.
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig(
                "read \(configURL.path): \(error)")
        }
        let textConfig = try decodeTextConfiguration(configData: configData)

        // Quantization table: `BaseConfiguration` holds the checkpoint-wide
        // default plus the per-layer overrides, keyed in the checkpoint's
        // `language_model.`-prefixed key space.
        let baseConfig = try? JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)

        // 2-3. Lazy skeleton → quantization structure → weight-sharing update.
        let skeleton = Gemma4TextModel(textConfig)
        let textWeights = reKeyedTextWeights(wrapper: wrapper, sanitizer: skeleton)
        try applyQuantizationStructure(
            skeleton: skeleton, weights: textWeights,
            perLayerQuantization: baseConfig?.perLayerQuantization)
        // verify: [.all] — a missing model key, an unused weight key, or a
        // shape mismatch all throw here. That is the design: any drift
        // between the wrapper's parameter tree and the MLXLLM architecture
        // must fail LOUDLY at load (→ engine_v2_fallback WARN + legacy),
        // never produce a silently wrong serving model.
        try skeleton.update(
            parameters: ModuleParameters.unflattened(textWeights), verify: [.all])

        // 4. Load-time forward parity gate (env-gated, default on).
        var parityDiff: Float? = nil
        if parityCheckEnabled(environment: environment) {
            // Return the probe's transient buffers to the OS before the load
            // path's post-build admission/headroom reads. The probe's two
            // forwards leave ~GiBs of intermediates in the MLX pool; fence
            // async GPU completion first (M4 IOKit guard), and clean up on
            // the parity-failure throw path too.
            defer {
                MLX.Stream().synchronize()
                MLX.Memory.clearCache()
            }
            parityDiff = try assertForwardParity(
                wrapper: wrapper, extracted: skeleton, vocabSize: textConfig.vocabSize)
        }

        return Extraction(model: skeleton, parityMaxAbsLogitDiff: parityDiff)
    }

    // MARK: - Adoption bound (config-only, no weights)

    /// The checkpoint's prefix-cache adoption bound derived from its
    /// `text_config` ALONE — the same `cbv2LayerKinds` the extracted text
    /// model would report, but without running the (parity-gated, forward-
    /// pass) extraction. Used by the slot factory's per-model funding gate
    /// (`PrefixCachePolicy.shouldFund`) BEFORE the carve, where only the
    /// VLM wrapper is loaded. nil when the config is unreadable/undecodable
    /// — the caller treats that as bound 0 (fund; the extraction inside
    /// engine construction will throw on the same config moments later, so
    /// no cache is ever actually built for a broken checkpoint).
    static func adoptionBoundTokens(modelDirectory: URL) -> Int? {
        cbv2LayerKinds(modelDirectory: modelDirectory)
            .map { PrefixCachePolicy.adoptionBoundTokens(layerKinds: $0) }
    }

    /// A VLM checkpoint's CBv2 layer kinds from `config.json`'s
    /// `text_config` ALONE — identical to what the extracted text model
    /// reports (the drift tests pin config-derived shape == engine truth).
    /// Used by the slot factory to construct the SSD prefix cache for VLM
    /// slots (layout-epoch + adoption-bound binding) BEFORE the extraction
    /// runs inside engine construction. nil when the config is
    /// unreadable/undecodable — no cache is built (the extraction will
    /// throw on the same config moments later).
    static func cbv2LayerKinds(modelDirectory: URL) -> [CBv2LayerKind]? {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let textConfig = try? decodeTextConfiguration(configData: configData)
        else { return nil }
        return textConfig.cbv2LayerKinds
    }

    // MARK: - Steps

    /// Decode MLXLLM's `Gemma4TextConfiguration` from the VLM checkpoint's
    /// `text_config` block. The top-level `quantization` block is merged in
    /// so the configuration's informational `quantizationBits`/`GroupSize`
    /// fields reflect the checkpoint (they do not drive the skeleton's
    /// quantization — `applyQuantizationStructure` does).
    static func decodeTextConfiguration(configData: Data) throws -> Gemma4TextConfiguration {
        let root: [String: Any]
        do {
            guard
                let parsed = try JSONSerialization.jsonObject(with: configData)
                    as? [String: Any]
            else {
                throw EngineV2VLMTextExtractionError.invalidConfig("config.json is not an object")
            }
            root = parsed
        } catch let error as EngineV2VLMTextExtractionError {
            throw error
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig("parse config.json: \(error)")
        }
        guard var textConfigJSON = root["text_config"] as? [String: Any] else {
            throw EngineV2VLMTextExtractionError.invalidConfig("no text_config object")
        }
        if textConfigJSON["quantization"] == nil, let quantization = root["quantization"] {
            textConfigJSON["quantization"] = quantization
        }
        do {
            let textConfigData = try JSONSerialization.data(withJSONObject: textConfigJSON)
            return try JSONDecoder.json5().decode(Gemma4TextConfiguration.self, from: textConfigData)
        } catch {
            throw EngineV2VLMTextExtractionError.invalidConfig("decode text_config: \(error)")
        }
    }

    /// Re-key the wrapper's live parameter tree into the text model's key
    /// space and drop everything outside the language model (vision tower,
    /// multimodal embedder). The result then passes through the text
    /// model's own `sanitize`, which drops the k/v-projection duplicates
    /// the wrapper allocates for KV-shared layers (MLXLLM does not allocate
    /// those modules) and leaves everything else untouched.
    private static func reKeyedTextWeights(
        wrapper: MLXVLM.Gemma4, sanitizer: Gemma4TextModel
    ) -> [String: MLXArray] {
        var textWeights: [String: MLXArray] = [:]
        for (key, value) in wrapper.parameters().flattened() {
            guard key.hasPrefix(languageModelPrefix) else { continue }
            textWeights[String(key.dropFirst(languageModelPrefix.count))] = value
        }
        return sanitizer.sanitize(weights: textWeights)
    }

    /// Mirror `loadWeights`' quantization pass onto the skeleton: a module is
    /// quantized iff the (re-keyed, live) weights carry `<path>.scales`, with
    /// (groupSize, bits, mode) resolved from the checkpoint's per-layer table
    /// under the module's `language_model.`-prefixed checkpoint key — the
    /// exact lookup the wrapper's own load performed, so the two module trees
    /// can never disagree on quantization structure. All arrays involved stay
    /// lazy; `update(parameters:)` replaces them before anything evaluates.
    private static func applyQuantizationStructure(
        skeleton: Gemma4TextModel,
        weights: [String: MLXArray],
        perLayerQuantization: BaseConfiguration.PerLayerQuantization?
    ) throws {
        let hasQuantizedWeights = weights.keys.contains { $0.hasSuffix(".scales") }
        guard hasQuantizedWeights else { return }
        guard let perLayerQuantization else {
            throw EngineV2VLMTextExtractionError.missingQuantizationConfig
        }
        quantize(model: skeleton) { path, _ in
            guard weights["\(path).scales"] != nil else { return nil }
            return perLayerQuantization
                .quantization(layer: languageModelPrefix + path)?.asTuple
        }
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
    /// Ceiling on max |Δlogit| across the probe. Final logits are
    /// softcapped to ±`final_logit_softcapping` (30 on every Gemma 4
    /// checkpoint), so unrelated distributions differ by up to ~60;
    /// same-weights implementation noise measured ≤ ~8 (see below).
    static let parityMaxAbsLogitDiff: Float = 20

    /// One tiny forward through the wrapper's text path and the extracted
    /// model on identical tokens — a CATASTROPHIC-EXTRACTION detector, not
    /// a bit-parity check.
    ///
    /// Token-exact parity between the two is structurally unattainable
    /// (measured on gemma-4-26B-A4B qat-4bit, 2026-07):
    ///
    ///   * the two implementations have different bf16 kernel/fusion
    ///     orderings, giving ~0.5 max |Δlogit| even at position 0 (where
    ///     RoPE is the identity), which flips near-tie top-8-of-128 MoE
    ///     expert selections at later positions (~8 max |Δlogit|);
    ///   * MLXVLM's wrapper mis-implements the checkpoint's declared
    ///     `rope_type: "proportional"` for full-attention layers as an
    ///     HF-style truncated-dims partial RoPE (freqs /128, partner +64),
    ///     while MLXLLM's `ProportionalRoPE` implements the declared type
    ///     (freqs /512 over the full head, partner +256 — verified against
    ///     the mlx_lm Python reference). The extracted model keeps the
    ///     CORRECT scheme; the wrapper discrepancy is flagged upstream.
    ///
    /// What a correct extraction guarantees — and what this gate enforces —
    /// is that both models compute the same function up to implementation
    /// noise: each side's greedy argmax must sit inside the other side's
    /// top-`parityTopK` at EVERY position, and max |Δlogit| must stay under
    /// `parityMaxAbsLogitDiff`. A mis-extracted model (wrong keys, wrong
    /// quantization structure, wrong config) produces unrelated
    /// distributions and fails both with overwhelming probability. The
    /// probe is fixed and both models are deterministic, so for a given
    /// (checkpoint, binary) the gate either always passes or always fails —
    /// no per-load flakiness.
    private static func assertForwardParity(
        wrapper: MLXVLM.Gemma4, extracted: Gemma4TextModel, vocabSize: Int
    ) throws -> Float {
        // Fixed probe: small ids well inside every Gemma vocab; length stays
        // far under the sliding window so the check exercises both layer
        // types without materializing meaningful KV.
        let probeTokens = [2, 651, 6134, 1024, 578, 108, 2364].map {
            min($0, max(0, vocabSize - 1))
        }
        let inputs = MLXArray(probeTokens.map(Int32.init)).expandedDimensions(axis: 0)

        let wrapperLogits = wrapper(inputs, cache: nil).asType(.float32)
        let extractedLogits = extracted(inputs, cache: nil).asType(.float32)

        let k = parityTopK
        // Top-k token ids per position, [1, L, k] (unordered within k).
        let wrapperTopK = argPartition(-wrapperLogits, kth: k - 1, axis: -1)[.ellipsis, ..<k]
        let extractedTopK = argPartition(-extractedLogits, kth: k - 1, axis: -1)[.ellipsis, ..<k]
        let wrapperArgmax = argMax(wrapperLogits, axis: -1)
        let extractedArgmax = argMax(extractedLogits, axis: -1)
        let maxAbsDiff = MLX.abs(wrapperLogits - extractedLogits).max()
        eval(wrapperTopK, extractedTopK, wrapperArgmax, extractedArgmax, maxAbsDiff)

        let positions = probeTokens.count
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
        guard diff <= parityMaxAbsLogitDiff else {
            throw EngineV2VLMTextExtractionError.parityMismatch(
                "max |Δlogit| \(diff) exceeds \(parityMaxAbsLogitDiff) "
                    + "(argmax containment held — distributions drifted)")
        }
        return diff
    }
}
