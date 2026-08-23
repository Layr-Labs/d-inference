// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: donation, staging, adoption", .serialized)
struct SSDPrefixCacheLifecycleTests {

    private let tokenCount = 64  // 8 whole blocks at blockSize 8


    @Test("donate writes encrypted per-block files, dedupes re-donation, frees RAM")
    func donateWritesAndDedupes() async throws {
        let dir = tempDir("donate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8), "write-behind never landed")
        #expect(cache.index.count == 8)
        let files = dbk3Files(under: dir)
        #expect(files.count == 8)
        // RAM discipline: nothing resident after donation.
        #expect(cache.bytesInUse == 0)

        // No raw chain hashes anywhere on disk (filenames are HMAC tags).
        let hasher = CBv2BlockHasher(
            blockSize: fixtureBlockSize, promptContractID: "test-prompt-contract")
        let chainHexes = hasher.chainHashes(tokens: tokens).map { SSDLookupKeys.hex($0) }
        for file in files {
            for hex in chainHexes {
                #expect(!file.lastPathComponent.contains(hex.prefix(16)))
            }
        }

        // Re-donating the identical prefix writes nothing new.
        let written = cache.stats().blocksWritten
        donateFixture(cache, tokens: tokens)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cache.stats().blocksWritten == written)
        #expect(dbk3Files(under: dir).count == 8)

        // A one-block extension writes ONLY the tail block.
        donateFixture(cache, tokens: Array(0 ..< (tokenCount + fixtureBlockSize)))
        #expect(await waitForIndexCount(cache, atLeast: 9))
        #expect(dbk3Files(under: dir).count == 9)
    }


    @Test("salt isolation on disk: scoped donation is unfindable by other scopes")
    func saltIsolation() async throws {
        let dir = tempDir("salt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens, salt: "scope-a")
        #expect(await waitForIndexCount(cache, atLeast: 8))

        let prompt = tokens + [9999]
        #expect(!(await cache.stage(requestID: "r-unscoped", promptTokens: prompt, cacheScope: "")).staged)
        #expect(!(await cache.stage(requestID: "r-b", promptTokens: prompt, cacheScope: "scope-b")).staged)
        #expect((await cache.stage(requestID: "r-a", promptTokens: prompt, cacheScope: "scope-a")).staged)
        // And the staged entry only resolves under the donor's salt.
        #expect(cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil) == nil)
        let hit = cache.lookup(
            tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: "scope-a")
        #expect(hit != nil)
        if hit != nil {
            cache.endAdoption(tokens: prompt, matched: hit!.matched, cacheSalt: "scope-a")
        }
        cache.completeStaging(requestID: "r-a")
    }

    @Test("corrupt block: auth failure ⇒ file deleted, index dropped, recompute fallback")
    func corruptBlockFallsBack() async throws {
        let dir = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // High benefit floor (7 blocks) so corruption forces total fallback
        // (reads fail at block 1, so no shorter run can ever satisfy it) —
        // while the 8-block donation still clears the per-donation gate
        // (floor = bound 0 + 56 < 64 donated tokens).
        let cache = makeCache(
            dir: dir, kek: kek, clock: clock,
            minEffectiveTokens: tokenCount - fixtureBlockSize)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8))

        // Flip a byte in every block file (deterministic total corruption).
        for file in dbk3Files(under: dir) {
            var bytes = try Data(contentsOf: file)
            bytes[bytes.count - 10] ^= 0xFF
            try bytes.write(to: file)
        }
        let prompt = tokens + [12345]
        let staged = await cache.stage(requestID: "r-c", promptTokens: prompt, cacheScope: "")
        #expect(!staged.staged, "corrupt blocks must fall back to recompute, not stage")
        #expect(staged.disposition == .missCorrupt)
        #expect(cache.stats().corruptDropped >= 1)
        // The poisoned file was deleted and de-indexed.
        #expect(cache.index.count < 8)
        #expect(cache.bytesInUse == 0)
    }

    @Test("TTL: expired entries are swept (files unlinked) and never adopted")
    func ttlExpirySweep() async throws {
        let dir = tempDir("ttl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock, ttlSeconds: 900)
        defer { cache.close() }

        let tokens = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: tokens)
        #expect(await waitForIndexCount(cache, atLeast: 8))

        // Cross the 15-minute TTL, then sweep (the write path + periodic
        // task call exactly this).
        clock.advance(901)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 0)
        #expect(dbk3Files(under: dir).isEmpty)
        #expect(cache.stats().ttlExpired == 8)
        // Nothing left to adopt.
        let prompt = tokens + [1]
        let expiredResult = await cache.stage(
            requestID: "r-t", promptTokens: prompt, cacheScope: "")
        #expect(!expiredResult.staged)
        #expect(expiredResult.disposition == .missAbsent)
    }

    @Test("TTL slides on hit: a staged (hit) entry survives what an untouched one doesn't")
    func ttlSlidesOnHit() async throws {
        let dir = tempDir("ttl-slide")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let cache = makeCache(dir: dir, kek: kek, clock: clock, ttlSeconds: 900)
        defer { cache.close() }

        let hot = Array(0 ..< tokenCount)
        let cold = Array(5000 ..< (5000 + tokenCount))
        donateFixture(cache, tokens: hot, seed: 1.0)
        donateFixture(cache, tokens: cold, seed: 2.0)
        #expect(await waitForIndexCount(cache, atLeast: 16))

        // 600 s later, HIT the hot prefix (stage bumps lastAccess).
        clock.advance(600)
        #expect((await cache.stage(requestID: "r-hot", promptTokens: hot + [7], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-hot")

        // 600 s more: the cold prefix (1,200 s idle) expires; the hot one
        // (600 s since its hit) survives.
        clock.advance(600)
        cache.sweepExpiredEntries()
        #expect(cache.index.count == 8)
        #expect((await cache.stage(requestID: "r-hot2", promptTokens: hot + [8], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-hot2")
        #expect(!(await cache.stage(requestID: "r-cold", promptTokens: cold + [9], cacheScope: "")).staged)
    }

    @Test("LRU eviction at the box-wide budget: oldest-by-last-hit unlinked first")
    func lruEvictionAtBudget() async throws {
        let dir = tempDir("lru")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let budget = SSDDiskBudget()
        let cache = makeCache(dir: dir, kek: kek, clock: clock, diskBudget: budget)
        defer { cache.close() }

        let old = Array(0 ..< tokenCount)
        donateFixture(cache, tokens: old, seed: 1.0)
        #expect(await waitForIndexCount(cache, atLeast: 8))
        let perBlockBytes = cache.index.totalBytes / 8

        clock.advance(60)  // the second prefix is strictly newer
        let fresh = Array(9000 ..< (9000 + tokenCount))
        donateFixture(cache, tokens: fresh, seed: 2.0)
        #expect(await waitForIndexCount(cache, atLeast: 16))

        // Synthetic tiny budget: room for 8 blocks ⇒ the 8 OLDEST (the
        // entire older prefix — strictly older lastAccess) are unlinked.
        // (Evicting only part of the older prefix would be
        // nondeterministic: its blocks share one lastAccess, and any
        // surviving prefix-contiguous run could still stage.)
        budget.enforce(budgetBytes: perBlockBytes * 8)
        #expect(cache.index.totalBytes <= perBlockBytes * 8)
        #expect(cache.stats().evictions >= 8)
        // The NEWER prefix must still be fully adoptable; the older one not.
        #expect((await cache.stage(requestID: "r-new", promptTokens: fresh + [1], cacheScope: "")).staged)
        cache.completeStaging(requestID: "r-new")
        #expect(!(await cache.stage(requestID: "r-old", promptTokens: old + [1], cacheScope: "")).staged)
    }



    @Test("budget eviction skips an undeletable oldest file and removes another victim")
    func budgetEvictionContinuesPastUndeletableOldest() throws {
        let dir = tempDir("lru-undeletable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = SSDDiskBudget()
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            diskBudget: budget)
        defer { cache.close() }

        let oldTag = Data(repeating: 0xaa, count: 16)
        let newerTag = Data(repeating: 0xbb, count: 16)
        let oldURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(oldTag))
        let newerURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(newerTag))
        try FileManager.default.createDirectory(
            at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: newerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: oldURL)
        try Data(repeating: 2, count: 64).write(to: newerURL)
        cache.index.insert(tag16: oldTag, fileBytes: 64, lastAccess: 1)
        cache.index.insert(tag16: newerTag, fileBytes: 64, lastAccess: 2)

        let oldFanout = oldURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: oldFanout.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: oldFanout.path)
        }

        #expect(budget.enforce(budgetBytes: 64) == 1)
        #expect(cache.stats().evictions == 1)
        #expect(cache.index.count == 1)
        #expect(cache.index.contains(tag16: oldTag))
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: newerURL.path))
    }

    @Test("TTL telemetry counts only successful owned-file removals")
    func ttlTelemetryExcludesInvalidIndexDrops() throws {
        let dir = tempDir("ttl-success-count")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            ttlSeconds: 1)
        defer { cache.close() }

        let symlinkTag = Data(repeating: 0xaa, count: 16)
        let regularTag = Data(repeating: 0xbb, count: 16)
        let symlinkURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(symlinkTag))
        let regularURL = SSDBlockStore.fileURL(
            root: dir, tag16Hex: SSDLookupKeys.hex(regularTag))
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: regularURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = dir.deletingLastPathComponent().appendingPathComponent(
            "ssd-ttl-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside-must-survive".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL, withDestinationURL: outside)
        try Data(repeating: 3, count: 64).write(to: regularURL)
        cache.index.insert(tag16: symlinkTag, fileBytes: 64, lastAccess: 1)
        cache.index.insert(tag16: regularTag, fileBytes: 64, lastAccess: 1)

        cache.sweepExpiredEntries()

        #expect(cache.index.count == 0)
        #expect(cache.stats().ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: regularURL.path))
        #expect(try Data(contentsOf: outside) == Data("outside-must-survive".utf8))
    }

    @Test("endurance write cap: an exhausted token bucket drops donations, engine unaffected")
    func writeCapDropsDonations() async throws {
        let dir = tempDir("cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // 1-byte/day cap: the first block write already exceeds it.
        let cache = makeCache(dir: dir, kek: kek, clock: clock, maxWriteBytesPerDay: 1)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        // Deterministic settling: poll until the donation is accounted as
        // dropped (either pre-extraction or in the write consumer).
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, cache.stats().donationsDropped == 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(cache.stats().donationsDropped >= 1)
        #expect(cache.stats().blocksWritten == 0)
        #expect(dbk3Files(under: dir).isEmpty)
    }

    @Test("exhausted write cap: donation dropped BEFORE extraction (synchronous), tags settled for retry")
    func writeCapSkipsExtractionSynchronously() async throws {
        let dir = tempDir("cap-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        // 1-byte/day cap: `mightAcceptWrite(perBlockBytes)` is false from
        // the first donation.
        let cache = makeCache(dir: dir, kek: kek, clock: clock, maxWriteBytesPerDay: 1)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        // The endurance pre-check drops the donation INSIDE donate() —
        // before any device-slice/eval/host-copy and before the write-
        // behind queue — so the drop is visible synchronously, no consumer
        // polling. (Pre-fix, the drop only landed asynchronously at the
        // consumer's per-block tryConsume, after full extraction.)
        #expect(cache.stats().donationsDropped == 8)
        #expect(cache.stats().blocksWritten == 0)
        #expect(dbk3Files(under: dir).isEmpty)

        // The skip settles the in-flight dedupe tags: the SAME prefix can
        // be re-donated later (counted as dropped again) instead of being
        // stranded in `inFlightWrites` until restart.
        donateFixture(cache, tokens: Array(0 ..< tokenCount))
        #expect(cache.stats().donationsDropped == 16)
    }

    @Test("stage pre-floor is overflow-safe: absurd MIN_EFFECTIVE_TOKENS disables staging, never traps")
    func stagePreFloorOverflowSafe() async throws {
        let dir = tempDir("floor-overflow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)

        // Seed real on-disk blocks with a sanely-configured writer.
        let writer = makeCache(dir: dir, kek: kek, clock: clock)
        donateFixture(writer, tokens: Array(0 ..< tokenCount))
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // Same dir, operator-misconfigured benefit floor: the stage
        // pre-floor sum (adoptionBound + minEffective) would trap on naive
        // addition. It must instead saturate and DISABLE staging.
        let cache = makeCache(
            dir: dir, kek: kek, clock: clock,
            adoptionBound: 1, minEffectiveTokens: Int.max)
        defer { cache.close() }
        cache.scanOnDisk()
        #expect(cache.index.count == 8, "scan must index the seeded blocks")
        #expect(
            !(await cache.stage(
                requestID: "r-overflow",
                promptTokens: Array(0 ..< tokenCount) + [99],
                cacheScope: "")).staged)
    }
}
