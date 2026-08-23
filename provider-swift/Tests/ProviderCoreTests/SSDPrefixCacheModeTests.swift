// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: production gate")
struct SSDPrefixCacheModeTests {

    @Test("reusable SSD cache requires a verified non-empty live weight hash")
    func verifiedWeightBindingRequired() {
        #expect(SSDPrefixCacheFactory.verifiedWeightHash(nil) == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash(" \n\t ") == nil)
        #expect(SSDPrefixCacheFactory.verifiedWeightHash("  abcd1234  ") == "abcd1234")
    }

    @Test("test root is isolated and requires the ephemeral-key gate")
    func isolatedTestRoot() {
        let root = tempDir("factory-test-root").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
        ]
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: raw) == root)
        #expect(
            SSDPrefixCacheFactory.cacheDirectory(
                modelId: "isolated-model",
                environment: raw
            ).deletingLastPathComponent() == root)
        #expect(
            SSDPrefixCacheFactory.cacheRootDirectory(environment: [
                SSDPrefixCacheFactory.testRootEnvironmentKey: root.path
            ]) != root)
    }

    @Test("durable-byte stage estimate is positive, conservative, and wire-bounded")
    func durableStageEstimate() {
        #expect(SSDPrefixCachePolicy.estimatedStageMillis(bytes: 1) == 1)
        #expect(SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: 1) > 0)
        #expect(SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: Int.max)
            == PrefixCacheReadyResult.maxStageMs)
    }

    @Test("box-wide disk budget: env override wins; default = min(20 GiB, free/2)")
    func diskBudgetResolver() {
        let gib = 1_073_741_824
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(
                environment: ["DARKBLOOM_PREFIX_CACHE_DISK_GB": "5"], freeBytes: 100 * gib)
                == 5 * gib)
        // Default: 20 GiB when free space is plentiful…
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: 100 * gib)
                == 20 * gib)
        // …clamped to free/2 on a tight volume…
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: 10 * gib)
                == 5 * gib)
        // …and the fixed default when free space is unknown.
        #expect(PrefixCachePolicy.ssdDiskBudgetBytes(environment: [:], freeBytes: nil) == 20 * gib)
        // Malformed env degrades to the default (never crashes, never 0).
        #expect(
            PrefixCachePolicy.ssdDiskBudgetBytes(
                environment: ["DARKBLOOM_PREFIX_CACHE_DISK_GB": "inf"], freeBytes: 100 * gib)
                == 20 * gib)
    }

    @Test("SSD knobs: TTL is capped at 15 minutes; write cap parses; stage gates parse")
    func ssdKnobs() {
        #expect(SSDPrefixCachePolicy.ttlSeconds(environment: [:]) == 900)
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "300"]) == 300)
        // The env can only SHORTEN the TTL (15-minute maximum) — raising or
        // disabling attempts fall back to the default.
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "86400"]) == 900)
        #expect(
            SSDPrefixCachePolicy.ttlSeconds(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS": "0"]) == 900)
        #expect(
            SSDPrefixCachePolicy.maxWriteBytesPerDay(environment: [:])
                == 150 * 1_000_000_000)
        #expect(
            SSDPrefixCachePolicy.maxWriteBytesPerDay(
                environment: ["DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY": "0"]) == 0)
        #expect(SSDPrefixCachePolicy.minEffectiveTokens(environment: [:]) == 1024)
        #expect(SSDPrefixCachePolicy.maxStageBytes(environment: [:]) == 1024 * 1_048_576)
        #expect(SSDPrefixCachePolicy.maxStageMillis(environment: [:]) == 1000)
        #expect(SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: 0)
            == 20 * 1_073_741_824)
    }
}
