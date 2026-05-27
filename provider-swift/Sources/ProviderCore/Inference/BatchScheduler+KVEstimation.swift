// Copyright © 2026 Eigen Labs.
//
// Pure, actor-state-free helpers that read a model's `config.json` and
// turn the architecture metadata into a per-token KV-cache cost in
// bytes. The result drives `BatchScheduler.tokenBudgetMax`, which gates
// admission.
//
// All functions are `static` on the `KVEstimation` enum (no instance,
// no actor isolation). The closure inside `loadModel` calls these
// directly without bouncing off the actor.
//
// `BatchScheduler` extends with a couple of static convenience
// shims (`resolvedKVBytesPerToken`, `resolvedMaxTokens`) that take
// scheduler-specific defaults and forward into this namespace.

import Foundation

/// Namespace for KV-cache cost estimation. Pure functions only; no
/// actor state, no global mutation.
enum KVEstimation {

    // MARK: - Tunables

    /// Maximum bytes we'll read from a `config.json` file. The model
    /// directory is operator-writable; a malicious or corrupt config
    /// could otherwise be used to OOM the parser.
    static let maxConfigJSONBytes = 4 * 1024 * 1024

    /// Architectural fields are clamped against these bounds before
    /// being used in KV-byte arithmetic. Higher than any real model,
    /// low enough to prevent integer overflow.
    private static let maxLayersBound = 1024
    private static let maxHeadsBound = 1024
    private static let maxHeadDimBound = 2048

    /// Recurrent-state layer types (Mamba, GatedDeltaNet) hold a fixed
    /// state per request, not per-token KV. They contribute 0 to the
    /// per-token KV-byte cost.
    private static let recurrentLayerTypes: Set<String> = [
        "linear_attention",   // Qwen3.5 GatedDeltaNet
        "recurrent",
    ]

    // MARK: - config.json read

    /// Read up to `maxConfigJSONBytes` from `url`. Returns `nil` if the
    /// file is missing, unreadable, or exceeds the cap.
    static func readBoundedConfigJSON(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxConfigJSONBytes + 1),
              data.count <= maxConfigJSONBytes else { return nil }
        return data
    }

    // MARK: - Architecture parsing

    /// Parse architecture metadata from `<modelDir>/config.json`.
    ///
    /// Covers:
    ///   - Standard transformer fields (`num_hidden_layers`,
    ///     `num_key_value_heads`, `head_dim`, `hidden_size`).
    ///   - Hybrid attention (Gemma 4, Gemma 3n): `num_kv_shared_layers`,
    ///     `global_head_dim`, `num_global_key_value_heads`,
    ///     `sliding_window_pattern`, `layer_types`.
    ///   - VLMs (Gemma 4) that wrap the text model under `text_config`.
    ///
    /// Returns `.empty` when the config can't be read or parsed.
    /// All numeric fields are clamped to defend against malicious or
    /// corrupt configs in operator-writable model directories.
    static func parseModelArchitecture(at configURL: URL) -> ModelArchitecture {
        guard let data = readBoundedConfigJSON(configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        // Gemma 4 VLM wraps the text model under `text_config`.
        let cfg: [String: Any] = (json["text_config"] as? [String: Any]) ?? json

        var numLayers: Int? = cfg["num_hidden_layers"] as? Int
        var kvHeads: Int? = cfg["num_key_value_heads"] as? Int
            ?? cfg["num_attention_heads"] as? Int  // MHA fallback

        var headDim: Int? = cfg["head_dim"] as? Int
        if headDim == nil,
           let hs = cfg["hidden_size"] as? Int,
           let nh = cfg["num_attention_heads"] as? Int, nh > 0 {
            headDim = hs / nh
        }

        // Hybrid-attention fields (Gemma 4, Gemma 3n).
        var numKvSharedLayers: Int = cfg["num_kv_shared_layers"] as? Int ?? 0
        var globalHeadDim: Int? = cfg["global_head_dim"] as? Int
        var numGlobalKvHeads: Int? = cfg["num_global_key_value_heads"] as? Int
        // `sliding_window_pattern=5` → repeating [S, S, S, S, F].
        var slidingWindowPattern: Int? = cfg["sliding_window_pattern"] as? Int
        var layerTypes: [String]? = cfg["layer_types"] as? [String]

        // Clamp against a malicious config.json (operator-writable dir)
        // that would otherwise inflate the token budget unbounded.
        if let l = numLayers { numLayers = min(max(l, 1), maxLayersBound) }
        if let h = kvHeads { kvHeads = min(max(h, 1), maxHeadsBound) }
        if let hd = headDim { headDim = min(max(hd, 1), maxHeadDimBound) }
        if let ghd = globalHeadDim { globalHeadDim = min(max(ghd, 1), maxHeadDimBound) }
        if let gkh = numGlobalKvHeads { numGlobalKvHeads = min(max(gkh, 1), maxHeadsBound) }
        if let l = numLayers {
            numKvSharedLayers = min(max(numKvSharedLayers, 0), l)
        } else {
            numKvSharedLayers = max(numKvSharedLayers, 0)
        }
        if let swp = slidingWindowPattern {
            let upperBound = numLayers ?? maxLayersBound
            slidingWindowPattern = min(max(swp, 0), upperBound)
        }
        if let lt = layerTypes, let l = numLayers, lt.count > l {
            layerTypes = Array(lt.prefix(l))
        }

        // Context length: `max_position_embeddings` is canonical for modern
        // transformers (Llama, Qwen, Gemma, Mistral). Fallbacks cover
        // older model configs that use different field names.
        var maxContextLength: Int? = cfg["max_position_embeddings"] as? Int
            ?? cfg["max_sequence_length"] as? Int
            ?? cfg["n_positions"] as? Int
            ?? cfg["seq_length"] as? Int
        // Clamp to a sane range (1 to 2M tokens).
        if let mcl = maxContextLength {
            maxContextLength = min(max(mcl, 1), 2_097_152)
        }

        return ModelArchitecture(
            numLayers: numLayers,
            kvHeads: kvHeads,
            headDim: headDim,
            numKvSharedLayers: numKvSharedLayers,
            globalHeadDim: globalHeadDim,
            numGlobalKvHeads: numGlobalKvHeads,
            slidingWindowPattern: slidingWindowPattern,
            layerTypes: layerTypes,
            maxContextLength: maxContextLength
        )
    }

    // MARK: - KV cost computation

    /// Compute total KV cache bytes per token across all layers, accounting
    /// for architecture-specific differences:
    ///
    /// - **KV sharing** (Gemma 4, Gemma 3n): only the first
    ///   `numLayers - numKvSharedLayers` layers allocate real KV caches.
    /// - **Hybrid attention** (Gemma 4, GPT-OSS): sliding-attention layers
    ///   use `headDim` / `kvHeads`, while full-attention layers can use
    ///   `globalHeadDim` / `numGlobalKvHeads`.
    /// - **Standard models** (Llama, Qwen, Mistral, Gemma 2): all layers
    ///   are uniform; degenerates to `cachedLayers * kvHeads * headDim * 4`.
    static func computeKVBytesPerToken(
        numLayers: Int,
        kvHeads: Int,
        headDim: Int,
        numKvSharedLayers: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        slidingWindowPattern: Int?,
        layerTypes: [String]?
    ) -> Int {
        let bytesPerElement = 2  // float16
        let kvTensors = 2        // K + V

        let cachedLayers = numLayers - numKvSharedLayers
        guard cachedLayers > 0 else { return 0 }

        let resolvedLayerTypes = resolveLayerTypes(
            cachedLayers: cachedLayers,
            layerTypes: layerTypes,
            slidingWindowPattern: slidingWindowPattern
        )

        let hasHybridDims = globalHeadDim != nil && globalHeadDim != headDim
            || numGlobalKvHeads != nil && numGlobalKvHeads != kvHeads

        if let types = resolvedLayerTypes {
            return totalHybridBytesPerToken(
                cachedLayers: cachedLayers,
                layerTypes: types,
                kvHeads: kvHeads,
                headDim: headDim,
                globalHeadDim: globalHeadDim,
                numGlobalKvHeads: numGlobalKvHeads,
                hasHybridDims: hasHybridDims,
                bytesPerElement: bytesPerElement,
                kvTensors: kvTensors
            )
        }

        // Hybrid dims but no per-layer types: conservatively use the
        // larger dimension across all cached layers.
        if let ghd = globalHeadDim, ghd > headDim {
            let maxKvHeads = max(kvHeads, numGlobalKvHeads ?? kvHeads)
            return cachedLayers * maxKvHeads * ghd * kvTensors * bytesPerElement
        }

        // Uniform full-attention (Llama, Qwen, Mistral, Gemma 2).
        return cachedLayers * kvHeads * headDim * kvTensors * bytesPerElement
    }

    // MARK: - Internal helpers

    /// Derive a per-layer attention type list from one of:
    ///   1. an explicit `layer_types` array (Gemma 4, GPT-OSS)
    ///   2. `slidingWindowPattern=N` → repeating [S, ..., S, F] of length N
    ///   3. neither → `nil` (caller falls back to uniform full-attention)
    private static func resolveLayerTypes(
        cachedLayers: Int,
        layerTypes: [String]?,
        slidingWindowPattern: Int?
    ) -> [String]? {
        if let lt = layerTypes, lt.count >= cachedLayers {
            return lt
        }
        guard let swp = slidingWindowPattern, swp > 1 else {
            return nil
        }
        var pattern = [String]()
        for i in 0..<swp {
            pattern.append(i == swp - 1 ? "full_attention" : "sliding_attention")
        }
        var types = [String]()
        while types.count < cachedLayers {
            types.append(contentsOf: pattern)
        }
        return Array(types.prefix(cachedLayers))
    }

    /// Sum per-layer KV bytes for hybrid-attention models, skipping
    /// recurrent layers (which hold a fixed state, not per-token KV).
    /// Compute KV bytes per token for hybrid-attention models.
    ///
    /// Only **full-attention** layers contribute a per-token cost (their KV
    /// cache grows linearly with sequence length). Sliding-attention layers
    /// have a **fixed** KV cache (window × per-layer bytes) that does NOT
    /// grow with sequence length. Counting them in the per-token cost
    /// overestimates by up to 2x for models like GPT-OSS 20B (50% sliding)
    /// and Gemma 4 (similar hybrid layout).
    private static func totalHybridBytesPerToken(
        cachedLayers: Int,
        layerTypes: [String],
        kvHeads: Int,
        headDim: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        hasHybridDims: Bool,
        bytesPerElement: Int,
        kvTensors: Int
    ) -> Int {
        var totalBytesPerToken = 0
        for i in 0..<cachedLayers {
            let layerType = layerTypes[i]
            if recurrentLayerTypes.contains(layerType) {
                continue
            }
            // Sliding-attention layers have a fixed-size KV cache (bounded
            // by the window size). Their per-token marginal cost is zero
            // once the window fills -- they do NOT grow the KV cache with
            // sequence length. Only full-attention layers contribute.
            if slidingLayerTypes.contains(layerType) {
                continue
            }

            let layerKvHeads: Int
            let layerHeadDim: Int

            if hasHybridDims && layerType == "full_attention" {
                layerKvHeads = numGlobalKvHeads ?? kvHeads
                layerHeadDim = globalHeadDim ?? headDim
            } else {
                layerKvHeads = kvHeads
                layerHeadDim = headDim
            }

            totalBytesPerToken += layerKvHeads * layerHeadDim * kvTensors * bytesPerElement
        }
        return totalBytesPerToken
    }

    private static let slidingLayerTypes: Set<String> = [
        "sliding_attention",
        "local_sliding_attention",
    ]
}

// MARK: - BatchScheduler convenience shims
//
// These live on `BatchScheduler` so the call sites in `loadModel` /
// `submit` read naturally (`Self.resolvedKVBytesPerToken(...)`), while
// the implementations stay namespaced under `KVEstimation`.

extension BatchScheduler {

    /// Default `max_tokens` resolution: caller-requested or scheduler
    /// default. Trivial helper, kept static so the closure in `submit`
    /// can call it without actor hop.
    static func resolvedMaxTokens(requested: Int?, defaultMaxTokens: Int) -> Int {
        requested ?? defaultMaxTokens
    }

    /// Decide per-token KV cost from architecture metadata, falling back
    /// to a weight-bytes heuristic when config.json is unavailable OR
    /// when config-derived numbers are implausibly small (which would
    /// otherwise inflate the token budget and OOM the GPU).
    static func resolvedKVBytesPerToken(
        architecture: ModelArchitecture,
        weightBytes: Int
    ) -> Int {
        let estimatedKV: Int
        if let layers = architecture.numLayers,
           let kvH = architecture.kvHeads,
           let hd = architecture.headDim,
           layers > 0, kvH > 0, hd > 0 {
            estimatedKV = KVEstimation.computeKVBytesPerToken(
                numLayers: layers,
                kvHeads: kvH,
                headDim: hd,
                numKvSharedLayers: architecture.numKvSharedLayers,
                globalHeadDim: architecture.globalHeadDim,
                numGlobalKvHeads: architecture.numGlobalKvHeads,
                slidingWindowPattern: architecture.slidingWindowPattern,
                layerTypes: architecture.layerTypes
            )
        } else {
            estimatedKV = max(weightBytes / 25_000, 100_000)
        }

        // Floor: real models exceed ~1000 B/token. A smaller value means
        // config.json is wrong; fall back to the heuristic to avoid an
        // OOM-inducing token budget.
        let kvFloor = 1_000
        if estimatedKV < kvFloor && architecture.numLayers != nil {
            let heuristicKV = max(weightBytes / 25_000, 100_000)
            FileHandle.standardError.write(Data(
                "[WARN] config.json produced implausibly small kvBytesPerToken=\(estimatedKV); falling back to heuristic=\(heuristicKV)\n".utf8
            ))
            return heuristicKV
        }
        return estimatedKV
    }

    // MARK: - Test shim
    //
    // `BatchingTests.swift` accesses these via `BatchScheduler.<name>`;
    // forward into `KVEstimation` so the test file doesn't need to know
    // about the namespace split.
    static var maxConfigJSONBytes: Int { KVEstimation.maxConfigJSONBytes }

    static func readBoundedConfigJSON(_ url: URL) -> Data? {
        KVEstimation.readBoundedConfigJSON(url)
    }
}
