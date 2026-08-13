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
    /// `snapshotContainer` measured), PLUS any `auxiliaryWeightBytes` folded
    /// in at construction (the MTP drafter's resident footprint — plan D5
    /// capacity truthfulness). Feeds the fleet KV budget
    /// (`UnifiedMemoryCap.kvBudgetBytes(residentWeightBytes:)`), re-slice
    /// grants, the heartbeat clamp, and StandaloneServer's mirrored budget:
    /// folding at construction means every consumer sees the sum with zero
    /// consumer-site changes.
    public let weightsBytes: Int
    /// Target container bytes only. Kept separately so a fail-open assistant
    /// load can remove its prospective charge before final re-slicing.
    public let targetWeightsBytes: Int
    /// Resident assistant estimate. Zero for target-only/fallback slots.
    public let auxiliaryWeightBytes: Int
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

    /// `auxiliaryWeightBytes`: resident weight bytes that live OUTSIDE the
    /// model container (the MTP drafter — never scanned, advertised, or
    /// attested), folded into `weightsBytes` here so all downstream memory
    /// accounting is truthful. Deliberately NOT an input to any KV-rate
    /// figure: the drafter writes no KV.
    public init(
        weightsBytes: Int,
        auxiliaryWeightBytes: Int = 0,
        fp16KVBytesPerToken: Int,
        maxContextLength: Int,
        defaultMaxTokens: Int
    ) {
        self.targetWeightsBytes = max(0, weightsBytes)
        self.auxiliaryWeightBytes = max(0, auxiliaryWeightBytes)
        let (total, overflow) = self.targetWeightsBytes.addingReportingOverflow(
            self.auxiliaryWeightBytes)
        self.weightsBytes = overflow ? Int.max : total
        self.fp16KVBytesPerToken = fp16KVBytesPerToken
        self.maxContextLength = maxContextLength
        self.defaultMaxTokens = defaultMaxTokens
    }

    /// Replace, rather than add to, the auxiliary charge. This is the only
    /// legal transition from a pre-admission candidate estimate to the bytes
    /// of an actually retained assistant.
    public func replacingAuxiliaryWeightBytes(_ bytes: UInt64) -> SlotSizingSnapshot {
        SlotSizingSnapshot(
            weightsBytes: targetWeightsBytes,
            auxiliaryWeightBytes: Int(min(bytes, UInt64(Int.max))),
            fp16KVBytesPerToken: fp16KVBytesPerToken,
            maxContextLength: maxContextLength,
            defaultMaxTokens: defaultMaxTokens)
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
    ///   - auxiliaryWeightBytes: non-snapshot resident weight bytes (the MTP
    ///     drafter estimate: file bytes × the standard 1.2 factor — sizing
    ///     runs before the drafter loads). Folded into `weightsBytes`; never
    ///     touches the KV-rate derivation below.
    public static func build(
        container: ModelContainer,
        modelPath: URL?,
        fallbackDefaultMaxTokens: Int,
        auxiliaryWeightBytes: Int = 0
    ) async -> SlotSizingSnapshot {
        struct ModuleFacts: @unchecked Sendable {
            let bytes: Int
            let moduleKVRate: Int?
            let isQwenVLMWrapper: Bool
        }
        let facts = await container.perform { ctx -> ModuleFacts in
            let bytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            // Engine truth first: the CBv2-adapted families expose their own
            // layer kinds (GPT-OSS derives them from the LOADED trunk, so
            // they are congruent with the actual layers even when config.json
            // omits `layer_types`).
            let rate: Int?
            switch ctx.model {
            case let gemma as Gemma4TextModel:
                rate = fp16KVBytesPerToken(layerKinds: gemma.cbv2LayerKinds)
            case let gptoss as GPTOSSModel:
                rate = fp16KVBytesPerToken(layerKinds: gptoss.cbv2LayerKinds)
            case let gemma as MLXVLM.Gemma4:
                // Direct ownership makes the loaded tower engine truth with
                // no config re-decode or second topology that can drift.
                rate = fp16KVBytesPerToken(layerKinds: gemma.textModel.cbv2LayerKinds)
            case let qwen as Qwen35MoEModel:
                rate = fp16KVBytesPerToken(layerKinds: qwen.cbv2LayerKinds)
            case is MLXVLM.Qwen35MoE:
                return ModuleFacts(
                    bytes: bytes,
                    moduleKVRate: nil,
                    isQwenVLMWrapper: true)
            default:
                rate = nil
            }
            return ModuleFacts(
                bytes: bytes,
                moduleKVRate: rate,
                isQwenVLMWrapper: false)
        }

        // Architecture metadata (context window + non-CBv2 fallback rate)
        // comes from the same config parse the load-gate estimate uses.
        let architecture: ModelArchitecture
        if let modelPath {
            architecture = KVEstimation.parseModelArchitecture(
                at: modelPath.appendingPathComponent("config.json"))
        } else {
            architecture = .empty
        }

        var kvRate = facts.moduleKVRate ?? 0
        if kvRate <= 0, facts.isQwenVLMWrapper, let modelPath {
            kvRate = qwenVLMTextKVRate(modelDirectory: modelPath) ?? 0
        }
        if kvRate <= 0 {
            // Non-CBv2 module: fall back to the config-parse figure so
            // callers that only need a rough rate still get one. Such a
            // model cannot build a v2 engine and is refused at load.
            kvRate = KVEstimation.resolvedKVBytesPerToken(
                architecture: architecture, weightBytes: facts.bytes)
        }

        let maxContext = architecture.maxContextLength ?? 0
        let defaultMaxTokens = maxContext > 0
            ? min(maxContext, 8192)
            : fallbackDefaultMaxTokens

        return SlotSizingSnapshot(
            weightsBytes: facts.bytes,
            auxiliaryWeightBytes: auxiliaryWeightBytes,
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

    static func qwenVLMTextKVRate(modelDirectory: URL) -> Int? {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL) else { return nil }
        guard let textConfig = try? EngineV2VLMTextExtraction.decodeQwenTextConfiguration(
            configData: configData)
        else { return nil }
        // Config-only sizing must not instantiate a target module: that would
        // allocate a second skeleton before extraction.
        return fp16KVBytesPerToken(layerKinds: textConfig.cbv2LayerKinds)
    }
}
