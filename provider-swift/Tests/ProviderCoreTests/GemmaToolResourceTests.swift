import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

extension GemmaToolConstraintTests {
    @Test("supported completion paths may exceed 256 tokens")
    func longCompletionPath() throws {
        let value = String(repeating: "x", count: 300)
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "const": .string(value),
                ]),
            ]),
            "required": .array([.string("value")]),
        ])
        var toolRequest = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        toolRequest.maxTokens = 512
        let prepared = try ToolChoicePromptPolicy.prepare(toolRequest)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: toolRequest,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: toolRequest.model, modelType: "gemma4_text"),
            defaultMaxTokens: 512,
            stopTokenIDs: [128])
        #expect(built != nil)
    }

    @Test("128 optional properties compile with linear grammar growth")
    func maximalOptionalSchemaIsLinear() throws {
        let nodeCount: (Int) throws -> Int = { propertyCount in
            var properties: [String: MLXLMCommon.JSONValue] = [:]
            for index in 0 ..< propertyCount {
                properties["p\(index)"] = .object([
                    "type": .string("string"),
                ])
            }
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object(properties),
            ])
            let toolRequest = request(
                choice: .mode(.required),
                tools: [tool(parameters: parameters)])
            let prepared = try ToolChoicePromptPolicy.prepare(toolRequest)
            var builder = GemmaByteNFABuilder()
            return try builder.build(
                tools: try #require(prepared.compiledTools),
                allowsParallel: false
            ).nodes.count
        }

        let halfSchemaNodes = try nodeCount(64)
        let maximalSchemaNodes = try nodeCount(128)
        #expect(maximalSchemaNodes > halfSchemaNodes)
        #expect(maximalSchemaNodes <= halfSchemaNodes * 2 + 512)
        #expect(maximalSchemaNodes < 100_000)

        var properties: [String: MLXLMCommon.JSONValue] = [:]
        for index in 0 ..< 128 {
            properties["p\(index)"] = .object(["type": .string("string")])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
        let toolRequest = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        let prepared = try ToolChoicePromptPolicy.prepare(toolRequest)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: toolRequest,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: toolRequest.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        #expect(built != nil)
    }

    @Test(
        "local production Gemma tokenizer compiles and accepts the canonical envelope",
        .enabled(if: Self.hasRealGemmaTokenizerFixture)
    )
    func realGemmaTokenizerIntegration() async throws {
        let directory = try #require(
            ModelScanner.resolveLocalPath(modelID: Self.realGemmaModelID))
        let loaded = try await LocalTokenizerLoader().load(from: directory)
        let handle = TokenizerHandle(
            loaded,
            toolConstraintContractVerified:
                Gemma4ToolConstraintContract.isVerified(
                    modelType: "gemma4_text",
                    modelDirectory: directory))
        let request = OpenAIChatCompletionRequest(
            model: "gemma-4-26b-qat-4bit",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: [tool()],
            toolChoice: .mode(.required),
            parallelToolCalls: false,
            maxTokens: 128)
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let eos = try #require(loaded.eosTokenId)

        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: handle,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [eos])
        let constraint = try #require(built)
        let output =
            #"<|tool_call>call:weather{city:<|"|>Paris<|"|>}<tool_call|>"#
        let tokens = loaded.encode(text: output, addSpecialTokens: false)
        var state = constraint.initialState
        for (offset, token) in tokens.enumerated() {
            let allowed = constraint.allowedTokenIDs(
                state: state, remainingTokens: 128 - offset)
            #expect(allowed.contains(token), "real token \(token) rejected at \(offset)")
            state = try #require(constraint.nextState(state: state, tokenID: token))
        }
        #expect(constraint.nextState(state: state, tokenID: eos) == -1)

        let cached = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: handle,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [eos])
        #expect(cached != nil)

        let unicodeParameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("string"),
                    "const": .string("👩🏽‍💻"),
                ]),
            ]),
            "required": .array([.string("value")]),
        ])
        let unicodeRequest = OpenAIChatCompletionRequest(
            model: request.model,
            messages: request.messages,
            tools: [tool(parameters: unicodeParameters)],
            toolChoice: .mode(.required),
            parallelToolCalls: false,
            maxTokens: 128)
        let unicodePrepared = try ToolChoicePromptPolicy.prepare(unicodeRequest)
        let unicodeBuilt = try ToolConstraintFactory.make(
            prepared: unicodePrepared,
            request: unicodeRequest,
            tokenizer: handle,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [eos])
        let unicodeConstraint = try #require(unicodeBuilt)
        let unicodeOutput =
            #"<|tool_call>call:weather{value:<|"|>👩🏽‍💻<|"|>}<tool_call|>"#
        var unicodeState = unicodeConstraint.initialState
        for token in loaded.encode(
            text: unicodeOutput, addSpecialTokens: false)
        {
            unicodeState = try #require(
                unicodeConstraint.nextState(
                    state: unicodeState, tokenID: token))
        }
        #expect(
            unicodeConstraint.nextState(
                state: unicodeState, tokenID: eos) == -1)
    }
}
