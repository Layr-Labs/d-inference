import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native channel boundary fidelity")
struct NativeChannelSplitterTests {
    @Test func ordinaryThinkSemanticsMatchExistingParserAcrossChunkWidths() {
        // A bare `</think>` while already in content is the one documented
        // divergence from the SDK think parser (vendor contract: absorb it);
        // it is covered separately below, so it stays out of the parity corpus
        // for the pre-closed prefix.
        let corpus: [(String, [String])] = [
            ("<think>", ["Plain answer.", "Reason Ω</think>Answer", "A<think>B</think>C<think>unfinished</thi"]),
            ("<think></think>", ["Plain answer.", "A<think>B</think>C<think>unfinished</thi"]),
        ]
        for (prefix, texts) in corpus {
            for text in texts {
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

    @Test func strayCloseInContentIsAbsorbedAndPrecedingTextStaysContent() {
        // Shape observed natively: prompt ends `<think></think>`, model emits a
        // preamble, a stray close and a tool call. Vendor parser (vLLM
        // nemotron_v3): preamble is content, `</think>` dropped, frame intact.
        let text = "I need the current weather.</think>\n<tool_call>\n<function=get_current_weather>\n<parameter=location>\nBoston, MA\n</parameter>\n</function>\n</tool_call>\n"
        let expected = text.replacingOccurrences(of: "</think>", with: "")
        for width in [1, 3, 7, 64, 4096] {
            var splitter = NativeChannelSplitter(prefix: "<think></think>", protectToolFrames: true)
            var pieces: [ParsedReasoning] = []
            let characters = Array(text)
            for start in stride(from: 0, to: characters.count, by: width) {
                pieces += splitter.parse(String(characters[start..<min(characters.count, start + width)]))
                #expect(splitter.bufferedCharacterCount < 14)
            }
            pieces += splitter.finish()
            #expect(pieces.map(\.content).joined() == expected)
            #expect(pieces.compactMap(\.reasoningContent).isEmpty)
            #expect(splitter.bufferedCharacterCount == 0)
        }
    }

    @Test func duplicateCloseAfterRealReasoningIsAbsorbed() {
        var splitter = NativeChannelSplitter(prefix: "<think>", protectToolFrames: false)
        let pieces = splitter.parse("thinking</think>answer</think> more") + splitter.finish()
        #expect(pieces.compactMap(\.reasoningContent).joined() == "thinking")
        #expect(pieces.map(\.content).joined() == "answer more")
    }

    @Test func closeMarkerInsideToolFrameStaysOpaque() {
        var splitter = NativeChannelSplitter(prefix: "<think></think>", protectToolFrames: true)
        let text = "<tool_call>\n<function=echo>\n<parameter=text>\nliteral </think> inside\n</parameter>\n</function>\n</tool_call>"
        let pieces = splitter.parse(text) + splitter.finish()
        #expect(pieces.map(\.content).joined() == text)
        #expect(pieces.compactMap(\.reasoningContent).isEmpty)
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
