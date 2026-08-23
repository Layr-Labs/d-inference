// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: own root survives the legacy kv sweep")
struct SSDRootIsolationTests {

    @Test("cacheDirectory lives under darkbloom/kv3, never under the legacy darkbloom/kv root")
    func rootIsOutsideLegacyTree() {
        let dir = SSDPrefixCacheFactory.cacheDirectory(modelId: "gpt-oss-20b")
        let path = dir.path
        #expect(path.contains("/darkbloom/kv3/"),
            "SSD tier must use its own root: \(path)")
        // The critical invariant: NOT inside the legacy root the upgrade
        // sweeper sheds (kv3 is a SIBLING of kv, not a subtree).
        #expect(!path.contains("/darkbloom/kv/"),
            "SSD tier must never live under the legacy kv root: \(path)")
        // Stable modelKey derivation (12-hex prefix of SHA256(modelId)).
        #expect(dir.lastPathComponent.count == 12)
    }

    @Test("the REAL legacy sweeper (LegacyKVCacheSweeper.sweep) leaves SSD entries intact and adoptable")
    func legacySweepSurvival() async throws {
        // Layout mirroring production: <caches>/darkbloom/kv (legacy) and
        // <caches>/darkbloom/kv3/<modelKey> (SSD) as SIBLINGS.
        let caches = tempDir("sweep-survival")
        defer { try? FileManager.default.removeItem(at: caches) }
        let legacyRoot = caches.appendingPathComponent("darkbloom/kv", isDirectory: true)
        let ssdDir = caches.appendingPathComponent(
            "darkbloom/kv3/aaaa11112222", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: legacyRoot.appendingPathComponent("aaaa11112222"),
            withIntermediateDirectories: true)
        try Data([1]).write(
            to: legacyRoot.appendingPathComponent("aaaa11112222/old.darkbloom-kv"))
        try fm.createDirectory(at: ssdDir, withIntermediateDirectories: true)

        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let writer = makeCache(dir: ssdDir, kek: kek, clock: clock)
        let tokens = Array(0 ..< 64)
        writer.donate(
            tokens: tokens,
            snapshots: fixtureSnapshots(tokenCount: 64),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // THE LEGACY SWEEP — the REAL production sweeper (the exact code
        // `ProviderLoop.run()` / the standalone server invoke at startup),
        // pointed at this layout's kv/ root: it sheds the retired tier's
        // ciphertext wholesale. kv3/ (a SIBLING, not a subtree) must be
        // untouched.
        let sweptBytes = LegacyKVCacheSweeper.sweep(kvRoot: legacyRoot)
        #expect(sweptBytes > 0, "the sweeper must have removed the legacy tier's bytes")
        #expect(!fm.fileExists(atPath: legacyRoot.path), "the legacy kv/ root must be gone")

        #expect(dbk3Files(under: ssdDir).count == 8, "SSD entries must survive the legacy sweep")
        // And they remain fully adoptable: fresh cache, scan, stage.
        let reader = makeCache(dir: ssdDir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 8)
        #expect((await reader.stage(
            requestID: "r-survive", promptTokens: tokens + [1], cacheScope: "")).staged)
        reader.completeStaging(requestID: "r-survive")
    }
}
