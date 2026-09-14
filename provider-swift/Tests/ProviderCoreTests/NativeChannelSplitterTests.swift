import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native channel boundary fidelity")
struct NativeChannelSplitterTests {
    @Test func qwenArgumentWrappersRemainContentWithBoundedIncrementalState() {
        for payload in [
            #"{"name":"f","arguments":{"text":"literal <tool_call>x</tool_call> <think>y</think> \\\"quote"}}"#,
            "<function=f><parameter=text>literal <tool_call>x</tool_call> <think>y</think> </function></parameter></function>",
        ] {
            let frame = "<tool_call>" + payload + "</tool_call>"
            for width in [1, 2, 7, frame.count] {
                var splitter = NativeChannelSplitter(prefix: "<think></think>", protectToolFrames: true,
                    qwenStructuredFrames: true)
                let characters = Array(frame)
                var pieces: [ParsedReasoning] = []
                for offset in stride(from: 0, to: characters.count, by: width) {
                    pieces += splitter.parse(String(characters[offset..<min(offset + width, characters.count)]))
                    #expect(splitter.bufferedCharacterCount <= 13)
                }
                pieces += splitter.parse("<think>actual thought</think>answer") + splitter.finish()
                #expect(pieces.map(\.content).joined() == frame + "answer")
                #expect(pieces.compactMap(\.reasoningContent).joined() == "actual thought")
                #expect(splitter.bufferedCharacterCount == 0)
            }
        }
    }

    @Test func ordinaryThinkSemanticsMatchExistingParserAcrossChunkWidths() {
        for prefix in ["<think>", "<think></think>"] {
            for text in ["Plain answer.", "Reason Ω</think>Answer", "A<think>B</think>C<think>unfinished</thi"] {
                for width in [1, 2, 9, 128] {
                    var reference = StreamingReasoningParser(format: .qwen3)
                    _ = reference.parse(prefix)
                    var native = NativeChannelSplitter(prefix: prefix, protectToolFrames: false)
                    var expected: [ParsedReasoning] = [], actual: [ParsedReasoning] = []
                    let characters = Array(text)
                    for start in stride(from: 0, to: characters.count, by: width) {
                        let chunk = String(characters[start..<min(characters.count, start + width)])
                        expected += reference.parse(chunk)
                        actual += native.parse(chunk)
                        #expect(native.bufferedCharacterCount < 14)
                    }
                    expected += reference.finish(); actual += native.finish()
                    #expect(expected.map(\.content).joined() == actual.map(\.content).joined())
                    #expect(expected.compactMap(\.reasoningContent).joined() == actual.compactMap(\.reasoningContent).joined())
                }
            }
        }
    }

    @Test func bareToolArgumentsAreOpaqueAndBufferIsBounded() {
        var splitter = NativeChannelSplitter(prefix: "<think></think>", protectToolFrames: true)
        let text = "<function=write><parameter=text>" + String(repeating: "x", count: 65536)
            + "<think>literal</think></parameter></function>"
        let pieces = splitter.parse(text) + splitter.finish()
        #expect(pieces.map(\.content).joined() == text)
        #expect(pieces.compactMap(\.reasoningContent).isEmpty)
        #expect(splitter.bufferedCharacterCount == 0)
    }

    @Test func unclosedToolFrameDrainsPayloadIncrementally() {
        var splitter = NativeChannelSplitter(prefix: "<think></think>", protectToolFrames: true)
        let payload = "<tool_call>" + String(repeating: "credential-sentinel ", count: 8192)
        let pieces = splitter.parse(payload)
        #expect(pieces.map(\.content).joined() == payload)
        #expect(pieces.compactMap(\.reasoningContent).isEmpty)
        #expect(splitter.bufferedCharacterCount <= "</tool_call>".count - 1)
        #expect(splitter.finish().map(\.content).joined().isEmpty)
        #expect(splitter.bufferedCharacterCount == 0)
    }
}
