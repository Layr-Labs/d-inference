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
