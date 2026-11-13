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
/// default only the MoE builds (Qwen 3.6, Qwen 3.5 35B), whose cards' presence
/// penalty keeps them from drafting, take the grammar; the dense builds (Qwen
/// 3.8, Qwen 3.5 9B) draft, and a Mac opts them in.
enum QwenStrictToolGrammar {
    /// Unset: the default builds (`qwen3_5_moe`). `on`, `1`, `true` or `yes`:
    /// every Qwen 3.5-family build (`qwen3_5`, `qwen3_5_moe`). An off word
    /// (`off`, `0`, `false`, `no`, `none`, `disabled`, any case) restores
    /// unconstrained calls. Any other value is a comma-separated list: a
    /// `model_type`, or a case-insensitive part of a model id (`qwen3.8-27b`);
    /// only Qwen 3.5-family builds qualify.
    static let environmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR"
    /// `on`, `1`, `true` or `yes` (any case): also requests whose tools are not `strict`.
    static let allToolsEnvironmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS"

    /// The Qwen 3.5 template family: the builds that can take the grammar.
    static let modelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe"]
    /// The builds that take it unless the switch says otherwise.
    static let defaultModelTypes: Set<String> = ["qwen3_5_moe"]

    enum Setting: Sendable, Equatable {
        case off
        case models(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)
    static let currentAllTools = allTools(environment: ProcessInfo.processInfo.environment)

    private static let offWords: Set<String> = ["off", "0", "false", "no", "none", "disabled"]
    private static let onWords: Set<String> = ["on", "1", "true", "yes"]

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "strict-tool-grammar")

    static func setting(environment: [String: String]) -> Setting {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .models(defaultModelTypes) }
        if onWords.contains(raw) { return .models(modelTypes) }
        if offWords.contains(raw) { return .off }
        let entries = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !offWords.contains($0) && !onWords.contains($0) })
        return entries.isEmpty ? .off : .models(entries)
    }

    static func allTools(environment: [String: String]) -> Bool {
        environment[allToolsEnvironmentKey].map {
            onWords.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? false
    }

    static func isEnabled(modelId: String, modelType: String?, setting: Setting = current) -> Bool {
        guard case .models(let entries) = setting,
              let type = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              modelTypes.contains(type) else { return false }
        let id = modelId.lowercased()
        return entries.contains { $0 == type || id.contains($0) }
    }

    /// Cheap pre-check before the engine is asked whether it runs constraints:
    /// an `auto` request with tools on the Qwen 3.5 call parser.
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, parser: ToolCallFormat?,
                            allTools: Bool = currentAllTools) -> Bool {
        guard prepared.mode == .auto, parser == .qwen35, let tools = prepared.tools, !tools.isEmpty else { return false }
        return allTools || tools.contains { $0.function.strict == true }
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
        allTools: Bool = currentAllTools
    ) -> QwenStrictToolConstraint? {
        guard isEnabled(modelId: request.model, modelType: modelType, setting: setting),
              isCandidate(prepared: prepared, parser: parser, allTools: allTools),
              let rendered = prepared.tools else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard !MediaIngest.hasMedia(request) else { return declined("media request") }
        let schema: QwenStrictToolSchema
        do {
            schema = try QwenStrictToolSchema(declared: prepared.declaredTools ?? rendered, rendered: rendered,
                                              forbidding: forbiddenMarkers, family: profile.family)
        } catch {
            return declined("a schema outside the constrained subset")
        }
        guard let promptTokens, !promptTokens.isEmpty,
              let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? QwenStrictToolConstraint(schema: schema, vocabulary: vocabulary,
            forbidding: forbiddenMarkers, startsInReasoning: prefix == ReasoningPromptProbe.thinkOpen,
            allowsParallelCalls: prepared.allowsParallelCalls, maxTokens: request.maxTokens ?? defaultMaxTokens) else {
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
        firstAddedTokenID: 248044,
        pieceTokens: [.init(spelling: "<think>", id: 248068), .init(spelling: "</think>", id: 248069),
                      .init(spelling: "<tool_call>", id: 248058), .init(spelling: "</tool_call>", id: 248059)],
        answerEOS: [.init(spelling: "<|im_end|>", id: 248046), .init(spelling: "<|endoftext|>", id: 248044)],
        vocabularySize: 248320)

    /// Fixed reasons only: never names, schemas, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> QwenStrictToolConstraint? {
        logger.info("Qwen strict tool calls served unconstrained: \(reason)")
        return nil
    }
}
