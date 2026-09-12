import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native channel boundary fidelity")
struct NativeChannelSplitterTests {
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
