import XCTest
import Jinja

@testable import ProviderCoreFoundation

/// Pins the Qwen3.6 generation-prompt tail against the same Jinja engine
/// the runtime tokenizer uses. The published EigenLabs artifact thinks
/// unless `enable_thinking` is defined AND boolean false.
final class Qwen36ThinkingTemplateTests: XCTestCase {

    private let generationTail = """
        {%- if add_generation_prompt %}
            {{- '<|im_start|>assistant\\n' }}
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\\n\\n</think>\\n\\n' }}
            {%- else %}
                {{- '<think>\\n' }}
            {%- endif %}
        {%- endif %}
        """

    func testDisabledThinkingClosesTheThinkBlock() throws {
        let rendered = try render(enableThinking: false)
        XCTAssertTrue(rendered.hasSuffix("<think>\n\n</think>\n\n"), rendered)
        XCTAssertFalse(ReasoningPromptTail.endsInsideThinkBlock(rendered))
    }

    func testEnabledAndDefaultThinkingOpenTheThinkBlock() throws {
        for enabled in [true, nil] as [Bool?] {
            let rendered = try render(enableThinking: enabled)
            XCTAssertTrue(
                rendered.hasSuffix("<think>\n"),
                "enable_thinking=\(String(describing: enabled)) rendered \(rendered)")
            XCTAssertTrue(ReasoningPromptTail.endsInsideThinkBlock(rendered))
        }
    }
}

/// Mirrors `ReasoningPromptProbe.promptEndsInsideThinkBlock` so the
/// Foundation-only suite can pin the Qwen3.6 tail without importing
/// ProviderCore / MLX.
enum ReasoningPromptTail {
    static func endsInsideThinkBlock(_ tail: String) -> Bool {
        var trimmed = Substring(tail)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return trimmed.hasSuffix("<think>")
    }
}

extension Qwen36ThinkingTemplateTests {
    fileprivate func render(enableThinking: Bool?) throws -> String {
        let template = try Template(
            normalizeSwiftJinjaTemplate(generationTail),
            with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = [
            "add_generation_prompt": .boolean(true),
        ]
        if let enableThinking {
            context["enable_thinking"] = .boolean(enableThinking)
        }
        return try template.render(context)
    }
}
