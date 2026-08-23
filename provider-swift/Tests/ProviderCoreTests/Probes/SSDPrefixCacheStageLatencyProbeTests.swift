// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private let ssdStageLatencyProbeEnabled =
    LiveInferenceFixtures.gateEnabled("DARKBLOOM_SSD_STAGE_LATENCY_PROBE")

/// Opt-in wall-clock probe for the real encrypted block-store path.
///
/// Run with:
///   DARKBLOOM_SSD_STAGE_LATENCY_PROBE=1 \
///   swift test --filter SSDPrefixCacheStageLatencyProbeTests
@Suite("SSD prefix cache: stage latency probe", .serialized)
struct SSDPrefixCacheStageLatencyProbeTests {
    @Test(
        "real SSD hit and miss p95 stay inside the configured stage deadline",
        .enabled(if: ssdStageLatencyProbeEnabled)
    )
    func hitAndMissP95() async throws {
        try #require(
            LiveInferenceFixtures.ensureMetallibColocated() != nil,
            "DARKBLOOM_SSD_STAGE_LATENCY_PROBE requires a usable MLX metallib")

        let dir = tempDir("latency-probe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = try dir.resourceValues(forKeys: [.volumeIsLocalKey])
        try #require(
            volume.volumeIsLocal == true,
            "DARKBLOOM_SSD_STAGE_LATENCY_PROBE requires a local filesystem volume")

        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000))
        defer { cache.close() }

        let tokenCount = 64
        let tokens = Array(0 ..< tokenCount)
        let hitPrompt = tokens + [999]
        cache.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: tokenCount),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(cache, atLeast: 8), "write-behind never landed")
        #expect(cache.index.count == 8)

        var missSamples: [Duration] = []
        for index in 0 ..< 50 {
            let started = ContinuousClock.now
            let result = await cache.stage(
                requestID: "miss-\(index)",
                promptTokens: Array(10_000 ..< (10_000 + tokenCount)) + [index],
                cacheScope: "")
            missSamples.append(started.duration(to: ContinuousClock.now))
            #expect(!result.staged)
            #expect(result.disposition == .missAbsent)
        }

        var hitSamples: [Duration] = []
        for index in 0 ..< 20 {
            let started = ContinuousClock.now
            let result = await cache.stage(
                requestID: "hit-\(index)", promptTokens: hitPrompt, cacheScope: "")
            hitSamples.append(started.duration(to: ContinuousClock.now))
            #expect(result.staged)
            let hit = try #require(
                cache.lookup(tokens: hitPrompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
            #expect(hit.matched == tokenCount)
            cache.endAdoption(tokens: hitPrompt, matched: hit.matched, cacheSalt: nil)
            cache.completeStaging(requestID: "hit-\(index)")
            #expect(cache.bytesInUse == 0)
        }

        missSamples.sort()
        hitSamples.sort()
        let missP95 = missSamples[47]
        let hitP95 = hitSamples[18]
        let policyDeadline = Duration.milliseconds(
            Int64(SSDPrefixCachePolicy.maxStageMillis(
                environment: ProcessInfo.processInfo.environment)))
        print(
            "SSD stage latency probe: miss_p95=\(missP95) "
                + "hit_p95=\(hitP95) deadline=\(policyDeadline)")
        #expect(missP95 < policyDeadline)
        #expect(hitP95 < policyDeadline)
    }
}
