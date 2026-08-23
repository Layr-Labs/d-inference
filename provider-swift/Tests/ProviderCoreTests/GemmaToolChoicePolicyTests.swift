import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

extension GemmaToolConstraintTests {
    @Test("named grammar rejects a different declared function")
    func namedChoiceFixesFunction() throws {
        let request = request(
            choice: .function(name: "weather"),
            tools: [tool(), tool(name: "forecast")])
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        let constraint = try #require(built)
        var state = constraint.initialState
        let wrong = Array("<|tool_call>call:forecast".utf8).map(Int.init)
        var rejected = false
        for token in wrong {
            guard let next = constraint.nextState(state: state, tokenID: token) else {
                rejected = true
                break
            }
            state = next
        }
        #expect(rejected)
    }

    @Test("named choice compiles only the selected tool schema")
    func namedChoiceIgnoresUnsupportedUnselectedSchema() throws {
        let unsupported: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "pattern": .string("^x$"),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .function(name: "weather"),
                tools: [tool(), tool(name: "unused", parameters: unsupported)]))
        #expect(prepared.tools?.map(\.function.name) == ["weather"])
        #expect(prepared.compiledTools?.map(\.name) == ["weather"])

        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .function(name: "unused"),
                    tools: [tool(), tool(name: "unused", parameters: unsupported)]))
        }
    }

    @Test("none grammar blocks both Gemma start tags while preserving text")
    func noneBlocksToolTags() throws {
        let request = request(choice: .mode(.none))
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        let constraint = try #require(built)

        var state = constraint.initialState
        for token in "ordinary answer".utf8.map(Int.init) {
            state = try #require(constraint.nextState(state: state, tokenID: token))
        }
        #expect(constraint.nextState(state: state, tokenID: 128) == -1)

        state = constraint.initialState
        var rejected = false
        for token in "<|tool_call>".utf8.map(Int.init) {
            guard let next = constraint.nextState(state: state, tokenID: token) else {
                rejected = true
                break
            }
            state = next
        }
        #expect(rejected)
    }

    @Test("tool_choice none needs no sampler grammar off the Gemma contract")
    func noneDoesNotRequireGemmaContract() throws {
        let noneRequest = request(choice: .mode(.none))
        let nonePrepared = try ToolChoicePromptPolicy.prepare(noneRequest)
        // `none` is honored by hiding the tools plus post-generation
        // rejection, so no automaton is needed off the pinned contract.
        #expect(nonePrepared.tools == nil)
        let offContract = try ToolConstraintFactory.make(
            prepared: nonePrepared,
            request: noneRequest,
            tokenizer: tokenizer,
            modelContext: .init(modelId: "llama-3-test", modelType: "llama"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        #expect(offContract == nil)
        let unverified = try ToolConstraintFactory.make(
            prepared: nonePrepared,
            request: noneRequest,
            tokenizer: TokenizerHandle(ASCIIConstraintTokenizer()),
            modelContext: .init(
                modelId: noneRequest.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        #expect(unverified == nil)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["city": .string("Paris")])),
            ], prepared: nonePrepared)
        }

        // Grammar-compiled modes stay fail-closed off the contract.
        for choice in [OpenAIToolChoice.mode(.required), .function(name: "weather")] {
            let forced = request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(forced)
            #expect(throws: MultiModelBatchSchedulerEngineError.self, "\(choice)") {
                _ = try ToolConstraintFactory.make(
                    prepared: prepared,
                    request: forced,
                    tokenizer: self.tokenizer,
                    modelContext: .init(
                        modelId: "llama-3-test", modelType: "llama"),
                    defaultMaxTokens: 128,
                    stopTokenIDs: [128])
            }
        }

        // A Gemma-capable model keeps the real no-tool automaton.
        let onContract = try ToolConstraintFactory.make(
            prepared: nonePrepared,
            request: noneRequest,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: noneRequest.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        #expect(onContract is GemmaNoToolTokenConstraint)
    }
}
