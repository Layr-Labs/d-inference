// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// GPT-OSS calls its Harmony parser does not see (`GPTOSSToolCallRecovery`).
/// The fixtures are OpenRouter's tool-call fuzz cases as the coordinator
/// forwards them (`realistic:*:anyOf[string,null]@null`,
/// `oneOf[string,null]@string`, `oneOf[integer,string]@string`), with the
/// Harmony text GPT-OSS 20B wrote for them at T 0.
@Suite("GPT-OSS tool call recovery")
struct GPTOSSToolCallRecoveryTests {
    static let giftTool = #"{"type":"function","function":{"name":"set_order_gift_message","strict":true,"parameters":{"#
        + #""additionalProperties":false,"properties":{"gift_message":{"anyOf":[{"description":"Text to print on the gift card","type":"string"},"#
        + #"{"description":"Remove the gift message","type":"null"}],"description":"The gift message for the order, or null to clear it","#
        + #""nullable":true,"type":"string"}},"required":["gift_message"],"type":"object"}}}"#
    static let noteTool = #"{"type":"function","function":{"name":"create_note","parameters":{"additionalProperties":false,"#
        + #""properties":{"content":{"description":"Text body of the new note, or null for a blank note.","nullable":true,"#
        + #""oneOf":[{"type":"string"},{"type":"null"}],"type":"string"}},"required":["content"],"type":"object"}}}"#
    static let productsTool = #"{"type":"function","function":{"name":"list_products","parameters":{"additionalProperties":false,"#
        + #""properties":{"category":{"description":"Numeric category ID or category name. Use an empty string for no category filter.","#
        + #""oneOf":[{"type":"integer"},{"type":"string"}],"type":"integer"}},"required":["category"],"type":"object"}}}"#
    /// A second tool that admits the same `{"content": …}` object.
    static let memoTool = #"{"type":"function","function":{"name":"create_memo","parameters":{"type":"object","#
        + #""properties":{"content":{"type":["string","null"]}},"required":["content"]}}}"#

    static let exit = "<|end|><|start|>assistant"

    static func prepared(_ tools: [String], choice: String? = nil) throws -> ToolChoicePromptPolicy.Prepared {
        let body = #"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Call it again."}],"tools":["#
            + tools.joined(separator: ",") + "]" + (choice.map { #","tool_choice":"# + $0 } ?? "") + "}"
        let request = try ProviderLoop.decodeOpenAIRequest(Data(body.utf8))
        return try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
    }

    static func exited() -> GenerationLoopExitRecord {
        let record = GenerationLoopExitRecord()
        record.requestExit(.init(period: 19, span: 2_048, generatedTokens: 4_096))
        return record
    }

    /// Routes `pieces` as visible text, then finishes with `stop`.
    static func run(_ recovery: GPTOSSToolCallRecovery, _ pieces: [String], stopReason: String = "stop",
                    cutAtLimit: Bool = false) -> (sent: [MLXServerGenerationEvent], call: ToolCall?) {
        var recovery = recovery
        var sent: [MLXServerGenerationEvent] = []
        for piece in pieces { sent += recovery.route(.content(piece)) }
        let finished = recovery.finish(stopReason: stopReason, cutAtLimit: cutAtLimit, hasCalls: false)
        return (sent + finished.release, finished.call)
    }

    static func text(_ events: [MLXServerGenerationEvent]) -> String {
        events.map { if case .content(let text) = $0 { text } else { "" } }.joined()
    }

    // MARK: - Arguments as the answer, after the loop guard's exit

    @Test(arguments: [
        (giftTool, #"{"gift_message":null}"#, "set_order_gift_message", ["gift_message": MLXLMCommon.JSONValue.null]),
        (noteTool, #"{"content":"Pick up dry cleaning before 6pm on Thursday."}"#, "create_note",
         ["content": .string("Pick up dry cleaning before 6pm on Thursday.")]),
    ])
    func anAnswerThatIsOneToolsArgumentsLeavesAsThatCall(
        tool: String, answer: String, name: String, arguments: [String: MLXLMCommon.JSONValue]
    ) throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([tool]), loopExit: Self.exited()))
        let (sent, call) = Self.run(recovery, [
            "But we need to produce a", Self.exit, "<|channel|>final<|message|>", answer,
        ])
        #expect(call?.function.name == name)
        #expect(call?.function.arguments == arguments)
        #expect(Self.text(sent).isEmpty, "the held answer does not leave as text")
    }

    @Test func aRecipientlessCommentaryAnswerAlsoLeavesAsTheCall() throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([Self.giftTool]), loopExit: Self.exited()))
        let (_, call) = Self.run(recovery, [Self.exit + #"<|channel|>commentary json<|message|>{"gift_message":"Hi"}"#])
        #expect(call?.function.arguments == ["gift_message": .string("Hi")])
    }

    /// Every other answer after the exit leaves as it was written, in order.
    @Test(arguments: [
        // Two declared tools admit it.
        ([noteTool, memoTool], #"<|channel|>final<|message|>{"content":"x"}"#),
        // Other text beside the object.
        ([noteTool], #"<|channel|>final<|message|>Here: {"content":"x"}"#),
        ([noteTool], "<|channel|>final<|message|>```json\n{\"content\":\"x\"}\n```"),
        // Not one object.
        ([noteTool], #"<|channel|>final<|message|>[{"content":"x"}]"#),
        ([noteTool], #"<|channel|>final<|message|>{"content":"x"} {"content":"y"}"#),
        ([noteTool], "<|channel|>final<|message|>{}"),
        // An undeclared key, a value the schema refuses.
        ([noteTool], #"<|channel|>final<|message|>{"content":"x","tag":1}"#),
        ([giftTool], #"<|channel|>final<|message|>{"gift_message":5}"#),
        // A plain answer.
        ([noteTool], "<|channel|>final<|message|>Done: the note is created."),
    ])
    func anyOtherAnswerLeavesAsWritten(tools: [String], answer: String) throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared(tools), loopExit: Self.exited()))
        let (sent, call) = Self.run(recovery, ["thinking", Self.exit, answer])
        #expect(call == nil)
        #expect(Self.text(sent) == "thinking" + Self.exit + answer)
    }

    @Test func withoutTheLoopGuardsExitTheAnswerIsNeverHeldOrRead() throws {
        for exit in [nil, GenerationLoopExitRecord()] {
            let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
                prepared: Self.prepared([Self.giftTool]), loopExit: exit))
            var held = recovery
            let piece = #"<|start|>assistant<|channel|>final<|message|>{"gift_message":null}"#
            #expect(held.route(.content(piece)) == [.content(piece)])
            #expect(Self.run(recovery, [piece]).call == nil)
        }
    }

    @Test func anAnswerCutAtTheLimitOrWithACallIsNotRead() throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([Self.giftTool]), loopExit: Self.exited()))
        let answer = [Self.exit, #"<|channel|>final<|message|>{"gift_message":null}"#]
        #expect(Self.run(recovery, answer, stopReason: "length").call == nil)
        #expect(Self.run(recovery, answer, cutAtLimit: true).call == nil)
        var withCall = recovery
        _ = withCall.route(.content(answer[0]))
        let call = ToolCall(function: .init(name: "set_order_gift_message", arguments: ["gift_message": .null]))
        // A call releases what was held, before itself.
        #expect(withCall.route(.toolCall(call)) == [.content(answer[0]), .toolCall(call)])
        #expect(withCall.finish(stopReason: "stop", cutAtLimit: false, hasCalls: true).call == nil)
    }

    @Test func onlyAnAutoGPTOSSRequestWithToolsTakesIt() throws {
        // A schema a forced choice also serves (`required` refuses `anyOf`).
        let tools = [#"{"type":"function","function":{"name":"ping","parameters":{"type":"object","#
            + #""properties":{"n":{"type":"integer"}},"required":["n"]}}}"#]
        #expect(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: try Self.prepared(tools), loopExit: nil) != nil)
        #expect(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: try Self.prepared(tools, choice: #""none""#), loopExit: nil) == nil)
        #expect(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: try Self.prepared(tools, choice: #""required""#), loopExit: nil) == nil)
        #expect(GPTOSSToolCallRecovery.make(modelType: "qwen3_5", format: .harmony,
            prepared: try Self.prepared(tools), loopExit: nil) == nil)
        #expect(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: try Self.prepared(tools), loopExit: nil, enabled: false) == nil)
        #expect(GPTOSSToolCallRecovery.environmentKey == "DARKBLOOM_GPTOSS_TOOL_CALL_RECOVERY")
    }

    @Test("`DARKBLOOM_GPTOSS_TOOL_CALL_RECOVERY` off turns it off; it reaches the launchd daemon")
    func theSwitchReachesTheDaemon() {
        let key = GPTOSSToolCallRecovery.environmentKey
        for value in ["0", "off", "false", "no", " OFF "] {
            #expect(!GPTOSSToolCallRecovery.isEnabled(environment: [key: value]), "\(value)")
        }
        for value in ["", "1", "on", "true"] {
            #expect(GPTOSSToolCallRecovery.isEnabled(environment: [key: value]), "\(value)")
        }
        #expect(GPTOSSToolCallRecovery.isEnabled(environment: [:]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
    }

    // MARK: - A complete call frame ending an open analysis

    static let analysis = "<|channel|>analysis<|message|>The user wants us to call the list_products tool again. "
        + "The previous calls used that format. So we should produce:\n\n```\n"
    static let frame = #"assistant<|channel|>commentary to=functions.list_products<|channel|>commentary json"#
        + #"<|message|>{"category":"Garden Tools"}"#

    @Test func aCompleteFrameEndingTheOpenAnalysisLeavesAsTheCall() throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([Self.productsTool]), loopExit: nil))
        let (sent, call) = Self.run(recovery, [Self.analysis, Self.frame])
        #expect(call?.function.name == "list_products")
        #expect(call?.function.arguments == ["category": .string("Garden Tools")])
        // The analysis itself leaves unchanged.
        #expect(Self.text(sent) == Self.analysis + Self.frame)
    }

    @Test(arguments: [
        // Partial frames.
        #"assistant<|channel|>commentary to=functions.list_products<|channel|>commentary json<|message|>{"category":"Gard"#,
        #"assistant<|channel|>commentary to=functions.list_products<|channel|>commentary json"#,
        // Text after the object.
        #"to=functions.list_products<|channel|>commentary json<|message|>{"category":"Garden Tools"}"#
            + "\n```\nThat is the call.",
        // An undeclared function, a refused value, an unknown header word.
        #"to=functions.delete_products<|channel|>commentary json<|message|>{"category":"Garden Tools"}"#,
        #"to=functions.list_products<|channel|>commentary json<|message|>{"category":[1]}"#,
        #"to=functions.list_products<|channel|>commentary yaml<|message|>{"category":"Garden Tools"}"#,
    ])
    func anIncompleteOrUndeclaredFrameIsNotACall(frame: String) throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([Self.productsTool]), loopExit: nil))
        #expect(Self.run(recovery, [Self.analysis, frame]).call == nil)
    }

    @Test func aFrameInAClosedAnalysisOrBeforeAnAnswerIsNotACall() throws {
        let recovery = try #require(GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: .harmony,
            prepared: Self.prepared([Self.productsTool]), loopExit: nil))
        #expect(Self.run(recovery, [Self.analysis, Self.frame, "<|end|>"]).call == nil)
        #expect(Self.run(recovery, [Self.analysis, Self.frame, "<|end|><|start|>assistant<|channel|>final<|message|>Ok"])
            .call == nil)
        #expect(Self.run(recovery, [Self.analysis, Self.frame], stopReason: "length").call == nil)
        // No analysis at all.
        #expect(Self.run(recovery, [Self.frame]).call == nil)
    }

    // MARK: - Through the scheduler's event stream

    #if DEBUG
    /// The engine output as the scheduler forwards it, with GPT-OSS's Harmony
    /// call parser; streamed and complete-call clients alike.
    static func serve(_ tool: String, output: [String], exited: Bool, streamed: Bool) async throws
        -> [MLXServerGenerationEvent]
    {
        var request = try ProviderLoop.decodeOpenAIRequest(Data((#"{"model":"gpt-oss-20b","stream":true,"#
            + #""messages":[{"role":"user","content":"Call it again."}],"tools":["# + tool + "]}").utf8))
        request.streamToolCallDeltas = streamed
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        let handler = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: "gpt_oss", streamToolCalls: streamed)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in output { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: "stop"))
        upstream.continuation.finish()
        let recovery = GPTOSSToolCallRecovery.make(modelType: "gpt_oss", format: handler?.format,
            prepared: prepared, loopExit: exited ? Self.exited() : GenerationLoopExitRecord())
        var events: [MLXServerGenerationEvent] = []
        for try await event in try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream.stream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            toolHandler: handler, harmonyCallRecovery: recovery) {
            events.append(event)
        }
        return events
    }

    static func calls(_ events: [MLXServerGenerationEvent]) -> [ToolCall] {
        events.compactMap {
            switch $0 {
            case .toolCall(let call): call
            case .toolCallDelta(let delta): delta.completed
            default: nil
            }
        }
    }

    @Test(arguments: [false, true])
    func theSchedulerReturnsTheRecoveredCalls(streamed: Bool) async throws {
        let answer = ["<|channel|>analysis<|message|>I'm stuck.", Self.exit,
                      #"<|channel|>final<|message|>{"gift_message":null}"#]
        let events = try await Self.serve(Self.giftTool, output: answer, exited: true, streamed: streamed)
        #expect(Self.calls(events).map(\.function.name) == ["set_order_gift_message"])
        #expect(!Self.text(events).contains("gift_message"))

        let frame = try await Self.serve(Self.productsTool, output: [Self.analysis, Self.frame], exited: false,
            streamed: streamed)
        #expect(Self.calls(frame).map(\.function.arguments) == [["category": .string("Garden Tools")]])
    }

    @Test(arguments: [false, true])
    func theSchedulerLeavesAPlainAnswerAsText(streamed: Bool) async throws {
        let answer = ["<|channel|>analysis<|message|>I'm stuck.", Self.exit,
                      "<|channel|>final<|message|>The gift message is cleared."]
        let events = try await Self.serve(Self.giftTool, output: answer, exited: true, streamed: streamed)
        #expect(Self.calls(events).isEmpty)
        #expect(Self.text(events).hasSuffix("The gift message is cleared."))
    }
    #endif
}
