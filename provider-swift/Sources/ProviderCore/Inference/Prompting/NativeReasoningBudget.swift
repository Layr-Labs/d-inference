// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// A validated family control, carried separately from the client's wire request.
struct NativeReasoningBudget: Sendable, Equatable {
    enum Family: Sendable { case nemotronSuper, mimoV26 }
    let maximumTokens: Int
    let family: Family

    func resolved(tokenizer: any MLXLMCommon.Tokenizer) throws -> CBv2ReasoningBudget {
        let open = tokenizer.encode(text: "<think>", addSpecialTokens: false)
        let close = tokenizer.encode(text: "</think>", addSpecialTokens: false)
        guard Self.acceptsMaximumTokens(maximumTokens), open.count == 1, close.count == 1,
              open != close, tokenizer.convertTokenToId("<think>") == open.first,
              tokenizer.convertTokenToId("</think>") == close.first,
              tokenizer.decode(tokenIds: open, skipSpecialTokens: false) == "<think>",
              tokenizer.decode(tokenIds: close, skipSpecialTokens: false) == "</think>" else {
            throw Self.refusal("reasoning budget requires validated atomic thought markers")
        }
        return try CBv2ReasoningBudget(maximumTokens: maximumTokens, openTokenID: open[0],
            closeTokenID: close[0], startsInsideThought: family == .nemotronSuper)
    }

    static func refusal(_ message: String) -> MultiModelBatchSchedulerEngineError {
        .unsupportedOutputControl("\(EngineV2Translation.unsupportedOutputControlPrefix): \(message)")
    }

    static let environmentKey = "DARKBLOOM_NATIVE_REASONING_BUDGET"
    static var isEnabled: Bool { CBv2ReasoningBudget.enabled() }
    static func isEnabled(
        for family: Family,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        families: Set<Family> = SDKFeatureDefaults.reasoningBudgetFamilies,
        injected: Set<String> = SDKFeatureDefaults.injectedKeys
    ) -> Bool {
        CBv2ReasoningBudget.enabled(environment: environment)
    }
    static func acceptsMaximumTokens(_ value: Int) -> Bool { value > 0 && value <= Int(Int32.max) }
}
