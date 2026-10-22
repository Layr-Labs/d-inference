import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Shared request/constraint fixtures. The vocabulary is four Flint terminals,
/// every single byte, then optional multi-byte pieces, so the production byte
/// machine runs without a tokenizer, model or MLX array.
private enum FlintFormatFixture {
    static let schema = #"""
    {"type":"object","properties":{
      "name":{"type":"string"},"age":{"type":"integer"},
      "tags":{"type":"array","items":{"type":"string","enum":["a","b"]},"maxItems":2},
      "ok":{"type":["boolean","null"]},"score":{"type":"number"}},
     "required":["name","age"],"additionalProperties":false}
    """#
    static let tools = #"""
    [{"type":"function","function":{"name":"weather","parameters":{"type":"object",
      "properties":{"city":{"type":"string"}}}}}]
    """#

    static func request(format: String, tools: String? = nil, choice: String? = nil) throws
        -> OpenAIChatCompletionRequest
    {
        var body = #"{"model":"RecursiveSI/flint","messages":[{"role":"user","content":"hi"}],"max_tokens":64"#
        body += #","response_format":"# + format
        if let tools { body += #","tools":"# + tools }
        if let choice { body += #","tool_choice":"# + choice }
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data((body + "}").utf8))
    }

    static func schemaFormat(_ schema: String) -> String {
        #"{"type":"json_schema","json_schema":{"name":"out","schema":"# + schema + "}}"
    }

    static let jsonObject = #"{"type":"json_object"}"#

    static func grammar(_ format: String) throws -> FlintJSONGrammar {
        try #require(try FlintResponseFormat.resolve(request(format: format), modelType: "flint")).grammar
    }

    static func constraint(_ format: String, mode: ToolConstraintMode = .auto, names: Set<String> = [],
                           extra: [String] = [], extraBytes: [[UInt8]] = []) throws -> FlintNativeProtocolConstraint {
        let terminal = ["<|end_of_text|>", "<|user|>", "<|observation|>", "<|developer|>"]
        let pieces = terminal.map { Array($0.utf8) } + (0...255).map { [UInt8($0)] }
            + extra.map { Array($0.utf8) } + extraBytes
        let vocabulary = FlintNativeVocabulary(pieces: pieces, stopTokenIDs: [0, 1, 2, 3],
            answerStops: [0, 1], observationStop: 2, fallbackTokenID: 0)
        let tools: [[String: any Sendable]]? = names.isEmpty ? nil : [["type": "function", "function": [
            "name": "weather", "parameters": ["type": "object", "properties": [
                "city": ["type": "string"]] as [String: any Sendable]] as [String: any Sendable],
        ] as [String: any Sendable]]]
        return try FlintNativeProtocolConstraint(mode: mode, maxTokens: 100_000, vocabulary: vocabulary,
            allowsParallel: true, allowedToolNames: names, tools: tools, responseFormat: grammar(format))
    }

    static func walk(_ text: String, _ constraint: FlintNativeProtocolConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for byte in text.utf8 {
            guard let next = constraint.nextState(state: state, tokenID: 4 + Int(byte)) else { return nil }
            state = next
        }
        return state
    }

    static func singleBytes(_ allowed: [Int]) -> [UInt8] {
        allowed.filter { (4..<260).contains($0) }.map { UInt8($0 - 4) }
    }
}

@Suite("Flint response_format constraint")
struct FlintResponseFormatConstraintTests {
    private typealias F = FlintFormatFixture

    @Test func jsonObjectFollowsTheOptionalThought() throws {
        let constraint = try F.constraint(F.jsonObject)
        for text in [#"{"a":[1,true,null,"x"],"b":{}}"#, #"<think>plan {not json "</think>{"a":1}"#,
                     " \n<think>x</think> \n {\"a\":1} \n"] {
            let state = try #require(F.walk(text, constraint), "\(text)")
            #expect(constraint.nextState(state: state, tokenID: 0) == -1)
            #expect(constraint.nextState(state: state, tokenID: 1) == -1)
            #expect(constraint.nextState(state: state, tokenID: 2) == nil)
            #expect(constraint.nextState(state: state, tokenID: 3) == nil)
        }
        for text in ["Answer", "[1]", #""x""#, "1", "true", "<think>x</think>Answer", #"{"a":1}x"#,
                     #"{"a":1}{"#, "{'a':1}", #"{"a":1,}"#, #"{"a" 1}"#] {
            #expect(F.walk(text, constraint) == nil, "\(text)")
        }
        // Reasoning stays unconstrained but can never end the response.
        let reasoning = try #require(F.walk(#"<think>{{{ "unterminated"#, constraint))
        for stop in 0...3 { #expect(constraint.nextState(state: reasoning, tokenID: stop) == nil) }
        for stop in 0...3 { #expect(constraint.nextState(state: 0, tokenID: stop) == nil) }
    }

    @Test func eosIsMaskedUntilTheValueCompletes() throws {
        let constraint = try F.constraint(F.jsonObject)
        let text = #"{"a": [1, 2.5e-3, "q\"\\é"], "b": {"c": null}}"#
        let bytes = Array(text.utf8)
        for end in 0..<bytes.count {
            let state = try #require(F.walk(String(decoding: bytes[..<end], as: UTF8.self), constraint))
            #expect(!constraint.allowedTokenIDs(state: state, remainingTokens: 10).contains(0))
            #expect(constraint.nextState(state: state, tokenID: 0) == nil)
        }
        let complete = try #require(F.walk(text + " \n", constraint))
        #expect(constraint.allowedTokenIDs(state: complete, remainingTokens: 10).contains(0))
        #expect(constraint.nextState(state: complete, tokenID: 1) == -1)

        let integer = try F.constraint(F.schemaFormat(#"{"type":"integer","enum":[1,12,-3]}"#))
        for (text, stops) in [("1", true), ("12", true), ("-", false), ("-3", true)] {
            let state = try #require(F.walk(text, integer))
            #expect((integer.nextState(state: state, tokenID: 0) == -1) == stops, "\(text)")
        }
        #expect(F.walk("13", integer) == nil)
    }

    @Test func schemaValidOutputIsAcceptedAndViolationsAreMasked() throws {
        let constraint = try F.constraint(F.schemaFormat(F.schema))
        for text in [#"{"age": 3, "name": "Bo \"B\"", "tags": ["a", "b"], "ok": null, "score": -1.25e+2}"#,
                     #"{"name":"","age":-0}"#, "<think>r</think>\n{\n  \"name\": \"x\",\n  \"age\": 7\n}\n"] {
            let state = try #require(F.walk(text, constraint), "\(text)")
            #expect(constraint.nextState(state: state, tokenID: 0) == -1)
        }
        for text in [#"{"name":"Bo"}"#, #"{"nam""#, #"{"x""#, #"{"name":1"#, #"{"age":1.5"#,
                     #"{"age":"3""#, #"{"tags":["c""#, #"{"tags":["a","b","a""#, #"{"age":1,"age""#,
                     #"{"ok":"yes""#, #"{"age":01"#, #"{"score":1e100"#, #"{"name":"a\x"#,
                     "{\"name\":\"raw\nnewline", #"{"name":"\u12g"#] {
            #expect(F.walk(text, constraint) == nil, "\(text)")
        }
        let keyStart = try #require(F.walk(#"{""#, constraint))
        #expect(F.singleBytes(constraint.allowedTokenIDs(state: keyStart, remainingTokens: 10)) == Array("anost".utf8))
        let missingAge = try #require(F.walk(#"{"name":"Bo""#, constraint))
        #expect(F.singleBytes(constraint.allowedTokenIDs(state: missingAge, remainingTokens: 10)) == [9, 10, 13, 32, 44])
        let inAge = try #require(F.walk(#"{"name":"Bo","age":3"#, constraint))
        #expect(F.singleBytes(constraint.allowedTokenIDs(state: inAge, remainingTokens: 10))
            == [9, 10, 13, 32, 44] + Array(48...57) + [125])
        // Every declared key is present: another member cannot be started.
        let allSeen = try #require(F.walk(#"{"age":3,"name":"x","ok":true,"score":0,"tags":[]"#, constraint))
        #expect(F.singleBytes(constraint.allowedTokenIDs(state: allSeen, remainingTokens: 10)) == [9, 10, 13, 32, 125])
    }

    @Test func numbersStringsAndLiteralsFollowJSON() throws {
        let number = try F.constraint(F.schemaFormat(#"{"type":"number"}"#))
        for (text, complete) in [("-0.5e+10", true), ("1E5", true), ("0", true), ("1.", false), ("-", false)] {
            let state = try #require(F.walk(text, number), "\(text)")
            #expect((number.nextState(state: state, tokenID: 0) == -1) == complete, "\(text)")
        }
        for text in ["1e100", ".5", "--1", "01", "1.2.3", "+1"] { #expect(F.walk(text, number) == nil, "\(text)") }

        let integer = try F.constraint(F.schemaFormat(#"{"type":"integer"}"#))
        #expect(F.walk("123456789012345", integer) != nil)
        for text in ["1234567890123456", "1.5", "1e3"] { #expect(F.walk(text, integer) == nil, "\(text)") }

        let strings = try F.constraint(F.schemaFormat(#"{"type":"string","enum":["a\"b","line\nnext"]}"#))
        for text in [#""a\"b""#, #""line\nnext""#] {
            #expect(F.walk(text, strings).flatMap { strings.nextState(state: $0, tokenID: 0) } == -1, "\(text)")
        }
        #expect(F.walk(#""ab""#, strings) == nil)

        let nullable = try F.constraint(F.schemaFormat(#"{"type":["string","null"]}"#))
        for text in ["null", #""x""#] {
            #expect(F.walk(text, nullable).flatMap { nullable.nextState(state: $0, tokenID: 0) } == -1)
        }
        let partial = try #require(F.walk("nul", nullable))
        #expect(nullable.nextState(state: partial, tokenID: 0) == nil)

        let any = try F.constraint(F.jsonObject)
        let nested = #"{"a":{"b":[1,{"c":"d"}],"e":false},"f":-1.5E3,"g":"é\n"}"#
        #expect(F.walk(nested, any).flatMap { any.nextState(state: $0, tokenID: 0) } == -1)
    }

    @Test func callFramesAndProtocolMarkupAreImpossible() throws {
        let frame = "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>"
        for mode in [ToolConstraintMode.auto, .none] {
            let constraint = try F.constraint(F.jsonObject, mode: mode, names: mode == ToolConstraintMode.auto ? ["weather"] : [],
                extra: ["<tool_call>"])
            #expect(F.walk(frame, constraint) == nil)
            #expect(constraint.nextState(state: 0, tokenID: 260) == nil)
            let inString = try #require(F.walk(#"{"a":""#, constraint))
            #expect(constraint.nextState(state: inString, tokenID: 260) == nil)
            for (marker, _) in FlintNativeVocabulary.markers {
                #expect(F.walk(marker, constraint, from: inString) == nil, "\(marker)")
            }
            #expect(F.walk(#"<b> & </p> <thin""#, constraint, from: inString) != nil)
            let afterThought = try #require(F.walk("<think>" + frame + "</think>", constraint))
            #expect(F.walk(frame, constraint, from: afterThought) == nil)
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try F.constraint(F.jsonObject, mode: .required, names: ["weather"])
        }
    }

    @Test func masksAgreeWithTransitionsAtVisitedBoundaries() throws {
        let extra = ["{\"", "\":", "\", \"", " \"", "true", "null", "12", ".5", "e-", "\n  ", "\"}", "}]",
                     "</think>{\"", "<think>", "\\n", "\\u00", "\"a", "\"ab\"", "age", "name\":\"", "é",
                     "<tool_call>", "<thi", "nk>", "  ", "\"a\"", "\"b\"]", "-0", "1e", "x\ny", "x>"]
        let cases: [(String, [String])] = [
            (F.schemaFormat(F.schema), ["", " ", "<think>r", "<think>r</think>", "{", "{\"", "{\"na",
                "{\"name\"", "{\"name\":", "{\"name\":\"B", "{\"name\":\"B\\", "{\"name\":\"B\\u0",
                "{\"name\":\"Bo\"", "{\"name\":\"Bo\",\"age\":1", "{\"name\":\"Bo\",\"age\":1,\"tags\":[",
                "{\"name\":\"Bo\",\"age\":1,\"tags\":[\"a", "{\"name\":\"Bo\",\"age\":1,\"tags\":[\"a\",",
                "{\"name\":\"Bo\",\"age\":1}", "{\"name\":\"Bo\",\"age\":1} ", "{\"score\":1.5e", "{\"ok\":nu"]),
            (F.jsonObject, ["", "{", "{\"k", "{\"k\":", "{\"k\":[", "{\"k\":[1", "{\"k\":[1,t", "{\"k\":{}",
                "{\"k\":\"<thi", "{}"]),
        ]
        for (format, paths) in cases {
            let constraint = try F.constraint(format, extra: extra)
            for path in paths {
                let state = try #require(F.walk(path, constraint), "\(path)")
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
                #expect(allowed == Array(Set(allowed)).sorted())
                for token in 0..<(260 + extra.count) {
                    #expect(allowed.contains(token) == (constraint.nextState(state: state, tokenID: token) != nil),
                            "\(path) token \(token)")
                }
            }
        }
    }

    @Test func outputsAreAcceptedAtEveryTokenSplit() throws {
        for (format, text) in [(F.schemaFormat(F.schema), #"<think>a</think>{"name":"Bo","age":12,"tags":["a"]}"#),
                               (F.jsonObject, " {\"age\": -0, \"name\": \"x\\\"y\\u00e9\", \"ok\": [true]}\n")] {
            let bytes = Array(text.utf8)
            for split in 1..<bytes.count {
                let constraint = try F.constraint(format, extraBytes: [Array(bytes[..<split]), Array(bytes[split...])])
                let first = try #require(constraint.nextState(state: 0, tokenID: 260), "\(split)")
                let final = try #require(constraint.nextState(state: first, tokenID: 261), "\(split)")
                #expect(constraint.nextState(state: final, tokenID: 0) == -1)
            }
        }
    }

    @Test func stringStatesCollapseAndNestingIsBounded() throws {
        let constraint = try F.constraint(F.jsonObject)
        let inString = try #require(F.walk(#"{"a":""#, constraint))
        let before = constraint.cachedStateCount
        var state = inString
        for _ in 0..<20_000 { state = try #require(constraint.nextState(state: state, tokenID: 4 + 120)) }
        #expect(state == inString)
        #expect(constraint.cachedStateCount == before)
        let deepest = #"{"a":"# + String(repeating: "[", count: FlintJSONState.maximumDepth - 1)
        let nested = try #require(F.walk(deepest, constraint))
        #expect(F.walk("[", constraint, from: nested) == nil)
        #expect(F.walk("{", constraint, from: nested) == nil)
        #expect(F.walk("1", constraint, from: nested) != nil)
    }
}

@Suite("Flint response_format request policy")
struct FlintResponseFormatPolicyTests {
    private typealias F = FlintFormatFixture

    @Test func toolsWithAResponseFormatGetOnlyTheFormat() throws {
        let handle = TokenizerHandle(FlintProtocolTestTokenizer())
        let stops: Set<Int> = [150001, 150003, 150005, 150018]
        for choice in [nil, #""auto""#, #""required""#, #"{"type":"function","function":{"name":"weather"}}"#] {
            let request = try F.request(format: F.jsonObject, tools: F.tools, choice: choice)
            try FlintRequestPolicy.validate(request, controls: .init(), modelType: "flint")
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
            #expect(prepared.mode == ToolConstraintMode.none)
            #expect(prepared.tools == request.tools, "declarations still render as received")
            #expect(prepared.messages == request.messages, "no forcing instruction")
            #expect(prepared.allowedToolNames.isEmpty && prepared.compiledTools == nil)
            #expect(!prepared.requiresToolCall && prepared.responseFormat != nil)
            let constraint = try #require(try ToolConstraintFactory.make(prepared: prepared, request: request,
                tokenizer: handle, modelContext: .init(modelId: request.model, modelType: "flint"),
                defaultMaxTokens: 64, stopTokenIDs: stops, nativePromptTokens: [150004]) as? FlintNativeProtocolConstraint)
            // The pinned test vocabulary spells only markers and "x": the
            // optional thought is the one admissible opening.
            #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 10) == [150006])
            #expect(constraint.nextState(state: 0, tokenID: 150010) == nil)
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "flint"))
            #expect(handler.format == .flint)
        }
        let none = try ToolChoicePromptPolicy.prepare(
            F.request(format: F.jsonObject, tools: F.tools, choice: #""none""#), modelType: "flint")
        #expect(none.mode == ToolConstraintMode.none && none.tools == nil && none.responseFormat != nil)
        let plain = try ToolChoicePromptPolicy.prepare(F.request(format: F.jsonObject), modelType: "flint")
        #expect(plain.mode == .auto && plain.responseFormat != nil)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoicePromptPolicy.prepare(F.request(format: F.jsonObject, tools: F.tools,
                choice: #"{"type":"function","function":{"name":"missing"}}"#), modelType: "flint")
        }
    }

    @Test func uncompilableSchemasFailClosedAsInvalidRequests() throws {
        let schemas = [
            "{}", #"{"description":"anything"}"#, #"{"type":"string","pattern":"^a"}"#,
            #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
            #"{"type":"array","items":{"type":"string"},"maxItems":64}"#,
            #"{"type":"object","properties":{"a":{"nullable":true}}}"#,
            #"{"type":"string","enum":["<think>"]}"#,
            #"{"type":"object","properties":{"bad key":{"type":"string"}}}"#,
            #"{"type":"object","properties":{"a":{"type":"string","x-darkbloom-original-boolean-schema":true}}}"#,
        ]
        for format in schemas.map(F.schemaFormat) + [#"{"type":"json_schema"}"#] {
            let request = try F.request(format: format)
            do {
                _ = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
                Issue.record("accepted \(format)")
            } catch let error as MultiModelBatchSchedulerEngineError {
                guard case .invalidToolPayload(let message) = error else {
                    Issue.record("unexpected \(error)"); continue
                }
                #expect(message.hasPrefix("Flint response_format is"))
                #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
            }
        }
    }

    @Test func otherFamiliesAndFormatsAreUnchanged() throws {
        let request = try F.request(format: F.schemaFormat(F.schema), tools: F.tools)
        for type in ["qwen3_5", "Flint", " flint ", nil] as [String?] {
            #expect(try FlintResponseFormat.resolve(request, modelType: type) == nil)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: type)
            #expect(prepared.mode == .auto && prepared.tools == request.tools && prepared.responseFormat == nil)
        }
        let text = try F.request(format: #"{"type":"text"}"#, tools: F.tools)
        #expect(try FlintResponseFormat.resolve(text, modelType: "flint") == nil)
        #expect(try ToolChoicePromptPolicy.prepare(text, modelType: "flint").mode == .auto)
    }
}

#if DEBUG
@Suite("Flint response_format output validation")
struct FlintResponseFormatOutputTests {
    private typealias F = FlintFormatFixture

    private struct Outcome {
        var content = "", reasoning = "", calls = 0
        var error: (any Error)?
    }

    private func run(_ request: OpenAIChatCompletionRequest, output: [String], finish: String) async throws -> Outcome {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "flint")
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared, modelType: "flint")
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for chunk in output { continuation.yield(.chunk(chunk)) }
            continuation.yield(.info(promptTokens: 1, completionTokens: output.count, tokensPerSecond: 0,
                finishReason: finish))
            continuation.finish()
        }
        let stream = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler, nativeReasoningPrefix: "")
        var outcome = Outcome()
        do {
            for try await event in stream {
                switch event {
                case .parsed(let parsed):
                    outcome.content += parsed.content
                    outcome.reasoning += parsed.reasoningContent ?? ""
                case .content(let text): outcome.content += text
                case .toolCall: outcome.calls += 1
                case .info: break
                }
            }
        } catch { outcome.error = error }
        return outcome
    }

    @Test func validContentFollowingReasoningSucceeds() async throws {
        let request = try F.request(format: F.schemaFormat(F.schema))
        let outcome = try await run(request, output: ["<think>pl", "an</think>", #"{"name":"Bo","#, #""age":3}"#],
            finish: "stop")
        #expect(outcome.error == nil)
        #expect(outcome.reasoning == "plan")
        #expect(outcome.content == #"{"name":"Bo","age":3}"#)
        let root = try F.request(format: F.schemaFormat(#"{"type":"integer"}"#))
        #expect(try await run(root, output: ["12"], finish: "stop").error == nil)
    }

    @Test(arguments: [
        (["PRIVATE not json"], "stop"), ([#"{"name":"PRIVATE"}"#], "stop"),
        ([#"{"name":"PRIVATE","#], "length"), (["<think>PRIVATE reasoning only"], "length"),
        ([#"{"name":"PRIVATE","age":3} trailing"#], "stop"),
    ])
    func invalidOrIncompleteContentIsAnExplicitError(output: [String], finish: String) async throws {
        let outcome = try await run(try F.request(format: F.schemaFormat(F.schema)), output: output, finish: finish)
        let error = try #require(outcome.error as? MLXOpenAIServiceError)
        guard case .invalidResponseFormatOutput(let message) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(!message.contains("PRIVATE"), "errors never quote generated content")
        #expect(finish != "length" || message.contains("budget"))
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    @Test func truncatedRootNumbersAndNonObjectsFail() async throws {
        let integer = try F.request(format: F.schemaFormat(#"{"type":"integer"}"#))
        #expect(try await run(integer, output: ["12"], finish: "length").error is MLXOpenAIServiceError)
        let object = try F.request(format: F.jsonObject)
        #expect(try await run(object, output: ["[1]"], finish: "stop").error is MLXOpenAIServiceError)
        #expect(try await run(object, output: [#"{"a":1}"#], finish: "length").error == nil)
    }

    @Test func toolsWithAFormatNeverReturnCalls() async throws {
        let request = try F.request(format: F.jsonObject, tools: F.tools, choice: #""required""#)
        let valid = try await run(request, output: [#"{"city":"Paris"}"#], finish: "stop")
        #expect(valid.error == nil && valid.calls == 0 && valid.content == #"{"city":"Paris"}"#)
        let frame = "<tool_call>weather<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>"
        let call = try await run(request, output: [frame], finish: "stop")
        #expect(call.calls == 0)
        let error = try #require(call.error as? MultiModelBatchSchedulerEngineError)
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }
}
#endif
