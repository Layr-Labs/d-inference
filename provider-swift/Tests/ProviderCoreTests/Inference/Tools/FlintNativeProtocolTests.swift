import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Flint native protocol constraints")
struct FlintNativeProtocolTests {
    private var tools: [[String: any Sendable]] {
        [
            ["type": "function", "function": ["name": "weather", "parameters": [
                "type": "object", "properties": [
                    "city": ["type": "string"], "payload": ["type": "object"],
                    "value": ["type": "null"], "é": ["type": "string"],
                ] as [String: any Sendable],
            ] as [String: any Sendable]] as [String: any Sendable]],
            ["type": "function", "function": ["name": "other", "parameters": [
                "type": "object", "properties": [:] as [String: any Sendable],
            ] as [String: any Sendable]] as [String: any Sendable]],
        ]
    }

    private func make(_ mode: ToolConstraintMode = .auto, parallel: Bool = true,
                      extra: [[UInt8]] = [], noTools: Bool = false) throws -> FlintNativeProtocolConstraint {
        let terminal = ["<|end_of_text|>", "<|user|>", "<|observation|>", "<|developer|>"]
        let pieces = terminal.map { Array($0.utf8) } + (0...255).map { [UInt8($0)] } + extra
        let vocabulary = FlintNativeVocabulary(pieces: pieces, stopTokenIDs: [0, 1, 2, 3],
            answerStops: [0, 1], observationStop: 2, fallbackTokenID: 0)
        return try FlintNativeProtocolConstraint(mode: mode, maxTokens: 100_000,
            vocabulary: vocabulary, allowsParallel: parallel,
            allowedToolNames: noTools ? [] : ["weather", "other"], tools: noTools ? nil : tools)
    }

    private func walk(_ text: String, _ constraint: FlintNativeProtocolConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for byte in text.utf8 {
            guard let next = constraint.nextState(state: state, tokenID: 4 + Int(byte)) else { return nil }
            state = next
        }
        return state
    }

    private func frame(_ value: String = "Paris", key: String = "city", name: String = "weather") -> String {
        "<tool_call>\(name)<arg_key>\(key)</arg_key><arg_value>\(value)</arg_value></tool_call>"
    }

    @Test func reasoningCannotStopOrExecuteItsQuotedCalls() throws {
        let constraint = try make(.none)
        let reasoning = try #require(walk("<think>Quoted " + frame("Tokyo"), constraint))
        for stop in 0...3 { #expect(constraint.nextState(state: reasoning, tokenID: stop) == nil) }
        for spelling in ["<|end_of_text|>", "<|user|>", "<|observation|>", "<|developer|>"] {
            #expect(walk(spelling, constraint, from: reasoning) == nil)
        }
        let content = try #require(walk("</think>Sunny.", constraint, from: reasoning))
        #expect(constraint.nextState(state: content, tokenID: 0) == -1)
        #expect(constraint.nextState(state: content, tokenID: 1) == -1)
        #expect(constraint.nextState(state: content, tokenID: 2) == nil)
        #expect(constraint.nextState(state: content, tokenID: 3) == nil)
        #expect(walk(frame(), constraint) == nil)
        #expect(walk("Sunny.<think>", constraint) == nil)
    }

    @Test func firstThinkCloseMatchesFlintChannelSplitterWithoutNestedMode() throws {
        let constraint = try make(.none)
        let state = try #require(walk("<think>literal <think>example</think>Answer.", constraint))
        #expect(constraint.nextState(state: state, tokenID: 0) == -1)
        #expect(walk("</think>", constraint, from: state) == nil)
    }

    @Test func automaticThinkingIsOptionalAndDoesNotForceAnAnswer() throws {
        for mode in [ToolConstraintMode.auto, .none] {
            let constraint = try make(mode, noTools: true)
            #expect(constraint.nextState(state: 0, tokenID: 0) == -1)
            #expect(walk("Direct answer.", constraint) != nil)
            #expect(walk("<think>reason</think>Answer.", constraint) != nil)
            #expect(walk(frame(), constraint) == nil)
            #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 0).isEmpty)
        }
    }

    @Test func answerMayEndWithLiteralMarkerPrefixButOpenFramesCannotStop() throws {
        for mode in [ToolConstraintMode.auto, .none] {
            let constraint = try make(mode)
            for text in ["<", "Answer <", "Answer </thi", "Answer <tool_call"] {
                let state = try #require(walk(text, constraint))
                for stop in [0, 1] {
                    #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).contains(stop))
                    #expect(constraint.nextState(state: state, tokenID: stop) == -1)
                }
            }
            let reasoning = try #require(walk("<think>reason </thi", constraint))
            for stop in 0...3 { #expect(constraint.nextState(state: reasoning, tokenID: stop) == nil) }
        }
        let required = try make(.required)
        for text in ["<", "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris"] {
            let state = try #require(walk(text, required))
            for stop in 0...3 { #expect(required.nextState(state: state, tokenID: stop) == nil) }
        }
    }

    @Test func modesAndParallelCardinalityFollowPreparedPolicy() throws {
        for mode in [ToolConstraintMode.auto, .required, .named("weather")] {
            let constraint = try make(mode, parallel: false)
            if mode != .auto {
                #expect(walk("Answer", constraint) == nil)
                #expect(constraint.nextState(state: 0, tokenID: 0) == nil)
            }
            let state = try #require(walk(frame(), constraint))
            #expect(constraint.nextState(state: state, tokenID: 2) == -1)
            for stop in [0, 1, 3] { #expect(constraint.nextState(state: state, tokenID: stop) == nil) }
            #expect(walk(frame(), constraint, from: state) == nil)
            #expect(walk("Answer", constraint, from: state) == nil)
            #expect(walk(frame(name: "missing"), constraint) == nil)
        }
        let named = try make(.named("weather"))
        #expect(walk("<tool_call>other</tool_call>", named) == nil)
        let required = try make(.required)
        let one = try #require(walk(frame(), required))
        #expect(walk("<tool_call>other</tool_call>", required, from: one) != nil)
        let auto = try make()
        #expect(walk("Checking. " + frame(), auto) != nil)
    }

    @Test func rawStringsStartingWithBracesKeepWhitespaceAndOpaqueMarkers() throws {
        for raw in ["  {\"unfinished\": 雪 </tool_call><think>literal</think>  ",
                    " \n[unfinished <|observation|> <tool_call>other  "] {
            let text = frame(raw)
            let constraint = try make(.required)
            let state = try #require(walk(text, constraint))
            #expect(constraint.nextState(state: state, tokenID: 2) == -1)
            let parsed = try #require(FlintToolCallParser().parse(content: text, tools: tools))
            #expect(parsed.function.arguments["city"] == .string(raw))
            let inValue = try #require(walk("<tool_call>weather<arg_key>city</arg_key><arg_value>", constraint))
            for stop in 0...3 { #expect(constraint.nextState(state: inValue, tokenID: stop) == nil) }
        }
    }

    @Test func JSONProtectsQuotedDelimitersEscapesAndUnicodeWhitespace() throws {
        let value = #"{"items":[{"text":"escaped \" </arg_value></tool_call><think> 雪","nil":null}]}"#
        for prefix in ["", " \n", "\u{2003}"] {
            let constraint = try make(.required)
            let text = frame(prefix + value, key: "payload")
            let state = try #require(walk(text, constraint))
            #expect(constraint.nextState(state: state, tokenID: 2) == -1)
            var scanner = FlintToolFrameScanner(tools: tools)
            var closes = 0
            for scalar in text.dropFirst("<tool_call>".count).unicodeScalars {
                if scanner.consume(scalar) { closes += 1 }
            }
            #expect(closes == 1)
            if prefix != "\u{2003}" { #expect(FlintToolCallParser().parse(content: text, tools: tools) != nil) }
        }
    }

    @Test func schemaKeyLookupPreservesUnicodeEquivalenceAndNullValues() throws {
        let constraint = try make(.required)
        let text = frame(" [raw ", key: "e\u{301}")
        #expect(walk(text, constraint) != nil)
        #expect(FlintToolCallParser().parse(content: text, tools: tools)?.function.arguments["é"] == .string(" [raw "))
        let nullable = frame("null", key: "value")
        #expect(walk(nullable, constraint) != nil)
        #expect(FlintToolCallParser().parse(content: nullable, tools: tools)?.function.arguments["value"] == .null)
    }

    @Test func completePiecesCannotHideTextAfterAClosingBoundary() throws {
        let pieces = [Array("</think>bad".utf8), Array((frame() + "bad").utf8)]
        let constraint = try make(.required, extra: pieces)
        let reasoning = try #require(walk("<think>reason", constraint))
        #expect(constraint.nextState(state: reasoning, tokenID: 260) == nil)
        #expect(!constraint.allowedTokenIDs(state: reasoning, remainingTokens: 100).contains(260))
        #expect(constraint.nextState(state: 0, tokenID: 261) == nil)
        #expect(!constraint.allowedTokenIDs(state: 0, remainingTokens: 100).contains(261))
    }

    @Test func protocolWorksAtEveryTokenSplitIncludingOpaquePayload() throws {
        let texts = ["<think>" + frame("Tokyo") + "</think>" + frame(),
                     frame(" { raw </tool_call><think> 雪 "),
                     frame(#"{"s":"</arg_value>","a":[null,true]}"#, key: "payload")]
        for text in texts {
            let bytes = Array(text.utf8)
            for split in 1..<bytes.count {
                let constraint = try make(.required, extra: [Array(bytes[..<split]), Array(bytes[split...])])
                let first = try #require(constraint.nextState(state: 0, tokenID: 260))
                let final = try #require(constraint.nextState(state: first, tokenID: 261))
                #expect(constraint.nextState(state: final, tokenID: 2) == -1)
            }
        }
    }

    @Test func masksAgreeWithTransitionsAtVisitedBoundaries() throws {
        for mode in [ToolConstraintMode.auto, .none, .required, .named("weather")] {
            let constraint = try make(mode)
            let paths = ["", "<", "<think>reason", "<think>reason</think>",
                         "<tool_call>wea", "<tool_call>weather<arg_key>ci",
                         "<tool_call>weather<arg_key>city</arg_key><arg_value>{ raw",
                         "<tool_call>weather<arg_key>payload</arg_key><arg_value>{\"s\":\"",
                         frame()]
            for path in paths {
                guard let state = walk(path, constraint) else { continue }
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
                #expect(allowed == Array(Set(allowed)).sorted())
                for token in 0..<260 {
                    #expect(allowed.contains(token) == (constraint.nextState(state: state, tokenID: token) != nil))
                }
            }
        }
    }

    @Test func maskCacheKeysIdentifyIdenticalMasksAndOptIntoChaining() throws {
        for mode in [ToolConstraintMode.auto, .none, .required] {
            let constraint = try make(mode)
            #expect(constraint.allowsChainedDecode)
            #expect(constraint.maskCacheKey(state: 0, remainingTokens: 0) == nil)
            #expect(constraint.maskCacheKey(state: constraint.cachedStateCount, remainingTokens: 10) == nil)
            var masksByKey: [Int: [Int]] = [:]
            for path in ["", "<", "<think>reason", "<think>reason</think>Answer",
                         "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris", frame()] {
                guard let state = walk(path, constraint) else { continue }
                for remaining in [1, 2, 100] {
                    let key = try #require(constraint.maskCacheKey(state: state, remainingTokens: remaining))
                    let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: remaining)
                    if let known = masksByKey[key] { #expect(known == allowed) } else { masksByKey[key] = allowed }
                }
            }
        }
    }

    @Test func longOpaqueTextReusesCanonicalStates() throws {
        let constraint = try make(.required)
        let state = try #require(walk("<tool_call>weather<arg_key>city</arg_key><arg_value>", constraint))
        let before = constraint.cachedStateCount
        var current = state
        for _ in 0..<20_000 { current = try #require(constraint.nextState(state: current, tokenID: 4 + 120)) }
        #expect(current == state)
        #expect(constraint.cachedStateCount == before)
    }

    @Test func malformedBoundariesAndResourceLimitsFailClosed() throws {
        let constraint = try make(.required)
        for text in ["<tool_call>weather<arg_value>", "<tool_call>weather<arg_key></arg_key>",
                     "<tool_call>weather<arg_key>city</arg_key> <arg_value>",
                     frame("literal </arg_value>tail"),
                     "<tool_call>weather<arg_key>" + String(repeating: "x", count: 1025),
                     "<tool_call>weather<arg_key>payload</arg_key><arg_value>" + String(repeating: "[", count: 129)] {
            #expect(walk(text, constraint) == nil)
        }
        // A syntactically valid delimiter is indistinguishable from an intended
        // raw literal. Do not claim recovery; duplicate keys/invalid JSON still
        // fail the retained complete-frame parser and schema validation.
        let invalidJSON = frame("oops", key: "value")
        #expect(walk(invalidJSON, constraint) != nil)
        #expect(FlintToolCallParser().parse(content: invalidJSON, tools: tools) == nil)
    }

    @Test func statePoolExhaustionIsBoundedAndCannotBecomeNormalEOS() throws {
        let constraint = try make(.required)
        var state = 0
        var exhausted = false
        for letter in "abcdefghijkl" {
            let text = frame("0", key: String(repeating: String(letter), count: 1024))
            guard let next = walk(text, constraint, from: state) else { exhausted = true; break }
            state = next
        }
        #expect(exhausted)
        #expect(constraint.cachedStateCount == FlintNativeProtocolConstraint.maximumStates)
        #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).isEmpty)
        #expect(constraint.maskCacheKey(state: state, remainingTokens: 100) == nil)
        #expect(constraint.nextState(state: state, tokenID: 2) == nil)
    }
}

@Suite("Flint constraint factory and vocabulary")
struct FlintNativeProtocolFactoryTests {
    private func request(choice: String = "\"auto\"", stop: String = "") throws -> OpenAIChatCompletionRequest {
        try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"test/flint","messages":[{"role":"user","content":"hi"}],"max_tokens":100,
         "tool_choice":\(choice),"tools":[{"type":"function","function":{"name":"weather",
         "parameters":{"type":"object","properties":{"city":{"type":"string"},
         "value":{"type":["string","null"],"enum":[null,"x"],"default":null}}}}}]\(stop)}
        """.utf8))
    }

    @Test func allModesUseNativeContractAndReuseVocabulary() throws {
        let handle = TokenizerHandle(FlintProtocolTestTokenizer())
        let stops: Set<Int> = [150001, 150003, 150005, 150018]
        let vocabulary = try FlintNativeVocabulary.cached(for: handle, stopTokenIDs: stops)
        #expect(try FlintNativeVocabulary.cached(for: handle, stopTokenIDs: stops) === vocabulary)
        for (choice, expected) in [("\"auto\"", CBv2TokenConstraintMode.auto), ("\"none\"", .none),
                                   ("\"required\"", .required),
                                   (#"{"type":"function","function":{"name":"weather"}}"#, .named)] {
            let request = try request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
            let constraint = try #require(try ToolConstraintFactory.make(prepared: prepared, request: request,
                tokenizer: handle, modelContext: .init(modelId: request.model, modelType: "flint"),
                defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: [150004]))
            #expect(constraint is FlintNativeProtocolConstraint)
            #expect(constraint.mode == expected)
        }
    }

    @Test func customStopsUseTheAnswerChannelAndBadBoundariesAreRefusedOnlyForExactFlint() throws {
        let request = try request(stop: #", "stop":["done"]"#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
        let handle = TokenizerHandle(FlintProtocolTestTokenizer())
        let stops: Set<Int> = [150001, 150003, 150005, 150018]
        let constraint = try ToolConstraintFactory.make(prepared: prepared, request: request, tokenizer: handle,
            modelContext: .init(modelId: request.model, modelType: "flint"),
            defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: [150004])
        #expect(constraint is FlintAnswerStopConstraint)
        #expect(constraint?.mode == .auto)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintFactory.make(prepared: prepared, request: request, tokenizer: handle,
                modelContext: .init(modelId: request.model, modelType: "flint"),
                defaultMaxTokens: 100, stopTokenIDs: stops, nativePromptTokens: [150006])
        }
        for type in ["other", "Flint", " flint "] {
            #expect(try ToolConstraintFactory.make(prepared: prepared, request: request, tokenizer: handle,
                modelContext: .init(modelId: request.model, modelType: type),
                defaultMaxTokens: 100, stopTokenIDs: [150001], nativePromptTokens: nil) == nil)
        }
        let clean = try self.request()
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolConstraintFactory.make(prepared: prepared, request: clean, tokenizer: handle,
                modelContext: .init(modelId: clean.model, modelType: "flint"),
                defaultMaxTokens: 100, stopTokenIDs: [150001], nativePromptTokens: [150006])
        }
    }

    @Test func byteProjectionAndPinnedContractAreVerified() throws {
        #expect(FlintNativeVocabulary.bytes("ĠaĊ") == Array(" a\n".utf8))
        #expect(FlintNativeVocabulary.bytes("Ã©") == Array("é".utf8))
        #expect(FlintNativeVocabulary.bytes("雪") == nil)
        #expect(throws: ToolConstraintSchemaError.self) {
            try FlintNativeVocabulary(tokenizer: FlintProtocolTestTokenizer(), stopTokenIDs: [150001, 150003, 150005])
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try FlintNativeVocabulary(tokenizer: FlintProtocolTestTokenizer(badMarkerEncoding: true),
                stopTokenIDs: [150001, 150003, 150005, 150018])
        }
    }
}

/// Shared protocol-only tokenizer for tests that never execute model logits.
struct FlintProtocolTestTokenizer: MLXLMCommon.Tokenizer {
    var badMarkerEncoding = false
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        badMarkerEncoding ? [] : convertTokenToId(text).map { [$0] } ?? []
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        FlintNativeVocabulary.markers.first { $0.0 == token }?.1
    }
    func convertIdToToken(_ id: Int) -> String? {
        guard (0..<150144).contains(id) else { return nil }
        return FlintNativeVocabulary.markers.first { $0.1 == id }?.0 ?? "x"
    }
    var bosToken: String? { "<|begin_of_text|>" }
    var eosToken: String? { "<|end_of_text|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [150004] }
}
