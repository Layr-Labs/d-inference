// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

private final class BudgetAvailableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func set(_ value: UInt64) {
        lock.withLock { self.value = value }
    }

    var current: UInt64 {
        lock.withLock { value }
    }
}

@Suite("SSD prefix cache: staging reservations", .serialized)
struct SSDPrefixCacheReservationTests {

    private let tokenCount = 64

    private func makeBudget(headroomGiB: UInt64 = 64) -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: headroomGiB * 1_073_741_824, active: 0, cache: 0,
                    systemAvailable: headroomGiB * 1_073_741_824)
            })
    }

    private func makeStagedCache(
        dir: URL, kek: SymmetricKey, clock: ClockBox, kvBudget: GlobalKVCacheBudget
    ) async -> SSDPrefixCache {
        let cache = makeCache(dir: dir, kek: kek, clock: clock, kvBudget: kvBudget)
        cache.donate(
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        _ = await waitForIndexCount(cache, atLeast: 8)
        return cache
    }

    private func waitForZeroOutstanding(
        _ budget: GlobalKVCacheBudget, timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await budget.outstandingReservedBytes() == 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await budget.outstandingReservedBytes() == 0
    }

    @Test("success path: reserve before read, release at endAdoption")
    func successPathReleases() async throws {
        let dir = tempDir("res-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-ok", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        let hit = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        #expect(await waitForZeroOutstanding(budget), "endAdoption must release the reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("corrupt tail block: reservation + accounting shrink to the SHORTENED run")
    func shortenedRunShrinksReservation() async throws {
        let dir = tempDir("res-shortened")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let kek = SymmetricKey(size: .bits256)
        let cache = await makeStagedCache(
            dir: dir, kek: kek, clock: clock, kvBudget: budget)
        defer { cache.close() }

        // Identify the LAST chain block's file via the production name
        // derivation (chain hash -> HMAC tag under K_lookup) and corrupt it,
        // so stage() reads 7 good blocks and then hits the auth failure.
        let tokens = Array(0 ..< tokenCount)
        let hasher = CBv2BlockHasher(
            blockSize: fixtureBlockSize, promptContractID: "test-prompt-contract")
        let chain = hasher.chainHashes(tokens: tokens)
        let keys = SSDLookupKeys(kek: kek)
        let fileURL: (Int) -> URL = { i in
            SSDBlockStore.fileURL(
                root: dir,
                tag16Hex: SSDLookupKeys.hex(
                    keys.tag16(chainHash: chain[i], cacheSalt: "")))
        }
        let lastURL = fileURL(chain.count - 1)
        var bytes = try Data(contentsOf: lastURL)
        bytes[bytes.count - 10] ^= 0xFF
        try bytes.write(to: lastURL)

        let prompt = tokens + [7]
        let stageResult = await cache.stage(
            requestID: "req-short", promptTokens: prompt, cacheScope: "")
        #expect(stageResult.staged)
        #expect(stageResult.disposition == .staged(
            matchedTokens: 7 * fixtureBlockSize,
            expectedPrefillTokensSaved: 7 * fixtureBlockSize,
            shortenedByCorruption: true))
        let expectedBytes = stageResult.deviceBytes
        #expect(expectedBytes > 0)
        #expect(cache.stats().corruptDropped == 1)
        // Regression (Codex, v0.7.5 SSD review): the reservation and the
        // staging accounting must reflect exact rehydrated MLX bytes for the
        // SHORTENED run — never the original run or encrypted file overhead.
        #expect(await budget.outstandingReservedBytes() == UInt64(expectedBytes))
        #expect(cache.bytesInUse == expectedBytes)

        // The shortened run adopts and the balanced release drains fully.
        let hit = try #require(
            cache.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil))
        #expect(hit.matched == (chain.count - 1) * fixtureBlockSize)
        cache.endAdoption(tokens: prompt, matched: hit.matched, cacheSalt: nil)
        #expect(await waitForZeroOutstanding(budget), "endAdoption must release the reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("backstop path (lookup never ran): completeStaging releases")
    func backstopReleases() async throws {
        let dir = tempDir("res-backstop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-b", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        cache.completeStaging(requestID: "req-b")
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
        // Idempotent.
        cache.completeStaging(requestID: "req-b")
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("cancel path: a cancelled staging task releases and stages nothing")
    func cancelReleases() async throws {
        let dir = tempDir("res-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let task = Task { () -> Bool in
            // Guarantee the cancellation flag is observed before staging
            // starts its read loop.
            while !Task.isCancelled { await Task.yield() }
            return (await cache.stage(requestID: "req-x", promptTokens: prompt, cacheScope: "")).staged
        }
        task.cancel()
        let staged = await task.value
        #expect(!staged)
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
    }

    @Test("refusal path: no shared-budget headroom ⇒ no staging, no leak")
    func refusalUnderPressure() async throws {
        let dir = tempDir("res-refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A budget whose headroom is ~zero: total tiny, everything reserved.
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 1, active: 0, cache: 0, systemAvailable: 1)
            })
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let staged = await cache.stage(requestID: "req-p", promptTokens: prompt, cacheScope: "")
        #expect(!staged.staged, "refusal under memory pressure must be a silent recompute")
        #expect(staged.disposition == .skippedCapacity)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(cache.bytesInUse == 0)
    }

    @Test("conversion peak reserves host, per-block MLX, and concatenated arrays")
    func conversionPeakReservationCoversThreeRepresentations() async throws {
        let dir = tempDir("res-conversion-peak")
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = BudgetAvailableBox(64 * 1_073_741_824)
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 64 * 1_073_741_824,
                    active: 0,
                    cache: 0,
                    systemAvailable: available.current)
            })
        let cache = await makeStagedCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            kvBudget: budget)
        defer { cache.close() }
        let fileBytes = try dbk3Files(under: dir).reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(fileBytes > 0)
        available.set(UInt64(fileBytes * 5 / 2))

        let refused = await cache.stage(
            requestID: "req-peak",
            promptTokens: Array(0 ..< tokenCount) + [1],
            cacheScope: "")
        #expect(refused.disposition == .skippedCapacity)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(cache.bytesInUse == 0)

        available.set(UInt64(fileBytes * 4))
        let staged = await cache.stage(
            requestID: "req-peak-success",
            promptTokens: Array(0 ..< tokenCount) + [1],
            cacheScope: "")
        #expect(staged.staged)
        #expect(staged.deviceBytes > 0)
        #expect(await budget.outstandingReservedBytes() == UInt64(staged.deviceBytes))
        cache.completeStaging(requestID: "req-peak-success")
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
    }

    @Test("close(): open tickets drained, reservations released, files kept")
    func closeDrainsTickets() async throws {
        let dir = tempDir("res-close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)

        let prompt = Array(0 ..< tokenCount) + [1]
        #expect((await cache.stage(requestID: "req-c", promptTokens: prompt, cacheScope: "")).staged)
        #expect(await budget.outstandingReservedBytes() > 0)
        cache.close()
        #expect(await waitForZeroOutstanding(budget))
        #expect(cache.bytesInUse == 0)
        // On-disk files SURVIVE close — durable warmth is the feature.
        #expect(!dbk3Files(under: dir).isEmpty)
    }

    @Test("concurrent same-prefix requests bind exact tickets to one reserved entry")
    func sharedEntryReservedExactlyOnce() async throws {
        // Regression (Codex, v0.7.5 SSD review — SSDPrefixCache staging
        // ticket accounting): when two concurrent same-prefix requests
        // attach to a single staged entry, the shared KV budget must be
        // charged for that entry's bytes EXACTLY ONCE, and the reservation
        // must persist for the whole residency window. Pre-fix, each
        // attached request took its own per-request reservation (double
        // charge), and `endAdoption` popped an ARBITRARY staging ticket —
        // so one request's adoption could release a still-pinned peer's
        // reservation, leaving the resident staged MLX arrays with NO
        // GlobalKVCacheBudget reservation (an over-admission hole under the
        // memory cap).
        let dir = tempDir("res-shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        let cache = await makeStagedCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock, kvBudget: budget)
        defer { cache.close() }

        let prompt = Array(0 ..< tokenCount) + [1]
        let requestA = CBv2RequestID(101)
        let requestB = CBv2RequestID(102)
        // Race both stages. One creates the entry and the other attaches,
        // regardless of which disk read wins.
        async let stageA = cache.stage(
            requestID: requestA, promptTokens: prompt, cacheScope: "")
        async let stageB = cache.stage(
            requestID: requestB, promptTokens: prompt, cacheScope: "")
        let (resultA, resultB) = await (stageA, stageB)
        #expect(resultA.staged)
        #expect(resultB.staged)
        let sharedReservation = await budget.outstandingReservedBytes()
        #expect(sharedReservation > 0)
        // Charged ONCE: attaching adds a residency ticket, not a reservation.
        // (Pre-fix this was 2 × afterA.)
        #expect(
            sharedReservation == UInt64(cache.bytesInUse),
            "attaching to a staged entry must not add a second reservation")
        #expect(cache.bytesInUse == Int(sharedReservation))

        // An unrelated request cannot consume either staged ticket. B can
        // finish while A's lookup is still delayed without stealing A's pin.
        #expect(cache.lookup(
            requestID: CBv2RequestID(999),
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil) == nil)
        let hitB = try #require(cache.lookup(
            requestID: requestB,
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil))
        cache.endAdoption(
            requestID: requestB,
            tokens: prompt,
            matched: hitB.matched,
            cacheSalt: nil)
        cache.completeStaging(requestID: requestB)
        #expect(
            await budget.outstandingReservedBytes() == sharedReservation,
            "a resident shared entry must stay reserved until its LAST user leaves")
        #expect(cache.bytesInUse == Int(sharedReservation))

        // A's slower lookup remains valid after B's terminal backstop. Only
        // A can balance A's ticket; then the shared reservation drains.
        let hitA = try #require(cache.lookup(
            requestID: requestA,
            tokens: prompt,
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil))
        cache.endAdoption(
            requestID: requestA,
            tokens: prompt,
            matched: hitA.matched,
            cacheSalt: nil)
        cache.completeStaging(requestID: requestA)
        #expect(await waitForZeroOutstanding(budget), "the last user must drain the entry reservation")
        #expect(cache.bytesInUse == 0)
    }

    @Test("same-prefix attachment needs no spare provisional headroom")
    func attachAtCapacity() async throws {
        let dir = tempDir("res-attach-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        let available = BudgetAvailableBox(64 * 1_073_741_824)
        let budget = GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            configReserveBytes: 0,
            memorySnapshot: {
                GlobalKVCacheBudget.MemorySnapshot(
                    total: 64 * 1_073_741_824,
                    active: 0,
                    cache: 0,
                    systemAvailable: available.current)
            })
        let cache = await makeStagedCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            kvBudget: budget)
        defer { cache.close() }
        let prompt = Array(0 ..< tokenCount) + [1]
        let first = await cache.stage(
            requestID: "attach-a",
            promptTokens: prompt,
            cacheScope: "")
        #expect(first.staged)
        let reserved = await budget.outstandingReservedBytes()
        #expect(reserved == UInt64(first.deviceBytes))
        available.set(reserved)

        let second = await cache.stage(
            requestID: "attach-b",
            promptTokens: prompt,
            cacheScope: "")
        #expect(second.staged)
        #expect(second.deviceBytes == first.deviceBytes)
        #expect(await budget.outstandingReservedBytes() == reserved)

        cache.completeStaging(requestID: "attach-a")
        cache.completeStaging(requestID: "attach-b")
        #expect(await waitForZeroOutstanding(budget))
    }

    @Test("two cache instances may reserve the same raw receipt id independently")
    func instanceNamespacesPreventGlobalReservationCollisions() async throws {
        let parent = tempDir("res-instance-namespace")
        defer { try? FileManager.default.removeItem(at: parent) }
        let budget = makeBudget()
        let clock = ClockBox(10_000)
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("aaaaaaaaaaaa"),
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("bbbbbbbbbbbb"),
            withIntermediateDirectories: false)
        let cacheA = await makeStagedCache(
            dir: parent.appendingPathComponent("aaaaaaaaaaaa"),
            kek: SymmetricKey(size: .bits256),
            clock: clock,
            kvBudget: budget)
        let cacheB = await makeStagedCache(
            dir: parent.appendingPathComponent("bbbbbbbbbbbb"),
            kek: SymmetricKey(size: .bits256),
            clock: clock,
            kvBudget: budget)
        defer { cacheA.close(); cacheB.close() }

        let requestID = CBv2RequestID(1)
        let prompt = Array(0 ..< tokenCount) + [1]
        let resultA = await cacheA.stage(
            requestID: requestID, promptTokens: prompt, cacheScope: "")
        let resultB = await cacheB.stage(
            requestID: requestID, promptTokens: prompt, cacheScope: "")

        #expect(resultA.staged)
        #expect(resultB.staged)
        #expect(await budget.outstandingReservedBytes()
            == UInt64(cacheA.bytesInUse + cacheB.bytesInUse))
        #expect((await budget.reservationIDsForTesting()).count == 2)

        await cacheA.abandonStaging(requestID: requestID)
        await cacheB.abandonStaging(requestID: requestID)
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
