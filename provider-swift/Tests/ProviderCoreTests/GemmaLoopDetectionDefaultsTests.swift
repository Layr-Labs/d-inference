// GemmaLoopDetectionDefaultsTests -- unit coverage for the default-on n-gram
// tail-loop detection gate applied to Gemma-4 requests
// (BatchScheduler+LoopDetectionDefaults.swift).
//
// Pure function, no model/GPU required -- mirrors the style of
// B1GreedyFastPathTests's eligibility-policy tests.

import Foundation
import Testing

@testable import ProviderCore

@Suite("Gemma-4 default loop detection")
struct GemmaLoopDetectionDefaultsTests {

    @Test("Gemma-4 model ids get the default when enabled")
    func gemmaModelGetsDefault() {
        let defaults = BatchScheduler.loopDetectionDefaults(
            modelId: "mlx-community/gemma-4-26b-a4b-it-8bit", enabled: true)
        #expect(defaults?.maxPatternSize == 64)
        #expect(defaults?.minCount == 3)
    }

    @Test("model id matching is case-insensitive")
    func caseInsensitiveMatch() {
        let defaults = BatchScheduler.loopDetectionDefaults(
            modelId: "MLX-Community/Gemma-4-12B-IT-4bit", enabled: true)
        #expect(defaults != nil)
    }

    @Test("non-Gemma model families get no default")
    func nonGemmaModelGetsNoDefault() {
        for modelId in [
            "mlx-community/Qwen3.5-4B-4bit",
            "mlx-community/gpt-oss-20b-mxfp4",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
        ] {
            #expect(BatchScheduler.loopDetectionDefaults(modelId: modelId, enabled: true) == nil)
        }
    }

    /// The `.contains("gemma")` match is a substring match, not "exactly
    /// Gemma-4" -- it also catches Gemma-2/Gemma-3 ids, mirroring the
    /// identical imprecision already in `BatchScheduler+B1FastPath.swift`'s
    /// own Gemma-family gate. Pinning that here so it's an explicit, known
    /// scope decision rather than an implicit side effect discovered later.
    /// If this repo ever validates loop detection specifically against
    /// Gemma-2/Gemma-3 (or decides it should NOT apply there), update this
    /// test alongside `loopDetectionDefaults` and `b1FastPathEligiblePure`
    /// together -- they should not drift apart on model-family scoping.
    @Test("the match is broader than Gemma-4 alone -- also matches Gemma-2/Gemma-3, by design parity with B1FastPath")
    func matchIsBroaderThanGemma4Alone() {
        #expect(BatchScheduler.loopDetectionDefaults(modelId: "mlx-community/gemma-2-9b-it-4bit", enabled: true) != nil)
        #expect(BatchScheduler.loopDetectionDefaults(modelId: "mlx-community/gemma-3-27b-it-4bit", enabled: true) != nil)
    }

    @Test("the env kill switch disables the default even for Gemma-4")
    func disabledGateShortCircuits() {
        #expect(
            BatchScheduler.loopDetectionDefaults(
                modelId: "mlx-community/gemma-4-26b-a4b-it-8bit", enabled: false) == nil)
    }

    @Test("empty model id gets no default")
    func emptyModelIdGetsNoDefault() {
        #expect(BatchScheduler.loopDetectionDefaults(modelId: "", enabled: true) == nil)
    }

    @Test("loop detection is ON by default; the env flag opts OUT")
    func envFlagDefaultOn() {
        // Same shape as B1GreedyFastPathTests.envFlagDefaultOn: documents the
        // expectation rather than asserting a hard true, since a developer's
        // shell may have exported the opt-out.
        let env = ProcessInfo.processInfo.environment
        let off: Set<String> = ["0", "false", "no", "off"]
        let optedOut = off.contains((env["DARKBLOOM_GEMMA_LOOP_DETECTION"] ?? "").lowercased())
        #expect(BatchScheduler.gemmaLoopDetectionEnabled() == !optedOut)
    }
}
