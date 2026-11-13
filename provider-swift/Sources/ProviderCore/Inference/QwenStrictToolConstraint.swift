// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Constrains the arguments of every call a Qwen 3.5 answer opens to the
/// declared schemas. Not implemented yet: never built.
final class QwenStrictToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let startsInReasoning: Bool

    private init(maxTokens: Int, fallbackTokenID: Int, startsInReasoning: Bool) {
        self.maxTokens = maxTokens
        self.fallbackTokenID = fallbackTokenID
        self.startsInReasoning = startsInReasoning
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { [] }
    func nextState(state: Int, tokenID: Int) -> Int? { nil }
}
