import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Required/named calls on the Qwen 3.5-family text route (Qwen 3.5 9B/35B,
/// 3.6, 3.8 on one Mac) open with a declared call frame, never with prose.
@Suite("Qwen forced tool calls are framed in the sampler")
struct QwenForcedToolFramingTests {
    private typealias F = QwenAnswerFixture
    /// One handle, so its framing vocabulary is built once for the suite.
    private static let handle = TokenizerHandle(QwenByteTestTokenizer())
    private static let toolCallClose = 248_059
    private static let twoTools = #"""
    [{"type":"function","function":{"name":"weather","parameters":{"type":"object",
      "properties":{"city":{"type":"string"}},"required":["city"]}}},
     {"type":"function","function":{"name":"time","parameters":{"type":"object","properties":{}}}}]
    """#
    private static let named = #"{"type":"function","function":{"name":"weather"}}"#

    private func request(choice: String?, parallel: Bool? = nil) throws -> OpenAIChatCompletionRequest {
        var body = #"{"model":"qwen3.6-35b-a3b-vl-mtp-mxfp8","messages":[{"role":"user","content":"hi"}],"#
            + #""max_tokens":64,"reasoning_parser":"qwen3","tools":"# + Self.twoTools
        if let choice { body += #","tool_choice":"# + choice }
        if let parallel { body += #","parallel_tool_calls":\#(parallel)"# }
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data((body + "}").utf8))
    }

    private func make(_ request: OpenAIChatCompletionRequest, modelType: String? = "qwen3_5_moe",
                      thinking: Bool = false, frames: Bool = true,
                      handle: TokenizerHandle = Self.handle) throws -> (any CBv2TokenConstraint)? {
        try ToolConstraintFactory.make(prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
            defaultMaxTokens: 100, stopTokenIDs: F.stops,
            nativePromptTokens: QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: thinking)),
            framesQwenForcedCalls: frames)
    }

    /// `Qwen4NativeToolConstraintTests` pins `allowedTokenIDs` to `nextState`.
    private func walk(_ text: String, _ constraint: any CBv2TokenConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for token in QwenByteTestTokenizer.tokens(text) {
            guard let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    private static func call(_ name: String, _ parameters: String = "") -> String {
        "<tool_call>\n<function=\(name)>\n\(parameters)</function>\n</tool_call>"
    }

    @Test func forcedCallsOnTheQwenTextRouteAreFramed() throws {
        for modelType in ["qwen3_5", "qwen3_5_moe"] {
            for choice in [#""required""#, Self.named] {
                let constraint = try #require(try make(request(choice: choice), modelType: modelType)
                    as? Qwen4NativeToolConstraint, "\(modelType) \(choice)")
                #expect(constraint.maxTokens == 64)
                let first = Set(constraint.allowedTokenIDs(state: 0, remainingTokens: 64))
                // The frame token, its spelling's first byte and framing whitespace.
                #expect(first.contains(F.toolCall) && first.contains(Int(UInt8(ascii: "<"))))
                #expect(first.contains(10) && first.contains(32))
                // No prose, no fence, no bare JSON, no thought and no empty answer can open it.
                for token in [Int(UInt8(ascii: "I")), Int(UInt8(ascii: "`")), Int(UInt8(ascii: "{")),
                              F.think, F.thinkClose, F.imEnd, F.endOfText] {
                    #expect(!first.contains(token), "\(modelType) \(choice) \(token)")
                }
            }
        }
    }

    @Test func aFramedCallEndsTheAnswerAndAnythingElseIsRefused() throws {
        let constraint = try #require(try make(request(choice: #""required""#)))
        let state = try #require(walk(Self.call("weather", "<parameter=city>\nParis\n</parameter>\n"), constraint))
        #expect(constraint.nextState(state: state, tokenID: F.imEnd) == -1)
        // After the call: whitespace, another frame or the end; never text.
        #expect(constraint.nextState(state: state, tokenID: Int(UInt8(ascii: "D"))) == nil)
        #expect(walk("Done", constraint, from: state) == nil)
        // Framed JSON is the dialect's other payload and stays admitted.
        let json = try #require(walk(#"<tool_call>{"name":"weather","arguments":{"city":"Paris"}}"#, constraint))
        #expect(constraint.nextState(state: json, tokenID: Self.toolCallClose) != nil)
        for prose in ["I will call weather.", "Sure!", "```xml\n<tool_call>", "<think>\nok\n</think>",
                      "<tool_call>\nweather", "<tool_call>\n<function=forecast>"] {
            #expect(walk(prose, constraint) == nil, "\(prose)")
        }
    }

    @Test func requiredAdmitsEveryDeclaredNameAndNamedOnlyItsOwn() throws {
        let required = try #require(try make(request(choice: #""required""#)))
        let named = try #require(try make(request(choice: Self.named)))
        for name in ["weather", "time"] {
            #expect(walk(Self.call(name), required) != nil, "required \(name)")
        }
        #expect(walk(Self.call("weather"), named) != nil)
        #expect(walk(Self.call("time"), named) == nil)
    }

    @Test func parallelCallsFollowTheRequest() throws {
        for parallel in [true, false] {
            let constraint = try #require(try make(request(choice: #""required""#, parallel: parallel)))
            let state = try #require(walk(Self.call("time") + "\n", constraint))
            #expect((constraint.nextState(state: state, tokenID: F.toolCall) != nil) == parallel)
            #expect(constraint.nextState(state: state, tokenID: F.imEnd) == -1)
        }
    }

    @Test func otherShapesKeepPromptOnlyPostValidation() throws {
        let required = try request(choice: #""required""#)
        // An engine that cannot run constraints (a pair, a native-tracked engine).
        #expect(try make(required, frames: false) == nil)
        // A thought this route cannot split from the call.
        #expect(try make(required, thinking: true) == nil)
        for choice in [nil, #""auto""#, #""none""#] as [String?] {
            #expect(try make(request(choice: choice)) == nil, "\(choice ?? "no choice")")
        }
        // Other families keep their own forced paths.
        for type in ["prism_hadamard_qwen35", "qwen3_vl_moe", "nemotron_h", "Qwen3_5", " qwen3_5"] {
            #expect(try make(required, modelType: type) == nil, "\(type)")
        }
        // A tokenizer whose framing tokens differ from the pinned ones.
        let moved = QwenByteTestTokenizer.pinned.map { $0.0 == "<tool_call>" ? ($0.0, 248_070) : $0 }
        #expect(try make(required, handle: TokenizerHandle(QwenByteTestTokenizer(markers: moved))) == nil)
        // The switch.
        let prepared = try ToolChoicePromptPolicy.prepare(required, modelType: "qwen3_5_moe")
        let prompt = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false))
        #expect(QwenForcedToolFraming.constraint(prepared: prepared, modelType: "qwen3_5_moe", tokenizer: Self.handle,
            maxTokens: 64, stopTokenIDs: F.stops, promptTokens: prompt, enabled: false) == nil)
        #expect(QwenForcedToolFraming.constraint(prepared: prepared, modelType: "qwen3_5_moe", tokenizer: Self.handle,
            maxTokens: 64, stopTokenIDs: F.stops, promptTokens: prompt, enabled: true) != nil)
    }

    @Test func onlyForcedCallsOnTheDualDialectParserTakeTheFraming() throws {
        let required = try ToolChoicePromptPolicy.prepare(request(choice: #""required""#), modelType: "qwen3_5")
        let named = try ToolChoicePromptPolicy.prepare(request(choice: Self.named), modelType: "qwen3_5")
        let auto = try ToolChoicePromptPolicy.prepare(request(choice: #""auto""#), modelType: "qwen3_5")
        #expect(QwenForcedToolFraming.isCandidate(prepared: required, parser: .qwen35))
        #expect(QwenForcedToolFraming.isCandidate(prepared: named, parser: .qwen35))
        #expect(!QwenForcedToolFraming.isCandidate(prepared: auto, parser: .qwen35))
        for parser in [ToolCallFormat.xmlFunction, .json, .nemotron, .mimoV2] {
            #expect(!QwenForcedToolFraming.isCandidate(prepared: required, parser: parser), "\(parser)")
        }
        #expect(!QwenForcedToolFraming.isCandidate(prepared: required, parser: nil))
    }

    @Test func theSwitchTurnsTheFramingOffAndReachesTheDaemon() {
        let key = QwenForcedToolFraming.environmentKey
        #expect(key == "DARKBLOOM_QWEN_FORCED_TOOL_FRAMING")
        #expect(QwenForcedToolFraming.isEnabled(environment: [:]))
        for value in ["on", "1", "true", "yes", ""] {
            #expect(QwenForcedToolFraming.isEnabled(environment: [key: value]), "\(value)")
        }
        for value in ["off", "0", "false", "no", " OFF ", "No"] {
            #expect(!QwenForcedToolFraming.isEnabled(environment: [key: value]), "\(value)")
        }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
    }

    @Test func onlyAnEngineThatRunsTokenConstraintsTakesTheFraming() {
        #expect(EngineV2Bridge.runsTokenConstraints(servesDistributedPair: false, tracksNativeShutdown: false))
        // A cluster pair refuses constraints before reserving; a native-tracked engine at submit.
        #expect(!EngineV2Bridge.runsTokenConstraints(servesDistributedPair: true, tracksNativeShutdown: false))
        #expect(!EngineV2Bridge.runsTokenConstraints(servesDistributedPair: false, tracksNativeShutdown: true))
        #expect(!EngineV2Bridge.runsTokenConstraints(servesDistributedPair: true, tracksNativeShutdown: true))
    }
}

/// The scheduler's text path on one Mac: what the engine is handed and what
/// the client sees, through the real `.qwen35` parser and validation.
@Suite("Qwen forced tool calls through the scheduler and bridge")
struct QwenForcedToolFramingServingTests {
    private let modelID = "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp"
    private static let tokenizer = TokenizerHandle(QwenByteTestTokenizer())
    private static let tools = #"""
    "tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object",
      "properties":{"city":{"type":"string"}},"required":["city"]}}},
     {"type":"function","function":{"name":"time","parameters":{"type":"object","properties":{}}}}]
    """#
    /// About 75 tokens to the byte-level stand-in, so its requests ask for 256.
    private static let xmlCall = "<tool_call>\n<function=weather>\n<parameter=city>\nParis\n</parameter>\n"
        + "</function>\n</tool_call>"

    /// Raw `.content` passes the service's qwen3 think parser, as it does
    /// downstream of the scheduler (the closed block's seed is not an answer).
    private struct Outcome {
        var content = ""
        var calls: [ToolCall] = []
        var error: (any Error)?
        private var parser = StreamingReasoningParser(format: .qwen3)

        mutating func record(_ event: MLXServerGenerationEvent) {
            switch event {
            case .content(let text): parser.parse(text).forEach { content += $0.content }
            case .parsed(let parsed): content += parsed.content
            case .toolCall(let call): calls.append(call)
            case .toolCallDelta(let delta): if let call = delta.completed { calls.append(call) }
            case .info, .logprobs: break
            }
        }

        mutating func finish() { parser.finish().forEach { content += $0.content } }
    }

    private func serve(_ engine: QwenScriptedEngine, modelType: String = "qwen3_5", fields: String) async throws
        -> Outcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [248046, 248044], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        #expect(await bridge.runsTokenConstraints)
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)]
        })
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"qwen3",\(Self.tools)\(fields)}
        """.utf8))
        var outcome = Outcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    @Test func aRequiredCallIsFramedAndReachesTheClientAsACall() async throws {
        let engine = QwenScriptedEngine(script: Self.xmlCall)
        let outcome = try await serve(engine, fields: #","tool_choice":"required","max_tokens":256"#)
        let request = try #require(engine.submitted.first)
        let constraint = try #require(request.tokenConstraint as? Qwen4NativeToolConstraint)
        #expect(constraint.maxTokens == request.maxTokens)
        #expect(outcome.error == nil)
        #expect(outcome.calls.map(\.function.name) == ["weather"])
        #expect(outcome.calls.first?.function.arguments["city"] == .string("Paris"))
        #expect(outcome.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(outcome.content.debugDescription)")
    }

    @Test func aNamedCallInTheFramedJSONDialectUsesTheBridgeDefaultBudget() async throws {
        // An omitted max_tokens: the engine resolves the bridge default (64,
        // not the scheduler's 4096), and the constraint must share it.
        let engine = QwenScriptedEngine(script: #"<tool_call>{"name":"weather","arguments":{"city":"Paris"}}</tool_call>"#)
        let outcome = try await serve(engine,
            fields: #","tool_choice":{"type":"function","function":{"name":"weather"}}"#)
        let request = try #require(engine.submitted.first)
        let constraint = try #require(request.tokenConstraint as? Qwen4NativeToolConstraint)
        #expect(request.maxTokens == 64 && constraint.maxTokens == 64)
        #expect(outcome.error == nil)
        #expect(outcome.calls.map(\.function.name) == ["weather"])
        #expect(outcome.calls.first?.function.arguments["city"] == .string("Paris"))
    }

    @Test func proseNeverReachesTheClientAndTheMissingCallStillFails() async throws {
        // The scripted model reaches for a sentence. Only framing whitespace or
        // a frame may open the answer, so the stand-in, which follows its
        // script or stops, ends after the whitespace with nothing else sampled.
        let engine = QwenScriptedEngine(script: "  I will check the weather in Paris.")
        let outcome = try await serve(engine, fields: #","tool_choice":"required","max_tokens":64"#)
        #expect(engine.submitted.first?.tokenConstraint is Qwen4NativeToolConstraint)
        #expect(outcome.calls.isEmpty)
        #expect(outcome.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(outcome.content.debugDescription)")
        #expect(outcome.error != nil)
    }

    @Test func autoCallsAndOtherFamiliesAreNotFramed() async throws {
        let auto = QwenScriptedEngine(script: Self.xmlCall)
        let outcome = try await serve(auto, fields: #","tool_choice":"auto","max_tokens":256"#)
        let request = try #require(auto.submitted.first)
        #expect(request.tokenConstraint == nil)
        #expect(outcome.error == nil && outcome.calls.map(\.function.name) == ["weather"])
        let bonsai = QwenScriptedEngine(script: Self.xmlCall)
        _ = try await serve(bonsai, modelType: "prism_hadamard_qwen35",
            fields: #","tool_choice":"required","max_tokens":256"#)
        #expect(bonsai.submitted.first?.tokenConstraint == nil)
    }
}

/// The production tokenizers and templates (tokenizer and template files only,
/// no weights): `DARKBLOOM_TEST_QWEN_TOKENIZER_DIRS=<dir>:<dir>…`, each holding a
/// build's `tokenizer.json`, `tokenizer_config.json`, `chat_template.jinja` and
/// `config.json` (for `model_type`).
@Suite("Qwen forced tool calls, real tokenizers",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIRS"] != nil))
struct QwenForcedToolFramingRealTokenizerTests {
    private static var tools: [[String: Any]] { [
        ["type": "function", "function": ["name": "get_weather", "description": "Get the current weather in a city.",
            "parameters": ["type": "object", "properties": ["location": ["type": "string"],
                "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]]], "required": ["location"]]]],
        ["type": "function", "function": ["name": "get_time", "description": "Get the local time in a city.",
            "parameters": ["type": "object", "properties": ["location": ["type": "string"]], "required": ["location"]]]],
    ] }

    @Test func theServedTokenizersFrameAForcedCall() async throws {
        let directories = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIRS"])
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let clock = ContinuousClock()
        for directory in directories {
            let label = directory.lastPathComponent
            let modelType = try Self.modelType(directory)
            let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
            let handle = TokenizerHandle(tokenizer)
            let stops = Set(["<|im_end|>", "<|endoftext|>"].compactMap { tokenizer.convertTokenToId($0) })
            let started = clock.now
            _ = try handle.qwen4FramingVocabulary(stopTokenIDs: stops)
            print("qwen-forced-framing \(label) model_type=\(modelType) vocabulary-build=\(clock.now - started)")
            for reasoning in [true, false] {
                for choice in ["required", "named"] {
                    let body = try Self.body(model: label, choice: choice, reasoning: reasoning)
                    let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: modelType)
                    let controls = ProviderLoop.extractChatTemplateControls(from: body)
                    let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
                    let prompt = try ProviderPromptContractPipeline.tokenize(prepared: prepared, request: request,
                        tokenizer: tokenizer, modelType: modelType, templateControls: controls)
                    let tail = tokenizer.decode(tokenIds: Array(prompt.suffix(ReasoningPromptProbe.tailTokenCount)),
                        skipSpecialTokens: false)
                    // The route renders the forced call with thinking off, whatever was asked.
                    #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == "<think></think>",
                        "\(label) \(choice) reasoning=\(reasoning): \(tail.debugDescription)")
                    let constraint = try #require(try ToolConstraintFactory.make(prepared: prepared, request: request,
                        tokenizer: handle, modelContext: .init(modelId: request.model, modelType: modelType),
                        defaultMaxTokens: 4_096, stopTokenIDs: stops, nativePromptTokens: prompt,
                        framesQwenForcedCalls: true), "\(label) \(choice)")
                    // A real tokenization of the call walks to the end of the answer.
                    let call = "<tool_call>\n<function=get_weather>\n<parameter=location>\nParis\n</parameter>\n"
                        + "</function>\n</tool_call>"
                    var state = 0
                    for (offset, token) in tokenizer.encode(text: call, addSpecialTokens: false).enumerated() {
                        #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 4_096 - offset).contains(token),
                            "\(label) \(choice) token \(token) at \(offset)")
                        state = try #require(constraint.nextState(state: state, tokenID: token))
                    }
                    let imEnd = try #require(tokenizer.convertTokenToId("<|im_end|>"))
                    #expect(constraint.nextState(state: state, tokenID: imEnd) == -1)
                    // The model's usual openings other than a call cannot be sampled.
                    let maskStarted = clock.now
                    let first = Set(constraint.allowedTokenIDs(state: 0, remainingTokens: 4_096))
                    let firstMask = clock.now - maskStarted
                    for opening in ["I'll check the weather.", "Sure", "Let me", "```", "{\"name\"", "<think>", "Okay"] {
                        let token = try #require(tokenizer.encode(text: opening, addSpecialTokens: false).first)
                        #expect(!first.contains(token), "\(label) \(opening.debugDescription) → \(token)")
                    }
                    if choice == "named" {
                        let other = "<tool_call>\n<function=get_time>"
                        var walked: Int? = 0
                        for token in tokenizer.encode(text: other, addSpecialTokens: false) {
                            walked = walked.flatMap { constraint.nextState(state: $0, tokenID: token) }
                        }
                        #expect(walked == nil, "\(label) named admits another function")
                    }
                    print("qwen-forced-framing \(label) \(choice) reasoning=\(reasoning) prompt=\(prompt.count) "
                        + "allowed-first=\(first.count) first-mask=\(firstMask)")
                }
            }
        }
    }

    private static func modelType(_ directory: URL) throws -> String {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json")))
        return try #require((config as? [String: Any])?["model_type"] as? String)
    }

    private static func body(model: String, choice: String, reasoning: Bool) throws -> Data {
        var toolChoice: Any = "required"
        if choice == "named" { toolChoice = ["type": "function", "function": ["name": "get_weather"]] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "What is the weather like in Paris today?"]],
            "tools": tools, "tool_choice": toolChoice, "reasoning": ["enabled": reasoning], "stream": true,
        ] as [String: Any])
    }
}
