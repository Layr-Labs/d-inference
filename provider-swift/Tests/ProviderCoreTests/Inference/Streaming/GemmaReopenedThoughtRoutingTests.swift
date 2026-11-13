// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Gemma reopened thought routing")
struct GemmaReopenedThoughtRoutingTests {
    @Test("the provider-selected parser separates a reopened thought", arguments: [1, 4, 1000])
    func selectedParser(width: Int) throws {
        let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_REOPENED_THOUGHTS"] == "1"
        let format = ProviderLoop.inferReasoningParser(for: "gemma4")
        #expect(format == .gemma4)
        let reopened = "<|channel>thought\nSecond<channel|>Done<channel|>"
        let text = "<|channel>thought\nFirst<channel|>Answer" + reopened
        var parser = StreamingReasoningParser(format: format)
        let characters = Array(text)
        var pieces: [ParsedReasoning] = []
        for start in stride(from: 0, to: characters.count, by: width) {
            pieces += parser.parse(String(characters[start..<min(start + width, characters.count)]))
        }
        pieces += parser.finish()
        let content = pieces.map(\.content).joined()
        let reasoning = pieces.compactMap(\.reasoningContent).joined()
        #expect(content == (enabled ? "AnswerDone" : "Answer" + reopened))
        #expect(reasoning == (enabled ? "FirstSecond" : "First"))
        let collected = ReasoningParser(format: format).parse(text)
        #expect(collected.content == content)
        #expect(collected.reasoningContent == reasoning)
    }
}
