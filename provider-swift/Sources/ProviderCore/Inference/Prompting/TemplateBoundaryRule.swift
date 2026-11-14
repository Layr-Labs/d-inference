// Copyright © 2026 Eigen Labs.
// The canonical grid's message-boundary rule, read from the chat template.

import Foundation
import MLXLMCommon

/// Reads the message-boundary rule from a slot's chat template at load. Every
/// probe conversation is rendered the way a request with the same messages is,
/// and the library checks the rule on two-turn prompts before it is used. A
/// template that fails the check gets no rule; the template is never changed.
enum TemplateBoundaryRule {
    struct UnencodableProbe: Error {}

    /// The rule for a slot whose scheduler has the grid on and no operator
    /// rule; nil in every other case. A derivation logs one line.
    static func rule(
        for scheduler: CBv2SchedulerConfig,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?,
        modelID: String,
        logInfo: (String) -> Void = { _ in }
    ) -> CBv2CanonicalBoundaryRule? {
        guard scheduler.canonicalPrefillGridTokens != nil, scheduler.canonicalBoundaryRule == nil
        else { return nil }
        let derivation = derive(tokenizer: tokenizer, modelType: modelType, modelID: modelID)
        logInfo("engine_v2: \(modelID) \(summary(of: derivation))")
        return derivation.rule
    }

    static func derive(
        tokenizer: any MLXLMCommon.Tokenizer, modelType: String?, modelID: String
    ) -> CBv2BoundaryRuleDerivation {
        CBv2CanonicalBoundaryRule.derive(
            isSpecial: { id in
                tokenizer.decode(tokenIds: [id], skipSpecialTokens: true).isEmpty
                    && !tokenizer.decode(tokenIds: [id], skipSpecialTokens: false).isEmpty
            },
            render: { probe in
                try ProviderPromptContractPipeline.tokenizeProviderBody(
                    try requestBody(for: probe, modelID: modelID),
                    tokenizer: tokenizer, modelType: modelType,
                    addGenerationPrompt: probe.addGenerationPrompt)
            })
    }

    /// The probe as a chat completion body. Tool call arguments travel as a
    /// JSON string, as they do in a request.
    static func requestBody(for probe: CBv2BoundaryProbe, modelID: String) throws -> Data {
        var body: [String: Any] = [
            "model": modelID,
            "messages": try probe.messages.map(requestMessage),
        ]
        if let tools = probe.tools { body["tools"] = tools }
        if let thinking = probe.enableThinking { body["enable_thinking"] = thinking }
        // `data(withJSONObject:)` raises on a value JSON cannot hold.
        guard JSONSerialization.isValidJSONObject(body) else { throw UnencodableProbe() }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func requestMessage(_ message: Message) throws -> [String: Any] {
        var message: [String: Any] = message
        guard let calls = message["tool_calls"] as? [[String: Any]] else { return message }
        message["tool_calls"] = try calls.map { call -> [String: Any] in
            var call = call
            guard var function = call["function"] as? [String: Any],
                let arguments = function["arguments"], !(arguments is String)
            else { return call }
            guard JSONSerialization.isValidJSONObject(arguments) else { throw UnencodableProbe() }
            function["arguments"] = String(
                decoding: try JSONSerialization.data(
                    withJSONObject: arguments, options: [.sortedKeys]),
                as: UTF8.self)
            call["function"] = function
            return call
        }
        return message
    }

    /// Pattern lengths and verdict names only: no token ids and no prompt text.
    static func summary(of derivation: CBv2BoundaryRuleDerivation) -> String {
        let verdicts = CBv2BoundaryRuleDerivation.Scenario.allCases.compactMap { scenario in
            derivation.verdicts[scenario].map { "\(scenario.rawValue)=\($0.rawValue)" }
        }
        let outcome: String
        if derivation.rule != nil {
            outcome = "accepted"
        } else {
            outcome = derivation.candidate == nil ? "not_derived" : "rejected"
        }
        let closeLengths = (derivation.candidate?.close ?? []).map { String($0.count) }
        return "template boundary rule \(outcome)"
            + " open_tokens=\(derivation.candidate?.open.count ?? 0)"
            + " close_tokens=\(closeLengths.joined(separator: "/"))"
            + " checks=\(verdicts.joined(separator: ","))"
    }
}
