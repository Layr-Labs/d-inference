import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// `ReasoningPromptProbe` — the detection behind the synthetic `<think>`
/// open injection (Qwen3.6 TTFT fix).
///
/// Qwen3.6/DeepSeek-style chat templates pre-open a think block at the
/// prompt tail, so the model's output carries only `</think>`. The
/// streaming think parser buffers close-only output in its `undecided`
/// state until the close arrives — TTFT then equals the entire thinking
/// duration. The probe decides when the engine may inject a synthetic
/// opening marker so reasoning streams incrementally instead.
@Suite("Reasoning prompt probe")
struct ReasoningPromptProbeTests {

    // MARK: - Tail detection

    @Test("a Qwen3.6-style generation prompt tail ends inside an open think block")
    func qwenTailDetected() {
        #expect(ReasoningPromptProbe.promptEndsInsideThinkBlock(
            "<|im_start|>assistant\n<think>\n"))
        #expect(ReasoningPromptProbe.promptEndsInsideThinkBlock("<think>"))
        // Trailing whitespace variants the tokenizer may render.
        #expect(ReasoningPromptProbe.promptEndsInsideThinkBlock("<think>\n\n"))
        #expect(ReasoningPromptProbe.promptEndsInsideThinkBlock("<think> \t\n"))
    }

    @Test("a pre-closed (thinking disabled) block is rejected")
    func preClosedBlockRejected() {
        // Thinking-off templates embed an EMPTY closed block in the prompt;
        // the output is pure content and must stream as content.
        #expect(!ReasoningPromptProbe.promptEndsInsideThinkBlock(
            "<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(!ReasoningPromptProbe.promptEndsInsideThinkBlock("</think>"))
    }

    @Test("prompts without a think tail are rejected")
    func plainTailsRejected() {
        #expect(!ReasoningPromptProbe.promptEndsInsideThinkBlock(""))
        #expect(!ReasoningPromptProbe.promptEndsInsideThinkBlock("<|im_start|>assistant\n"))
        // An open tag mid-tail followed by other text is not "ends inside".
        #expect(!ReasoningPromptProbe.promptEndsInsideThinkBlock("<think>\nalready reasoning"))
    }

    // MARK: - Injection gating

    private static let openThinkTail = "<|im_start|>assistant\n<think>\n"

    private func shouldInject(
        parser: ReasoningParserFormat?,
        stream: Bool? = true,
        tokens: [Int] = [1, 2, 3],
        tail: String = Self.openThinkTail
    ) -> Bool {
        ReasoningPromptProbe.shouldSynthesizeThinkOpen(
            reasoningParser: parser,
            stream: stream,
            promptTokens: tokens,
            decodeTail: { _ in tail }
        )
    }

    @Test("only think-format parsers inject")
    func parserGate() {
        #expect(shouldInject(parser: .qwen3))
        #expect(shouldInject(parser: .deepseekR1))
        // A verbatim/none parser would leak the literal marker to consumers.
        #expect(!shouldInject(parser: ReasoningParserFormat.none))
        #expect(!shouldInject(parser: nil))
        #expect(!shouldInject(parser: .harmony))
        #expect(!shouldInject(parser: .gemma4))
    }

    @Test("only streaming requests inject")
    func streamGate() {
        // Non-streaming collection classifies close-only output correctly
        // at completion; injection is a streaming-only concern.
        #expect(!shouldInject(parser: .qwen3, stream: false))
        #expect(!shouldInject(parser: .qwen3, stream: nil))
    }

    @Test("an empty prompt or a non-think tail never injects")
    func tailGate() {
        #expect(!shouldInject(parser: .qwen3, tokens: []))
        #expect(!shouldInject(parser: .qwen3, tail: "<|im_start|>assistant\n"))
        #expect(!shouldInject(parser: .qwen3, tail: "<think>\n\n</think>\n\n"))
    }

    @Test("the probe decodes only a bounded prompt tail")
    func boundedTailDecode() {
        let tokens = Array(0..<4096)
        var seen: [Int]?
        _ = ReasoningPromptProbe.shouldSynthesizeThinkOpen(
            reasoningParser: .qwen3,
            stream: true,
            promptTokens: tokens,
            decodeTail: { ids in
                seen = ids
                return Self.openThinkTail
            }
        )
        #expect(seen == Array(tokens.suffix(ReasoningPromptProbe.tailTokenCount)))
    }
}
