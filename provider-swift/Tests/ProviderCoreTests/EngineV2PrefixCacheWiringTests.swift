// Copyright © 2026 Eigen Labs.
//
// Provider-side tests for cache usage propagation. Production prefix-cache
// construction is SSD-only and covered by SSDPrefixCacheTests.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private final class PrefixScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [CBv2Event]
    private var submittedRequests: [CBv2Request] = []

    init(events: [CBv2Event]) {
        self.events = events
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submittedRequests.append(request) }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for event in events { continuation.yield(event) }
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 0,
            activeTokens: 0)
    }

    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

private struct PrefixStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "t\($0)" }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { ["</s>": 2][token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        [1, 2, 3, 4, 5]
    }
}

private final class PrefixTelemetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEvent] = []

    func append(_ event: TelemetryEvent) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [TelemetryEvent] {
        lock.withLock { events }
    }
}

@Suite("EngineV2 prefix cache: usage detail")
struct EngineV2PrefixCacheUsageTests {

    @Test("native contiguous rate includes fp32 owning-full rows without staging")
    func nativeReservationRate() {
        #expect(EngineV2Factory.nativeKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: true
        ) == 124_576)
        #expect(EngineV2Factory.nativeKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: false
        ) == 100_000)
        #expect(EngineV2Factory.nativeKVBytesPerToken(
            nominalFP16BytesPerToken: Int.max,
            fp16FullKVBytesPerToken: 1,
            fullRowsUseFP32: true
        ) == Int.max)
    }

    @Test("recurrent models accept only the stronger exact-state cache")
    func recurrentCachePairing() {
        var recurrent = CBv2ModelCapabilities.initialRecurrentTarget
        recurrent.supportsExactStatePrefixReuse = true
        let exact = ExactPrefixCacheV2(
            config: .init(modelIdentity: "qwen-test", maxBytes: 0))
        let legacy = PrefixCacheV2()

        #expect(EngineV2Factory.prefixCacheIsSupported(
            capabilities: recurrent, prefixCache: exact))
        #expect(!EngineV2Factory.prefixCacheIsSupported(
            capabilities: recurrent, prefixCache: legacy))
        #expect(!EngineV2Factory.prefixCacheIsSupported(
            capabilities: recurrent, prefixCache: nil))
        #expect(EngineV2Factory.prefixCacheIsSupported(
            capabilities: .attentionOnly, prefixCache: legacy))
        #expect(!EngineV2Factory.prefixCacheIsSupported(
            capabilities: .attentionOnly, prefixCache: exact))
    }

    @Test("bridge records prefixCacheHitTokens into the per-request signal at the terminal")
    func usageSignalRecords() async throws {
        let engine = PrefixScriptedEngine(events: [
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 300, completionTokens: 1, prefixCacheHitTokens: 256)),
        ])
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            eosTokenIds: [2])
        let signal = EngineV2RequestUsageSignal()
        #expect(signal.prefixCacheHitTokens == nil, "unset until the terminal")

        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 300),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-usage",
            usageSignal: signal)
        for await _ in stream {}

        #expect(signal.prefixCacheHitTokens == 256)
    }

    @Test("bridge emits content-free frozen replay plan telemetry")
    func frozenReplayTelemetry() async throws {
        let engine = PrefixScriptedEngine(events: [
            .finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: 2817,
                    completionTokens: 1,
                    prefixCacheHitTokens: 1280,
                    prefixCacheOutcome: .hit,
                    prefixCacheMatchedTokens: 2816,
                    prefixCachePrefillTokensSaved: 1280,
                    prefixCacheStrategy: .frozenFullReplay,
                    prefixCacheReplayTokens: 1536,
                    prefixCacheBoundarySplits: 1)),
        ])
        let capture = PrefixTelemetryCapture()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefixStubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: { capture.append($0) })

        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 2817),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-frozen-telemetry")
        for await _ in stream {}

        let replay = try #require(capture.snapshot.first {
            $0.fields?["operation"]?.description == "prefix_cache_replay"
        })
        #expect(replay.fields?["prefix_reuse_strategy"]?.description == "frozen_full_replay")
        #expect(replay.fields?["prefix_matched_tokens"]?.description == "2816")
        #expect(replay.fields?["prefix_replay_tokens"]?.description == "1536")
        #expect(replay.fields?["prefix_saved_tokens"]?.description == "1280")
        #expect(replay.fields?["prefix_boundary_splits"]?.description == "1")
        #expect(replay.fields?["prefix_capacity_refusal"]?.description == "false")
        #expect(replay.fields?["prefix_cold_fallback"]?.description == "false")
        #expect(replay.fields?.keys.contains("request_id") != true)

        await bridge.emitPrefixCacheColdFallback(
            requestId: "req-capacity",
            reason: "stage_capacity",
            capacityRefusal: true)
        let fallback = try #require(capture.snapshot.last {
            $0.requestId == "req-capacity"
        })
        #expect(fallback.fields?["prefix_capacity_refusal"]?.description == "true")
        #expect(fallback.fields?["prefix_cold_fallback"]?.description == "true")
        #expect(fallback.fields?["reason"]?.description == "stage_capacity")
    }

    @Test("injectCachedTokens: splices prompt_tokens_details into a usage frame")
    func injectCachedTokens() throws {
        let usageFrame = """
            data: {"id":"c1","choices":[],"usage":{"prompt_tokens":300,"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":4}}}

            """
        let out = ProviderLoop.injectCachedTokens(into: usageFrame, cachedTokens: 256)
        let payload = try #require(out.split(separator: "\n").first?
            .replacingOccurrences(of: "data: ", with: ""))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let usage = try #require(obj["usage"] as? [String: Any])
        let details = try #require(usage["prompt_tokens_details"] as? [String: Any])
        #expect(details["cached_tokens"] as? Int == 256)
        #expect(usage["prompt_tokens"] as? Int == 300)
        #expect(usage["completion_tokens"] as? Int == 9)
        let completionDetails = try #require(usage["completion_tokens_details"] as? [String: Any])
        #expect(completionDetails["reasoning_tokens"] as? Int == 4)
    }

    @Test("injectCachedTokens: merges into an existing prompt_tokens_details object")
    func injectMergesExistingDetails() throws {
        let frame = """
            data: {"usage":{"prompt_tokens":10,"prompt_tokens_details":{"audio_tokens":3}}}

            """
        let out = ProviderLoop.injectCachedTokens(into: frame, cachedTokens: 8)
        let payload = try #require(out.split(separator: "\n").first?
            .replacingOccurrences(of: "data: ", with: ""))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let details = try #require(
            (obj["usage"] as? [String: Any])?["prompt_tokens_details"] as? [String: Any])
        #expect(details["cached_tokens"] as? Int == 8)
        #expect(details["audio_tokens"] as? Int == 3, "existing detail keys survive")
    }

    @Test("injectCachedTokens: non-usage frames and zero hits pass through untouched")
    func injectPassThrough() {
        let contentFrame = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: contentFrame, cachedTokens: 5)
            == contentFrame)
        let done = "data: [DONE]\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: done, cachedTokens: 5) == done)
        let usageFrame = "data: {\"usage\":{\"prompt_tokens\":10}}\n\n"
        #expect(ProviderLoop.injectCachedTokens(into: usageFrame, cachedTokens: 0) == usageFrame)
    }
}

// MARK: - fp32 paged pages: KV rate wiring

/// Engine stub whose only job is to report a fixed byte capacity, so the
/// heartbeat's rate→budget division is observable without a model.
private final class CapacityStubEngine: CBv2Engine, @unchecked Sendable {
    private let kvBytesCapacity: Int

    init(kvBytesCapacity: Int) {
        self.kvBytesCapacity = kvBytesCapacity
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: kvBytesCapacity,
            activeTokens: 0)
    }

    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

/// The fp32-page seam: `DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32` doubles what a
/// token costs in the pool, so the rate the slot hands `makeBridge` must
/// double — and the heartbeat's advertised token budget must HALVE — or
/// `BackendCapacity.Slots` being scheduler-authoritative lets the coordinator
/// over-admit ~2x against a pool holding half the tokens.
@Suite("EngineV2 fp32 paged pages: KV rate wiring")
struct EngineV2FP32PagedRateTests {

    @Test("processKVBytesPerToken doubles on fp32 pages and only there")
    func processRateDoubling() {
        // fp32 pages: flat 2x over the nominal rate.
        #expect(EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: false,
            pagedPoolDType: "float32"
        ) == 200_000)
        // fp16 pages and no dtype (contiguous): the base rate untouched.
        #expect(EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: false,
            pagedPoolDType: "float16"
        ) == 100_000)
        #expect(EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: false,
            pagedPoolDType: nil
        ) == 100_000)
        // Contiguous GPT-OSS keeps the native-width adjustment.
        #expect(EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: 100_000,
            fp16FullKVBytesPerToken: 24_576,
            fullRowsUseFP32: true,
            pagedPoolDType: nil
        ) == 124_576)
        // Saturating, never trapping, on absurd rates.
        #expect(EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: Int.max / 2 + 1,
            fp16FullKVBytesPerToken: 0,
            fullRowsUseFP32: false,
            pagedPoolDType: "float32"
        ) == Int.max)
    }

    @Test("the slot rate follows the CONSTRUCTED pool's dtype, not the request")
    func slotRateFollowsPoolDType() {
        // One owning full-attention layer: kvHeads * headDim * 2 (K+V) * 2
        // bytes = 8 * 64 * 4 = 2048 fp16 full-row bytes per token.
        let layerKinds = [
            CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 8, queryHeads: 16),
            CBv2LayerKind(
                attention: .slidingWindow(512), headDim: 64, kvHeads: 8, queryHeads: 16),
        ]
        let nominal = 100_000

        // Paged pool built with fp32 pages: the whole row doubles.
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .paged,
            pagedPoolDType: "float32",
            layerKinds: layerKinds,
            nominalFP16BytesPerToken: nominal,
            servingModelIsGPTOSS: false
        ) == 200_000)

        // Paged with default fp16 pages: nominal, unchanged.
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .paged,
            pagedPoolDType: "float16",
            layerKinds: layerKinds,
            nominalFP16BytesPerToken: nominal,
            servingModelIsGPTOSS: false
        ) == nominal)

        // An fp32 REQUEST that degraded to contiguous has no pages to
        // widen: the dtype is ignored on a contiguous build even if a
        // stale value were threaded through.
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .contiguous,
            pagedPoolDType: "float32",
            layerKinds: layerKinds,
            nominalFP16BytesPerToken: nominal,
            servingModelIsGPTOSS: false
        ) == nominal)

        // Contiguous GPT-OSS keeps the fp32 owning-full-row delta
        // (native-width rate), exactly as before this seam existed.
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .contiguous,
            pagedPoolDType: nil,
            layerKinds: layerKinds,
            nominalFP16BytesPerToken: nominal,
            servingModelIsGPTOSS: true
        ) == nominal + 2048)

        // Paged GPT-OSS never takes the native-width path (fp32 full rows
        // are a contiguous-backend behavior).
        #expect(EngineV2SlotFactory.slotKVBytesPerToken(
            resolvedKind: .paged,
            pagedPoolDType: "float16",
            layerKinds: layerKinds,
            nominalFP16BytesPerToken: nominal,
            servingModelIsGPTOSS: true
        ) == nominal)
    }

    @Test("a doubled rate halves the heartbeat's advertised token budget")
    func doubledRateHalvesTokenBudget() async {
        let capacityBytes = 8_000_000
        let fp16Rate = 2_000

        func budget(rate: Int) async -> (max: Int64, rate: Int64) {
            let bridge = EngineV2Bridge(
                engine: CapacityStubEngine(kvBytesCapacity: capacityBytes),
                modelId: "gemma-4-26b-qat-4bit",
                tokenizer: TokenizerHandle(PrefixStubTokenizer()),
                eosTokenIds: [2],
                kvBytesPerToken: rate,
                kvBackendKind: .paged)
            let slot = await bridge.backendSlotCapacity()
            return (slot.activeTokenBudgetMax, slot.kvBytesPerToken)
        }

        let fp16 = await budget(rate: fp16Rate)
        let fp32 = await budget(rate: EngineV2Factory.processKVBytesPerToken(
            nominalFP16BytesPerToken: fp16Rate,
            fp16FullKVBytesPerToken: 0,
            fullRowsUseFP32: false,
            pagedPoolDType: "float32"))

        #expect(fp16.max == Int64(capacityBytes / fp16Rate))
        #expect(fp32.rate == fp16.rate * 2)
        #expect(fp32.max == fp16.max / 2, "fp32 pages hold half the tokens per byte grant")
    }
}
