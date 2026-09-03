// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

private final class DonationOutcomeRecorder: PrefixCacheDonationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [PrefixCacheDonationOutcome: Int] = [:]

    func record(_ outcome: PrefixCacheDonationOutcome) {
        lock.withLock { counts[outcome, default: 0] += 1 }
    }

    func count(_ outcome: PrefixCacheDonationOutcome) -> Int {
        lock.withLock { counts[outcome, default: 0] }
    }
}

@Suite("SSD prefix cache: donation outcomes", .serialized)
struct SSDPrefixCacheDonationOutcomeTests {
    @Test("every donation opportunity settles one bounded outcome")
    func branchOutcomes() async throws {
        let root = tempDir("donation-outcomes")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DonationOutcomeRecorder()

        let noBlock = makeCache(
            dir: root.appendingPathComponent("no-block"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        noBlock.donate(
            tokens: Array(0 ..< 7),
            snapshots: fixtureSnapshots(tokenCount: 7),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let belowFloor = makeCache(
            dir: root.appendingPathComponent("floor"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            adoptionBound: 8,
            minEffectiveTokens: 8,
            donationRecorder: recorder)
        belowFloor.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let incomplete = makeCache(
            dir: root.appendingPathComponent("incomplete"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        incomplete.donate(
            tokens: Array(0 ..< 16),
            snapshots: [nil, nil],
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let stageCapped = makeCache(
            dir: root.appendingPathComponent("stage-cap"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            maxStageBytes: 512,
            donationRecorder: recorder)
        stageCapped.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let rateLimited = makeCache(
            dir: root.appendingPathComponent("rate"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            maxWriteBytesPerDay: 1,
            donationRecorder: recorder)
        rateLimited.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        let closed = makeCache(
            dir: root.appendingPathComponent("closed"),
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        closed.close()
        closed.donate(
            tokens: Array(0 ..< 16),
            snapshots: fixtureSnapshots(tokenCount: 16),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)

        #expect(recorder.count(.noCompleteBlock) == 1)
        #expect(recorder.count(.belowEffectiveTokenFloor) == 1)
        #expect(recorder.count(.incompleteLayerState) == 1)
        #expect(recorder.count(.stageSizeExceeded) == 1)
        #expect(recorder.count(.writeRateLimited) == 1)
        #expect(recorder.count(.cacheClosed) == 1)

        for cache in [noBlock, belowFloor, incomplete, stageCapped, rateLimited] {
            cache.close()
        }
    }

    @Test("durable and deduplicated donations settle distinctly")
    func durableOutcomes() async throws {
        let dir = tempDir("donation-durable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = DonationOutcomeRecorder()
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            donationRecorder: recorder)
        defer { cache.close() }

        let tokens = Array(0 ..< 16)
        let snapshots = fixtureSnapshots(tokenCount: tokens.count)
        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        await cache.waitForWritesForTesting()
        #expect(recorder.count(.donated) == 1)

        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(recorder.count(.alreadyDurable) == 1)
        let total = PrefixCacheDonationOutcome.allCases.reduce(0) {
            $0 + recorder.count($1)
        }
        #expect(total == 2)
    }
}
