import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

private final class CountingConstraintTokenizer:
    MLXLMCommon.Tokenizer, @unchecked Sendable
{
    private let base = ASCIIConstraintTokenizer()
    private let lock = NSLock()
    private var convertCalls = 0

    var conversionCount: Int {
        lock.withLock { convertCalls }
    }

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
        lock.withLock { convertCalls += 1 }
        if id == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return base.convertIdToToken(id)
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
    @Test("required grammar admits only a complete schema-valid Gemma call")
    func requiredGrammar() throws {
        let request = request(choice: .mode(.required))
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        let constraint = try #require(built)

        let output =
            #"<|tool_call>call:weather{city:<|"|>Paris<|"|>}<tool_call|>"#
        var state = constraint.initialState
        for (offset, token) in output.utf8.map(Int.init).enumerated() {
            let allowed = constraint.allowedTokenIDs(
                state: state, remainingTokens: 128 - offset)
            #expect(allowed.contains(token), "token \(token) rejected at offset \(offset)")
            state = try #require(constraint.nextState(state: state, tokenID: token))
        }
        #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 1) == [128])
        #expect(constraint.nextState(state: state, tokenID: 128) == -1)
    }

    @Test("free-form strings never admit ASCII control token shortcuts")
    func freeStringRejectsControlTokens() throws {
        let request = request(choice: .mode(.required))
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let constraint = try #require(try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128]))
        var state = constraint.initialState
        for token in #"<|tool_call>call:weather{city:<|"|>"#.utf8.map(Int.init) {
            state = try #require(
                constraint.nextState(state: state, tokenID: token))
        }
        #expect(
            !constraint.allowedTokenIDs(
                state: state, remainingTokens: 64
            ).contains(0x7F))
    }

    @Test("concurrent cold requests build one tokenizer vocabulary")
    func concurrentVocabularyBuildIsSingleFlight() async throws {
        let counted = CountingConstraintTokenizer()
        let handle = TokenizerHandle(counted)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    _ = try handle.gemmaVocabulary(stopTokenIDs: [128])
                }
            }
            try await group.waitForAll()
        }
        #expect(counted.conversionCount == 1_153)
    }
    @Test("every allowed function branch fits the remaining token budget")
    func toolBranchBudgetViability() throws {
        let emptyParameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
        let short = tool(name: "a", parameters: emptyParameters)
        let long = tool(
            name: String(repeating: "z", count: 40),
            parameters: emptyParameters)
        var request = request(
            choice: .mode(.required),
            tools: [short, long])
        let shortestOutput = "<|tool_call>call:a{}<tool_call|>"
        request.maxTokens = shortestOutput.utf8.count + 3
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let constraint = try #require(try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: request.maxTokens!,
            stopTokenIDs: [128]))

        let prefix = "<|tool_call>call:"
        var state = constraint.initialState
        for token in prefix.utf8.map(Int.init) {
            state = try #require(
                constraint.nextState(state: state, tokenID: token))
        }
        let allowed = constraint.allowedTokenIDs(
            state: state,
            remainingTokens: request.maxTokens! - prefix.utf8.count)
        #expect(allowed.contains(Int(Character("a").asciiValue!)))
        #expect(!allowed.contains(Int(Character("z").asciiValue!)))
    }
    @Test("numeric grammar cannot exceed parser-representable bounds")
    func numericGrammarIsBounded() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("value")]),
        ])
        let request = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        let constraint = try #require(built)
        var state = constraint.initialState
        var rejected = false
        let output =
            "<|tool_call>call:weather{value:9999999999999999999}<tool_call|>"
        for token in output.utf8.map(Int.init) {
            guard let next = constraint.nextState(state: state, tokenID: token) else {
                rejected = true
                break
            }
            state = next
        }
        #expect(rejected)
    }

    @Test("number constants never round or trap during grammar rendering")
    func numberConstantsRequireExactRepresentation() {
        let unsupported: [MLXLMCommon.JSONValue] = [
            .int(9_007_199_254_740_993),
            .int(Int.max),
            .double(9_007_199_254_740_994.0),
            .double(-9_007_199_254_740_994.0),
            .double(0.10000000000000001),
        ]
        for value in unsupported {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("number"),
                        "const": value,
                    ]),
                ]),
            ])
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                _ = try ToolChoicePromptPolicy.prepare(
                    request(
                        choice: .mode(.required),
                        tools: [tool(parameters: parameters)]))
            }
        }
    }

    @Test("raw decimal and exponent number constants fail before inference")
    func rawNumberConstantSyntaxIsRejected() throws {
        for literal in ["1.0", "1e0"] {
            let body = """
                {
                  "model":"gemma-4-test",
                  "messages":[{"role":"user","content":"x"}],
                  "tools":[{"type":"function","function":{
                    "name":"calculate",
                    "parameters":{
                      "type":"object",
                      "properties":{"value":{"type":"number","const":\(literal)}}
                    }
                  }}],
                  "tool_choice":"required"
                }
                """
            let decoded = try JSONDecoder().decode(
                OpenAIChatCompletionRequest.self,
                from: Data(body.utf8))
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                _ = try ToolChoicePromptPolicy.prepare(decoded)
            }
        }
    }

    @Test("mathematical integer constants accept decimal and exponent spellings")
    func mathematicalIntegerConstantSyntaxIsAccepted() throws {
        for literal in [
            "1.0", "1e0", "-2.0", "-2e0", "9007199254740993.0",
        ] {
            let body = """
                {
                  "model":"gemma-4-test",
                  "messages":[{"role":"user","content":"x"}],
                  "tools":[{"type":"function","function":{
                    "name":"calculate",
                    "parameters":{
                      "type":"object",
                      "properties":{"value":{"type":"integer","const":\(literal)}}
                    }
                  }}],
                  "tool_choice":"required"
                }
                """
            let decoded = try JSONDecoder().decode(
                OpenAIChatCompletionRequest.self,
                from: Data(body.utf8))
            _ = try ToolChoicePromptPolicy.prepare(decoded)
        }
    }
}
