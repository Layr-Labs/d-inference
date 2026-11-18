// Copyright © 2026 Eigen Labs.
//
// Red-test stub (TOOLCALL-PR2): the API the new tests read, with today's
// behavior: no constraint is ever built, and the automaton admits everything.
// The fix replaces this file.

import Foundation
import MLXLMCommon
import MLXLMServer

enum GPTOSSAutoToolGrammar {
    static let environmentKey = "DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR"
    static let enabled = false

    static func isEnabled(_ value: String?) -> Bool { false }

    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared, modelType: String?, tokenizer: TokenizerHandle, maxTokens: Int,
        stopTokenIDs: Set<Int>, promptTokens: [Int]?, runsTokenConstraints: Bool, enabled: Bool = enabled
    ) -> GPTOSSAutoToolConstraint? { nil }

    static func compiledArguments(declared: [OpenAITool], rendered: [OpenAITool]) -> [CompiledToolSchema?] {
        rendered.map { _ in nil }
    }
}

final class GPTOSSAutoToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    static let freeMaskKey = -2
    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let names: [[UInt8]]
    private let vocabulary: JSONAnswerVocabulary

    init(names: [String], arguments: [CompiledToolSchema?], framing: GPTOSSHarmonyFraming,
         vocabulary: JSONAnswerVocabulary, maxTokens: Int) throws {
        self.names = names.map { Array($0.utf8) }
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
    }

    func withMaxTokens(_ budget: Int) throws -> GPTOSSAutoToolConstraint { self }
    func constrainsArguments(of name: String) -> Bool { false }
    var cachedStateCount: Int { 1 }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { Array(0..<vocabulary.pieces.count) }
    func nextState(state: Int, tokenID: Int) -> Int? { vocabulary.stopTokenIDs.contains(tokenID) ? -1 : 0 }
}
