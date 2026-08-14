import XCTest

import Jinja

@testable import ProviderCoreFoundation

/// Pins the reasoning-disable render contract for Qwen3.6-style hybrid
/// thinking templates (OpenRouter baseline: "Expected reasoning length to be
/// at most 0").
///
/// The coordinator canonicalizes every "reasoning off" spelling into
/// `reasoning: {"enabled": false}`, which the engine maps to the
/// `enable_thinking` template variable. The template's disable branch is
/// gated on the Jinja boolean-literal test:
///
///     {%- if enable_thinking is defined and enable_thinking is false %}
///
/// so the entire disable path hinges on swift-jinja (1) treating a Swift
/// `Bool` in `additionalContext` as a Jinja boolean and (2) implementing the
/// `is false` test against boolean literals. A Jinja engine bump that breaks
/// either silently re-enables thinking fleet-wide — these tests fail first.
final class ReasoningDisableRenderTests: XCTestCase {

    /// The exact generation-prompt block of the Qwen3.6 chat template
    /// (EigenLabs/Qwen3.6-35B-A3B-MLX-VL, mirrored in the registry build's
    /// chat_template.jinja), reduced to the message loop + generation prompt.
    private let qwen36GenerationPromptTemplate = """
        {%- for message in messages %}
            {%- if message.role == "user" %}
                {{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>' + '\\n' }}
            {%- endif %}
        {%- endfor %}
        {%- if add_generation_prompt %}
            {{- '<|im_start|>assistant\\n' }}
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\\n\\n</think>\\n\\n' }}
            {%- else %}
                {{- '<think>\\n' }}
            {%- endif %}
        {%- endif %}
        """

    private func render(_ additionalContext: [String: Any?]) throws -> String {
        let template = try Template(qwen36GenerationPromptTemplate)
        var context: [String: Jinja.Value] = [
            "messages": try Value(any: [["role": "user", "content": "hi"] as [String: Any]]),
            "add_generation_prompt": .boolean(true),
        ]
        for (key, value) in additionalContext {
            context[key] = try Value(any: value)
        }
        return try template.render(context)
    }

    func testEnableThinkingFalsePreClosesThinkBlock() throws {
        let rendered = try render(["enable_thinking": false])
        XCTAssertTrue(
            rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
            "disabled thinking must render the pre-closed think block; got tail: \(rendered.suffix(64))")
    }

    func testEnableThinkingAbsentKeepsThinkingOn() throws {
        let rendered = try render([:])
        XCTAssertTrue(
            rendered.hasSuffix("<|im_start|>assistant\n<think>\n"),
            "hybrid templates think by default; got tail: \(rendered.suffix(64))")
    }

    func testEnableThinkingTrueKeepsThinkingOn() throws {
        let rendered = try render(["enable_thinking": true])
        XCTAssertTrue(
            rendered.hasSuffix("<|im_start|>assistant\n<think>\n"),
            "explicit enable must keep the open think block; got tail: \(rendered.suffix(64))")
    }

    /// The pre-closed (disabled) tail must never be mistaken for an open
    /// think block by the synthetic `<think>` injection probe — the parser
    /// would otherwise classify the whole answer as reasoning.
    func testDisabledTailIsNotAnOpenThinkBlock() throws {
        let rendered = try render(["enable_thinking": false])
        var tail = Substring(rendered)
        while let last = tail.last, last.isWhitespace {
            tail.removeLast()
        }
        XCTAssertFalse(
            tail.hasSuffix("<think>"),
            "disabled tail must end with </think>, not an open <think>")
    }
}
