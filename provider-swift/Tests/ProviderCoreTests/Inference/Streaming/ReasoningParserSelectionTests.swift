import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// Reasoning-parser selection by model type.
///
/// Regression guard for the hard-swap modelType bug (#2): a build that was
/// dropped from `advertisedModels` but is still resident in a model slot was
/// served with `modelType == nil`, which falls the reasoning parser back to
/// `.qwen3`. For a Gemma build that meant the `<think>` channel wasn't extracted
/// and reasoning tokens leaked into the visible answer. The fix sources
/// `modelType` from the loaded `ModelSlot` (captured at load), so it is never
/// nil for a model that can serve. These tests pin the mapping and, crucially,
/// that a Gemma model must NOT resolve to the same parser as the nil fallback.
@Suite("Reasoning parser selection")
struct ReasoningParserSelectionTests {
    @Test("a Gemma model selects the gemma4 reasoning parser")
    func gemmaSelectsGemma4() {
        #expect(ProviderLoop.inferReasoningParser(for: "gemma") == .gemma4)
        #expect(ProviderLoop.inferReasoningParser(for: "gemma3") == .gemma4)
        #expect(ProviderLoop.inferReasoningParser(for: "Gemma") == .gemma4)
    }

    @Test("a nil model type is the dangerous fallback — and a Gemma model must not collapse onto it")
    func nilFallbackDiffersFromGemma() {
        // The fallback itself is qwen3 (documents the hazard).
        #expect(ProviderLoop.inferReasoningParser(for: nil) == .qwen3)
        // The exact bug symptom: a Gemma build resolving like a nil modelType.
        // If these are ever equal, modelType sourcing has regressed.
        #expect(ProviderLoop.inferReasoningParser(for: "gemma") != ProviderLoop.inferReasoningParser(for: nil))
    }

    @Test("other known families map to their parsers")
    func knownFamilies() {
        #expect(ProviderLoop.inferReasoningParser(for: "gpt_oss") == .harmony)
        #expect(ProviderLoop.inferReasoningParser(for: "qwen") == .qwen3)
        #expect(ProviderLoop.inferReasoningParser(for: "deepseek") == .deepseekR1)
    }
}
