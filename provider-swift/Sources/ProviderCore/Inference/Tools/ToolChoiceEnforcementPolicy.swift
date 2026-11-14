// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Selects the enforcement boundary for forced tool choices. Gemma keeps its
/// token-level grammar and GPT-OSS frames its Harmony call in the sampler;
/// supported native structured formats are prompt-forced. Every forced call is
/// then rejected fail-closed unless parsing, function selection, and schema
/// validation all succeed before any call is exposed to the client.
enum ToolChoiceEnforcementPolicy {
    enum Strategy: Equatable {
        case none
        case gemmaGrammar
        case structuredPostValidation
        /// GPT-OSS: the sampler frames the Harmony call after the analysis
        /// message (`GPTOSSForcedToolConstraint`); the call is still parsed
        /// and validated before it is exposed.
        case harmonyFraming
    }

    /// Per-model wire capability, never inferred from a caller's model label.
    /// Other families retain their existing media/grammar behavior until their
    /// complete forced-choice and tool-result-media paths are qualified. The
    /// managed Super owner renders media requests from the same plan as text
    /// (`NemotronSuperRequestPlan`): forced calls are prompt-forced and
    /// withheld until they validate, and the pinned template renders media in
    /// tool results.
    static func advertisesNativeMediaTools(for model: ModelInfo) -> Bool {
        let family = model.modelType == "diffusion_gemma" || servesMediaWithTextControls(model)
        return family && model.isVision == true
            && model.templateRenderOK == true && advertisesCapability(for: model)
    }

    /// Per-model wire capability (`native_media_controls`): a JSON response
    /// format and non-empty tools are served together with image or video
    /// input. Only the managed Super owner, whose media route takes the text
    /// route's request plan, with the same vision and template checks as
    /// `advertisesNativeMediaTools`.
    static func advertisesNativeMediaControls(for model: ModelInfo) -> Bool {
        servesMediaWithTextControls(model) && model.isVision == true
            && model.templateRenderOK == true && advertisesCapability(for: model)
    }

    /// The managed Super serving identity: its media route renders from the
    /// same request plan as text (`NemotronSuperRequestPlan`).
    private static func servesMediaWithTextControls(_ model: ModelInfo) -> Bool {
        NemotronSuperServingPolicy.isServingIdentity(modelID: model.id, modelType: model.modelType)
    }

    /// Bonsai media uses the same withheld/schema-validated native tool frames
    /// as its text path; it does not require a sampler grammar. Admission must
    /// also attest the actual loaded native wrapper, not only caller metadata.
    static func supportsForcedMedia(context: ChatTemplateFixContext, nativeWrapperLoaded: Bool) -> Bool {
        if nativeWrapperLoaded && context.modelType == "diffusion_gemma" { return true }
        return nativeWrapperLoaded && context.modelType == "prism_hadamard_qwen35"
            && (EngineV2SupportedModels.isBonsai2ListingModelID(context.modelId)
                || Bonsai9BModelPolicy.matches(modelId: context.modelId, modelType: context.modelType))
    }

    static func isFramingWhitespace(_ text: String) -> Bool {
        // XML framing whitespace only. Foundation's broader character set
        // also includes invisible Unicode characters that are not framing.
        text.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    static func forcedStrategy(
        mode: ToolConstraintMode,
        modelContext: ChatTemplateFixContext
    ) throws -> Strategy {
        switch mode {
        case .required, .named:
            break
        case .none, .auto:
            return .none
        }

        if Gemma4TemplateFix.applies(to: modelContext) { return .gemmaGrammar }
        // GLM's forced calls are prompt-forced, withheld and validated like
        // Qwen and Nemotron; its engine constrains only JSON answers
        // (`JSONAnswerPolicy`, behind `DARKBLOOM_GLM_JSON_ANSWERS`).
        // Muse Glimmer's calls leave only at the engine terminal, after its
        // tool channel parsed and the call validated.
        if Qwen35TemplateFix.applies(to: modelContext) || nativeStructuredTarget(modelContext)
            || modelContext.modelType == "mimo_v2"
            || GLM5NextPromptPolicy.applies(modelType: modelContext.modelType)
            || MuseGlimmerModelPolicy.isModelType(modelContext.modelType) {
            return .structuredPostValidation
        }
        if GPTOSSForcedToolCalls.applies(to: modelContext) { return .harmonyFraming }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "inference-enforced tool_choice is unsupported for this model family")
    }

    /// Whether this concrete advertised model can honor required/named tool
    /// choice. Gemma's sampler grammar remains bound to its pinned template;
    /// native Qwen/Nemotron use prompt forcing plus withheld post-validation.
    static func advertisesCapability(for model: ModelInfo) -> Bool {
        let context = ChatTemplateFixContext(
            modelId: model.id, modelType: model.modelType)
        if Gemma4TemplateFix.applies(to: context) {
            return model.toolConstraintTemplateHash
                == Gemma4ToolConstraintContract.pinnedTemplateSHA256
        }
        if nativeStructuredTarget(context) {
            return true
        }
        // The managed Super owner prompt-forces required/named calls on text
        // and media requests and withholds output until the call validates
        // (`NemotronSuperLocalOutput`).
        if NemotronSuperServingPolicy.isServingIdentity(modelID: model.id, modelType: model.modelType) {
            return true
        }
        // GLM-5.3-Flash prompt-forces text calls and withholds them until the
        // native parser and schema validator accept them; media refuses forced
        // choice before any media work.
        if GLM5NextPromptPolicy.applies(modelType: model.modelType),
            GLM5NextCoordinatorServing.isManagedModelID(model.id) {
            return true
        }
        // Muse Glimmer prompt-forces a required or named call and withholds
        // every call until its tool channel parses and the call validates.
        if MuseGlimmerModelPolicy.matches(modelId: model.id, modelType: model.modelType) {
            return true
        }
        if let admittedType = structuredForcedToolModelTypes[model.id] {
            return model.modelType == admittedType
        }
        if GPTOSSForcedToolCalls.advertises(model) { return true }
        return ModelRuntimeRequirements.qwen38ConcreteModelIDs.contains(model.id)
            && Qwen35TemplateFix.applies(to: context)
    }

    /// Exact catalog builds whose required/named calls are prompt-forced,
    /// withheld and schema-validated, each bound to the `model_type` whose
    /// parser that path accepts. A renamed or retyped artifact stays
    /// unadvertised, so the coordinator never routes it a forced request.
    static let structuredForcedToolModelTypes: [String: String] = [
        "Qwen3.5-9B": "qwen3_5",
        "qwen3.5-35b-a3b": "qwen3_5_moe",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": "qwen3_5_moe",
        "mimo-v2.6-flash-mopd": "mimo_v2",
    ]

    /// Explicit family admission is supplied by each model onboarding change.
    /// Shared tool-frame validation alone must not advertise a new model.
    static func nativeStructuredTarget(_ context: ChatTemplateFixContext) -> Bool {
        let type = context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == "flint" { return context.modelType == "flint" }
        if type == "qwen4_exp" || type == "qwen4_exp_text" { return true }
        // Native block diffusion retains its trained sampler. Required/named
        // calls use prompt selection plus withheld schema/cardinality validation,
        // never an AR automaton advanced on provisional canvas tokens.
        if type == "diffusion_gemma" { return true }
        if type == "prism_hadamard_qwen35" {
            return (EngineV2SupportedModels.isBonsai2ListingModelID(context.modelId)
                || Bonsai9BModelPolicy.matches(modelId: context.modelId, modelType: context.modelType))
        }
        return type == "nemotron_h"
            && EngineV2SupportedModels.isNemotron35ListingModelID(context.modelId)
    }

    /// Consumer routing is not a public qualification/catalog advertisement.
    static func usesNativeTextChannels(_ context: ChatTemplateFixContext) -> Bool {
        context.modelType == "mimo_v2" || MuseGlimmerModelPolicy.isModelType(context.modelType)
            || nativeStructuredTarget(context)
    }

    /// Qwen 3.5, 3.6 and 3.8 text with tools keeps its legacy tool framing
    /// (`auto` calls stream while generated; forced calls keep the family's
    /// prompt policy), but its reasoning is classified before tool parsing,
    /// as on the native families: tool syntax that a thought mentions or
    /// drafts stays reasoning, never a call, and cannot swallow the real call.
    static func splitsQwenReasoningBeforeTools(_ context: ChatTemplateFixContext) -> Bool {
        let type = context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "qwen3_5" || type == "qwen3_5_moe"
    }

    /// Nemotron's existing behavior, plus the Qwen types (`QwenStrayThinkClose`,
    /// on by default).
    static func absorbsStrayThinkClose(_ context: ChatTemplateFixContext) -> Bool {
        QwenStrayThinkClose.applies(context)
            || (context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nemotron_h"
                && EngineV2SupportedModels.isNemotron35ListingModelID(context.modelId))
    }

    /// Nested examples inside native XML-family reasoning stay reasoning.
    /// Admission is family-specific; this is a wire policy, not an architecture
    /// alias, and must not change legacy Nemotron or other model behavior.
    static func preservesInnerReasoningSpans(_ context: ChatTemplateFixContext) -> Bool {
        if Qwen4ModelIdentity.isQualified(context.modelId), context.modelType == "qwen4_exp" {
            return true
        }
        return context.modelType == "prism_hadamard_qwen35"
            && (EngineV2SupportedModels.isBonsai2ListingModelID(context.modelId)
                || Bonsai9BModelPolicy.matches(modelId: context.modelId, modelType: context.modelType))
    }

    static func validateParser(
        _ format: ToolCallFormat,
        strategy: Strategy,
        modelContext: ChatTemplateFixContext? = nil
    ) throws {
        switch strategy {
        case .none:
            return
        case .gemmaGrammar:
            guard format == .gemma else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced Gemma tool_choice requires the gemma tool parser")
            }
        case .harmonyFraming:
            guard format == .harmony else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "GPT-OSS tool_choice requires the Harmony tool parser")
            }
        case .structuredPostValidation:
            if modelContext?.modelType == "flint" {
                guard format == .flint else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Flint tool_choice requires the native Flint parser")
                }
                return
            }
            if modelContext?.modelType == "mimo_v2" {
                guard format == .mimoV2 else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "native MiMo tool_choice requires the native MiMo parser")
                }
                return
            }
            if MuseGlimmerModelPolicy.isModelType(modelContext?.modelType) {
                guard format == .atem else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Muse Glimmer tool_choice requires the native ATEM parser")
                }
                return
            }
            if GLM5NextPromptPolicy.applies(modelType: modelContext?.modelType) {
                guard format == .glm5 else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "GLM tool_choice requires the native GLM parser")
                }
                return
            }
            let type = modelContext?.modelType?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == "diffusion_gemma" {
                guard format == .gemma else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "native diffusion tool_choice requires the Gemma tool parser")
                }
                return
            }
            let nativeQwen = type == "qwen4_exp" || type == "qwen4_exp_text"
                || type == "prism_hadamard_qwen35" || type?.hasPrefix("qwen3_5") == true
            let framedFormat: ToolCallFormat = nativeQwen ? .qwen35 : .nemotron
            guard format == .xmlFunction || format == framedFormat else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced structured tool_choice requires the native model's framed or XML tool parser")
            }
        }
    }
}
