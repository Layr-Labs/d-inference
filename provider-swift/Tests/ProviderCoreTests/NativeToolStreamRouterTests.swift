import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native reasoning before tool parsing")
struct NativeToolStreamRouterTests {
    @Test func reasoningMarkersInsideArgumentsRemainArgumentData() throws {
        for format: ToolCallFormat in [.nemotron, .qwen35] {
            let handler = BatchedToolStreamHandler(format: format, tools: nil)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think></think>")
            let frame = "<tool_call><function=write><parameter=text>literal <think>code</think> end</parameter></function></tool_call>"
            for character in frame { _ = try router.process(String(character)) }
            _ = try router.finishText()
            let calls = handler.finish()
            #expect(calls.count == 1)
            #expect(calls.first?.function.arguments["text"] == .string("literal <think>code</think> end"))
        }
    }

    @Test func nativeBareFunctionInsideReasoningIsNeverInvoked() throws {
        let handler = BatchedToolStreamHandler(format: .nemotron, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think>")
        _ = try router.process("An example: <function=fake></function></think>\n")
        _ = try router.process("<function=add><parameter=a>19</parameter><parameter=b>23</parameter></function>")
        _ = try router.finishText()
        #expect(handler.finish().map(\.function.name) == ["add"])
    }

    @Test func reasoningToolExampleIsNeverInvokedEvenWithSplitMarkers() throws {
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think>")
        let thought = #"Consider 🌊 <tool_call>{"name":"fake","arguments":{}}</tool_call> privately."#
        let output = thought + #"</think> <tool_call>{"name":"add","arguments":{"a":19,"b":23}}</tool_call>"#
        var events: [MLXServerGenerationEvent] = []
        for character in output { events += try router.process(String(character)) }
        events += try router.finishText()
        var reasoning = ""
        for event in events {
            guard case .parsed(let piece) = event else {
                Issue.record("native thought must not become raw content")
                continue
            }
            #expect(piece.content.isEmpty)
            reasoning += piece.reasoningContent ?? ""
        }
        #expect(reasoning == thought)
        let calls = handler.finish()
        #expect(calls.count == 1)
        #expect(calls.first?.function.name == "add")
    }

    @Test func truncatedThoughtNeverPromotesToAnswerOrTool() throws {
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think>")
        let thought = "Unfinished analysis with <tool_call>"
        let events = try router.process(thought) + router.finishText()
        var restored = ""
        for event in events {
            guard case .parsed(let piece) = event else { Issue.record("unexpected raw content"); continue }
            #expect(piece.content.isEmpty)
            restored += piece.reasoningContent ?? ""
        }
        #expect(restored == thought)
        #expect(handler.finish().isEmpty)
    }

    @Test func ordinaryNativeAnswerStreamsWithoutWaitingForEOF() throws {
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: "<think></think>")
        #expect(try router.process("Thanks.") == [.parsed(.init(content: "Thanks.", reasoningContent: nil))])
        #expect(try router.finishText().isEmpty)
    }

    @Test func forcedProseStillFailsAndLegacyRoutingIsUnchanged() throws {
        var forced = NativeToolStreamRouter(handler: nil, requiresToolCall: true, nativePrefix: "<think></think>")
        #expect(throws: (any Error).self) { try forced.process("No, I won't call it.") }
        var legacy = NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: nil)
        #expect(try legacy.process("legacy text") == [.content("legacy text")])
        var legacyForced = NativeToolStreamRouter(handler: nil, requiresToolCall: true, nativePrefix: nil)
        #expect(throws: (any Error).self) { try legacyForced.process(" \n") }
    }
}
