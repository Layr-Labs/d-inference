import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

private struct WideConstraintTokenizer: MLXLMCommon.Tokenizer {
    private let base = ASCIIConstraintTokenizer()

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        base.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        if id < 129 { return base.convertIdToToken(id) }
        return id < 5_000 ? "a" : nil
    }

    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(
            messages: messages, tools: tools,
            additionalContext: additionalContext)
    }
}

extension GemmaToolConstraintTests {
    @Test("stop sequence that makes a finite grammar impossible is rejected")
    func stopConflictFailsBeforeInference() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "const": .string("END"),
                ]),
            ]),
            "required": .array([.string("value")]),
        ])
        var request = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        request.stop = ["END"]
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolConstraintFactory.make(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer,
                modelContext: .init(
                    modelId: request.model, modelType: "gemma4_text"),
                defaultMaxTokens: 128,
                stopTokenIDs: [128])
        }
    }

    @Test("constrained stop automata have explicit count and byte bounds")
    func constrainedStopSetIsBounded() throws {
        var request = request(choice: .mode(.required))
        request.stop = ["a", "b", "c", "d", "e"]
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolConstraintFactory.make(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer,
                modelContext: .init(
                    modelId: request.model, modelType: "gemma4_text"),
                defaultMaxTokens: 128,
                stopTokenIDs: [128])
        }
    }

    @Test("stop composition finds a safe completion in wide vocabularies")
    func stopCompositionSearchesBeyondHeuristicBreakers() throws {
        var request = request(choice: .mode(.required))
        request.stop = ["a<", "aa", "a0", "a_"]
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let constraint = try #require(try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: TokenizerHandle(
                WideConstraintTokenizer(),
                toolConstraintContractVerified: true),
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128]))

        var state = constraint.initialState
        let prefix = #"<|tool_call>call:weather{city:<|"|>a"#
        for token in prefix.utf8.map(Int.init) {
            state = try #require(
                constraint.nextState(state: state, tokenID: token))
        }
        #expect(
            !constraint.allowedTokenIDs(
                state: state, remainingTokens: 20
            ).isEmpty)
    }

}
