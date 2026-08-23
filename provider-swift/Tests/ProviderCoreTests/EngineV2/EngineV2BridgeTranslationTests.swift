// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Translation

@Suite("EngineV2 translation: ChatCompletionRequest → CBv2Request")
struct EngineV2TranslationTests {

    @Test("full request translates field-by-field")
    func fullFieldTranslation() {
        let request = makeRequest(
            temperature: 0.7, topP: 0.9, topK: 40, maxTokens: 128,
            repetitionPenalty: 1.1, presencePenalty: 0.5, frequencyPenalty: 0.25,
            stop: .multiple(["a", "b"]), seed: 42,
            logitBias: ["50256": -100], logprobs: true, topLogprobs: 5
        )
        let cbv2 = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(9),
            promptTokens: [1, 2, 3],
            request: request,
            defaultMaxTokens: 4096,
            stopTokenIds: [2, 7]
        )
        #expect(cbv2.id == CBv2RequestID(9))
        #expect(cbv2.promptTokens == [1, 2, 3])
        #expect(cbv2.maxTokens == 128)
        #expect(cbv2.stopTokens == [2, 7])
        #expect(cbv2.stopStrings == ["a", "b"])
        #expect(cbv2.priority == 0)
        #expect(cbv2.sampling.temperature == 0.7)
        #expect(cbv2.sampling.topP == 0.9)
        #expect(cbv2.sampling.topK == 40)
        #expect(cbv2.sampling.repetitionPenalty == 1.1)
        #expect(cbv2.sampling.presencePenalty == 0.5)
        #expect(cbv2.sampling.frequencyPenalty == 0.25)
        #expect(cbv2.sampling.seed == 42)
        #expect(cbv2.sampling.logitBias == [50256: -100])
        #expect(cbv2.sampling.topLogprobs == 5)
    }

    @Test("unset knobs collapse to legacy defaults (greedy temperature 0)")
    func defaultTranslation() {
        let cbv2 = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(1),
            promptTokens: [1],
            request: makeRequest(),
            defaultMaxTokens: 2048,
            stopTokenIds: []
        )
        // Legacy engine path uses `request.temperature ?? 0.0` — pinned here
        // so v2 can't drift to the contract's 1.0 default.
        #expect(cbv2.sampling.temperature == 0.0)
        #expect(cbv2.sampling.topP == 1.0)
        #expect(cbv2.sampling.topK == 0)
        #expect(cbv2.sampling.repetitionPenalty == 1.0)
        #expect(cbv2.sampling.frequencyPenalty == 0)
        #expect(cbv2.sampling.presencePenalty == 0)
        #expect(cbv2.sampling.seed == nil)
        #expect(cbv2.sampling.logitBias.isEmpty)
        #expect(cbv2.sampling.topLogprobs == 0)
        // maxTokens defaulting matches BatchScheduler.resolvedMaxTokens.
        #expect(cbv2.maxTokens == 2048)
        #expect(cbv2.stopStrings.isEmpty)
    }

    @Test("logit_bias string keys parse to token ids; junk keys are dropped")
    func logitBiasParsing() {
        let parsed = EngineV2Translation.parseLogitBias([
            "50256": -100,
            " 42 ": 1.5,      // whitespace-tolerant
            "abc": 5,         // non-numeric → dropped
            "-7": 3,          // negative id → dropped
        ])
        #expect(parsed == [50256: -100, 42: 1.5])
        #expect(EngineV2Translation.parseLogitBias(nil).isEmpty)
        #expect(EngineV2Translation.parseLogitBias([:]).isEmpty)
    }

    @Test("parseLogitBias reports a dropped-key count for the silent-drop signal (fix #9)")
    func logitBiasDroppedCount() {
        let result = EngineV2Translation.parseLogitBiasCountingDropped([
            "50256": -100,   // valid
            "abc": 5,        // non-numeric → dropped
            "-7": 3,         // negative → dropped
            " 9 ": 1,        // valid (whitespace tolerant)
        ])
        #expect(result.bias == [50256: -100, 9: 1])
        #expect(result.dropped == 2)
        // All-valid → zero dropped; nil/empty → zero dropped.
        #expect(EngineV2Translation.parseLogitBiasCountingDropped(["1": 2]).dropped == 0)
        #expect(EngineV2Translation.parseLogitBiasCountingDropped(nil).dropped == 0)
    }

    @Test("logprobs/top_logprobs mapping (0 = none; chosen-token → 1; clamp 20)")
    func topLogprobsMapping() {
        #expect(EngineV2Translation.topLogprobs(logprobs: nil, topLogprobs: nil) == 0)
        #expect(EngineV2Translation.topLogprobs(logprobs: false, topLogprobs: 3) == 0)
        // Contract can't express "chosen token only" — maps to 1 (see
        // CONTRACT-ISSUES-H-provider.md §2).
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: nil) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 0) == 1)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 5) == 5)
        #expect(EngineV2Translation.topLogprobs(logprobs: true, topLogprobs: 50) == 20)
    }

    @Test("cacheScope maps onto CBv2Request.cacheSalt; \"\" maps to nil")
    func cacheSaltMapping() {
        // TB-007 forward plumbing: a non-empty tenant scope becomes the
        // per-request salt; unscoped ("") falls back to nil so the engine
        // uses its cache-level salt (byte-identical pre-salt hashes).
        let salted = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(1), promptTokens: [1], request: makeRequest(),
            defaultMaxTokens: 16, stopTokenIds: [], cacheScope: "tenant-a")
        #expect(salted.cacheSalt == "tenant-a")
        let unsalted = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(2), promptTokens: [1], request: makeRequest(),
            defaultMaxTokens: 16, stopTokenIds: [])
        #expect(unsalted.cacheSalt == nil)
    }

    @Test("engine logprobs convert to the OpenAI streaming entry shape")
    func sseTokenLogprobConversion() {
        let names = [10: "Hi", 11: "Yo"]
        let entries = EngineV2Translation.sseTokenLogprobs(
            [
                CBv2TokenLogprob(
                    token: 10, logprob: -0.25,
                    topLogprobs: [(token: 10, logprob: -0.25), (token: 11, logprob: -1.5)]
                ),
                CBv2TokenLogprob(token: 11, logprob: -0.5),
            ],
            decodeToken: { names[$0] ?? "?" }
        )
        #expect(entries.count == 2)
        #expect(entries[0].token == "Hi")
        #expect(entries[0].logprob == -0.25)
        #expect(entries[0].bytes == [72, 105])  // UTF-8 of "Hi"
        #expect(entries[0].topLogprobs.count == 2)
        #expect(entries[0].topLogprobs[1].token == "Yo")
        #expect(entries[0].topLogprobs[1].logprob == -1.5)
        #expect(entries[0].topLogprobs[1].bytes == [89, 111])
        // No alternatives requested → empty top_logprobs, entry still carried.
        #expect(entries[1].token == "Yo")
        #expect(entries[1].topLogprobs.isEmpty)
    }

    @Test("stop resolution follows buildStopTokenIds semantics")
    func stopResolution() {
        // model EOS ∪ tokenizer EOS ∪ resolvable extra EOS tokens.
        let resolved = EngineV2Translation.stopTokenIds(
            eosTokenIds: [1, 2],
            tokenizerEOSTokenId: 2,
            extraEOSTokens: ["<|eot|>", "<|unknown|>"],
            convertTokenToId: { ["<|eot|>": 7][$0] }
        )
        #expect(resolved == [1, 2, 7])
    }

    @Test("bridge resolves the stop set once at construction and stamps every request")
    func bridgeStampsStopTokens() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(
            engine: engine,
            tokenizer: StubTokenizer(),   // eos "</s>" → 2
            eosTokenIds: [1],
            extraEOSTokens: ["<|eot|>"]   // → 7
        )
        let stream = await bridge.submit(request: makeRequest())
        _ = await record(stream)
        #expect(engine.submitted.count == 1)
        #expect(engine.submitted[0].stopTokens == [1, 2, 7])
        // Tokenization went through the tokenizer's chat-template path.
        #expect(engine.submitted[0].promptTokens == [1, 2, 3, 4, 5])
    }

    @Test("bridge stamps the tenant cache scope as CBv2Request.cacheSalt")
    func bridgeStampsCacheSalt() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        // Coordinator path shape: scope decoded out-of-band, passed explicitly.
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1, 2], request: makeRequest(), requestId: "req-salt-1",
            cacheScope: "tenant-scope"))
        // Caller-controlled body fields never become cache identity.
        _ = await record(await bridge.submit(
            request: makeRequest(promptCacheKey: "consumer-key"),
            requestId: "req-salt-2"))
        _ = await record(await bridge.submit(
            request: makeRequest(user: "user-77"), requestId: "req-salt-3"))
        // No tenant identity at all → nil (engine cache-level salt fallback).
        _ = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-salt-4"))
        #expect(engine.submitted.count == 4)
        #expect(engine.submitted[0].cacheSalt == "tenant-scope")
        #expect(engine.submitted[1].cacheSalt == nil)
        #expect(engine.submitted[2].cacheSalt == nil)
        #expect(engine.submitted[3].cacheSalt == nil)
    }
}
