import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

#if DEBUG
@Suite("GLM tool suffix validation")
struct GLM5ToolFailureTests {
    private let valid = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"

    /// A malformed suffix commits no call. A required call fails (422); an
    /// `auto` response returns the suffix as text instead of failing.
    @Test(arguments: [false, true], [1, 7, 4096])
    func malformedSuffixNeverCommitsEarlierCall(forced: Bool, width: Int) async throws {
        let output = valid + "PRIVATE_STRAY"
        let result = try await run(output, forced: forced, width: width)
        expectUnparsed(result, output: output, forced: forced)
    }

    @Test(arguments: [false, true])
    func truncatedSecondCallNeverCommitsEarlierCall(forced: Bool) async throws {
        let output = valid + "<tool_call>echo<arg_key>text"
        let result = try await run(output, forced: forced, width: 1)
        expectUnparsed(result, output: output, forced: forced)
    }

    @Test(arguments: [false, true])
    func validCallSurvives(forced: Bool) async throws {
        let result = try await run(valid, forced: forced, width: 1)
        #expect(result.failure == nil)
        #expect(result.calls.map(\.function.name) == ["echo"])
        #expect(result.visible.isEmpty)
    }

    /// The SDK refuses an oversized suffix while it streams, before EOS: that
    /// still fails the response, `auto` included, before any of it is released.
    @Test(arguments: [false, true])
    func oversizedFrameFailsBeforeFallback(forced: Bool) async throws {
        let output = "<tool_call>echo" + String(repeating: "x", count: (1 << 20) + 1)
        let result = try await run(output, forced: forced, width: 65536)
        #expect(result.calls.isEmpty && result.visible.isEmpty)
        #expect(result.failure == (forced ? .toolChoiceViolation("native GLM tool output is invalid")
            : .generationFailed("native GLM tool output is invalid")))
    }

    /// An oversized suffix never bypasses the EOS checks: a think marker inside
    /// a drafted call is not released, whether the suffix arrives in pieces or
    /// in one delivery.
    @Test(arguments: [65536, 1 << 22])
    func oversizedSuffixIsNeverReleased(width: Int) async throws {
        let draft = "<tool_call>echo<arg_key>text</arg_key><arg_value></think></arg_value></tool_call>"
        let output = "Draft " + draft + "PRIVATE</think>Answer" + String(repeating: "x", count: 1 << 20)
        let result = try await run(output, forced: false, width: width)
        #expect(result.calls.isEmpty && !result.visible.contains("PRIVATE"))
        #expect(result.failure == .generationFailed("native GLM tool output is invalid"))
    }

    /// The model's raw output after the prompt's open `<think>` (the legacy
    /// text path: the tool parser also reads the reasoning), the calls an
    /// `auto` response returns, and its visible text, which the service's
    /// reasoning parser then splits at `</think>`. Shapes from the
    /// conformance replay: a tag mentioned or a call drafted in the thought, a
    /// text answer that mentions the tag, clean calls.
    static let strayCases: [(name: String, output: String, calls: [String], visible: String)] = {
        let call = "<tool_call>echo<arg_key>text</arg_key><arg_value>SAFE</arg_value></tool_call>"
        let other = "<tool_call>echo<arg_key>text</arg_key><arg_value>MORE</arg_value></tool_call>"
        let draft = "<tool_call>echo<arg_key>text</arg_key><arg_value>DRAFT</arg_value></tool_call>"
        return [
            ("call", "Need it.</think>" + call, ["SAFE"], "Need it.</think>"),
            ("call drafted in the thought", "I'll do " + draft + " maybe.</think>" + call, ["SAFE"],
             "I'll do " + draft + " maybe.</think>"),
            ("tag mentioned in the thought", "Wrap it in <tool_call> tags.</think>" + call, ["SAFE"],
             "Wrap it in <tool_call> tags.</think>"),
            ("tag mentioned in the thought, text answer",
             "The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool.", [],
             "The tool would need <tool_call> syntax, but I can answer.</think>Zürich is cool."),
            ("text answer mentions the tag", "Simple.</think>To call a tool, GLM writes <tool_call> first.", [],
             "Simple.</think>To call a tool, GLM writes <tool_call> first."),
            ("answer quotes a frame, then calls",
             "Simple.</think>The format is <tool_call> … </tool_call>. Calling: " + call, ["SAFE"],
             "Simple.</think>The format is <tool_call> … </tool_call>. Calling: "),
            ("two calls", "Two.</think>" + call + "\n" + other, ["SAFE", "MORE"], "Two.</think>"),
            ("call from an unclosed thought", "Need it." + call, ["SAFE"], "Need it."),
            ("call drafted in the thought, no call", "I'd do " + draft + "</think>", [],
             "I'd do " + draft + "</think>"),
            ("tag mentioned before two calls", "Use <tool_call>.</think>" + call + " " + other + "\n",
             ["SAFE", "MORE"], "Use <tool_call>.</think>"),
        ]
    }()

    @Test(arguments: GLM5ToolFailureTests.strayCases.indices, [1, 4096])
    func strayToolTagsAreTextAndTheFinalCallsParse(index: Int, width: Int) async throws {
        let shape = Self.strayCases[index]
        let result = try await run(shape.output, forced: false, width: width)
        #expect(result.failure == nil, "\(shape.name)")
        #expect(result.calls.count == shape.calls.count, "\(shape.name)")
        #expect(result.calls.compactMap { $0.function.arguments["text"]?.anyValue as? String } == shape.calls,
            "\(shape.name)")
        #expect(result.visible == shape.visible, "\(shape.name)")
    }

    /// A required call keeps failing closed when its suffix does not parse: the
    /// parser's own refusal, or the visible-text check when text precedes it.
    @Test(arguments: [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#])
    func forcedChoiceStillRefusesAStraySuffix(choice: String) async throws {
        let stray = try await run("<tool_call>.</tool_call>" + valid, forced: true, width: 1, choice: choice)
        #expect(stray.calls.isEmpty && stray.visible.isEmpty)
        #expect(stray.failure == .toolChoiceViolation("native GLM tool output is invalid"))
        let mentioned = try await run("Wrap it in <tool_call> tags.</think>" + valid, forced: true, width: 1,
            choice: choice)
        #expect(mentioned.calls.isEmpty && mentioned.visible.isEmpty)
        let failure = try #require(mentioned.failure)
        #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == 422)
    }

    static let storeTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"doc":{"type":"object"}},"required":["doc"]}}}"#

    /// The delimiters quoted inside a JSON argument are data: the calls start
    /// at the real frame, not at a quoted tag.
    @Test func quotedDelimitersStayArgumentData() async throws {
        let tool = Self.storeTool
        let output = "See <tool_call> here.</think><tool_call>store<arg_key>doc</arg_key>"
            + #"<arg_value>{"x":"</tool_call><tool_call>store"}</arg_value></tool_call>"#
        let result = try await run(output, forced: false, width: 3, tool: tool)
        #expect(result.failure == nil)
        #expect(result.calls.count == 1)
        #expect(result.calls.first?.function.arguments["doc"] == .object(["x": .string("</tool_call><tool_call>store")]))
        #expect(result.visible == "See <tool_call> here.</think>")
    }

    /// An undeclared or malformed final call is not salvaged: the response is
    /// text, as are its earlier calls.
    @Test func malformedFinalCallIsText() async throws {
        let output = "Use <tool_call>.</think>" + valid
            + "<tool_call>nope<arg_key>text</arg_key><arg_value>a</arg_value></tool_call>"
        let result = try await run(output, forced: false, width: 5)
        #expect(result.failure == nil)
        #expect(result.calls.isEmpty)
        #expect(result.visible == output)
    }

    /// Calls are never split out of a suffix that did not parse in an output
    /// the token limit cut off; a suffix that parses keeps its calls, as before.
    @Test func truncatedOutputIsNotSplit() async throws {
        let output = "Wrap it in <tool_call> tags.</think>" + valid
        let result = try await run(output, forced: false, width: 4, finishReason: "length")
        #expect(result.failure == nil)
        #expect(result.calls.isEmpty)
        #expect(result.visible == output)
        let clean = try await run("Need it.</think>" + valid, forced: false, width: 4, finishReason: "length")
        #expect(clean.failure == nil && clean.calls.count == 1 && clean.visible == "Need it.</think>")
    }

    /// A frame that has started its arguments owns everything up to its own
    /// `</tool_call>`: a frame inside an argument, or after one, is data and
    /// never becomes a call, whether the outer frame is cut off or closed.
    @Test(arguments: [nil, "length"], [1, 7, 4096])
    func framesInsideAFrameAreNeverCalls(finishReason: String?, width: Int) async throws {
        let nested = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let cases: [(output: String, tool: String?)] = [
            ("<tool_call>store<arg_key>doc</arg_key><arg_value>{\"x\":\"" + nested, Self.storeTool),
            ("<tool_call>echo<arg_key>text</arg_key><arg_value>draft " + valid, nil),
            ("Use <tool_call>.</think><tool_call>echo<arg_key>text</arg_key><arg_value>a</arg_value>junk" + valid, nil),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
            #expect(result.visible == shape.output, "\(shape.output)")
        }
    }

    /// Arguments that break the SDK's grammar end the lexer's reading of
    /// frames: a frame after them (here quoted in a JSON string the malformed
    /// value opened) stays data and never becomes a call, whether the output
    /// stops or is cut off. So does one after a name followed by anything but
    /// `<arg_key>` or `</tool_call>` that belongs to a frame.
    @Test(arguments: ["stop", "length"], [1, 7, 4096])
    func framesAfterMalformedArgumentsAreNeverCalls(finishReason: String, width: Int) async throws {
        let inner = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let open = "<tool_call>store<arg_key>doc</arg_key><arg_value>"
        let outputs = [
            open + #"{"x": ],"y":""# + "</tool_call>" + inner,
            open + #"{"x": <bad>,"y":""# + "</tool_call>" + inner,
            open + #"{"x": 1 "y":""# + "</tool_call>" + inner,
            "<tool_call>store<arg_value>" + inner,
            "<tool_call>store</arg_value>" + inner,
            "<tool_call>store</arg_key>" + inner,
        ]
        for output in outputs {
            let result = try await run(output, forced: false, width: width, finishReason: finishReason,
                tool: Self.storeTool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(output)")
            #expect(result.visible == output, "\(output)")
        }
    }

    /// Released text would hand a think marker from inside a drafted call to
    /// the service's reasoning parser as a channel boundary: that response keeps
    /// failing, as before.
    @Test func thinkMarkerInsideAReleasedFrameStillFails() async throws {
        let draft = "Draft <tool_call>echo<arg_key>text</arg_key><arg_value></think></arg_value></tool_call>"
        for output in [draft + "PRIVATE</think>Answer", draft + " more.</think>" + valid] {
            let result = try await run(output, forced: false, width: 5)
            #expect(result.calls.isEmpty && result.visible == "Draft ")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"))
        }
    }

    /// The same holds for a think marker in a key, after a frame whose
    /// arguments break the grammar (which owns the rest of the response), and
    /// in an output cut off at the token limit, whose whole suffix would be
    /// released.
    @Test(arguments: [1, 5, 4096])
    func thinkMarkerAnywhereInAReleasedFrameStillFails(width: Int) async throws {
        let cases: [(output: String, finishReason: String, tool: String?)] = [
            ("Draft <tool_call>echo<arg_key></think></arg_key><arg_value>0</arg_value></tool_call>PRIVATE</think>Answer",
             "stop", nil),
            ("Draft <tool_call>store<arg_key>doc</arg_key><arg_value>{bad}</arg_value></tool_call>PRIVATE</think>Answer",
             "stop", Self.storeTool),
            ("Draft <tool_call>. <tool_call>echo<arg_key>text</arg_key><arg_value></think>PRIVATE</arg_value></tool_call>",
             "length", nil),
            ("Draft <tool_call>echo<bad><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "stop", nil),
            ("Draft <tool_call>echo<bad><arg_key>text</arg_key><arg_value></think></arg_value></tool_call>PRIVATE</think>Answer",
             "length", nil),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: shape.finishReason,
                tool: shape.tool)
            #expect(result.calls.isEmpty && result.visible == "Draft ", "\(shape.output)")
            #expect(result.failure == .generationFailed("native GLM tool output is invalid"), "\(shape.output)")
        }
    }

    /// `store` with a declared object key `é` (U+00E9) and string-typed
    /// additional properties.
    static let accentTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"\u00e9":{"type":"object"}},"additionalProperties":{"type":"string"}}}}"#

    /// A frame never borrows a later frame's closing tags: a raw value holding
    /// the SDK's frame tags (which the SDK refuses), a malformed header that
    /// leads into arguments, and a key the SDK refuses because it only
    /// canonically equals a declared one each make the frame own the rest, so
    /// no frame after it is a call, at a stop or the token limit.
    @Test(arguments: ["stop", "length"], [1, 7, 4096])
    func framesNeverBorrowALaterFramesClose(finishReason: String, width: Int) async throws {
        let echo = { (text: String) in "<tool_call>echo<arg_key>text</arg_key><arg_value>\(text)</arg_value></tool_call>" }
        let inner = "<tool_call>store<arg_key>doc</arg_key><arg_value>{}</arg_value></tool_call>"
        let cases: [(output: String, tool: String?)] = [
            ("<tool_call>echo<arg_key>text</arg_key><arg_value>draft " + echo("ONE") + echo("TWO"), nil),
            ("<tool_call>store<bad><arg_key>doc</arg_key><arg_value>{\"x\":\"" + inner, Self.storeTool),
            ("<tool_call>store<arg_key>e\u{301}</arg_key><arg_value>{\"x\":\"</arg_value></tool_call><tool_call>store</tool_call>",
             Self.accentTool),
        ]
        for shape in cases {
            let result = try await run(shape.output, forced: false, width: width, finishReason: finishReason,
                tool: shape.tool)
            #expect(result.failure == nil && result.calls.isEmpty, "\(shape.output)")
            #expect(result.visible == shape.output, "\(shape.output)")
        }
    }

    /// Declared keys (byte for byte) and additional properties keep their
    /// types after a mention: the final call parses.
    @Test func declaredAndAdditionalKeysStillParse() async throws {
        for (frame, key, value) in [
            ("<tool_call>store<arg_key>\u{e9}</arg_key><arg_value>{}</arg_value></tool_call>", "\u{e9}",
             JSONValue.object([:])),
            ("<tool_call>store<arg_key>note</arg_key><arg_value>plain {text}</arg_value></tool_call>", "note",
             JSONValue.string("plain {text}")),
        ] {
            let result = try await run("Use <tool_call>.</think>" + frame, forced: false, width: 3, finishReason: "stop",
                tool: Self.accentTool)
            #expect(result.failure == nil && result.visible == "Use <tool_call>.</think>", "\(frame)")
            #expect(result.calls.map { $0.function.arguments } == [[key: value]], "\(frame)")
        }
    }

    /// A think marker inside the final call's own argument is that call's
    /// data: the call parses and nothing of it is released.
    @Test func thinkMarkerInsideTheFinalCallStaysItsArgument() async throws {
        let call = "<tool_call>echo<arg_key>text</arg_key><arg_value>strip </think> tags</arg_value></tool_call>"
        let result = try await run("Use <tool_call>.</think>" + call, forced: false, width: 3, finishReason: "stop")
        #expect(result.failure == nil)
        #expect(result.calls.compactMap { $0.function.arguments["text"]?.anyValue as? String } == ["strip </think> tags"])
        #expect(result.visible == "Use <tool_call>.</think>")
    }

    /// Finding the calls is linear in the suffix: many mentions before them.
    @Test func manyMentionsBeforeTheCalls() async throws {
        let mentions = String(repeating: "<tool_call> ", count: 20_000)
        let result = try await run(mentions + valid, forced: false, width: 65536)
        #expect(result.failure == nil && result.calls.count == 1 && result.visible == mentions)
    }

    /// And many adjacent frames after a mention: the run that ends the
    /// response is collected in one pass.
    @Test func manyFramesAfterAMention() throws {
        let tools: [[String: any Sendable]] = [["type": "function", "function": ["name": "a"] as [String: any Sendable]]]
        let suffix = "<tool_call>." + String(repeating: "<tool_call>a</tool_call>", count: 40_000)
        let split = GLM5ToolSuffix.split(suffix, tools: tools)
        guard case .text(let text, let calls) = split else {
            Issue.record("expected text and calls, got \(split)")
            return
        }
        #expect(text == "<tool_call>." && calls.count == 40_000)
        #expect(calls.allSatisfy { $0.function.name == "a" && $0.function.arguments.isEmpty })
    }

    /// And many additional properties against a large declared schema: each
    /// key's type is one lookup.
    @Test func manyAdditionalKeysAgainstALargeSchema() throws {
        var properties: [String: any Sendable] = [:]
        for index in 0 ..< 5_000 { properties["p\(index)"] = ["type": "string"] as [String: any Sendable] }
        let parameters: [String: any Sendable] = ["type": "object", "properties": properties,
                                                  "additionalProperties": ["type": "string"] as [String: any Sendable]]
        let tools: [[String: any Sendable]] = [["type": "function",
            "function": ["name": "f", "parameters": parameters] as [String: any Sendable]]]
        let arguments = (0 ..< 5_000).map { "<arg_key>x\($0)</arg_key><arg_value>v</arg_value>" }.joined()
        let split = GLM5ToolSuffix.split("<tool_call>.<tool_call>f" + arguments + "</tool_call>", tools: tools)
        guard case .text(let text, let calls) = split else {
            Issue.record("expected text and calls, got \(split)")
            return
        }
        #expect(text == "<tool_call>." && calls.count == 1 && calls.first?.function.arguments.count == 5_000)
    }

    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the whole-suffix failure.
    @Test func rollbackRestoresTheSuffixFailure() throws {
        let request = try MiMoConsumerFixture.request(choice: #""auto""#)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        for textFallback in [true, false] {
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "glm5_next"))
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                tools: prepared.tools?.map { $0.toolSpec() }, glmUnparsedOutputIsText: textFallback)
            _ = try router.process("Wrap it in <tool_call> tags.</think>" + valid)
            _ = try router.finishText()
            let finished = try router.finishCompleteCalls(truncated: false)
            if textFallback {
                try router.checkNativeToolFailure()
                #expect(finished.calls.count == 1)
                #expect(finished.residual == "<tool_call> tags.</think>")
            } else {
                #expect(finished.calls.isEmpty)
                #expect(throws: MultiModelBatchSchedulerEngineError.generationFailed(
                    "native GLM tool output is invalid")) { try router.checkNativeToolFailure() }
            }
        }
        #expect(GLM5ToolSuffix.environmentKey == "DARKBLOOM_GLM_TOOL_TEXT_FALLBACK")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GLM5ToolSuffix.environmentKey))
    }

    /// Forced choice is served by structured post-validation: the production
    /// handler is the native GLM parser, which withholds calls until EOS.
    @Test func publicForcedGLMUsesTheWithheldNativeParser() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"echo"}}"#] {
            let request = try MiMoConsumerFixture.request(choice: choice)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "glm5_next"))
            #expect(handler.format == .glm5 && !handler.streamsCalls)
            let context = ChatTemplateFixContext(modelId: request.model, modelType: "glm5_next")
            #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: prepared.mode, modelContext: context)
                == .structuredPostValidation)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try ToolChoiceEnforcementPolicy.validateParser(.json, strategy: .structuredPostValidation,
                    modelContext: context)
            }
        }
    }

    private struct Outcome {
        var calls: [ToolCall] = []
        var visible = ""
        var failure: MultiModelBatchSchedulerEngineError?
    }

    /// A required call fails closed (422); an `auto` response returns the
    /// unparsed suffix as text, with no call and no failure.
    private func expectUnparsed(_ result: Outcome, output: String, forced: Bool) {
        #expect(result.calls.isEmpty)
        if forced {
            #expect(result.visible.isEmpty)
            #expect(result.failure == .toolChoiceViolation("native GLM tool output is invalid"))
            if let failure = result.failure { #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == 422) }
        } else {
            #expect(result.failure == nil)
            #expect(result.visible == output)
        }
    }

    /// The production event stream on the legacy text path (no native
    /// channel), fed `width` characters at a time.
    private func run(_ output: String, forced: Bool, width: Int, finishReason: String? = nil,
                     tool: String? = nil, choice forcedChoice: String = #""required""#) async throws -> Outcome {
        let choice = forced ? forcedChoice : #""auto""#
        var request = try MiMoConsumerFixture.request(choice: choice)
        if let tool {
            var body = try #require(JSONSerialization.jsonObject(with: MiMoConsumerFixture.body(
                choice: choice)) as? [String: Any])
            body["tools"] = [try JSONSerialization.jsonObject(with: Data(tool.utf8))]
            request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
        }
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "glm5_next"))
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let upstream = AsyncStream<GenerationEvent> { continuation in
            let chars = Array(output)
            for start in stride(from: 0, to: chars.count, by: width) {
                continuation.yield(.chunk(String(chars[start..<min(start + width, chars.count)])))
            }
            if let finishReason {
                continuation.yield(.info(promptTokens: 1, completionTokens: 1, tokensPerSecond: 1,
                    finishReason: finishReason))
            }
            continuation.finish()
        }
        let stream = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {},
            prepared: prepared, releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"),
            toolHandler: handler)
        var result = Outcome()
        do {
            for try await event in stream {
                switch event {
                case .toolCall(let call): result.calls.append(call)
                case .content(let text): result.visible += text
                case .parsed(let value): result.visible += value.content
                default: break
                }
            }
        } catch { result.failure = try #require(error as? MultiModelBatchSchedulerEngineError) }
        return result
    }
}
#endif
