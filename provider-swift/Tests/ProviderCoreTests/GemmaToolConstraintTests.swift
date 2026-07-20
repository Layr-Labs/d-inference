import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

private struct ASCIIConstraintTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.utf8.map(Int.init)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.compactMap {
            $0 >= 0 && $0 < 128 ? UInt8($0) : nil
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? {
        if token == "<eos>" { return 128 }
        let bytes = Array(token.utf8)
        return bytes.count == 1 ? Int(bytes[0]) : nil
    }
    func convertIdToToken(_ id: Int) -> String? {
        if id == 128 { return "<eos>" }
        guard id >= 0, id < 128, let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    let bosToken: String? = nil
    let eosToken: String? = "<eos>"
    let unknownToken: String? = nil
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

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

@Suite("Gemma CBv2 tool constraints")
struct GemmaToolConstraintTests {
    private static let realGemmaModelID =
        "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static var hasRealGemmaTokenizerFixture: Bool {
        ModelScanner.resolveLocalPath(modelID: realGemmaModelID) != nil
    }

    private let tokenizer = TokenizerHandle(
        ASCIIConstraintTokenizer(),
        toolConstraintContractVerified: true)

    @Test("tool grammar accepts only exact Gemma types and pinned template bytes")
    func pinnedTemplateContract() throws {
        #expect(Gemma4ToolConstraintContract.supports(modelType: "gemma4_text"))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: "gemma4_assistant_v2"))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: nil))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("drifted template".utf8).write(
            to: directory.appendingPathComponent("chat_template.jinja"))
        #expect(
            !Gemma4ToolConstraintContract.isVerified(
                modelType: "gemma4_text",
                modelDirectory: directory))
    }

    private func tool(
        name: String = "weather",
        parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("city")]),
            "additionalProperties": .bool(false),
        ])
    ) -> OpenAITool {
        OpenAITool(function: .init(
            name: name, description: "Weather", parameters: parameters))
    }

    private func request(
        choice: OpenAIToolChoice,
        tools: [OpenAITool]? = nil,
        parallel: Bool = false
    ) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "gemma-4-test",
            messages: [.init(role: .user, content: .text("weather"))],
            tools: tools ?? [tool()],
            toolChoice: choice,
            parallelToolCalls: parallel,
            maxTokens: 128)
    }

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

    @Test("unsupported constrained schema fails before engine submission")
    func unsupportedSchemaFailsClosed() {
        let unsupported: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "oneOf": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("integer")]),
                    ]),
                ]),
            ]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(choice: .mode(.required), tools: [
                    tool(parameters: unsupported),
                ]))
        }
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

    @Test("structural schemas infer object and array types like the coordinator")
    func structuralTypeInferenceMatchesCoordinator() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "properties": .object([
                "values": .object([
                    "items": .object(["type": .string("string")]),
                    "maxItems": .int(2),
                ]),
            ]),
        ])
        let inferred = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        let prepared = try ToolChoicePromptPolicy.prepare(inferred)
        #expect(prepared.compiledTools?.count == 1)
    }

    @Test("unimplemented schema assertions never become prompt-only theater")
    func unknownSchemaKeywordFailsClosed() {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "minProperties": .int(1),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("provider and coordinator share the grammar complexity ceiling")
    func grammarComplexityFailsBeforeVocabularyBuild() {
        var value: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
        ])
        for _ in 0 ..< 4 {
            value = .object([
                "type": .string("array"),
                "items": value,
                "maxItems": .int(16),
            ])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["value": value]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

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

    @Test("finite strings cannot contain Gemma parser delimiters")
    func parserDelimiterFailsClosed() throws {
        for marker in [
            #"<|"|>"#, "<escape>", "<|tool_call>", "<tool_call|>",
            "<start_function_call>", "<end_function_call>",
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        "const": .string("bad\(marker)value"),
                    ]),
                ]),
                "required": .array([.string("value")]),
            ])
            let request = request(
                choice: .mode(.required),
                tools: [tool(parameters: parameters)])
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
    }

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
        var request = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        request.maxTokens = 512
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 512,
            stopTokenIDs: [128])
        #expect(built != nil)
    }

    @Test("128 optional properties compile within a bounded budget")
    func maximalOptionalSchemaIsLinear() throws {
        var properties: [String: MLXLMCommon.JSONValue] = [:]
        for index in 0 ..< 128 {
            properties["p\(index)"] = .object(["type": .string("string")])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
        let request = request(
            choice: .mode(.required),
            tools: [tool(parameters: parameters)])
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let clock = ContinuousClock()
        let start = clock.now
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelContext: .init(
                modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [128])
        #expect(built != nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test("nullable branches count toward the grammar complexity ceiling")
    func nullableBranchesAreCharged() {
        var properties: [String: MLXLMCommon.JSONValue] = [:]
        for index in 0 ..< 128 {
            properties["p\(index)"] = .object([
                "type": .array([.string("string"), .string("null")]),
                "enum": .array([.null]),
            ])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
        let tools = (0 ..< 64).map {
            tool(name: "tool\($0)", parameters: parameters)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(choice: .mode(.required), tools: tools))
        }
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

    @Test("parallel policy and schema validator reject invalid auto output")
    func outputValidation() throws {
        let baseRequest = request(choice: .mode(.auto), parallel: false)
        let prepared = try ToolChoicePromptPolicy.prepare(baseRequest)
        let valid = ToolCall(function: .init(
            name: "weather", arguments: ["city": .string("Paris")]))
        try ToolConstraintValidation.validate([valid], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([valid, valid], prepared: prepared)
        }
        let invalid = ToolCall(function: .init(
            name: "weather", arguments: ["city": .int(1)]))
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([invalid], prepared: prepared)
        }

        let broadSchema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "patternProperties": .object([
                "^city$": .object([
                    "oneOf": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("integer")]),
                    ]),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
        let broadRequest = request(
            choice: .mode(.auto),
            tools: [tool(parameters: broadSchema)],
            parallel: false)
        let broadPrepared = try ToolChoicePromptPolicy.prepare(broadRequest)
        #expect(broadPrepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["city": .string("Paris")])),
        ], prepared: broadPrepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["country": .string("FR")])),
            ], prepared: broadPrepared)
        }

        let unsafePatternSchema: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "patternProperties": .object([
                "^(a+)+$": .object(["type": .string("string")]),
            ]),
            "additionalProperties": .bool(false),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: unsafePatternSchema)],
                    parallel: false))
        }
    }

    @Test("unsupported auto regex fails before inference")
    func unsupportedAutoRegexFailsDuringPreparation() {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "code": .object([
                    "type": .string("string"),
                    "pattern": .string("^[a-z]+$"),
                ]),
            ]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("auto pattern validation distinguishes keywords from property names")
    func autoPatternPropertyNameIsNotAKeyword() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "pattern": .string("^city$"),
                ]),
            ]),
        ])
        _ = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
    }

    @Test("auto pattern depth does not count tuple containers")
    func autoPatternTupleContainerDepth() throws {
        var item: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
            "pattern": .string("^city$"),
        ])
        for _ in 0 ..< 17 {
            item = .object([
                "type": .string("array"),
                "items": .array([item]),
            ])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["value": item]),
        ])
        _ = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
    }

    @Test("auto pattern depth bounds malformed nested tuple arrays")
    func autoPatternMalformedTupleDepthIsBounded() {
        var items: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
            "pattern": .string("^city$"),
        ])
        for _ in 0 ..< 40 {
            items = .array([items])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("array"),
            "items": items,
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("auto validation honors draft-04 tuple items and additionalItems")
    func autoTupleItemsValidation() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "coordinates": .object([
                    "type": .string("array"),
                    "items": .array([
                        .object(["type": .string("integer")]),
                        .object(["type": .string("string")]),
                    ]),
                    "additionalItems": .bool(false),
                ]),
            ]),
            "required": .array([.string("coordinates")]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        #expect(prepared.compiledTools == nil)
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: [
                    "coordinates": .array([.int(7), .string("north")]),
                ])),
        ], prepared: prepared)
        for invalid in [
            MLXLMCommon.JSONValue.array([.string("north"), .int(7)]),
            .array([.int(7), .string("north"), .bool(true)]),
        ] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather",
                        arguments: ["coordinates": invalid])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto integer validation accepts only integral finite doubles")
    func autoIntegerValidationAcceptsIntegralDoubles() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "count": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("count")]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["count": .double(1.0)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["count": .double(1.5)])),
            ], prepared: prepared)
        }
    }

    @Test("auto enum and const compare JSON numbers mathematically")
    func autoNumericFiniteValuesCompareAcrossRepresentations() throws {
        for assertion in [
            ("enum", MLXLMCommon.JSONValue.array([.int(1)])),
            ("const", MLXLMCommon.JSONValue.int(1)),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("number"),
                        assertion.0: assertion.1,
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            #expect(prepared.compiledTools == nil)
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather", arguments: ["value": .double(1.0)])),
            ], prepared: prepared)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": .double(2.0)])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto uniqueItems uses JSON Schema numeric equality")
    func autoUniqueItemsUsesSchemaEquality() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "values": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("number")]),
                    "uniqueItems": .bool(true),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["values": .array([.int(1), .double(2.0)])])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["values": .array([.int(1), .double(1.0)])])),
            ], prepared: prepared)
        }
    }

    @Test("auto numeric bounds preserve integer precision")
    func autoNumericBoundsPreserveIntegerPrecision() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("integer"),
                    "maximum": .int(9_007_199_254_740_992),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .int(9_007_199_254_740_992)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .int(9_007_199_254_740_993)])),
            ], prepared: prepared)
        }
    }

    @Test("auto numeric bounds support the full finite Double range")
    func autoNumericBoundsSupportFullDoubleRange() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("number"),
                    "minimum": .double(1e199),
                    "maximum": .double(1e201),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather",
                arguments: ["value": .double(1e200)])),
        ], prepared: prepared)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintValidation.validate([
                .init(function: .init(
                    name: "weather",
                    arguments: ["value": .double(1e202)])),
            ], prepared: prepared)
        }
    }

    @Test("auto validation honors draft-04 boolean exclusive bounds")
    func autoDraft04ExclusiveBounds() throws {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "type": .string("number"),
                    "minimum": .int(5),
                    "exclusiveMinimum": .bool(true),
                    "maximum": .int(10),
                    "exclusiveMaximum": .bool(true),
                ]),
            ]),
        ])
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(
                choice: .mode(.auto),
                tools: [tool(parameters: parameters)]))
        try ToolConstraintValidation.validate([
            .init(function: .init(
                name: "weather", arguments: ["value": .int(6)])),
        ], prepared: prepared)
        for boundary in [5, 10] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintValidation.validate([
                    .init(function: .init(
                        name: "weather", arguments: ["value": .int(boundary)])),
                ], prepared: prepared)
            }
        }
    }

    @Test("auto string bounds count Unicode code points")
    func autoStringBoundsUseUnicodeCodePoints() throws {
        let decomposed = "e\u{301}"
        for (assertion, bound, shouldPass) in [
            ("minLength", 2, true),
            ("maxLength", 1, false),
        ] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        assertion: .int(bound),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            let call = ToolCall(function: .init(
                name: "weather", arguments: ["value": .string(decomposed)]))
            if shouldPass {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
    }

    @Test("auto validation restores normalized boolean schema semantics")
    func autoBooleanSchemaSemanticsSurviveNormalization() throws {
        for accepts in [true, false] {
            let parameters: MLXLMCommon.JSONValue = .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object([
                        "type": .string("string"),
                        ToolSchemaNormalization.originalBooleanSchemaKey:
                            .bool(accepts),
                    ]),
                ]),
            ])
            let prepared = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.auto),
                    tools: [tool(parameters: parameters)]))
            #expect(prepared.compiledTools == nil)
            let call = ToolCall(function: .init(
                name: "weather", arguments: ["value": .int(7)]))
            if accepts {
                try ToolConstraintValidation.validate([call], prepared: prepared)
            } else {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try ToolConstraintValidation.validate([call], prepared: prepared)
                }
            }
        }
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

        let clock = ContinuousClock()
        let start = clock.now
        let built = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: handle,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [eos])
        let compileDuration = start.duration(to: clock.now)
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
        #expect(compileDuration < .seconds(2))

        let cachedStart = clock.now
        _ = try ToolConstraintFactory.make(
            prepared: prepared,
            request: request,
            tokenizer: handle,
            modelContext: .init(modelId: request.model, modelType: "gemma4_text"),
            defaultMaxTokens: 128,
            stopTokenIDs: [eos])
        #expect(cachedStart.duration(to: clock.now) < .milliseconds(100))

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
