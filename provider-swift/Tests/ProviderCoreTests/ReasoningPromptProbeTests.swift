import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Reasoning prompt probe")
struct ReasoningPromptProbeTests {
    @Test("open prompt blocks initialize reasoning", arguments: [
        "<|im_start|>assistant\n<think>\n", "<think>", "<think> \t\n",
    ])
    func openBlock(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == "<think>")
    }

    @Test("closed prompt blocks initialize content", arguments: [
        "<|im_start|>assistant\n<think>\n\n</think>\n\n",
        "</think>", "<think>prompt-side reasoning</think> \t\n",
    ])
    func closedBlock(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == "<think></think>")
    }

    @Test("unknown or incomplete tails retain the parser's default state", arguments: [
        "", "<|im_start|>assistant\n", "<think>\nalready reasoning",
        "<think>\n</thi", "quoted </think> followed by text",
    ])
    func unknownTail(tail: String) {
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail) == nil)
    }

    private func prefix(
        parser: ReasoningParserFormat?, stream: Bool? = true,
        tokens: [Int] = [1, 2, 3], tail: String = "<think>\n"
    ) -> String? {
        ReasoningPromptProbe.streamingPrefix(
            reasoningParser: parser, stream: stream, promptTokens: tokens,
            decodeTail: { _ in tail })
    }

    @Test("only streaming think parsers receive a prefix", arguments: ["<think>\n", "</think>\n"])
    func gates(tail: String) {
        #expect(prefix(parser: .qwen3, tail: tail) != nil)
        #expect(prefix(parser: .deepseekR1, tail: tail) != nil)
        for parser: ReasoningParserFormat? in [nil, .some(.none), .harmony, .gemma4] {
            #expect(prefix(parser: parser, tail: tail) == nil)
        }
        #expect(prefix(parser: .qwen3, stream: false, tail: tail) == nil)
        #expect(prefix(parser: .qwen3, stream: nil, tail: tail) == nil)
        #expect(prefix(parser: .qwen3, tokens: [], tail: tail) == nil)
    }

    @Test("the probe decodes only a bounded prompt tail")
    func boundedTailDecode() {
        let tokens = Array(0..<4096)
        var seen: [Int]?
        let result = ReasoningPromptProbe.streamingPrefix(
            reasoningParser: .qwen3, stream: true, promptTokens: tokens,
            decodeTail: { ids in
                seen = ids
                return "</think>\n"
            })
        #expect(seen == Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)))
        #expect(result == "<think></think>")
    }
}
