// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// The call grammar (`QwenStrictToolConstraint`, Nemotron family) for
/// Nemotron 3.5 Super's `auto` tool calls, on its owner's own route
/// (`NemotronSuperLocalImageHTTP`): text, image and video requests alike.
///
/// Super writes Lightning's call frame and parses it with the same parser, and
/// its `auto` calls are returned as generated, so a call that names an
/// undeclared parameter or an enum value outside its schema reaches the
/// client. Under the grammar every `auto` call, `strict` or not, names a
/// declared function and its declared parameters, includes the required ones
/// and writes values the schema allows (lenient where a schema holds an
/// assertion the grammar cannot spell). Reasoning and text stay free, and the
/// model still decides whether to call. The rendered prompt does not change.
///
/// Served as before: a request with a reasoning budget (the bridge cannot
/// hold a budget and a grammar on one row); one whose reasoning, left
/// unterminated, becomes its answer (`force_nonempty_content` with thinking
/// on), since the grammar leaves reasoning free and the parser would then read
/// a call written there; and every request the grammar declines
/// (`QwenStrictToolGrammar.build`).
///
/// MTP: on a speculating owner a constrained text row drafts through its free
/// reasoning and text (constraint spans, `DARKBLOOM_CONSTRAINT_SPANS`) and
/// verifies drafts inside a call with the grammar (`DARKBLOOM_CBV2_MTP_GRAMMAR`),
/// both on for Super by default (`NemotronSuperLocalMTP.config`). With both
/// off it decodes target-only, for its whole answer, beside the owner's
/// speculating rows (`ineligibleRowsDecodeBesideSpeculation`). Media rows
/// decode target-only either way.
enum NemotronSuperToolGrammar {
    /// Unset or any value but an off word (`off`, `0`, `false`, `no`, `none`,
    /// `disabled`, any case): on. An off word restores unconstrained calls.
    /// Read once per process; forwarded to the provider job.
    static let environmentKey = "DARKBLOOM_NEMOTRON_SUPER_TOOL_GRAMMAR"

    static let current = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return true }
        return !["off", "0", "false", "no", "none", "disabled"].contains(raw)
    }

    /// The constraint for one Super request submitted as `promptTokens`, or
    /// nil (its calls are returned as generated, as before). `body` is the raw
    /// request: the caller's declarations as sent, before ingress
    /// normalization, are what a value is held to (`Prepared.declaredTools`);
    /// the parser reads the plan's rendered ones. `maxTokens` is the output the
    /// bridge resolves for that prompt (`EngineV2Bridge.outputTokens`): the
    /// engine refuses a constraint whose budget differs from its request's.
    static func constraint(
        plan: NemotronSuperRequestPlan,
        body: Data,
        tokenizer: TokenizerHandle,
        promptTokens: [Int],
        stopTokenIDs: Set<Int>,
        maxTokens: Int,
        runsTokenConstraints: Bool,
        enabled: Bool = current
    ) -> QwenStrictToolConstraint? {
        guard enabled, let family = QwenStrictToolGrammar.Family(parser: .nemotron),
              QwenStrictToolGrammar.isCandidate(prepared: plan.toolPolicy, parser: .nemotron, allTools: true)
        else { return nil }
        guard plan.nativeReasoningBudget == nil else { return QwenStrictToolGrammar.declined("a reasoning budget") }
        guard !(plan.controls.forceNonemptyContent && plan.controls.enableThinking) else {
            return QwenStrictToolGrammar.declined("reasoning that may become the answer")
        }
        var prepared = plan.toolPolicy
        prepared.declaredTools = (try? JSONDecoder().decode(ChatTemplateControls.self, from: body))?.declaredTools
        var request = plan.request
        request.maxTokens = maxTokens
        return QwenStrictToolGrammar.build(prepared: prepared, request: request, family: family,
            tokenizer: tokenizer, defaultMaxTokens: maxTokens, stopTokenIDs: stopTokenIDs,
            promptTokens: promptTokens, runsTokenConstraints: runsTokenConstraints)
    }
}
