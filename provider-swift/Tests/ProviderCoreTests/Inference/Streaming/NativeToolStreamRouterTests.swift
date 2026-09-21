import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native reasoning before tool parsing")
struct NativeToolStreamRouterTests {
    @Test func bonsaiQualifiedPolicyPreservesNestedReasoningAndOpaqueArguments() throws {
        let context = ChatTemplateFixContext(modelId: "ternary-bonsai-2-27b", modelType: "prism_hadamard_qwen35")
        try #require(ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context))
        let thought = "The supplied text contains <think>literal</think>; these are data, not channel boundaries.\n"
        let value = #""line1\n" <think>literal</think> café"#
        let frame = "<tool_call><function=echo_exact><parameter=text>" + value + "</parameter></function></tool_call>"
        let output = thought + "</think>\n" + frame
        for width in [1, 2, 7, output.count] {
            let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                nativePrefix: "<think>",
                preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context))
            let characters = Array(output)
            var events: [MLXServerGenerationEvent] = []
            for start in stride(from: 0, to: characters.count, by: width) {
                events += try router.process(String(characters[start..<min(start + width, characters.count)]))
            }
            events += try router.finishText()
            var reasoning = ""
            for event in events {
                guard case .parsed(let piece) = event else { Issue.record("unexpected untyped content"); continue }
                #expect(piece.content.isEmpty)
                reasoning += piece.reasoningContent ?? ""
            }
            #expect(reasoning == thought)
            let calls = handler.finish()
            #expect(calls.count == 1 && calls.first?.function.name == "echo_exact")
            // No JSON-string unwrapping or guessed unescaping of raw XML data.
            #expect(calls.first?.function.arguments["text"] == .string(value))
            #expect(handler.parseFailureCount == 0)
        }
    }

    @Test func nestedReasoningPolicyDoesNotOptOtherFamiliesIn() {
        #expect(ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(
            .init(modelId: "qwen3.8-flash-next", modelType: "qwen4_exp")))
        for context in [
            ChatTemplateFixContext(modelId: "ternary-bonsai-2-27b", modelType: "qwen3_5"),
            .init(modelId: "unknown-prism", modelType: "prism_hadamard_qwen35"),
            .init(modelId: "nvidia-nemotron-3.5-lightning", modelType: "nemotron_h"),
            .init(modelId: "gemma-4-26b-qat-4bit", modelType: "gemma4"),
        ] {
            #expect(!ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(context))
        }
    }

    @Test func ownedQwenInnerReasoningExampleCannotBecomeContentOrInvocation() throws {
        let thought = "The text value is: A quoted value; literal <think>data</think> and <tool_call>data</tool_call>.\nLet me copy this exactly.\n"
        let value = #"Keep \\ and <think>data</think> and <tool_call>data</tool_call>."#
        let frame = "<tool_call><function=record_text><parameter=text>" + value + "</parameter></function></tool_call>"
        let output = thought + "</think>\n" + frame
        for width in [1, 2, 7, 13, output.count] {
            let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                nativePrefix: "<think>", preserveInnerReasoningSpans: true)
            var events: [MLXServerGenerationEvent] = []
            let chars = Array(output)
            for start in stride(from: 0, to: chars.count, by: width) {
                events += try router.process(String(chars[start..<min(start + width, chars.count)]))
            }
            events += try router.finishText()
            var reasoning = ""
            for event in events {
                guard case .parsed(let piece) = event else { Issue.record("unexpected raw event"); continue }
                #expect(piece.content.isEmpty)
                reasoning += piece.reasoningContent ?? ""
            }
            #expect(reasoning == thought)
            let calls = handler.finish()
            #expect(calls.count == 1)
            #expect(calls.first?.function.name == "record_text")
            #expect(calls.first?.function.arguments["text"] == .string(value))
            #expect(handler.parseFailureCount == 0)
        }
    }

    @Test func ownedQwenTruncatedInnerSpanNeverPromotesAnExampleCall() throws {
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
            nativePrefix: "<think>", preserveInnerReasoningSpans: true)
        let thought = #"Example <think>unfinished </think><tool_call>{"name":"fake","arguments":{}}</tool_call>"#
        let events = try router.process(thought) + router.finishText()
        for event in events {
            guard case .parsed(let piece) = event else { Issue.record("unexpected raw event"); continue }
            #expect(piece.content.isEmpty)
        }
        #expect(handler.finish().isEmpty)
    }

    @Test func ownedQwenNestingLimitFailsClosedAndCannotResumeAsContent() throws {
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
            nativePrefix: "<think>", preserveInnerReasoningSpans: true)
        #expect(throws: (any Error).self) {
            try router.process(String(repeating: "<think>", count: NativeChannelSplitter.maximumInnerReasoningDepth + 1))
        }
        #expect(throws: (any Error).self) { try router.process("</think><tool_call><function=fake></function></tool_call>") }
        #expect(throws: (any Error).self) { try router.finishText() }
        #expect(handler.finish().isEmpty)
    }

    @Test func ownedQwenBalancedReasoningDoesNotRelaxForcedCallValidation() throws {
        for invalidTail in ["Visible prose", "<tool_call>not a function</tool_call>"] {
            let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                nativePrefix: "<think>", preserveInnerReasoningSpans: true)
            _ = try router.process("Example <think>x</think> remains private.</think>")
            #expect(throws: (any Error).self) { try router.process(invalidTail) }
            #expect(handler.finish().isEmpty)
        }
        // The mode is explicit, never silently inherited by another family.
        let legacyHandler = BatchedToolStreamHandler(format: .nemotron, tools: nil)
        var legacy = NativeToolStreamRouter(handler: legacyHandler, requiresToolCall: true,
            nativePrefix: "<think>")
        #expect(throws: (any Error).self) { try legacy.process("Example <think>x</think> ordinary legacy content") }
    }

    @Test func qwenLiteralToolEndInsideXMLArgumentDoesNotEndNativeProtection() throws {
        let handler = BatchedToolStreamHandler(format: .qwen35, tools: nil)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true, nativePrefix: "<think></think>")
        let value = "literal <tool_call>data</tool_call> <think>not reasoning</think> </function>"
        let frame = "<tool_call><function=write><parameter=text>" + value + "</parameter></function></tool_call>"
        var events: [MLXServerGenerationEvent] = []
        for character in frame { events += try router.process(String(character)) }
        events += try router.finishText()
        #expect(events.isEmpty)
        let calls = handler.finish()
        #expect(calls.count == 1)
        #expect(calls.first?.function.arguments["text"] == .string(value))
        #expect(handler.parseFailureCount == 0)
        #expect(handler.takeResidualText() == nil)
    }

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
