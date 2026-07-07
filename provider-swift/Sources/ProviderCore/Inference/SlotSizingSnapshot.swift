// Copyright © 2026 Eigen Labs.
//
// Scheduler-free sizing snapshot for a v2 model slot (v0.7.5 one-engine
// release). Replaces the sizing the v2 path used to parasitize from the
// always-constructed legacy `BatchScheduler` (`snapshotContainer` +
// `applyPostLoadBudgets`): weight bytes, the fp16 per-token KV rate, the
// model's context window, and the default max-token budget — everything the
// slot lifecycle (KV re-slicing, bridge construction, heartbeat capacity,
// vision reservations) needs, with no `BatchScheduler` in the loop.
//
// KV rate derivation — ENGINE TRUTH, not a config re-derivation: the rate is
// computed from the model's own `cbv2LayerKinds` (the same per-layer
// structure `AdmissionV2` charges against) using the same arithmetic as
// `AdmissionV2.estimatedBytes`:
//
//     bytes(T) = Σ over storage-owning layers of
//                  retained(T) × 2(K+V) × kvHeads × headDim × 2(fp16)
//     where retained(T) = T for full-attention layers
//                       = min(T, window) for sliding-window layers
//
// The PER-TOKEN rate reported here is the long-context marginal rate
// (d bytes/dT once every sliding window has plateaued): only FULL-attention
// non-shared layers contribute. That is deliberately the same convention as
// `KVEstimation.computeKVBytesPerToken` (the config.json parse the load gate
// keeps using as its pre-load estimate), and a drift unit test pins the two
// against each other for both production families (gpt_oss, gemma4).

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Immutable sizing facts for one loaded model slot.
public struct SlotSizingSnapshot: Sendable, Equatable {
    /// Σ parameter nbytes over the loaded container (same figure the legacy
    /// `snapshotContainer` measured). Feeds the fleet KV budget
    /// (`UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes:)`).
    public let weightsBytes: Int
    /// fp16 per-token KV cost (bytes/token), engine-truth marginal rate —
    /// see the header. 0 = unknown (non-CBv2 family; such models are not
    /// advertised and cannot serve, but the snapshot itself never fails).
    public let fp16KVBytesPerToken: Int
    /// The model's configured context window (`max_position_embeddings`),
    /// or 0 when unknown. Bounds re-slice weights and vision KV clamps.
    public let maxContextLength: Int
    /// Default `max_tokens` for requests that omit it: `min(context, 8192)`
    /// when the context is known, else the provider default (mirrors the
    /// legacy `applyPostLoadBudgets` policy).
    public let defaultMaxTokens: Int

    public init(
        weightsBytes: Int,
        fp16KVBytesPerToken: Int,
        maxContextLength: Int,
        defaultMaxTokens: Int
    ) {
        self.weightsBytes = weightsBytes
        self.fp16KVBytesPerToken = fp16KVBytesPerToken
        self.maxContextLength = maxContextLength
        self.defaultMaxTokens = defaultMaxTokens
    }

    // MARK: - Builder

    /// Snapshot the loaded container. Runs the weight walk inside
    /// `container.perform` (off-actor, exactly like the legacy
    /// `snapshotContainer`); config.json reads happen after.
    ///
    /// - Parameters:
    ///   - container: the just-loaded model container.
    ///   - modelPath: the checkpoint directory (for `config.json`).
    ///   - fallbackDefaultMaxTokens: the provider-wide default max-token
    ///     budget used when the model's context window is unknown.
    public static func build(
        container: ModelContainer,
        modelPath: URL?,
        fallbackDefaultMaxTokens: Int
    ) async -> SlotSizingSnapshot {
        struct ModuleFacts: @unchecked Sendable {
            let bytes: Int
            let moduleKVRate: Int?
            let isGemma4VLMWrapper: Bool
        }
        let facts = await container.perform { ctx -> ModuleFacts in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            // Engine truth first: the CBv2-adapted families expose their own
            // layer kinds (GPT-OSS derives them from the LOADED trunk, so
            // they are congruent with the actual layers even when config.json
            // omits `layer_types`).
            var rate: Int? = nil
            var isWrapper = false
            switch ctx.model {
            case let gemma as Gemma4TextModel:
                rate = fp16KVBytesPerToken(layerKinds: gemma.cbv2LayerKinds)
            case let gptoss as GPTOSSModel:
                rate = fp16KVBytesPerToken(layerKinds: gptoss.cbv2LayerKinds)
            case is MLXVLM.Gemma4:
                // The VLM wrapper has no CBv2 hooks; its extracted text model
                // does. Derive from the checkpoint's text_config below (the
                // SAME decoder the extraction uses, so the kinds equal what
                // the extracted model will report).
                isWrapper = true
            default:
                break
            }
            return ModuleFacts(bytes: bytes, moduleKVRate: rate, isGemma4VLMWrapper: isWrapper)
        }

        // Architecture metadata (context window + the config-parse fallback
        // rate) from config.json — the same parse the load-gate estimate uses.
        let architecture: ModelArchitecture
        if let modelPath {
            architecture = KVEstimation.parseModelArchitecture(
                at: modelPath.appendingPathComponent("config.json"))
        } else {
            architecture = .empty
        }

        var kvRate = facts.moduleKVRate ?? 0
        if kvRate <= 0, facts.isGemma4VLMWrapper, let modelPath {
            kvRate = gemma4VLMTextKVRate(modelDirectory: modelPath) ?? 0
        }
        if kvRate <= 0 {
            // Non-CBv2 module (or a wrapper whose text_config failed to
            // decode): fall back to the config-parse figure so callers that
            // only need a rough rate (vision reservations in tests) still
            // get one. Such a model cannot build a v2 engine and is refused
            // at load — this value never sizes a real engine grant.
            kvRate = BatchScheduler.resolvedKVBytesPerToken(
                architecture: architecture, weightBytes: facts.bytes)
        }

        let maxContext = architecture.maxContextLength ?? 0
        let defaultMaxTokens = maxContext > 0
            ? min(maxContext, 8192)
            : fallbackDefaultMaxTokens

        return SlotSizingSnapshot(
            weightsBytes: facts.bytes,
            fp16KVBytesPerToken: kvRate,
            maxContextLength: maxContext,
            defaultMaxTokens: defaultMaxTokens
        )
    }

    // MARK: - KV rate arithmetic (engine truth)

    /// fp16 per-token KV rate from CBv2 layer kinds — the long-context
    /// marginal rate of `AdmissionV2.estimatedBytes`: KV-shared layers own
    /// no storage; sliding-window layers plateau at their window (zero
    /// marginal cost); full-attention layers grow `2(K+V) × kvHeads ×
    /// headDim × 2(fp16)` bytes per token forever. Pure; unit-tested against
    /// the config.json parse (`KVEstimation`) for both production families.
    public static func fp16KVBytesPerToken(layerKinds: [CBv2LayerKind]) -> Int {
        var perToken = 0
        for kind in layerKinds where kind.sharesKVWithLayer == nil {
            guard case .full = kind.attention else { continue }
            perToken += 2 * kind.kvHeads * kind.headDim * 2
        }
        return perToken
    }

    /// Total fp16 KV bytes retained after `tokens` tokens of one sequence —
    /// the EXACT `AdmissionV2.estimatedBytes` arithmetic (window plateaus
    /// included), reproduced for sizing decisions that want the absolute
    /// figure rather than the marginal rate.
    public static func estimatedKVBytes(layerKinds: [CBv2LayerKind], tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        var total = 0
        for kind in layerKinds where kind.sharesKVWithLayer == nil {
            let retained: Int
            switch kind.attention {
            case .full: retained = tokens
            case .slidingWindow(let window): retained = min(tokens, window)
            }
            total += retained * 2 * kind.kvHeads * kind.headDim * 2
        }
        return total
    }

    /// CBv2 layer kinds for a Gemma 4 VLM checkpoint's TEXT model, decoded
    /// from `config.json`'s `text_config` with the same decoder the
    /// weight-sharing extraction uses (`EngineV2VLMTextExtraction`), so the
    /// kinds equal what the extracted `Gemma4TextModel` will report.
    static func gemma4VLMTextKVRate(modelDirectory: URL) -> Int? {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let textConfig = try? EngineV2VLMTextExtraction.decodeTextConfiguration(
                configData: configData)
        else { return nil }
        return fp16KVBytesPerToken(layerKinds: textConfig.cbv2LayerKinds)
    }
}
