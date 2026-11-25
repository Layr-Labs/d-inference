import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Inkling-2-shaped byte-level tokenizer: GPT-2 single-byte spellings at ids
/// 0...255, "x" for the other base ids, the Inkling message and content tokens
/// at their real ids and nothing else. Every text byte is its own token.
struct InklingByteTestTokenizer: MLXLMCommon.Tokenizer {
    static let controls: [(String, Int)] = [
        ("<|endoftext|>", 199999), ("<|message_user|>", 200000), ("<|message_model|>", 200001),
        ("<|message_system|>", 200002), ("<|message_tool|>", 200003), ("<|content_text|>", 200004),
        ("<|content_image|>", 200005), ("<|content_model_end_sampling|>", 200006),
        ("<|content_thinking|>", 200008), ("<|end_message|>", 200010), ("<|content_tool_error|>", 200022),
        ("<|content_xml|>", 200024), ("<|begin_of_text|>", 200028), ("<|content_invoke_tool_json|>", 200049),
        ("<|content_invoke_tool_text|>", 200057),
    ]
    static let messageModel = 200001, contentText = 200004, endOfSampling = 200006, contentThinking = 200008
    static let endMessage = 200010, invokeJSON = 200049, invokeText = 200057, toolError = 200022
    static let stops: Set<Int> = [endOfSampling]
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = ByteLevelBPE.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    static func tokens(_ text: String) -> [Int] {
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

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id -> [UInt8] in
            if let control = Self.controls.first(where: { $0.1 == id }) { return Array(control.0.utf8) }
            return id < 256 ? [UInt8(id)] : Array("x".utf8)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { Self.controls.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let control = Self.controls.first(where: { $0.1 == id }) { return control.0 }
        if id < 256 { return Self.byteSpelling[UInt8(id)] }
        return id < 199998 ? "x" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|content_model_end_sampling|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        Self.tokens("<|message_user|><|content_text|>hi<|end_message|>")
    }
}

/// Sampler-framed forced calls on Inkling 2 (`InklingForcedToolConstraint`),
/// with OpenRouter's tool-choice test tools.
@Suite("Inkling 2 forced tool calls")
struct InklingForcedToolCallTests {
    typealias T = InklingByteTestTokenizer

    static var calculate: [String: Any] { ["type": "function", "function": [
        "name": "calculate",
        "description": "Evaluate a mathematical expression",
        "parameters": [
            "type": "object",
            "properties": ["expression": ["type": "string", "description": "The expression to evaluate"]],
            "required": ["expression"],
        ] as [String: Any],
    ] as [String: Any]] }
    static var weather: [String: Any] { ["type": "function", "function": [
        "name": "get_current_weather",
        "description": "Get the current weather in a given location",
        "parameters": [
            "type": "object",
            "properties": [
                "location": ["type": "string"],
                "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]],
            ],
            "required": ["location"],
        ] as [String: Any],
    ] as [String: Any]] }
    static var namedCalculate: [String: Any] { ["type": "function", "function": ["name": "calculate"]] }

    static func prepared(_ choice: Any, tools: [[String: Any]] = [weather, calculate], parallel: Bool? = nil,
                         prompt: String = "Hi, how are you?") throws -> ToolChoicePromptPolicy.Prepared {
        var body: [String: Any] = [
            "model": "thinkingmachines/Inkling-2-Mini",
            "messages": [["role": "user", "content": prompt]],
            "tools": tools,
            "tool_choice": choice,
        ]
        if let parallel { body["parallel_tool_calls"] = parallel }
        let request = try ProviderLoop.decodeOpenAIRequest(try JSONSerialization.data(withJSONObject: body),
            modelType: "inkling2_loop")
        return try ToolChoicePromptPolicy.prepare(request, modelType: "inkling2_loop")
    }

    static func vocabulary() throws -> JSONAnswerVocabulary {
        var pieces = [[UInt8]](repeating: [], count: JSONAnswerProfile.inkling2Arguments.vocabularySize)
        for byte in 0...255 { pieces[byte] = [UInt8(byte)] }
        return try JSONAnswerVocabulary(pieces: pieces, profile: .inkling2Arguments,
            stopTokenIDs: T.stops.union([T.endMessage]))
    }

    static func constraint(_ choice: Any = "required", tools: [[String: Any]] = [weather, calculate],
                           parallel: Bool? = nil, maxTokens: Int = 4_096,
                           opensInMessage: Bool = false) throws -> InklingForcedToolConstraint {
        let prepared = try prepared(choice, tools: tools, parallel: parallel)
        return try InklingForcedToolConstraint(mode: prepared.mode, tools: #require(prepared.compiledTools),
            allowsParallel: prepared.allowsParallelCalls, tokenizer: T(), vocabulary: vocabulary(),
            maxTokens: maxTokens, opensInMessage: opensInMessage)
    }

    static func thought(_ text: String) -> String { "<|message_model|><|content_thinking|>" + text + "<|end_message|>" }

    static func call(_ name: String, _ body: String) -> String {
        "<|message_model|>" + name + "<|content_invoke_tool_json|>" + body + "<|end_message|>"
    }

    /// Feeds `tokens` as the sampler would: each must be allowed at its budget
    /// before it is confirmed. The final state (-1 after the end of sampling),
    /// or nil at the first token refused.
    static func walk(_ tokens: [Int], _ constraint: InklingForcedToolConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for (offset, token) in tokens.enumerated() {
            let remaining = constraint.maxTokens - offset
            guard state >= 0, constraint.allowedTokenIDs(state: state, remainingTokens: remaining).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    static func walk(_ text: String, _ constraint: InklingForcedToolConstraint) -> Int? {
        walk(T.tokens(text), constraint)
    }

    // MARK: - Calls

    @Test(arguments: [true, false])
    func aRequiredChoiceWalksAThoughtThenACall(thinks: Bool) throws {
        let constraint = try Self.constraint()
        let output = (thinks ? Self.thought("The user greets me; I must call a tool.") : "")
            + Self.call("calculate", #"{"name":"calculate","args":{"expression":"2+2"}}"#)
            + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, constraint) == -1)
    }

    @Test func noAnswerTextCanOpen() throws {
        let constraint = try Self.constraint()
        let header = try #require(Self.walk("<|message_model|>", constraint))
        let allowed = constraint.allowedTokenIDs(state: header, remainingTokens: 4_000)
        #expect(allowed.contains(T.contentThinking))
        for refused in [T.contentText, T.toolError, T.invokeText, T.endOfSampling, T.endMessage] {
            #expect(!allowed.contains(refused))
        }
        // Only the declared names' first pieces open a call.
        #expect(Set(allowed.filter { $0 < 256 }) == Set([Int(Character("c").asciiValue!),
                                                        Int(Character("g").asciiValue!)]))
        #expect(Self.walk("<|message_model|><|content_text|>I am fine.", constraint) == nil)
        // At the start, nothing but a message opens; the end of sampling waits for a call.
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 4_000) == [T.messageModel])
        // After the thought: a call only, no second thought and no text.
        let afterThought = try #require(Self.walk(Self.thought("Hmm.") + "<|message_model|>", constraint))
        let next = constraint.allowedTokenIDs(state: afterThought, remainingTokens: 4_000)
        #expect(!next.contains(T.contentThinking) && !next.contains(T.contentText))
    }

    @Test func aNamedChoiceAdmitsOnlyThatFunction() throws {
        let constraint = try Self.constraint(Self.namedCalculate)
        let header = try #require(Self.walk("<|message_model|>", constraint))
        #expect(constraint.allowedTokenIDs(state: header, remainingTokens: 4_000).filter { $0 < 256 }
            == [Int(Character("c").asciiValue!)])
        #expect(Self.walk(Self.call("get_current_weather", #"{"name":"get_current_weather","args":{"location":"Boston"}}"#),
                          constraint) == nil)
        let output = Self.thought("They asked about Boston weather, but calculate is required.")
            + Self.call("calculate", #"{"name":"calculate","args":{"expression":"0"}}"#) + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, constraint) == -1)
    }

    @Test func theBodyFollowsTheFunctionsSchema() throws {
        let constraint = try Self.constraint()
        for body in [
            #"{"name":"calculate","args":{"expression":2}}"#,
            #"{"name":"calculate","args":{"expression":"1","extra":true}}"#,
            #"{"name":"get_current_weather","args":{"expression":"1"}}"#,
            #"{"name":"calculate"}"#,
            #"{"name":"calculate","args":{}}"#,
            "calculate(2+2)",
        ] {
            #expect(Self.walk(Self.call("calculate", body), constraint) == nil, "\(body)")
        }
        // `args` first, spaces, and the closing braces together are all one valid body.
        let output = Self.call("get_current_weather",
            #"{ "args": {"location": "Boston, MA", "unit": "fahrenheit"}, "name": "get_current_weather" }"#)
            + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, constraint) == -1)
        // The body can never spell a message token as text.
        let open = try #require(Self.walk(#"<|message_model|>calculate<|content_invoke_tool_json|>{"name":"calculate","args":{"expression":""#,
                                          constraint))
        #expect(Self.walk(Array("<|end_message|>".utf8).map(Int.init), constraint, from: open) == nil)
    }

    @Test(arguments: [nil, true, false] as [Bool?])
    func parallelCallsFollowTheRequest(parallel: Bool?) throws {
        let constraint = try Self.constraint(parallel: parallel)
        let first = Self.call("calculate", #"{"name":"calculate","args":{"expression":"1"}}"#)
        let afterFirst = try #require(Self.walk(first, constraint))
        let allowed = constraint.allowedTokenIDs(state: afterFirst, remainingTokens: 4_000)
        #expect(allowed.contains(T.endOfSampling))
        #expect(allowed.contains(T.messageModel) == (parallel != false))
        let second = first + Self.call("calculate", #"{"name":"calculate","args":{"expression":"2"}}"#)
            + "<|content_model_end_sampling|>"
        #expect((Self.walk(second, constraint) == -1) == (parallel != false))
    }

    // MARK: - Thought

    @Test func theThoughtEndsWithinTheCallsReserveAndCap() throws {
        let constraint = try Self.constraint(maxTokens: 400)
        let thinking = try #require(Self.walk("<|message_model|><|content_thinking|>", constraint))
        #expect(constraint.allowedTokenIDs(state: thinking, remainingTokens: constraint.thoughtReserve)
            == [T.endMessage])
        #expect(constraint.allowedTokenIDs(state: thinking, remainingTokens: constraint.thoughtReserve + 1).count > 2)
        // A thought cannot start without room for the call.
        let header = try #require(Self.walk("<|message_model|>", constraint))
        #expect(!constraint.allowedTokenIDs(state: header, remainingTokens: constraint.thoughtReserve)
            .contains(T.contentThinking))
        // The cap ends a thought whatever the budget.
        let long = try Self.constraint(maxTokens: 40_000)
        let longThinking = try #require(Self.walk("<|message_model|><|content_thinking|>", long))
        #expect(long.allowedTokenIDs(state: longThinking,
            remainingTokens: 40_000 - InklingForcedToolConstraint.thoughtCap) == [T.endMessage])
        // A thought never spells a message token as text.
        #expect(Self.walk(Array("<|end_message|>".utf8).map(Int.init), constraint, from: thinking) == nil)
    }

    @Test func aPromptOpenAtTheModelMessageStartsAtItsHeader() throws {
        let constraint = try Self.constraint(opensInMessage: true)
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 4_000).contains(T.contentThinking))
        let output = "<|content_thinking|>ok<|end_message|>"
            + Self.call("calculate", #"{"name":"calculate","args":{"expression":"1"}}"#)
            + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, constraint) == -1)
    }

    // MARK: - What the stream reads

    /// The framed output is exactly what the channel lexer reads as a call.
    @Test func theFramedCallIsWhatTheLexerReads() throws {
        let prepared = try Self.prepared(Self.namedCalculate)
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: prepared.requiresToolCall,
            nativePrefix: nil, tools: prepared.tools?.map { $0.toolSpec() }, streamedCalls: prepared,
            nativeInklingChannels: true, inklingStreamsCalls: false)
        let output = Self.thought("Calculate is required.")
            + Self.call("calculate", #"{"name":"calculate","args":{"expression":"0"}}"#)
            + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, try Self.constraint(Self.namedCalculate)) == -1)
        _ = try router.process(output)
        _ = try router.finishText()
        let calls = try router.finishCompleteCalls(truncated: false).calls
        #expect(calls.map(\.function.name) == ["calculate"])
        #expect(calls.first?.function.arguments == ["expression": .string("0")])
    }

    // MARK: - OpenRouter's tool-choice bodies

    /// OpenRouter's endpoint tests for Inkling 2 Mini, as it sends them
    /// upstream (`tool_choice` required on a greeting with `calculate`; named
    /// `calculate` on a weather question with both tools; reasoning on and off).
    static let openRouterBodies: [(task: String, body: String)] = [
        ("reasoning-enabled-tool-choice-required", #"{"model":"thinkingmachines/Inkling-2-Mini","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Hi, how are you?"}],"max_tokens":65536,"tools":[{"type":"function","function":{"name":"calculate","description":"Perform a mathematical calculation","strict":true,"parameters":{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. 2 + 2"}},"additionalProperties":false,"required":["expression"]}}}],"tool_choice":"required","reasoning_effort":"high","chat_template_kwargs":{"thinking":true,"enable_thinking":true},"reasoning":{"enabled":true,"effort":"high"}}"#),
        ("reasoning-enabled-tool-choice-function", #"{"model":"thinkingmachines/Inkling-2-Mini","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"What is the weather like in Boston, MA in fahrenheit?"}],"max_tokens":65536,"tools":[{"type":"function","function":{"name":"get_current_weather","description":"Get the current weather in a given location","strict":true,"parameters":{"type":"object","properties":{"location":{"type":"string","description":"The city and state, e.g. San Francisco, CA"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"additionalProperties":false,"required":["location","unit"]}}},{"type":"function","function":{"name":"calculate","description":"Perform a mathematical calculation","strict":true,"parameters":{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. 2 + 2"}},"additionalProperties":false,"required":["expression"]}}}],"tool_choice":{"type":"function","function":{"name":"calculate"}},"reasoning_effort":"high","chat_template_kwargs":{"thinking":true,"enable_thinking":true},"reasoning":{"enabled":true,"effort":"high"}}"#),
        ("reasoning-disabled-tool-choice-required", #"{"model":"thinkingmachines/Inkling-2-Mini","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Hi, how are you?"}],"max_tokens":65536,"tools":[{"type":"function","function":{"name":"calculate","description":"Perform a mathematical calculation","strict":true,"parameters":{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. 2 + 2"}},"additionalProperties":false,"required":["expression"]}}}],"tool_choice":"required","chat_template_kwargs":{"thinking":false,"enable_thinking":false},"reasoning":{"enabled":false}}"#),
        ("reasoning-disabled-tool-choice-function", #"{"model":"thinkingmachines/Inkling-2-Mini","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"What is the weather like in Boston, MA in fahrenheit?"}],"max_tokens":65536,"tools":[{"type":"function","function":{"name":"get_current_weather","description":"Get the current weather in a given location","strict":true,"parameters":{"type":"object","properties":{"location":{"type":"string","description":"The city and state, e.g. San Francisco, CA"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"additionalProperties":false,"required":["location","unit"]}}},{"type":"function","function":{"name":"calculate","description":"Perform a mathematical calculation","strict":true,"parameters":{"type":"object","properties":{"expression":{"type":"string","description":"The mathematical expression to evaluate, e.g. 2 + 2"}},"additionalProperties":false,"required":["expression"]}}}],"tool_choice":{"type":"function","function":{"name":"calculate"}},"chat_template_kwargs":{"thinking":false,"enable_thinking":false},"reasoning":{"enabled":false}}"#),
    ]

    @Test(arguments: openRouterBodies.map(\.task))
    func openRoutersToolChoiceBodiesAreFramed(task: String) throws {
        let body = try #require(Self.openRouterBodies.first { $0.task == task }).body
        // Tools, choice, messages and budget as sent (the coordinator's own
        // handling of the reasoning fields is not under test here).
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "inkling2_loop")
        #expect(prepared.mode.requiresInferenceConstraint)
        let constraint = try InklingForcedToolConstraint(mode: prepared.mode, tools: #require(prepared.compiledTools),
            allowsParallel: prepared.allowsParallelCalls, tokenizer: T(), vocabulary: Self.vocabulary(),
            maxTokens: request.maxTokens ?? 65_536)
        // A greeting is not an answer: no text opens, only `calculate` does.
        #expect(Self.walk("<|message_model|><|content_text|>I am doing well", constraint) == nil)
        let header = try #require(Self.walk("<|message_model|>", constraint))
        #expect(constraint.allowedTokenIDs(state: header, remainingTokens: 60_000).filter { $0 < 256 }
            == [Int(Character("c").asciiValue!)])
        let output = Self.thought("A calculate call is required.")
            + Self.call("calculate", #"{"name":"calculate","args":{"expression":"2 + 2"}}"#)
            + "<|content_model_end_sampling|>"
        #expect(Self.walk(output, constraint) == -1)
        // The strict schema holds: no other key, no missing expression.
        #expect(Self.walk(Self.call("calculate", #"{"name":"calculate","args":{}}"#), constraint) == nil)
        #expect(Self.walk(Self.call("calculate", #"{"name":"calculate","args":{"expression":"1","unit":"c"}}"#),
                          constraint) == nil)
    }

    // MARK: - Refusals and the switch

    @Test func autoAndNoneAreNotFramed() throws {
        for choice in ["auto", "none"] {
            let prepared = try Self.prepared(choice)
            #expect(throws: (any Error).self) {
                try InklingForcedToolConstraint(mode: prepared.mode, tools: prepared.compiledTools ?? [],
                    allowsParallel: true, tokenizer: T(), vocabulary: Self.vocabulary(), maxTokens: 100)
            }
        }
    }

    @Test("`DARKBLOOM_INKLING_FORCED_TOOLS` off restores prompt-forced calls; it reaches the launchd daemon")
    func theSwitch() {
        for value in ["off", "false", "0", "none", "no", "disabled", " OFF "] {
            #expect(!InklingForcedToolCalls.isEnabled(value), "\(value)")
        }
        for value in [nil, "", "1", "on", "true"] as [String?] {
            #expect(InklingForcedToolCalls.isEnabled(value), "\(String(describing: value))")
        }
        #expect(InklingForcedToolCalls.applies(modelType: "inkling2_loop", enabled: true))
        #expect(!InklingForcedToolCalls.applies(modelType: "inkling2_loop", enabled: false))
        #expect(!InklingForcedToolCalls.applies(modelType: "gpt_oss", enabled: true))
        let key = InklingForcedToolCalls.environmentKey
        #expect(key == "DARKBLOOM_INKLING_FORCED_TOOLS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
    }
}
