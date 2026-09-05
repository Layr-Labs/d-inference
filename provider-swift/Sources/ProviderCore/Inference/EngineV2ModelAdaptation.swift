// Copyright © 2026 Eigen Labs.
//
// The ONE family-typed seam left in Darkbloom, and the reason it is still
// here (Darkbloom runner contract §3, §14).
//
// The contract's end state is that Darkbloom names no model family: the
// provider resolves `RunnerRegistry.resolve(modelType:)`, calls
// `Runner.load(directory, options)`, and builds the engine with
// `runner.makeEngine(EngineBuild(...))` — see `EngineV2RunnerBuild.swift`,
// which is that path, complete. What blocks the SERVING slot from taking it
// today is the LOADER, not the engine: `Runner.load` loads the checkpoint
// itself, while the provider's slot lifecycle (`ProviderLoop
// .ensureModelLoaded`, `StandaloneServer`, `SlotSizingSnapshot`,
// `EngineV2VisionPrefill`, the idle-unload and re-slice accounting) is built
// around an `MLXLMCommon.ModelContainer` that is already resident by the
// time any engine is constructed. Calling `Runner.load` there would load a
// SECOND copy of the weights, which the weights-load-once rule forbids.
//
// So the families that load through `ModelContainerLoading` keep a typed
// adaptation, and it lives HERE — in one file, off the engine factory and
// off the slot factory — instead of in three switches that could drift.
// Everything it answers is read off the model's own CBv2 hooks; nothing is
// re-derived. When the loader moves behind the registry this file is
// DELETED, not extended: a new family belongs in a runner in the fork.
//
// Qwen 3.8 Flash-Next is deliberately absent. Its forward pass cannot run
// without the n-gram row source, which arrives through
// `RunnerLoadOptions.resources` at `Runner.load` and has no container-path
// equivalent; a typed arm here would look like support that does not exist.
// It is served by `Qwen4ExpRunner` through `EngineV2RunnerBuild`.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

enum EngineV2ModelAdaptation {

    /// The `model_type`s `adapt` can actually serve over an already-resident
    /// `ModelContainer`, and therefore the ones the provider may advertise
    /// while the slot lifecycle still loads that way.
    ///
    /// This set exists ONLY because the two halves are out of step for one
    /// release: `RunnerRegistry` claims every `model_type` a runner can
    /// serve, and three of them (`qwen3_5_text`, `qwen4_exp`,
    /// `qwen4_exp_text`) resolve to a module `adapt` has no arm for.
    /// Advertising those would turn a clean 404 at the advertise gate into a
    /// load-then-503 that the coordinator reroutes to another provider which
    /// fails the same way. The registry stays the authority on what a runner
    /// serves; this is the narrower question of what THIS provider can build
    /// today, and it is deleted with the rest of the file when the slot
    /// lifecycle loads through `Runner.load`.
    static let containerServableModelTypes: Set<String> = [
        "gemma4", "gemma4_text",  // Gemma4TextModel, or the VLM wrapper's tower
        "gpt_oss",  // GPTOSSModel
        "qwen3_5", "qwen3_5_moe",  // Qwen35Model and its MoE subclass
        "qwen3_vl", "qwen3_vl_moe",  // the MLXVLM.Qwen3VL wrapper, served directly
    ]

    /// Everything the engine needs from the loaded module: its per-layer
    /// attention structure, what the engine may switch on, and the model's
    /// own cache construction funnel.
    struct Adaptation {
        let layerKinds: [CBv2LayerKind]
        let capabilities: CBv2ModelCapabilities
        /// `newCacheV2` stays the single cache-construction funnel on BOTH
        /// backends — GPT-OSS primes its sinks-activation probe inside it
        /// (one host readback per layer, at build time, never on the step
        /// path).
        let newCaches:
            ((Int, CBv2LayerKind) -> any CBv2AttendingLayerCache)
                throws -> [any CBv2AttendingLayerCache]
    }

    /// Adapt a loaded module, or refuse. The refusal is the same
    /// `unsupportedModel` the advertise gate makes unreachable in practice
    /// and that is kept as loud insurance.
    static func adapt(model: any LanguageModel) throws -> Adaptation {
        switch model {
        case let gemma as Gemma4TextModel:
            return Adaptation(
                layerKinds: gemma.cbv2LayerKinds,
                capabilities: .attentionOnly,
                newCaches: { make in try gemma.newCacheV2(makeLayerCache: make) })
        case let gptoss as GPTOSSModel:
            return Adaptation(
                layerKinds: gptoss.cbv2LayerKinds,
                capabilities: .attentionOnly,
                newCaches: { make in gptoss.newCacheV2(makeLayerCache: make) })
        case let qwen as Qwen35Model:
            return Adaptation(
                layerKinds: qwen.cbv2LayerKinds,
                capabilities: qwen.cbv2Capabilities,
                newCaches: { make in qwen.newCacheV2(makeLayerCache: make) })
        case let qwen as MLXVLM.Qwen3VL:
            return Adaptation(
                layerKinds: qwen.cbv2LayerKinds,
                capabilities: qwen.cbv2Capabilities,
                newCaches: { make in qwen.newCacheV2(makeLayerCache: make) })
        default:
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
    }

    /// The model's CBv2 layer kinds, or nil for a non-adapted family (which
    /// throws `unsupportedModel` at engine construction anyway). Needed by
    /// the SSD prefix cache's construction (layout-epoch binding + adoption
    /// bound) before any engine exists.
    static func layerKinds(model: any LanguageModel) -> [CBv2LayerKind]? {
        (try? adapt(model: model))?.layerKinds
    }

    /// The model's prefix-cache adoption bound (`PrefixCachePolicy
    /// .adoptionBoundTokens` over the model's own `cbv2LayerKinds`).
    /// A family that declares no prefix reuse returns 0 — treated as "fund"
    /// by the gate (pure-full-attention semantics), and such a model is
    /// refused before any cache matters anyway.
    static func adoptionBoundTokens(model: any LanguageModel) -> Int {
        guard let adaptation = try? adapt(model: model) else { return 0 }
        guard adaptation.capabilities.supportsPrefixReuse else { return 0 }
        return PrefixCachePolicy.adoptionBoundTokens(
            layerKinds: adaptation.layerKinds)
    }

    /// Resolve the exact module instance served by CBv2. Gemma 4 VLM owns
    /// its `Gemma4TextModel`; direct VLM forwards and CBv2 therefore share
    /// one language tower, one parameter tree, and one residency footprint.
    /// Qwen3-VL exposes its CBv2 language hooks on the wrapper itself, so
    /// the wrapper is the direct serving model and retains vision/DeepStack
    /// state. The runner-path equivalent is `runner.servingModel`.
    static func directServingModel(
        model: any LanguageModel, isVLM: Bool
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        if model is MLXVLM.Qwen3VL { return model }
        guard let gemma4 = model as? MLXVLM.Gemma4 else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        return gemma4.textModel
    }

    /// Whether this model's OWNING full-attention rows are stored fp32 on
    /// the contiguous backend, on top of the all-fp16 sizing snapshot. The
    /// slot's advertised `kv_bytes_per_token` has to charge what a token
    /// actually costs, so this is a storage fact about the family, not a
    /// policy.
    static func usesFP32FullAttentionRows(model: any LanguageModel) -> Bool {
        model is GPTOSSModel
    }

    /// Dense Qwen 3.5/3.8 has no routed-expert tile geometry to preserve, so
    /// it takes a larger solo prefill stripe than the MoE default: a longer
    /// stripe amortizes the repeated weight reads and dispatch overhead of
    /// long recurrent prefills while the scheduler's solo gate keeps it away
    /// from decode work. The MoE target subclasses the dense class, so the
    /// subclass is tested first.
    static func prefersDenseQwenSoloPrefillStripe(
        model: (any LanguageModel)?
    ) -> Bool {
        guard let model else { return false }
        return model is Qwen35Model && !(model is Qwen35MoEModel)
    }

    /// One load-time snapshot of the Gemma 4 optimization controls, or nil
    /// for every other family. Never arms the benchmark counters: the QMM
    /// hot path stays free of counter atomics.
    static func gemmaOptimizationReport(
        model: any LanguageModel
    ) -> GemmaOptimizationReport? {
        guard let gemmaModel = model as? Gemma4TextModel else { return nil }
        let r1 = GPU.gemma4ExpertQMMDiagnostics()
        let layerInterval = gemmaModel.cbv2PrefillChunkEvalInterval
        return GemmaOptimizationReport(
            layer18Requested: layerInterval > 0,
            layer18Effective:
                layerInterval > 0
                && gemmaModel.cbv2LayerKinds.count >= layerInterval,
            weightedUnsortRequested: gemmaModel.weightedExpertUnsortRequested,
            weightedUnsortEffective: gemmaModel.weightedExpertUnsortEffective,
            safeR1Requested: r1.requested,
            safeR1GeometryEligible: gemmaModel.expertQMMGeometryEligible,
            safeR1AOTAvailable: r1.aotAvailable,
            safeR1NAXAvailable: r1.naxAvailable)
    }
}
