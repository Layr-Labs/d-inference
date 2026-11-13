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

    @Test(arguments: [false, true])
    func oversizedFrameFailsBeforeFallback(forced: Bool) async throws {
        let output = "<tool_call>echo" + String(repeating: "x", count: (1 << 20) + 1)
        let result = try await run(output, forced: forced, width: 65536)
        expectUnparsed(result, output: output, forced: forced)
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
    @Test func forcedChoiceStillRefusesAStraySuffix() async throws {
        let stray = try await run("<tool_call>.</tool_call>" + valid, forced: true, width: 1)
        #expect(stray.calls.isEmpty && stray.visible.isEmpty)
        #expect(stray.failure == .toolChoiceViolation("native GLM tool output is invalid"))
        let mentioned = try await run("Wrap it in <tool_call> tags.</think>" + valid, forced: true, width: 1)
        #expect(mentioned.calls.isEmpty && mentioned.visible.isEmpty)
        let failure = try #require(mentioned.failure)
        #expect(ProviderLoop.mapInferenceErrorToStatus(failure) == 422)
    }

    /// The delimiters quoted inside a JSON argument are data: the calls start
    /// at the real frame, not at a quoted tag.
    @Test func quotedDelimitersStayArgumentData() async throws {
        let tool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","properties":{"doc":{"type":"object"}},"required":["doc"]}}}"#
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

    /// Calls are never split out of an output the token limit cut off.
    @Test func truncatedOutputIsNotSplit() async throws {
        let output = "Wrap it in <tool_call> tags.</think>" + valid
        let result = try await run(output, forced: false, width: 4, finishReason: "length")
        #expect(result.failure == nil)
        #expect(result.calls.isEmpty)
        #expect(result.visible == output)
    }

    /// The search for the calls' first frame is bounded.
    @Test func callsAfterTooManyTagsStayText() async throws {
        let mentions = String(repeating: "<tool_call> ", count: GLM5ToolSuffix.maximumStarts)
        let within = try await run(String(mentions.dropFirst(12)) + valid, forced: false, width: 4096)
        #expect(within.calls.count == 1 && within.failure == nil)
        let beyond = try await run(mentions + valid, forced: false, width: 4096)
        #expect(beyond.calls.isEmpty && beyond.failure == nil)
        #expect(beyond.visible == mentions + valid)
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
            let finished = router.finishCompleteCalls(truncated: false)
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
                     tool: String? = nil) async throws -> Outcome {
        let choice = forced ? #""required""# : #""auto""#
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
