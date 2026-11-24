// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Grammar-constrained arguments for `strict` tool calls on the Qwen
/// 3.5-family text route (Qwen 3.5 9B and 35B, 3.6 and 3.8 on one Mac).
///
/// A `strict` call is validated against the caller's schema when its frame
/// closes, after the answer has started streaming, so a call that misses the
/// schema fails a started response. Under this grammar the model can only
/// write calls that validate: the sampler holds every call's function name,
/// parameter names and values to the declared schemas
/// (`QwenStrictToolConstraint`), while reasoning and text stay free and `auto`
/// still decides whether to call. The rendered prompt does not change.
///
/// It applies to `auto` requests that declare a `strict` function (with
/// `DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS`, any request with tools), on an
/// engine that runs token constraints, when every declared schema compiles
/// (`$ref`s inlined as the coordinator does). Such a request has every call
/// validated already, so every call is constrained. A request the policy
/// declines (an unsupported schema keyword, a union of several types, an
/// unrecognized prompt boundary, an unverified tokenizer, a cluster pair) is
/// served exactly as before, never refused.
///
/// A token constraint keeps the engine from drafting with MTP on that row
/// and, on these engines, on every row of a decode step it shares
/// (`EngineLoopV2.mtpDraftBatchRows`), as for constrained JSON answers. So by
/// default the grammar takes the MoE builds (Qwen 3.6, Qwen 3.5 35B), whose
/// cards' presence penalty keeps them from drafting, and Qwen 3.8 27B, whose
/// strict calls missing their schemas were its main remaining failure; the
/// coordinator turns it off for a build by forwarding no `strict` flag
/// (`EIGENINFERENCE_STRICT_TOOLS_UNMARK_MODELS`). The 9B drafts too, and a Mac
/// opts it in.
///
/// Nemotron 3.5 Lightning (`nemotron_h`, the listing builds only) writes the
/// same call frame, and its `auto` calls are returned as generated, so a call
/// that misses the caller's schema reaches the client. There the grammar holds
/// every `auto` call, `strict` or not (`nemotronEnvironmentKey`), including the
/// bare `<function=…>` frame its parser also reads. Nemotron 3.5 Super takes the
/// same family on its owner's own route, media included (`NemotronSuperToolGrammar`).
enum QwenStrictToolGrammar {
    /// Unset: the default builds (`qwen3_5_moe` and `qwen3.8-27b`). `on`, `1`,
    /// `true` or `yes`: every Qwen 3.5-family build (`qwen3_5`, `qwen3_5_moe`).
    /// An off word (`off`, `0`, `false`, `no`, `none`, `disabled`, any case)
    /// restores unconstrained calls. Any other value is a comma-separated list: a
    /// `model_type`, or a case-insensitive part of a model id (`qwen3.8-27b`);
    /// only Qwen 3.5-family builds qualify.
    static let environmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR"
    /// `on`, `1`, `true` or `yes` (any case): also requests whose tools are not `strict`.
    static let allToolsEnvironmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS"

    /// Unset or an on word: Nemotron 3.5 Lightning's `auto` calls follow the
    /// grammar, every tool. An off word restores unconstrained calls.
    static let nemotronEnvironmentKey = "DARKBLOOM_NEMOTRON_TOOL_GRAMMAR"

    /// The Qwen 3.5 template family: the builds that can take the grammar.
    static let modelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe"]
    /// Nemotron 3.5's type; only its listing builds take the grammar (Nano shares the type).
    static let nemotronModelType = "nemotron_h"
    /// The builds that take it unless the switch says otherwise: a
    /// `model_type` or a model-id part, as in a list.
    static let defaultBuilds: Set<String> = ["qwen3_5_moe", "qwen3.8-27b"]

    enum Setting: Sendable, Equatable {
        case off
        case models(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)
    static let currentAllTools = allTools(environment: ProcessInfo.processInfo.environment)
    static let currentNemotron = nemotron(environment: ProcessInfo.processInfo.environment)

    private static let offWords: Set<String> = ["off", "0", "false", "no", "none", "disabled"]
    private static let onWords: Set<String> = ["on", "1", "true", "yes"]

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "strict-tool-grammar")

    static func setting(environment: [String: String]) -> Setting {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .models(defaultBuilds) }
        if onWords.contains(raw) { return .models(modelTypes) }
        if offWords.contains(raw) { return .off }
        let entries = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !offWords.contains($0) && !onWords.contains($0) })
        return entries.isEmpty ? .off : .models(entries)
    }

    static func nemotron(environment: [String: String]) -> Bool {
        guard let raw = environment[nemotronEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else { return true }
        return !offWords.contains(raw)
    }

    static func allTools(environment: [String: String]) -> Bool {
        environment[allToolsEnvironmentKey].map {
            onWords.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? false
    }

    static func isEnabled(modelId: String, modelType: String?, setting: Setting = current,
                          nemotron: Bool = currentNemotron) -> Bool {
        let type = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == nemotronModelType {
            return nemotron && EngineV2SupportedModels.isNemotron35ListingModelID(modelId)
        }
        guard case .models(let entries) = setting, let type, modelTypes.contains(type) else { return false }
        let id = modelId.lowercased()
        return entries.contains { $0 == type || id.contains($0) }
    }

    /// Cheap pre-check before the engine is asked whether it runs constraints:
    /// an `auto` request with tools on the Qwen 3.5 call parser (`strict` tools
    /// unless `allTools`), or on Nemotron's (every tool).
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, parser: ToolCallFormat?,
                            allTools: Bool = currentAllTools) -> Bool {
        guard prepared.mode == .auto, let family = Family(parser: parser), let tools = prepared.tools, !tools.isEmpty
        else { return false }
        return family.allTools || allTools || tools.contains { $0.function.strict == true }
    }

    /// What differs between the call parsers that read this frame.
    struct Family {
        let profile: JSONAnswerProfile
        let forbiddenMarkers: [[UInt8]]
        /// The parser also reads a bare `<function=…>` frame, which is then held too.
        let bareFunctionCalls: Bool
        /// Every `auto` call is held, not only `strict` ones.
        let allTools: Bool

        init?(parser: ToolCallFormat?) {
            guard let parser else { return nil }
            switch parser {
            case .qwen35:
                self.init(profile: QwenStrictToolGrammar.profile, forbiddenMarkers: QwenStrictToolGrammar.forbiddenMarkers,
                          bareFunctionCalls: false, allTools: false)
            case .nemotron:
                // Holds reasoning-first requests too. Lightning does not draft
                // under `mtp_mode = auto` (`nemotron_h` is not among
                // `MTPMode.automaticEmbeddedModelTypes`); Super's owner does,
                // and its constrained text rows draft through constraint spans
                // and grammar-aware MTP, on for Super by default
                // (`DARKBLOOM_CONSTRAINT_SPANS`, `DARKBLOOM_CBV2_MTP_GRAMMAR`;
                // `NemotronSuperLocalMTP.config`).
                self.init(profile: QwenStrictToolGrammar.nemotronProfile,
                          forbiddenMarkers: QwenStrictToolGrammar.nemotronForbiddenMarkers,
                          bareFunctionCalls: true, allTools: true)
            default:
                return nil
            }
        }

        private init(profile: JSONAnswerProfile, forbiddenMarkers: [[UInt8]], bareFunctionCalls: Bool, allTools: Bool) {
            self.profile = profile
            self.forbiddenMarkers = forbiddenMarkers
            self.bareFunctionCalls = bareFunctionCalls
            self.allTools = allTools
        }
    }

    /// The constraint for an eligible request, or nil (today's unconstrained
    /// calls). `runsTokenConstraints`: the slot's engine samples under one
    /// (not a cluster pair, not a native-tracked engine).
    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        parser: ToolCallFormat?,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool,
        setting: Setting = current,
        allTools: Bool = currentAllTools,
        nemotron: Bool = currentNemotron
    ) -> QwenStrictToolConstraint? {
        guard isEnabled(modelId: request.model, modelType: modelType, setting: setting, nemotron: nemotron),
              isCandidate(prepared: prepared, parser: parser, allTools: allTools),
              let family = Family(parser: parser) else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard !MediaIngest.hasMedia(request) else { return declined("media request") }
        return build(prepared: prepared, request: request, family: family, tokenizer: tokenizer,
                     defaultMaxTokens: defaultMaxTokens, stopTokenIDs: stopTokenIDs, promptTokens: promptTokens,
                     runsTokenConstraints: runsTokenConstraints)
    }

    /// The constraint for a request its route already found eligible, text or
    /// media alike (the media prompt's tail is the same assistant boundary),
    /// or nil, served as before.
    static func build(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        family: Family,
        tokenizer: TokenizerHandle,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool
    ) -> QwenStrictToolConstraint? {
        guard let rendered = prepared.tools else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        let schema: QwenStrictToolSchema
        do {
            // The grammar spells each value as the parser reads it
            // (`ToolStreamPreparation.makeHandler`).
            schema = try QwenStrictToolSchema(declared: prepared.declaredTools ?? rendered,
                                              rendered: prepared.argumentTools ?? rendered,
                                              forbidding: family.forbiddenMarkers, family: family.profile.family,
                                              lenient: family.allTools)
        } catch {
            return declined("a schema outside the constrained subset")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: family.profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? QwenStrictToolConstraint(schema: schema, vocabulary: vocabulary,
            forbidding: family.forbiddenMarkers, startsInReasoning: prefix == ReasoningPromptProbe.thinkOpen,
            allowsParallelCalls: prepared.allowsParallelCalls, bareFunctionCalls: family.bareFunctionCalls,
            maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined("no positive output budget")
        }
        return constraint
    }

    /// Spellings no argument value may contain: the turn, reasoning and call
    /// markers (each also an added token of these tokenizers).
    static let forbiddenMarkers: [[UInt8]] = forbiddenSpellings.map { Array($0.utf8) }
    private static let forbiddenSpellings = [
        "<tool_call>", "</tool_call>", "<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|endoftext|>",
    ]

    /// The Qwen 3.5 vocabulary contract (`JSONAnswerProfile.qwen35`) with the
    /// call markers as ordinary pieces. Every watched marker ends in `>`, so
    /// the pieces holding one are the only ones that can end a free span.
    static let profile = JSONAnswerProfile(
        family: "Qwen tools",
        thinkClose: "</think>",
        reasoningStops: ["<tool_call>", "</parameter>"] + forbiddenSpellings,
        contentMarkers: forbiddenSpellings + ["</parameter>"],
        bpeIDs: 0..<248044,
        pieceTokens: [.init(spelling: "<think>", id: 248068), .init(spelling: "</think>", id: 248069),
                      .init(spelling: "<tool_call>", id: 248058), .init(spelling: "</tool_call>", id: 248059)],
        answerEOS: [.init(spelling: "<|im_end|>", id: 248046), .init(spelling: "<|endoftext|>", id: 248044)],
        vocabularySize: 248320)

    /// Nemotron 3.5's spellings no argument value may contain: its turn,
    /// reasoning and call markers (added tokens), and `<function=`, which opens
    /// a bare frame its parser reads.
    static let nemotronForbiddenMarkers: [[UInt8]] = nemotronForbiddenSpellings.map { Array($0.utf8) }
    private static let nemotronForbiddenSpellings = [
        "<tool_call>", "</tool_call>", "<think>", "</think>", "<|im_start|>", "<|im_end|>", "<function=",
    ]

    /// The Nemotron 3.5 vocabulary contract (`JSONAnswerProfile.nemotron35`)
    /// with the call markers as ordinary pieces. `<function=` ends in `=`, so
    /// the pieces holding an `=` can end a free span too.
    static let nemotronProfile = JSONAnswerProfile(
        family: "Nemotron tools",
        thinkClose: "</think>",
        reasoningStops: ["<tool_call>", "</parameter>"] + nemotronForbiddenSpellings,
        contentMarkers: nemotronForbiddenSpellings + ["</parameter>"],
        bpeIDs: 1000..<131072,
        pieceTokens: [.init(spelling: "<think>", id: 12), .init(spelling: "</think>", id: 13),
                      .init(spelling: "<tool_call>", id: 14), .init(spelling: "</tool_call>", id: 15)],
        answerEOS: [.init(spelling: "<|im_end|>", id: 11), .init(spelling: "</s>", id: 2)],
        vocabularySize: 131072)

    /// Fixed reasons only: never names, schemas, prompt content or token IDs.
    static func declined(_ reason: StaticString) -> QwenStrictToolConstraint? {
        logger.info("Strict tool calls served unconstrained: \(reason)")
        return nil
    }
}
