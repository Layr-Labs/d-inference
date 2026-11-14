// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Muse Glimmer output through the production tool-stream preparation, the
/// native router and the scheduler's forwarding body: what a client receives
/// as `reasoning_content`, `content` and `tool_calls`.
@Suite("Muse Glimmer tool stream")
struct MuseGlimmerToolStreamTests {
    private static let modelID = MuseGlimmerModelPolicy.catalogModelID
    private static let modelType = MuseGlimmerModelPolicy.modelType

    private static var tools: [[String: Any]] { [
        ["type": "function", "function": [
            "name": "get_weather", "description": "Weather for a city.",
            "parameters": ["type": "object", "required": ["city"], "properties": [
                "city": ["type": "string"], "days": ["type": "integer"],
                "detail": ["type": "boolean"], "tags": ["type": "array", "items": ["type": "string"]]]]]],
        ["type": "function", "function": [
            "name": "docs_read", "description": "Read one document.",
            "parameters": ["type": "object", "required": ["path"],
                           "properties": ["path": ["type": "string"]]]]],
    ] }

    private struct Outcome {
        var reasoning = ""
        var content = ""
        var calls: [ToolCall] = []
        var info: ServerGenerationInfo?

        mutating func record(_ event: MLXServerGenerationEvent) {
            switch event {
            case .content(let text): content += text
            case .parsed(let parsed):
                content += parsed.content
                reasoning += parsed.reasoningContent ?? ""
            case .toolCall(let call): calls.append(call)
            case .toolCallDelta(let delta): if let call = delta.completed { calls.append(call) }
            case .logprobs: break
            case .info(let info): self.info = info
            }
        }
    }

    private struct Fixture {
        let request: OpenAIChatCompletionRequest
        let prepared: ToolChoicePromptPolicy.Prepared
        let controls: ChatTemplateControls

        init(tools: [[String: Any]]? = MuseGlimmerToolStreamTests.tools, extra: [String: Any] = [:]) throws {
            var body: [String: Any] = [
                "model": MuseGlimmerToolStreamTests.modelID, "stream": true,
                "messages": [["role": "user", "content": "Weather in Paris?"]],
            ]
            if let tools { body["tools"] = tools }
            body.merge(extra) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: body)
            request = try ProviderLoop.decodeOpenAIRequest(data, modelType: MuseGlimmerToolStreamTests.modelType)
            controls = ProviderLoop.extractChatTemplateControls(from: data)
            var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: MuseGlimmerToolStreamTests.modelType)
            // As the scheduler sets it: the caller's declarations as sent.
            prepared.declaredTools = controls.declaredTools
            self.prepared = prepared
        }

        var withholdsReasoning: Bool {
            ProviderPromptContractPipeline.withholdsReasoning(
                request, controls: controls, modelType: MuseGlimmerToolStreamTests.modelType)
        }
    }

    private static func call(_ name: String, _ parameters: [(String, String)] = [], recipient: String? = nil) -> String {
        "<|start|>assistant to=\(recipient ?? name)<|message|><atem:function_calls>\n" + invoke(name, parameters)
            + "\n</atem:function_calls>"
    }

    private static func invoke(_ name: String, _ parameters: [(String, String)] = []) -> String {
        "<atem:invoke name=\"\(name)\">\n"
            + parameters.map { "<atem:parameter name=\"\($0.0)\">\($0.1)</atem:parameter>\n" }.joined()
            + "</atem:invoke>"
    }

    /// The model's text after the generation prompt's `<|start|>assistant`.
    private static func generated(_ frames: String) -> String {
        precondition(frames.hasPrefix("<|start|>assistant"))
        return String(frames.dropFirst("<|start|>assistant".count))
    }

    #if DEBUG
    /// The scheduler's own forwarding body over a scripted engine stream.
    private func stream(
        _ fixture: Fixture, _ output: String, chunk: Int = 5, finish: String = "stop", reference: Bool = true
    ) async throws -> Outcome {
        var events: [GenerationEvent] = []
        var index = output.startIndex
        while index < output.endIndex {
            let next = output.index(index, offsetBy: chunk, limitedBy: output.endIndex) ?? output.endIndex
            events.append(.chunk(String(output[index..<next])))
            index = next
        }
        events.append(.info(promptTokens: 40, completionTokens: 30, tokensPerSecond: 50, finishReason: finish))
        let scripted = events
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
        let handler = try ToolStreamPreparation.makeHandler(
            request: fixture.request, prepared: fixture.prepared, modelType: Self.modelType)
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        // The switch as a clean process reads it, whatever this process's environment says.
        scheduler.museGlimmerReferenceToolCalls = reference
        let output = try scheduler._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: fixture.prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: Self.modelID), toolHandler: handler,
            withholdReasoning: fixture.withholdsReasoning, nativeGlimmerChannels: true)
        var outcome = Outcome()
        for try await event in output { outcome.record(event) }
        return outcome
    }

    private func expectNoFraming(_ outcome: Outcome) {
        for text in [outcome.reasoning, outcome.content] {
            for marker in ["<|", "to=self", "to=user", "<atem:"] {
                #expect(!text.contains(marker), "\(marker) in \(text)")
            }
        }
    }

    @Test("the request's parser is ATEM and its calls are never exposed before they validate")
    func preparation() throws {
        let fixture = try Fixture()
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: fixture.request, prepared: fixture.prepared, modelType: Self.modelType))
        #expect(handler.format == .atem)
        #expect(!handler.streamsCalls)
        #expect(try ToolStreamPreparation.makeHandler(
            request: try Fixture(tools: nil).request, prepared: try Fixture(tools: nil).prepared,
            modelType: Self.modelType) == nil)
        #expect(try MuseGlimmerRequestPolicy.toolCallFormat(requested: nil, modelType: Self.modelType) == .atem)
        #expect(try MuseGlimmerRequestPolicy.toolCallFormat(requested: "auto", modelType: Self.modelType) == .atem)
        #expect(try MuseGlimmerRequestPolicy.toolCallFormat(requested: "atem", modelType: "llama") == nil)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try MuseGlimmerRequestPolicy.toolCallFormat(requested: "hermes", modelType: Self.modelType)
        }
    }

    @Test("reasoning, then the answer: each in its own field, at any chunking")
    func reasoningAndAnswer() async throws {
        let output = " to=self<|message|>Greet briefly.<|eom|><|start|>assistant to=user<|message|>Hello there!"
        for chunk in [1, 3, 17, 400] {
            let outcome = try await stream(try Fixture(tools: nil), output, chunk: chunk)
            #expect(outcome.reasoning == "Greet briefly.")
            #expect(outcome.content == "Hello there!")
            #expect(outcome.calls.isEmpty)
            #expect(outcome.info?.stopReason == "stop")
            #expect(outcome.info?.completionTokens == 30)
            expectNoFraming(outcome)
        }
    }

    @Test("output cut at max_tokens inside reasoning: reasoning only, finish reason length")
    func truncatedInsideReasoning() async throws {
        let outcome = try await stream(
            try Fixture(), " to=self<|message|>Still working through the", finish: "length")
        #expect(outcome.reasoning == "Still working through the")
        #expect(outcome.content.isEmpty && outcome.calls.isEmpty)
        #expect(outcome.info?.stopReason == "length")
    }

    @Test("one call after reasoning, typed by its schema")
    func oneCall() async throws {
        let output = " to=self<|message|>Look it up.<|eom|>" + Self.call("get_weather", [
            ("city", "Paris"), ("days", "3"), ("detail", "true"), ("tags", "[\"a\", \"b\"]")])
        for chunk in [1, 3, 17, 400] {
            let outcome = try await stream(try Fixture(), output, chunk: chunk)
            #expect(outcome.reasoning == "Look it up.")
            #expect(outcome.content.isEmpty)
            #expect(outcome.calls.count == 1)
            let call = try #require(outcome.calls.first)
            #expect(call.function.name == "get_weather")
            #expect(call.function.arguments == [
                "city": .string("Paris"), "days": .int(3), "detail": .bool(true),
                "tags": .array([.string("a"), .string("b")])])
            expectNoFraming(outcome)
        }
    }

    @Test("parallel calls: one per message, and several in one block")
    func parallelCalls() async throws {
        let messages = " to=self<|message|>Two cities.<|eom|>" + Self.call("get_weather", [("city", "Paris")])
            + "<|eom|>" + Self.call("get_weather", [("city", "Zürich")])
        let block = " to=get_weather<|message|><atem:function_calls>\n"
            + Self.invoke("get_weather", [("city", "Paris")]) + "\n"
            + Self.invoke("docs_read", [("path", "a.txt")]) + "\n</atem:function_calls>"
        for chunk in [1, 17, 400] {
            let perMessage = try await stream(try Fixture(), messages, chunk: chunk)
            #expect(perMessage.calls.map(\.function.name) == ["get_weather", "get_weather"])
            #expect(perMessage.calls.map { $0.function.arguments["city"] } == [.string("Paris"), .string("Zürich")])
            let oneBlock = try await stream(try Fixture(), block, chunk: chunk)
            #expect(oneBlock.calls.map(\.function.name) == ["get_weather", "docs_read"])
            #expect(oneBlock.calls.last?.function.arguments == ["path": .string("a.txt")])
        }
    }

    @Test("a call that reached its closing tag is returned even without a terminator")
    func callBeforeTerminator() async throws {
        let complete = " to=get_weather<|message|><atem:function_calls>\n"
            + Self.invoke("get_weather", [("city", "Paris")])
        for finish in ["stop", "length"] {
            let outcome = try await stream(try Fixture(), complete, finish: finish)
            #expect(outcome.calls.map(\.function.name) == ["get_weather"])
        }
    }

    @Test("the doubled name a bare tool draws is the declared tool")
    func doubledName() async throws {
        let output = " to=get_weather.get_weather<|message|><atem:function_calls>\n"
            + Self.invoke("get_weather.get_weather", [("city", "Paris")]) + "\n</atem:function_calls>"
        let outcome = try await stream(try Fixture(), output)
        #expect(outcome.calls.map(\.function.name) == ["get_weather"])
        // A declared namespaced name is kept as written.
        let namespaced = try await stream(
            try Fixture(), Self.generated(Self.call("docs_read", [("path", "a.txt")])))
        #expect(namespaced.calls.map(\.function.name) == ["docs_read"])
        let names: Set<String> = ["get_weather", "weather.get", "time.get"]
        func name(_ emitted: String) -> String {
            MuseGlimmerToolFrame.normalizingName(in: Self.invoke(emitted), declaredNames: names)
        }
        #expect(name("get_weather.get_weather") == Self.invoke("get_weather"))
        #expect(name("weather.get") == Self.invoke("weather.get"))
        // Never matched on a trailing segment or an undeclared head.
        #expect(name("foo.get_weather") == Self.invoke("foo.get_weather"))
        #expect(name("x.get") == Self.invoke("x.get"))
        #expect(name("other.other") == Self.invoke("other.other"))
    }

    @Test("a call cut off by max_tokens is no call and no error")
    func truncatedCall() async throws {
        let cut = " to=self<|message|>Go.<|eom|><|start|>assistant to=get_weather<|message|>"
            + "<atem:function_calls>\n<atem:invoke name=\"get_weather\">\n<atem:parameter name=\"city\">Par"
        let outcome = try await stream(try Fixture(), cut, finish: "length")
        #expect(outcome.reasoning == "Go.")
        #expect(outcome.calls.isEmpty && outcome.content.isEmpty)
        #expect(outcome.info?.stopReason == "length")
    }

    /// The request failed as the model's noncompliance (422), never as the provider's (500).
    private func expectNoncompliance(
        _ fixture: Fixture, _ output: String, reference: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            let outcome = try await stream(fixture, output, reference: reference)
            Issue.record("expected a refusal, got \(outcome.calls.map(\.function.name)) \(outcome.content)",
                         sourceLocation: sourceLocation)
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .toolChoiceViolation = error else {
                Issue.record("expected a 422 refusal, got \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    private static var strictTools: [[String: Any]] {
        tools.map { tool in
            var tool = tool
            var function = tool["function"] as! [String: Any]
            function["strict"] = true
            tool["function"] = function
            return tool
        }
    }

    private static var closedTools: [[String: Any]] {
        tools.map { tool in
            var tool = tool
            var function = tool["function"] as! [String: Any]
            var parameters = function["parameters"] as! [String: Any]
            parameters["additionalProperties"] = false
            function["parameters"] = parameters
            tool["function"] = function
            return tool
        }
    }

    @Test("auto without strict: each call the strict parser rejects is returned as generated, as vLLM returns it")
    func autoCallsAsGenerated() async throws {
        // The strict parser's rejections, each a 500 before.
        let cases: [(String, [[String: Any]], String, [String: MLXLMCommon.JSONValue])] = [
            ("undeclared name", Self.tools, "delete_everything", ["path": .string("/")]),
            ("missing required parameter", Self.tools, "get_weather", ["days": .int(3)]),
            ("extra parameter under additionalProperties false", Self.closedTools, "get_weather",
             ["city": .string("Paris"), "mood": .string("sunny")]),
            ("integral float for an integer", Self.tools, "get_weather", ["city": .string("Paris"), "days": .int(6)]),
            ("wrong type", Self.tools, "get_weather", ["city": .string("Paris"), "days": .string("soon")]),
            ("invalid JSON for an array", Self.tools, "get_weather",
             ["city": .string("Paris"), "tags": .string("[a, b")]),
        ]
        let written: [String: [(String, String)]] = [
            "undeclared name": [("path", "/")],
            "missing required parameter": [("days", "3")],
            "extra parameter under additionalProperties false": [("city", "Paris"), ("mood", "sunny")],
            "integral float for an integer": [("city", "Paris"), ("days", "6.0")],
            "wrong type": [("city", "Paris"), ("days", "soon")],
            "invalid JSON for an array": [("city", "Paris"), ("tags", "[a, b")],
        ]
        for (label, tools, name, arguments) in cases {
            let output = " to=self<|message|>Call.<|eom|>" + Self.call(name, written[label]!)
            let outcome = try await stream(try Fixture(tools: tools), output)
            #expect(outcome.calls.map { $0.function.name } == [name], "\(label)")
            #expect(outcome.calls.first?.function.arguments == arguments, "\(label)")
            #expect(outcome.content.isEmpty, "\(label)")
            #expect(outcome.info?.stopReason == "stop", "\(label)")
            expectNoFraming(outcome)
            // The strict parser, kept behind the switch, refuses each, now as the model's failure.
            await expectNoncompliance(try Fixture(tools: tools), output, reference: false)
        }
    }

    @Test("a string parameter keeps its text byte for byte; any other value is decoded")
    func referenceTyping() async throws {
        for text in ["12345", "true", "null", " padded "] {
            let outcome = try await stream(try Fixture(), Self.generated(Self.call("get_weather", [("city", text)])))
            #expect(outcome.calls.first?.function.arguments["city"] == .string(text), "\(text)")
        }
        let typed = try await stream(try Fixture(), Self.generated(Self.call("get_weather", [
            ("city", "Paris"), ("days", "6.0"), ("detail", "false"), ("tags", "[\"a\"]")])))
        #expect(typed.calls.first?.function.arguments == [
            "city": .string("Paris"), "days": .int(6), "detail": .bool(false), "tags": .array([.string("a")])])
    }

    @Test("strict tools hold the call to the declarations: off the schema is refused as noncompliance (422)")
    func strictToolsRefuse() async throws {
        let strict = try Fixture(tools: Self.strictTools)
        for (name, parameters) in [("delete_everything", [("path", "/")]), ("get_weather", [("days", "3")]),
                                   ("get_weather", [("city", "Paris"), ("days", "soon")])] {
            await expectNoncompliance(strict, Self.generated(Self.call(name, parameters)))
        }
        // Draft 7: an integral float is an integer, and the reader types it as one.
        let integral = try await stream(strict, Self.generated(Self.call("get_weather", [
            ("city", "Paris"), ("days", "6.0")])))
        #expect(integral.calls.first?.function.arguments == ["city": .string("Paris"), "days": .int(6)])
        // A string parameter whose text looks like a number is still the string the schema asks for.
        let numeric = try await stream(strict, Self.generated(Self.call("get_weather", [("city", "12345")])))
        #expect(numeric.calls.first?.function.arguments == ["city": .string("12345")])
    }

    @Test("forced choice holds the call to the declarations: off the schema is refused as noncompliance (422)")
    func forcedChoiceRefuses() async throws {
        let required = try Fixture(extra: ["tool_choice": "required"])
        for (name, parameters) in [("delete_everything", [("path", "/")]), ("get_weather", [("days", "3")])] {
            await expectNoncompliance(required, Self.generated(Self.call(name, parameters)))
        }
        let named = try Fixture(extra: ["tool_choice": ["type": "function", "function": ["name": "docs_read"]]])
        await expectNoncompliance(named, Self.generated(Self.call("get_weather", [("city", "Paris")])))
        let passes = try await stream(required, Self.generated(Self.call("get_weather", [("city", "Paris")])))
        #expect(passes.calls.map(\.function.name) == ["get_weather"])
    }

    @Test("a frame that holds no call is refused as noncompliance (422), never a provider failure, either way")
    func invalidToolOutput() async throws {
        let unfinished = " to=get_weather<|message|><atem:function_calls>\n<atem:invoke name=\"get_weather\">"
        let unnamed = " to=get_weather<|message|><atem:function_calls>\n<atem:invoke>\n"
            + "<atem:parameter name=\"city\">Paris</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"
        for reference in [true, false] {
            for output in [unfinished, unnamed] {
                await expectNoncompliance(try Fixture(), output, reference: reference)
            }
        }
        // No declared tools, or `tool_choice: none`: there is nothing to call. Never answer text either.
        let call = Self.generated(Self.call("get_weather", [("city", "Paris")]))
        for reference in [true, false] {
            await expectNoncompliance(try Fixture(tools: nil), call, reference: reference)
            await expectNoncompliance(try Fixture(extra: ["tool_choice": "none"]), call, reference: reference)
        }
    }

    @Test("an invoke quoted in reasoning or in the answer is not a call")
    func quotedInvokes() async throws {
        let quoted = "<atem:function_calls>\n" + Self.invoke("get_weather", [("city", "Paris")])
            + "\n</atem:function_calls>"
        let outcome = try await stream(
            try Fixture(), " to=self<|message|>I might send " + quoted + ".<|eom|>"
                + "<|start|>assistant to=user<|message|>You would write " + quoted + ".")
        #expect(outcome.calls.isEmpty)
        #expect(outcome.reasoning == "I might send " + quoted + ".")
        #expect(outcome.content == "You would write " + quoted + ".")
    }

    @Test("required tool choice: a call passes, an answer instead of a call is refused")
    func requiredToolChoice() async throws {
        let required = try Fixture(extra: ["tool_choice": "required"])
        #expect(required.prepared.requiresToolCall)
        let called = try await stream(
            required, " to=self<|message|>Must call.<|eom|>" + Self.call("get_weather", [("city", "Paris")]))
        #expect(called.calls.map(\.function.name) == ["get_weather"])
        #expect(called.reasoning == "Must call.")
        for output in [" to=user<|message|>It is sunny.", " to=self<|message|>No call needed."] {
            await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                _ = try await stream(required, output)
            }
        }
        let named = try Fixture(extra: ["tool_choice": ["type": "function", "function": ["name": "docs_read"]]])
        await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try await stream(named, Self.generated(Self.call("get_weather", [("city", "Paris")])))
        }
    }

    @Test("reasoning the caller declined is generated but never sent")
    func withheldReasoning() async throws {
        let output = " to=self<|message|>Private thoughts.<|eom|><|start|>assistant to=user<|message|>Public answer."
        for extra in [["reasoning": ["exclude": true]], ["include_reasoning": false],
                      ["reasoning": ["enabled": false]]] as [[String: Any]] {
            let fixture = try Fixture(tools: nil, extra: extra)
            #expect(fixture.withholdsReasoning)
            let outcome = try await stream(fixture, output)
            #expect(outcome.reasoning.isEmpty)
            #expect(outcome.content == "Public answer.")
        }
        #expect(try !Fixture(tools: nil).withholdsReasoning)
        #expect(try !Fixture(tools: nil, extra: ["reasoning": ["effort": "none"]]).withholdsReasoning)
    }

    @Test("with reasoning declined, no logprob entry leaves: the filter cannot tell reasoning from the answer")
    func withheldReasoningLogprobs() async throws {
        func entries(withholding: Bool) async throws -> [SSETokenLogprob] {
            let fixture = try Fixture(tools: nil, extra: withholding ? ["reasoning": ["exclude": true]] : [:])
            let upstream = AsyncStream<GenerationEvent> { continuation in
                for (token, text) in [("secret", " to=self<|message|>secret<|eom|><|start|>assistant"),
                                      ("answer", " to=user<|message|>answer")] {
                    continuation.yield(.logprobs([SSETokenLogprob(token: token, logprob: -0.1, bytes: nil, topLogprobs: [])]))
                    continuation.yield(.chunk(text))
                }
                continuation.yield(.info(promptTokens: 4, completionTokens: 2, tokensPerSecond: 1, finishReason: "stop"))
                continuation.finish()
            }
            let scheduler = MultiModelBatchSchedulerEngine(
                registryProvider: { [:] }, engineV2Logprobs: EngineV2LogprobsPlumbing(topLogprobs: 0))
            let output = try scheduler._testMakeEventStream(
                upstream: upstream, cancelUpstream: {}, prepared: fixture.prepared,
                releaseBox: OneShotRelease(release: { _ in }, modelId: Self.modelID),
                withholdReasoning: fixture.withholdsReasoning, nativeGlimmerChannels: true)
            var seen: [SSETokenLogprob] = []
            for try await event in output { if case .logprobs(let batch) = event { seen += batch } }
            return seen
        }
        #expect(try await entries(withholding: false).map(\.token) == ["secret", "answer"])
        #expect(try await entries(withholding: true).isEmpty)
    }
    #endif
}
