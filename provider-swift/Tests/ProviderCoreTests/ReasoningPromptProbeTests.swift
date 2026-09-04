import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// `ReasoningPromptProbe` — the detection behind the synthetic think-marker
/// injections (Qwen3.6 TTFT fix and the tagless / thinking-off TTFT fix).
///
/// Qwen3.6/DeepSeek-style chat templates pre-open a think block at the
/// prompt tail, so the model's output carries only `</think>`. The
/// streaming think parser buffers close-only output in its `undecided`
/// state until the close arrives — TTFT then equals the entire thinking
/// duration. The same state buffers TAGLESS output whole. The probe decides
/// which synthetic marker (if any) the engine injects so both stream
/// incrementally instead.
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

    // MARK: - Injection verdict (three-way)

    private static let openThinkTail = "<|im_start|>assistant\n<think>\n"

    private func injection(
        parser: ReasoningParserFormat?,
        stream: Bool? = true,
        tokens: [Int] = [1, 2, 3],
        tail: String = Self.openThinkTail
    ) -> ReasoningPromptProbe.Injection {
        ReasoningPromptProbe.injection(
            reasoningParser: parser,
            stream: stream,
            promptTokens: tokens,
            decodeTail: { _ in tail }
        )
    }

    @Test("only think-format parsers inject anything")
    func parserGate() {
        #expect(injection(parser: .qwen3) == .preOpened)
        #expect(injection(parser: .deepseekR1) == .preOpened)
        // A verbatim/none parser would leak the literal marker to consumers.
        #expect(injection(parser: ReasoningParserFormat.none) == .inapplicable)
        #expect(injection(parser: nil) == .inapplicable)
        #expect(injection(parser: .harmony) == .inapplicable)
        #expect(injection(parser: .gemma4) == .inapplicable)
    }

    @Test("only streaming requests inject anything")
    func streamGate() {
        // Non-streaming collection classifies close-only output correctly
        // at completion; injection is a streaming-only concern.
        #expect(injection(parser: .qwen3, stream: false) == .inapplicable)
        #expect(injection(parser: .qwen3, stream: nil) == .inapplicable)
    }

    @Test("a non-pre-opened tail selects the empty pair so tagless output streams")
    func notPreOpenedSelectsEmptyPair() {
        // An empty prompt cannot have pre-opened anything.
        #expect(injection(parser: .qwen3, tokens: []) == .notPreOpened)
        // Plain assistant header (qwen3-vl instruct, Qwen3.x thinking off
        // without the empty block, DeepSeek without the pre-open).
        #expect(injection(parser: .qwen3, tail: "<|im_start|>assistant\n") == .notPreOpened)
        #expect(injection(parser: .deepseekR1, tail: "<|Assistant|>") == .notPreOpened)
        // The pre-CLOSED thinking-off block: output is pure content, and an
        // orphan close cannot occur — stream from the first token.
        #expect(injection(parser: .qwen3, tail: "<think>\n\n</think>\n\n") == .notPreOpened)
        #expect(
            injection(parser: .qwen3, tail: "<|im_start|>assistant\n<think>\n\n</think>\n\n")
                == .notPreOpened)
    }

    @Test("an unclosed open tag mid-tail disables injection instead of leaking")
    func unclosedOpenMidTailIsInapplicable() {
        // The turn continues past `<think>` (assistant prefill inside
        // reasoning): the model's orphan close would leak as content under
        // the empty pair, so no marker is injected and the parser buffers
        // until the close — the pre-change behaviour.
        #expect(injection(parser: .qwen3, tail: "<think>\nalready reasoning") == .inapplicable)
        #expect(ReasoningPromptProbe.tailHasUnclosedThinkOpen("<think>\nalready reasoning"))
        // A closed block followed by text is not pre-opened: content streams.
        #expect(injection(parser: .qwen3, tail: "<think>\nx\n</think>\n\n") == .notPreOpened)
        #expect(!ReasoningPromptProbe.tailHasUnclosedThinkOpen("<think>\n\n</think>\n\n"))
        #expect(!ReasoningPromptProbe.tailHasUnclosedThinkOpen("<|im_start|>assistant\n"))
    }

    @Test("each verdict maps to exactly the marker the parser needs")
    func markers() {
        #expect(ReasoningPromptProbe.Injection.preOpened.marker == "<think>")
        #expect(ReasoningPromptProbe.Injection.notPreOpened.marker == "<think></think>")
        #expect(ReasoningPromptProbe.Injection.inapplicable.marker == nil)
        // The empty pair is literally open+close: two parser transitions
        // with empty spans, so nothing can ever be emitted for it.
        #expect(
            ReasoningPromptProbe.thinkEmptyPair
                == ReasoningPromptProbe.thinkOpen + "</think>")
    }

    @Test("the probe decodes only a bounded prompt tail")
    func boundedTailDecode() {
        let tokens = Array(0..<4096)
        var seen: [Int]?
        _ = ReasoningPromptProbe.injection(
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
