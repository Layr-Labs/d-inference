// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore


@Suite("EngineV2 matched stop sequence")
struct EngineV2MatchedStopSequenceTests {
    @Test("returns the exact first caller sequence present in generated text")
    func exactMatchedSequence() {
        #expect(EngineV2Bridge.matchedStopSequence(
            candidates: ["<later>", "<stop>", "<other>"],
            generatedText: "answer<stop>ignored<later>"
        ) == "<stop>")
    }

    @Test("preserves caller order for same-position overlapping sequences")
    func overlappingSequenceOrder() {
        #expect(EngineV2Bridge.matchedStopSequence(
            candidates: ["<stop>", "<stop>long"],
            generatedText: "answer<stop>long"
        ) == "<stop>")
    }

    @Test("natural EOS does not invent a matched sequence")
    func noMatchedSequence() {
        #expect(EngineV2Bridge.matchedStopSequence(
            candidates: ["<stop>", "<other>"],
            generatedText: "natural ending"
        ) == nil)
    }

    @Test("compares Unicode scalars exactly rather than canonically")
    func unicodeScalarExactness() {
        #expect(EngineV2Bridge.matchedStopSequence(
            candidates: ["cafe\u{301}"],
            generatedText: "caf\u{E9}"
        ) == nil)
    }

    @Test("natural EOS token rendering cannot impersonate a stop string")
    func eosRenderingIsExcluded() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "", tokens: [2], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine, eosTokenIds: [2])
        let signal = EngineV2RequestUsageSignal()
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(stop: .single("t2")),
            usageSignal: signal
        ))
        #expect(signal.matchedStopSequence == nil)
    }

    @Test("engine stop records the exact matched caller sequence")
    func engineStopRecordsMatch() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "", tokens: [9], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let signal = EngineV2RequestUsageSignal()
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(stop: .single("t9")),
            usageSignal: signal
        ))
        #expect(signal.matchedStopSequence == "t9")
    }

    @Test("finish-time detokenizer flush records a matched caller sequence")
    func lengthFinishRecordsFlushMatch() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "", tokens: [9], logprobs: nil),
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let signal = EngineV2RequestUsageSignal()
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: makeRequest(stop: .single("t9")),
            usageSignal: signal
        ))
        #expect(signal.matchedStopSequence == "t9")
    }
}

// MARK: - Event framing (fixture-compare against the legacy stream shape)
