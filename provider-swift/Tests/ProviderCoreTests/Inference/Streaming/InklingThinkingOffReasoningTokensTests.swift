// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// What withheld reasoning a request's usage signal records, and so what the
/// coordinator handler counts in `reasoning_tokens`: every count it reports
/// (the final usage chunk, a cancelled stream, a missing usage chunk, and the
/// completion record) reads the visible reasoning plus this signal's withheld
/// reasoning. Inkling 2 withholds its thought only when the request turned
/// thinking off; that thought is not counted as reasoning. Reasoning withheld
/// because the client declined to receive it still is.
@Suite("Inkling 2 thinking off: the withheld thought is not reasoning")
struct InklingThinkingOffReasoningTokensTests {
    static let thought = "<|message_model|><|content_thinking|>The user wants a short greeting. Think it over.<|end_message|>"
    static let answer = "<|message_model|><|content_text|>Hello there.<|end_message|><|content_model_end_sampling|>"

    static func inklingRouter(withhold: Bool) -> NativeToolStreamRouter {
        NativeToolStreamRouter(handler: nil, requiresToolCall: false, nativePrefix: nil, tools: nil,
            withholdReasoning: withhold, streamedCalls: nil, nativeInklingChannels: true, inklingStreamsCalls: false)
    }

    /// Feeds `text` in `width`-character pieces, recording withheld reasoning
    /// after each piece and at the end, as the scheduler's event stream does.
    static func run(_ router: inout NativeToolStreamRouter, _ text: String, width: Int, inkling: Bool,
                    into signal: EngineV2RequestUsageSignal) throws -> [MLXServerGenerationEvent] {
        let characters = Array(text)
        var events: [MLXServerGenerationEvent] = []
        for start in stride(from: 0, to: characters.count, by: width) {
            events += try router.process(String(characters[start..<min(start + width, characters.count)]))
            MultiModelBatchSchedulerEngine.recordWithheldReasoning(router.takeWithheldReasoning(), on: signal,
                nativeInklingChannels: inkling)
        }
        events += try router.finishText()
        MultiModelBatchSchedulerEngine.recordWithheldReasoning(router.takeWithheldReasoning(), on: signal,
            nativeInklingChannels: inkling)
        return events
    }

    @Test("thinking off: the thought ends the pre-content interval but is not recorded as reasoning",
          arguments: [1, 7, 4096])
    func thinkingOffThoughtIsNotReasoning(width: Int) throws {
        var router = Self.inklingRouter(withhold: true)
        let signal = EngineV2RequestUsageSignal()
        let events = try Self.run(&router, Self.thought + Self.answer, width: width, inkling: true, into: signal)
        #expect(!signal.hasWithheldReasoning, "reasoning_tokens counts no withheld thought")
        #expect(signal.withheldReasoning.isEmpty)
        #expect(signal.firstWithheldOutputAt != nil, "the thought was still generated output")
        let reasoning = events.compactMap { event -> String? in
            if case .parsed(let parsed) = event { return parsed.reasoningContent }
            return nil
        }.joined()
        #expect(reasoning.isEmpty, "nothing visible either")
    }

    @Test("thinking on: the thought streams as visible reasoning and nothing is withheld")
    func thinkingOnIsUnchanged() throws {
        var router = Self.inklingRouter(withhold: false)
        let signal = EngineV2RequestUsageSignal()
        let events = try Self.run(&router, Self.thought + Self.answer, width: 5, inkling: true, into: signal)
        let reasoning = events.compactMap { event -> String? in
            if case .parsed(let parsed) = event { return parsed.reasoningContent }
            return nil
        }.joined()
        #expect(reasoning == "The user wants a short greeting. Think it over.")
        #expect(!signal.hasWithheldReasoning && signal.firstWithheldOutputAt == nil)
    }

    @Test("reasoning another model withholds because the client declined it is still recorded as reasoning")
    func declinedReasoningOfOtherModelsStillCounts() {
        let signal = EngineV2RequestUsageSignal()
        MultiModelBatchSchedulerEngine.recordWithheldReasoning("Weigh ", on: signal, nativeInklingChannels: false)
        MultiModelBatchSchedulerEngine.recordWithheldReasoning("", on: signal, nativeInklingChannels: false)
        MultiModelBatchSchedulerEngine.recordWithheldReasoning("the request.", on: signal, nativeInklingChannels: false)
        #expect(signal.hasWithheldReasoning)
        #expect(signal.withheldReasoning == "Weigh the request.")
        #expect(signal.firstWithheldOutputAt != nil)
    }
}
