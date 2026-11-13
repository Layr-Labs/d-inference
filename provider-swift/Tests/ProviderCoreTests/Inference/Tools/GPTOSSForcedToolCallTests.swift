import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// GPT-OSS-shaped byte-level tokenizer: GPT-2 single-byte spellings at ids
/// 0...255, "x" for the other base ids, the Harmony control tokens at their
/// o200k ids and nothing else. Every text byte is its own token.
struct HarmonyByteTestTokenizer: MLXLMCommon.Tokenizer {
    static let controls: [(String, Int)] = [
        ("<|startoftext|>", 199998), ("<|endoftext|>", 199999), ("<|return|>", 200002), ("<|constrain|>", 200003),
        ("<|channel|>", 200005), ("<|start|>", 200006), ("<|end|>", 200007), ("<|message|>", 200008),
        ("<|call|>", 200012), ("<|endofprompt|>", 200018),
    ]
    static let endOfText = 199999, returnToken = 200002, constrain = 200003, channel = 200005
    static let start = 200006, end = 200007, message = 200008, call = 200012
    static let stops: Set<Int> = [endOfText, returnToken, call]
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = ByteLevelBPE.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    var controls = Self.controls

    static func tokens(_ text: String, controls: [(String, Int)] = controls) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let control = controls.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(control.1)
                index += control.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text, controls: controls) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id -> [UInt8] in
            if let control = controls.first(where: { $0.1 == id }) { return Array(control.0.utf8) }
            return id < 256 ? [UInt8(id)] : Array("x".utf8)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { controls.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let control = controls.first(where: { $0.1 == id }) { return control.0 }
        if id < 256 { return Self.byteSpelling[UInt8(id)] }
        return id < 199998 ? "x" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|return|>" }
    var unknownToken: String? { nil }
    /// A rendered prompt: it ends at the assistant boundary, as Harmony's does.
    static let prompt = tokens("<|start|>user<|message|>hi<|end|><|start|>assistant")

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Self.prompt }
}

enum GPTOSSForcedFixture {
    typealias T = HarmonyByteTestTokenizer

    static var weather: [String: Any] { ["type": "function", "function": [
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": [
            "type": "object",
            "properties": ["city": ["type": "string"], "unit": ["type": "string", "enum": ["c", "f"]]],
            "required": ["city"],
            "additionalProperties": false,
        ] as [String: Any],
    ] as [String: Any]] }
    static var time: [String: Any] { ["type": "function", "function": [
        "name": "get_time",
        "parameters": [
            "type": "object", "properties": ["timezone": ["type": "string"]], "required": ["timezone"],
        ] as [String: Any],
    ] as [String: Any]] }
    static var namedWeather: [String: Any] { ["type": "function", "function": ["name": "get_weather"]] }

    static func request(choice: Any?, tools: [[String: Any]] = [weather, time], effort: String? = nil,
                        maxTokens: Int? = nil) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(body(choice: choice, tools: tools, effort: effort, maxTokens: maxTokens),
            modelType: "gpt_oss")
    }

    static func body(choice: Any?, tools: [[String: Any]] = [weather, time], effort: String? = nil,
                     maxTokens: Int? = nil) throws -> Data {
        var body: [String: Any] = [
            "model": "gpt-oss-20b",
            "messages": [
                ["role": "system", "content": "You are a weather assistant."],
                ["role": "user", "content": "What is the weather in Paris right now?"],
            ],
            "tools": tools,
        ]
        if let choice { body["tool_choice"] = choice }
        if let effort { body["reasoning_effort"] = effort }
        if let maxTokens { body["max_tokens"] = maxTokens }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func vocabulary() throws -> JSONAnswerVocabulary {
        var pieces = [[UInt8]](repeating: [], count: JSONAnswerProfile.gptOSS.vocabularySize)
        for byte in 0...255 { pieces[byte] = [UInt8(byte)] }
        return try JSONAnswerVocabulary(pieces: pieces, profile: .gptOSS, stopTokenIDs: T.stops)
    }

    static func constraint(_ choice: Any, tools: [[String: Any]] = [weather, time],
                           maxTokens: Int = 4_096) throws -> GPTOSSForcedToolConstraint {
        let prepared = try ToolChoicePromptPolicy.prepare(request(choice: choice, tools: tools), modelType: "gpt_oss")
        return try GPTOSSForcedToolConstraint(mode: prepared.mode, tools: #require(prepared.compiledTools),
            tokenizer: T(), vocabulary: vocabulary(), maxTokens: maxTokens)
    }

    static func analysis(_ reasoning: String) -> String {
        "<|channel|>analysis<|message|>" + reasoning + "<|end|>"
    }

    static func call(_ name: String, _ arguments: String) -> String {
        "<|start|>assistant<|channel|>commentary to=functions.\(name) <|constrain|>json<|message|>" + arguments
    }

    /// Feeds `text` through the constraint as the sampler would: each token
    /// must be allowed at its budget before it is confirmed. Returns the final
    /// state (-1 after `<|call|>`), or nil at the first token refused.
    static func walk(_ text: String, _ constraint: GPTOSSForcedToolConstraint, from initial: Int = 0,
                     consumed: Int = 0) -> Int? {
        var state = initial
        for (offset, token) in T.tokens(text).enumerated() {
            let remaining = constraint.maxTokens - consumed - offset
            guard state >= 0, constraint.allowedTokenIDs(state: state, remainingTokens: remaining).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }
}

@Suite("GPT-OSS forced tool calls")
struct GPTOSSForcedToolCallTests {
    typealias F = GPTOSSForcedFixture
    typealias T = HarmonyByteTestTokenizer

    // MARK: - The constraint

    @Test("a named call is forced after the model reasons, with schema-valid arguments")
    func namedCallFollowsReasoning() throws {
        let constraint = try F.constraint(F.namedWeather)
        #expect(constraint.mode == .named)
        // The analysis header is forced token by token.
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 4_096) == [T.channel])
        let reasoned = try #require(F.walk(F.analysis("The user wants the weather in Paris."), constraint))
        // After the analysis only the named function's header is admitted.
        var state = reasoned
        for (offset, token) in T.tokens(F.call("get_weather", "")).enumerated() {
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 4_000 - offset) == [token])
            state = try #require(constraint.nextState(state: state, tokenID: token))
        }
        // The arguments are the function's schema; `<|call|>` only once the object closes.
        #expect(!constraint.allowedTokenIDs(state: state, remainingTokens: 3_000).contains(T.call))
        let complete = try #require(F.walk(#"{"city":"Paris","unit":"c"}"#, constraint, from: state))
        let closing = constraint.allowedTokenIDs(state: complete, remainingTokens: 2_000)
        #expect(closing.contains(T.call))
        #expect(closing.allSatisfy { $0 == T.call || [9, 10, 13, 32].contains($0) }, "only JSON whitespace or the call")
        #expect(constraint.nextState(state: complete, tokenID: T.call) == -1)
    }

    @Test("required admits exactly the declared functions after the analysis")
    func requiredChoosesADeclaredFunction() throws {
        let constraint = try F.constraint("required")
        #expect(constraint.mode == .required)
        let reasoned = try #require(F.walk(F.analysis("Paris weather."), constraint))
        for (name, arguments) in [("get_weather", #"{"city":"Paris"}"#), ("get_time", #"{"timezone":"CET"}"#)] {
            let state = try #require(F.walk(F.call(name, arguments), constraint, from: reasoned), "\(name)")
            #expect(constraint.nextState(state: state, tokenID: T.call) == -1, "\(name)")
        }
        // An undeclared function, a final answer, a commentary preamble and a
        // second analysis message are all impossible.
        #expect(F.walk(F.call("get_stock", "{}"), constraint, from: reasoned) == nil)
        #expect(F.walk("<|start|>assistant<|channel|>final<|message|>Sunny.", constraint, from: reasoned) == nil)
        #expect(F.walk("<|start|>assistant<|channel|>commentary<|message|>Checking.", constraint,
            from: reasoned) == nil)
        #expect(F.walk("<|start|>assistant<|channel|>analysis<|message|>More.", constraint, from: reasoned) == nil)
        // Nor can the model answer before reasoning or call without the analysis.
        #expect(F.walk("<|channel|>final<|message|>Sunny.", constraint) == nil)
        #expect(F.walk("<|channel|>commentary to=functions.get_weather", constraint) == nil)
    }

    @Test("arguments outside the schema cannot be generated")
    func argumentsFollowTheSchema() throws {
        let constraint = try F.constraint(F.namedWeather)
        let header = try #require(F.walk(F.analysis("ok") + F.call("get_weather", ""), constraint))
        for invalid in [#"{"city":1"#, #"{"country":"FR""#, #"{"city":"Paris","unit":"kelvin""#, "[", #""Paris""#,
                        #"{"city":"Paris","city""#] {
            #expect(F.walk(invalid, constraint, from: header) == nil, "\(invalid)")
        }
        // A missing required property keeps `<|call|>` impossible.
        let missing = try #require(F.walk(#"{"unit":"f""#, constraint, from: header))
        #expect(F.walk("}", constraint, from: missing) == nil)
        // Harmony spellings inside a string are refused, so the parser never
        // reads a frame boundary inside the arguments.
        #expect(F.walk(#"{"city":"<|call|>"#, constraint, from: header) == nil)
        #expect(F.walk(#"{"city":"<|end|>"#, constraint, from: header) == nil)
    }

    @Test("reasoning text never spells a Harmony control token")
    func reasoningNeverSpellsMarkers() throws {
        let constraint = try F.constraint("required")
        let open = try #require(F.walk("<|channel|>analysis<|message|>", constraint))
        for marker in ["<|end|>", "<|start|>", "<|channel|>", "<|message|>", "<|call|>", "<|return|>"] {
            let prefix = try #require(F.walk(String(marker.dropLast()), constraint, from: open), "\(marker)")
            #expect(!constraint.allowedTokenIDs(state: prefix, remainingTokens: 4_000).contains(Int(UInt8(ascii: ">"))))
            #expect(constraint.nextState(state: prefix, tokenID: Int(UInt8(ascii: ">"))) == nil, "\(marker)")
        }
        // Ordinary text with angle brackets and pipes is reasoning.
        #expect(F.walk("a <| b |> c -> d <|en x", constraint, from: open) != nil)
        // The analysis ends only with the `<|end|>` token.
        #expect(constraint.allowedTokenIDs(state: open, remainingTokens: 4_000).contains(T.end))
        for token in [T.call, T.returnToken, T.endOfText, T.start, T.channel, T.message, T.constrain] {
            #expect(!constraint.allowedTokenIDs(state: open, remainingTokens: 4_000).contains(token), "\(token)")
        }
    }

    @Test("near the budget the analysis ends so the call can start")
    func budgetEndsReasoning() throws {
        let constraint = try F.constraint(F.namedWeather, maxTokens: 400)
        let open = try #require(F.walk("<|channel|>analysis<|message|>", constraint))
        let reserve = constraint.analysisReserve
        #expect(reserve == 1 + T.tokens(F.call("get_weather", "")).count
            + GPTOSSForcedToolConstraint.argumentsAllowance + 1)
        #expect(constraint.allowedTokenIDs(state: open, remainingTokens: reserve + 1).count > 1)
        #expect(constraint.allowedTokenIDs(state: open, remainingTokens: reserve) == [T.end])
        #expect(constraint.maskCacheKey(state: open, remainingTokens: reserve) == -1)
        #expect(constraint.maskCacheKey(state: open, remainingTokens: reserve + 1) == open)
        #expect(constraint.allowedTokenIDs(state: open, remainingTokens: 0) == [])
        #expect(constraint.maskCacheKey(state: open, remainingTokens: 0) == nil)
        // A budget within the reserve ends the analysis at once, then calls.
        let tight = try F.constraint(F.namedWeather, maxTokens: 100)
        let tightOpen = try #require(F.walk("<|channel|>analysis<|message|>", tight))
        #expect(tight.allowedTokenIDs(state: tightOpen, remainingTokens: 90) == [T.end])
        let called = try #require(F.walk(F.analysis("") + F.call("get_weather", #"{"city":"Rome"}"#), tight))
        #expect(tight.nextState(state: called, tokenID: T.call) == -1)
        #expect(tight.allowsChainedDecode)
    }

    @Test("the constraint refuses tokenizers and choices it cannot frame")
    func refusesWhatItCannotFrame() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(F.request(choice: F.namedWeather), modelType: "gpt_oss")
        let tools = try #require(prepared.compiledTools)
        var missing = T()
        missing.controls.removeAll { $0.0 == "<|constrain|>" }
        var unencoded = T()
        unencoded.controls = unencoded.controls.map { $0.0 == "<|channel|>" ? ("<|channel|>", 7) : $0 }
        for tokenizer in [missing, unencoded] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try GPTOSSForcedToolConstraint(mode: prepared.mode, tools: tools, tokenizer: tokenizer,
                    vocabulary: F.vocabulary(), maxTokens: 100)
            }
        }
        for mode: ToolConstraintMode in [.auto, .none, .named("get_stock")] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try GPTOSSForcedToolConstraint(mode: mode, tools: tools, tokenizer: T(),
                    vocabulary: F.vocabulary(), maxTokens: 100)
            }
        }
        #expect(throws: ToolConstraintSchemaError.self) {
            try GPTOSSForcedToolConstraint(mode: prepared.mode, tools: tools, tokenizer: T(),
                vocabulary: F.vocabulary(), maxTokens: 0)
        }
    }

    // MARK: - Admission and serving

    @Test("the switch, the strategy and the advertisement")
    func switchStrategyAndAdvertisement() throws {
        let context = ChatTemplateFixContext(modelId: "gpt-oss-20b", modelType: "gpt_oss")
        for value in [nil, "", "on", "1", "true"] { #expect(GPTOSSForcedToolCalls.isEnabled(value), "\(value ?? "nil")") }
        for value in ["off", "OFF", "0", "false", "no", " off "] { #expect(!GPTOSSForcedToolCalls.isEnabled(value), "\(value)") }
        #expect(GPTOSSForcedToolCalls.applies(to: context, enabled: true))
        #expect(!GPTOSSForcedToolCalls.applies(to: context, enabled: false))
        #expect(!GPTOSSForcedToolCalls.applies(to: .init(modelId: "gpt-oss-20b", modelType: "gemma4"), enabled: true))
        let build = ModelInfo(id: "gpt-oss-20b", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        #expect(GPTOSSForcedToolCalls.advertises(build, enabled: true))
        #expect(!GPTOSSForcedToolCalls.advertises(build, enabled: false))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GPTOSSForcedToolCalls.environmentKey))
        #expect(LaunchAgent.passthroughEnvironment(from: [GPTOSSForcedToolCalls.environmentKey: "off"])[
            GPTOSSForcedToolCalls.environmentKey] == "off")
        for mode: ToolConstraintMode in [.required, .named("get_weather")] {
            let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: mode, modelContext: context)
            #expect(strategy == .harmonyFraming)
            try ToolChoiceEnforcementPolicy.validateParser(.harmony, strategy: strategy, modelContext: context)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoiceEnforcementPolicy.validateParser(.json, strategy: strategy, modelContext: context)
            }
        }
    }

    @Test("a named function that is not declared is a 400 before any generation")
    func undeclaredNamedFunctionIsAClientError() throws {
        let request = try F.request(choice: ["type": "function", "function": ["name": "get_stock"]])
        do {
            _ = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            Issue.record("expected a refusal")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .invalidToolPayload(_, let refusal) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(refusal == .invalidToolChoice)
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
        let noTools = try ProviderLoop.decodeOpenAIRequest(F.body(choice: "required", tools: []), modelType: "gpt_oss")
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoicePromptPolicy.prepare(noTools, modelType: "gpt_oss")
        }
    }

    @Test("auto and none are unchanged: same messages and tools, no constraint, no gate")
    func autoAndNoneAreUnchanged() throws {
        let handle = TokenizerHandle(T())
        for choice in [nil, "auto"] as [String?] {
            let request = try F.request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            #expect(prepared.mode == .auto)
            #expect(prepared.messages == request.messages)
            #expect(prepared.tools == request.tools)
            #expect(try ToolConstraintFactory.make(prepared: prepared, request: request, tokenizer: handle,
                modelContext: .init(modelId: "gpt-oss-20b", modelType: "gpt_oss"), defaultMaxTokens: 256,
                stopTokenIDs: T.stops, nativePromptTokens: T.prompt) == nil)
        }
        let none = try F.request(choice: "none")
        let preparedNone = try ToolChoicePromptPolicy.prepare(none, modelType: "gpt_oss")
        #expect(preparedNone.mode == .none && preparedNone.tools == nil)
        #expect(try ToolConstraintFactory.make(prepared: preparedNone, request: none, tokenizer: handle,
            modelContext: .init(modelId: "gpt-oss-20b", modelType: "gpt_oss"), defaultMaxTokens: 256,
            stopTokenIDs: T.stops, nativePromptTokens: T.prompt) == nil)
        // Auto text and calls route exactly as before: visible text is content.
        let request = try F.request(choice: "auto")
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        let handler = try #require(try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "gpt_oss", streamToolCalls: false))
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil)
        let answer = "<|channel|>final<|message|>It is sunny.<|return|>"
        let events = try router.process(answer)
        #expect(events.map(Self.content).joined() == answer)
    }

    @Test("the factory builds the constraint at the assistant boundary for forced choice")
    func factoryBuildsTheConstraint() throws {
        let handle = TokenizerHandle(T())
        for (choice, mode) in [("required", CBv2TokenConstraintMode.required), (F.namedWeather, .named)] as [(Any, CBv2TokenConstraintMode)] {
            let request = try F.request(choice: choice, maxTokens: 300)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            let constraint = try #require(try ToolConstraintFactory.make(prepared: prepared, request: request,
                tokenizer: handle, modelContext: .init(modelId: "gpt-oss-20b", modelType: "gpt_oss"),
                defaultMaxTokens: 1_000, stopTokenIDs: T.stops, nativePromptTokens: T.prompt)
                as? GPTOSSForcedToolConstraint)
            #expect(constraint.mode == mode)
            #expect(constraint.maxTokens == 300)
            // A prompt that does not end at the assistant boundary is refused.
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolConstraintFactory.make(prepared: prepared, request: request, tokenizer: handle,
                    modelContext: .init(modelId: "gpt-oss-20b", modelType: "gpt_oss"), defaultMaxTokens: 1_000,
                    stopTokenIDs: T.stops, nativePromptTokens: T.tokens("<|start|>assistant<|channel|>final"))
            }
        }
    }

    @Test("effort renders the same with forced choice, and the constraint does not depend on it")
    func effortWithForcedChoice() throws {
        for effort in [nil, "low", "medium", "high", "none", "xhigh"] as [String?] {
            var contexts: [NSDictionary] = []
            for choice in [nil, "required", F.namedWeather] as [Any?] {
                let body = try F.body(choice: choice, effort: effort)
                let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "gpt_oss")
                let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
                let controls = ProviderLoop.extractChatTemplateControls(from: body)
                try ReasoningEffortPolicy.validate(request, controls: controls, modelType: "gpt_oss")
                let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(for: request,
                    controls: controls, modelType: "gpt_oss", requiresToolCall: prepared.requiresToolCall) ?? [:]
                let expected = effort.flatMap(ReasoningEffort.init(clientValue:))?.harmonyLevel.rawValue
                #expect(context["reasoning_effort"] as? String == expected, "\(effort ?? "nil")")
                contexts.append(try #require(JSONSerialization.jsonObject(
                    with: JSONSerialization.data(withJSONObject: context)) as? NSDictionary))
            }
            // Required and named render the effort exactly as auto does.
            #expect(contexts.allSatisfy { $0.isEqual(to: contexts[0] as! [AnyHashable: Any]) }, "\(effort ?? "nil")")
            let forced = try F.constraint(F.namedWeather)
            let walked = F.walk(F.analysis("effort \(effort ?? "default")") + F.call("get_weather", #"{"city":"Paris"}"#),
                forced)
            #expect(walked.map { forced.nextState(state: $0, tokenID: T.call) } == -1)
        }
    }

    /// The engine's chunks hold whole tokens: one per decode step, or a few.
    @Test("forced output streams only its analysis, then one validated call", arguments: [1, 3, 8])
    func forcedOutputServes(width: Int) throws {
        for choice in ["required", F.namedWeather] as [Any] {
            let output = F.analysis("The user asks for Paris.") + F.call("get_weather", #"{"city":"Paris","unit":"c"}"#)
            let (calls, shown) = try serve(choice, output: output, width: width)
            #expect(calls.map(\.function.name) == ["get_weather"])
            #expect(calls.first?.function.arguments == ["city": .string("Paris"), "unit": .string("c")])
            #expect(shown == F.analysis("The user asks for Paris."))
        }
    }

    @Test("a forced response that answers, skips the call or calls another function fails closed")
    func forcedViolationsFailClosed() throws {
        let analysis = F.analysis("thinking")
        let cases: [(Any, String)] = [
            ("required", analysis + "<|start|>assistant<|channel|>final<|message|>Sunny."),
            ("required", "<|channel|>final<|message|>Sunny."),
            ("required", analysis),
            ("required", analysis + F.call("get_weather", #"{"city":1}"#)),
            (F.namedWeather, analysis + F.call("get_time", #"{"timezone":"UTC"}"#)),
        ]
        for (choice, output) in cases {
            for width in [1, 8] {
                do {
                    _ = try serve(choice, output: output, width: width)
                    Issue.record("expected a violation for \(output)")
                } catch MultiModelBatchSchedulerEngineError.toolChoiceViolation {
                }
            }
        }
    }

    // MARK: - Helpers

    /// The engine's complete-call terminal for a forced GPT-OSS request: route
    /// text in chunks of `width` whole tokens, flush the parser, validate
    /// before any call is exposed.
    private func serve(_ choice: Any, output: String, width: Int) throws -> (calls: [ToolCall], shown: String) {
        let request = try F.request(choice: choice)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        let handler = try #require(try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "gpt_oss"))
        #expect(handler.format == .harmony && !handler.streamsCalls)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: prepared.requiresToolCall,
            nativePrefix: nil, tools: prepared.tools?.map { $0.toolSpec() })
        var shown = ""
        let tokens = T.tokens(output)
        for start in stride(from: 0, to: tokens.count, by: width) {
            let chunk = T().decode(tokenIds: Array(tokens[start..<min(tokens.count, start + width)]),
                skipSpecialTokens: false)
            shown += try router.process(chunk).map(Self.content).joined()
        }
        shown += try router.finishText().map(Self.content).joined()
        let calls = handler.finish()
        try ToolConstraintValidation.validate(calls, prepared: prepared)
        return (calls, shown)
    }

    private static func content(_ event: MLXServerGenerationEvent) -> String {
        switch event {
        case .content(let text): text
        case .parsed(let parsed): parsed.content
        default: ""
        }
    }
}
