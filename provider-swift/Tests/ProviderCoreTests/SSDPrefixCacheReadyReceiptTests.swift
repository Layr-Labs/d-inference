// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

private final class ReadyReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrefixCacheReadyResult] = []

    func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
    var snapshot: [PrefixCacheReadyResult] { lock.withLock { values } }

    func waitForCount(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if snapshot.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return snapshot.count >= count
    }
}

@Suite("SSD prefix cache: durable-ready receipts", .serialized)
struct SSDPrefixCacheReadyReceiptTests {
    private func correlatedDonate(
        _ cache: SSDPrefixCache,
        requestID: CBv2RequestID,
        tokenCount: Int,
        seed: Float = 1
    ) {
        cache.donate(
            requestID: requestID,
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount, seed: seed),
            layerKinds: fixtureLayerKinds,
            cacheSalt: "scope")
    }

    @Test("ready is durable/readable and increases across successive donations")
    func monotonicReady() async throws {
        let dir = tempDir("ready-monotonic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize)
        defer { cache.close() }
        let box = ReadyReceiptBox()
        let requestID = CBv2RequestID(41)
        cache.registerReadyReceipt(requestID: requestID, callback: box.append)

        correlatedDonate(cache, requestID: requestID, tokenCount: 64)
        #expect(await box.waitForCount(1))
        #expect(box.snapshot[0].readyTokens == 64)
        #expect(box.snapshot[0].requiredRecomputeTokens == 0)
        #expect(box.snapshot[0].expectedPrefillTokensSaved == 64)
        #expect(try #require(box.snapshot[0].stageMs) > 0)
        #expect(try #require(box.snapshot[0].stageMs) <= PrefixCacheReadyResult.maxStageMs)

        correlatedDonate(cache, requestID: requestID, tokenCount: 72)
        #expect(await box.waitForCount(2))
        #expect(box.snapshot.map(\.readyTokens) == [64, 72])

        // Re-donation of the same terminal prefix is durable but must not
        // emit a duplicate/non-increasing receipt.
        correlatedDonate(cache, requestID: requestID, tokenCount: 72)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(box.snapshot.count == 2)
    }

    @Test("too-short, rate-limited, immediate-eviction, corrupt, and shutdown donations emit no ready")
    func noReadyFailureMatrix() async throws {
        func run(
            _ label: String,
            make: (URL, SymmetricKey, ClockBox) -> SSDPrefixCache,
            mutate: ((URL) -> Void)? = nil,
            closeBeforeDonate: Bool = false
        ) async -> [PrefixCacheReadyResult] {
            let dir = tempDir(label)
            defer { try? FileManager.default.removeItem(at: dir) }
            let kek = SymmetricKey(size: .bits256)
            let cache = make(dir, kek, ClockBox(10_000))
            let box = ReadyReceiptBox()
            let id = CBv2RequestID(51)
            cache.registerReadyReceipt(requestID: id, callback: box.append)
            if closeBeforeDonate { cache.close() }
            correlatedDonate(cache, requestID: id, tokenCount: 64)
            mutate?(dir)
            try? await Task.sleep(for: .milliseconds(500))
            cache.close()
            return box.snapshot
        }

        // Exactly at donation floor: no write job exists.
        let tooShortDir = tempDir("ready-short")
        defer { try? FileManager.default.removeItem(at: tooShortDir) }
        let tooShort = makeCache(
            dir: tooShortDir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: 64)
        let tooShortBox = ReadyReceiptBox()
        tooShort.registerReadyReceipt(requestID: CBv2RequestID(50), callback: tooShortBox.append)
        correlatedDonate(tooShort, requestID: CBv2RequestID(50), tokenCount: 64)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(tooShortBox.snapshot.isEmpty)
        tooShort.close()

        #expect(await run("ready-rate", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize,
                maxWriteBytesPerDay: 1)
        }).isEmpty)
        #expect(await run("ready-evict", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize,
                diskBudgetBytes: 0)
        }).isEmpty)
        #expect(await run("ready-shutdown", make: { dir, kek, clock in
            makeCache(
                dir: dir, kek: kek, clock: clock,
                minEffectiveTokens: fixtureBlockSize)
        }, closeBeforeDonate: true).isEmpty)

        // Corrupt every landed file inside the post-write whole-root barrier;
        // settlement's authenticated reread must suppress the receipt.
        let corruptDir = tempDir("ready-corrupt")
        defer { try? FileManager.default.removeItem(at: corruptDir) }
        let corrupt = makeCache(
            dir: corruptDir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize,
            maintainWholeRoot: {
                for file in dbk3Files(under: corruptDir) {
                    guard var bytes = try? Data(contentsOf: file), bytes.count > 16 else { continue }
                    bytes[bytes.count - 8] ^= 0xff
                    try? bytes.write(to: file)
                }
            })
        let corruptBox = ReadyReceiptBox()
        corrupt.registerReadyReceipt(requestID: CBv2RequestID(52), callback: corruptBox.append)
        correlatedDonate(corrupt, requestID: CBv2RequestID(52), tokenCount: 64)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(corruptBox.snapshot.isEmpty)
        corrupt.close()
    }

    @Test("terminal cleanup retention covers the coordinator two-minute attempt window")
    func receiptRetention() {
        #expect(SSDPrefixCache.readyReceiptRetention == .seconds(120))
    }

    @Test("write-behind maintenance/ready never blocks donation return")
    func responsePathNotDelayed() async throws {
        let dir = tempDir("ready-nonblocking")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            minEffectiveTokens: fixtureBlockSize,
            maintainWholeRoot: {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            })
        defer { cache.close(); release.signal() }
        let id = CBv2RequestID(61)
        cache.registerReadyReceipt(requestID: id, callback: { _ in })
        let returned = Task {
            correlatedDonate(cache, requestID: id, tokenCount: 64)
            return true
        }
        #expect(await returned.value)
        let enteredResult = await waitForSemaphore(entered, timeout: .now() + 5)
        #expect(enteredResult == .success)
        release.signal()
    }
}
