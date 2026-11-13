// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Sampler framing for required/named tool calls on the Qwen 3.5-family text
/// route (Qwen 3.5 9B and 35B, 3.6 and 3.8 on one Mac). That route renders a
/// forced call with thinking off and withholds it until it validates, and the
/// router fails the request on any visible text before a validated call, but
/// nothing kept the model from opening with prose (422 `tool_noncompliance`).
/// These tokenizers carry Qwen4's framing tokens, which
/// `Qwen4ToolFramingVocabulary` verifies, so the native Qwen4 framing
/// constraint applies unchanged: only a declared function header, or framed
/// JSON, can open the answer; the arguments stay model-selected and are
/// validated as before. A request this policy declines keeps that prompt-only
/// behavior, never a new refusal. The rendered prompt is not changed.
enum QwenForcedToolFraming {
    /// `off` (or `0`, `false`, `no`) restores prompt-only forced calls.
    static let environmentKey = "DARKBLOOM_QWEN_FORCED_TOOL_FRAMING"
    static let enabledByDefault = isEnabled(environment: ProcessInfo.processInfo.environment)

    private static let modelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe"]

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "forced-tool-framing")

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return true }
        return !["off", "0", "false", "no"].contains(raw)
    }

    /// Whether a request may take the framing: a forced call on this route's
    /// dual-dialect parser, whose two dialects are exactly the frames the
    /// constraint admits. The engine must also run token constraints
    /// (`EngineV2Bridge.runsTokenConstraints`).
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, parser: ToolCallFormat?) -> Bool {
        prepared.requiresToolCall && parser == .qwen35
    }

    /// The framing constraint for an eligible request, or nil. Only a prompt
    /// that ends in the closed think block qualifies: with thinking on, this
    /// route cannot split a thought from the call.
    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        tokenizer: TokenizerHandle,
        maxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        enabled: Bool = enabledByDefault
    ) -> Qwen4NativeToolConstraint? {
        guard enabled, prepared.requiresToolCall, let modelType, modelTypes.contains(modelType) else { return nil }
        guard let promptTokens, !promptTokens.isEmpty,
              ReasoningPromptProbe.streamingPrefix(forPromptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) == closedThinking else {
            return declined("prompt does not end in the closed think block")
        }
        guard let vocabulary = try? tokenizer.qwen4FramingVocabulary(stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not carry the Qwen framing tokens")
        }
        guard let constraint = try? Qwen4NativeToolConstraint(mode: prepared.mode, maxTokens: maxTokens,
            vocabulary: vocabulary, nativePrefix: closedThinking, allowsParallel: prepared.allowsParallelCalls,
            allowedToolNames: prepared.allowedToolNames) else {
            return declined("no framing for these declarations or this budget")
        }
        return constraint
    }

    private static let closedThinking = ReasoningPromptProbe.thinkOpen + ReasoningPromptProbe.thinkClose

    /// Fixed reasons only: never names, schemas, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> Qwen4NativeToolConstraint? {
        logger.info("Qwen forced tool call served prompt-only: \(reason)")
        return nil
    }
}
