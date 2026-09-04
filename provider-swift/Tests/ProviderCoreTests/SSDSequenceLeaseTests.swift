// Copyright © 2026 Eigen Labs.
//
// Receipt-sequence lease for the SSD cache epoch store: v2 receipt sequences
// are issued from memory inside a leased window whose end is the persisted
// high-water mark, so a receipt never pays a record rewrite + fsync, and no
// epoch-store I/O ever runs under SSDPrefixCache.lock (the lock the engine
// submit thread takes in lookup()). The coordinator only requires sequences
// strictly increasing per (provider, model, epoch); a crash skips at most one
// window. Live-isolated: real record files under throwaway temp dirs.

import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private func leaseTempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ssd-seq-lease-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func leaseBinding() -> SSDCacheEpochStore.Binding {
    SSDCacheEpochStore.Binding(
        modelId: "lease-model",
        modelAggregateHash: String(repeating: "a", count: 64),
        promptContractId: String(repeating: "b", count: 64),
        blockHashVersion: CBv2BlockHasher.version,
        blockSize: 256,
        layoutEpoch: "layout",
        keyFingerprint: String(repeating: "e", count: 64))
}

/// The persisted high-water mark, read back the way an operator would.
private func persistedNextSequence(root: URL) throws -> UInt64 {
    let data = try Data(contentsOf: root.appendingPathComponent("cache-epoch.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let value = try #require(object["nextSequence"] as? NSNumber)
    return value.uint64Value
}

private final class TimedValue<T: Sendable>: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?
    func set(_ value: T?) {
        lock.withLock { self.value = value }
        done.signal()
    }
    var seen: T? { lock.withLock { value } }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore, timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

/// An SSDPrefixCache over `modelRoot` bound to `epochStore`, with the
/// capability advertised (scan ready).
private func makeSequenceCache(
    modelRoot: URL, epochStore: SSDCacheEpochStore, binding: SSDCacheEpochStore.Binding
) async throws -> (cache: SSDPrefixCache, epoch: String) {
    let cache = SSDPrefixCache(
        config: .init(
            modelId: binding.modelId,
            promptContractID: binding.promptContractId,
            weightHash: binding.modelAggregateHash,
            blockSize: binding.blockSize,
            adoptionBoundTokens: 0,
            layoutEpoch: binding.layoutEpoch,
            epochStore: epochStore,
            root: modelRoot,
            ttlSeconds: 900,
            minEffectiveTokens: 256,
            maxStageBytes: 1 << 20,
            maxStageMillis: 1_000,
            nowSeconds: { 10_000 }),
        kekKey: SymmetricKey(size: .bits256),
        kvBudget: nil,
        diskBudget: SSDDiskBudget(),
        maxWriteBytesPerDay: 0,
        strictFsync: false,
        diskBudgetBytes: { 1 << 30 })
    cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)
    var capability: PrefixCacheV2Capability?
    for _ in 0 ..< 500 where capability == nil {
        capability = cache.prefixCacheV2Capability()
        if capability == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    return (cache, try #require(capability).cacheEpoch)
}

@Suite("SSD cache epoch: receipt sequence lease")
struct SSDSequenceLeaseTests {

    @Test("sequences are issued from memory: one record write per lease window")
    func leaseWindowPersistsOnce() throws {
        let root = try leaseTempRoot("window")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SSDCacheEpochStore(root: root, binding: leaseBinding())
        let epoch = try #require(store.current)
        #expect(try persistedNextSequence(root: root) == 1)

        var issued: [UInt64] = []
        for _ in 0 ..< 300 {
            issued.append(try #require(store.takeNextSequence(expectedEpoch: epoch)))
        }
        #expect(issued == Array(1 ... 300))
        // The record moved to the END of the leased window on the first take
        // and has not been touched since — not to 301 by 300 rewrites.
        let mark = try persistedNextSequence(root: root)
        #expect(mark > 301, "persisted mark \(mark) tracks every receipt (no lease)")
        #expect(mark == 1 + SSDCacheEpochStore.sequenceLeaseSize)

        // Exhausting the window re-leases exactly once.
        let remaining = Int(SSDCacheEpochStore.sequenceLeaseSize) - 300
        for _ in 0 ..< remaining {
            _ = try #require(store.takeNextSequence(expectedEpoch: epoch))
        }
        #expect(try persistedNextSequence(root: root) == 1 + SSDCacheEpochStore.sequenceLeaseSize)
        #expect(
            store.takeNextSequence(expectedEpoch: epoch)
                == 1 + SSDCacheEpochStore.sequenceLeaseSize)
        #expect(try persistedNextSequence(root: root) == 1 + 2 * SSDCacheEpochStore.sequenceLeaseSize)
    }

    @Test("restart and rotation: the next value exceeds everything issued; a fresh epoch starts at 1")
    func restartMonotonicAndRotationResets() throws {
        let root = try leaseTempRoot("restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = leaseBinding()
        let store = try SSDCacheEpochStore(root: root, binding: binding)
        let epoch = try #require(store.current)
        var highest: UInt64 = 0
        for _ in 0 ..< 50 {
            highest = try #require(store.takeNextSequence(expectedEpoch: epoch))
        }
        #expect(highest == 50)

        // A restarted process leases above the persisted mark, so nothing it
        // issues can collide with a receipt the old process already sent.
        let restarted = try SSDCacheEpochStore(root: root, binding: binding)
        #expect(restarted.current == epoch)
        let first = try #require(restarted.takeNextSequence(expectedEpoch: epoch))
        #expect(first > highest)
        #expect(first == 1 + SSDCacheEpochStore.sequenceLeaseSize)
        // Two live instances keep disjoint windows.
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 51)
        #expect(restarted.takeNextSequence(expectedEpoch: epoch) == first + 1)

        // Rotation resets the lease: the fresh epoch starts at 1 and the old
        // epoch's window is dead.
        let rotated = try #require(store.rotate())
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
        #expect(store.takeNextSequence(expectedEpoch: rotated) == 1)
        #expect(store.takeNextSequence(expectedEpoch: rotated) == 2)
        #expect(try persistedNextSequence(root: root) == 1 + SSDCacheEpochStore.sequenceLeaseSize)
        #expect(restarted.takeNextSequence(expectedEpoch: epoch) == nil)
        #expect(restarted.takeNextSequence(expectedEpoch: rotated) == nil)
    }

    @Test("a leased sequence needs no record lock; a non-rotating change does not reset it")
    func leasedSequenceTakesNoRecordLock() async throws {
        let root = try leaseTempRoot("no-io")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SSDCacheEpochStore(root: root, binding: leaseBinding())
        let epoch = try #require(store.current)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 1)

        // Hold the process-wide record lock through a non-rotating change
        // (the shape of an unlink window) and take a sequence from another
        // thread: it must come from the in-memory window, not wait for the
        // record.
        // Plain threads, not the cooperative pool: a loaded suite can starve
        // the pool and turn a blocked probe into a false timeout.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let mutationDone = DispatchSemaphore(value: 0)
        let probe = TimedValue<UInt64>()
        Thread.detachNewThread {
            _ = store.performOwnedNonRotatingChange {
                entered.signal()
                release.wait()
            }
            mutationDone.signal()
        }
        #expect(await waitForSemaphore(entered, timeout: .now() + 30) == .success)
        Thread.detachNewThread { probe.set(store.takeNextSequence(expectedEpoch: epoch)) }
        let answered = await waitForSemaphore(probe.done, timeout: .now() + 10)
        release.signal()
        _ = await waitForSemaphore(mutationDone, timeout: .now() + 30)
        #expect(answered == .success, "takeNextSequence waited on the record lock")
        #expect(probe.seen == 2)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 3)
    }

    @Test("SSDPrefixCache issues sequences without holding its lock across epoch-store I/O")
    func cacheSequenceReleasesLockBeforeStore() async throws {
        let root = try leaseTempRoot("cache-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("cccccccccccc", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let otherRoot = root.appendingPathComponent("dddddddddddd", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: otherRoot)
        let binding = leaseBinding()
        let epochStore = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let cache = SSDPrefixCache(
            config: .init(
                modelId: binding.modelId,
                promptContractID: binding.promptContractId,
                weightHash: binding.modelAggregateHash,
                blockSize: binding.blockSize,
                adoptionBoundTokens: 0,
                layoutEpoch: binding.layoutEpoch,
                epochStore: epochStore,
                root: modelRoot,
                ttlSeconds: 900,
                minEffectiveTokens: 256,
                maxStageBytes: 1 << 20,
                maxStageMillis: 1_000,
                nowSeconds: { 10_000 }),
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0,
            strictFsync: false,
            diskBudgetBytes: { 1 << 30 })
        defer { cache.close() }
        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)
        var capability: PrefixCacheV2Capability?
        for _ in 0 ..< 500 where capability == nil {
            capability = cache.prefixCacheV2Capability()
            if capability == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let epoch = try #require(capability).cacheEpoch

        // Exhaust the window so the next take must re-lease (record I/O).
        for _ in 0 ..< Int(SSDCacheEpochStore.sequenceLeaseSize) {
            _ = try #require(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch))
        }
        // Hold the process-wide record lock from an unrelated root (an
        // unloaded-root deletion), then issue the re-leasing take from another
        // thread: it blocks on the record — but must NOT be holding
        // SSDPrefixCache.lock while it does, or every path under that lock
        // (staging pins, ticket release, receipt registration, the engine's
        // submit-thread lookup) stalls behind a record write. `bytesInUse` is
        // the pure lock-only probe: it reads the staging map and nothing else.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = TimedValue<Bool>()
        Thread.detachNewThread {
            holder.set(
                SSDCacheEpochStore.performUnloadedDestructiveChange(root: otherRoot) {
                    entered.signal()
                    release.wait()
                })
        }
        #expect(await waitForSemaphore(entered, timeout: .now() + 30) == .success)
        let taken = TimedValue<UInt64>()
        Thread.detachNewThread {
            taken.set(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch))
        }
        try await Task.sleep(for: .milliseconds(200))
        let lockProbe = TimedValue<Int>()
        Thread.detachNewThread { lockProbe.set(cache.bytesInUse) }
        let answered = await waitForSemaphore(lockProbe.done, timeout: .now() + 10)
        release.signal()
        #expect(await waitForSemaphore(holder.done, timeout: .now() + 30) == .success)
        #expect(holder.seen == true)
        #expect(answered == .success, "SSDPrefixCache.lock was held across the epoch-store re-lease")
        #expect(lockProbe.seen == 0)
        #expect(await waitForSemaphore(taken.done, timeout: .now() + 30) == .success)
        #expect(taken.seen == 1 + SSDCacheEpochStore.sequenceLeaseSize)
    }

    @Test("a non-rotating unlink window issues sequences; a rotating one refuses promptly")
    func nonRotatingWindowIssuesSequences() async throws {
        let root = try leaseTempRoot("gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("eeeeeeeeeeee", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let binding = leaseBinding()
        let epochStore = try SSDCacheEpochStore(root: modelRoot, binding: binding)
        let (cache, epoch) = try await makeSequenceCache(
            modelRoot: modelRoot, epochStore: epochStore, binding: binding)
        defer { cache.close() }
        #expect(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 1)

        // Capacity eviction / TTL sweep / reconcile / corrupt drop: the epoch
        // is unchanged inside the window, so a lookup or ready receipt that
        // lands meanwhile must get its sequence — a nil is never retried by
        // the evidence sequencer and the donation is never reported durable.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let held = TimedValue<Bool>()
        Thread.detachNewThread {
            held.set(
                cache.holdDestructiveEpochForTesting(rotating: false) {
                    entered.signal()
                    release.wait()
                })
        }
        #expect(await waitForSemaphore(entered, timeout: .now() + 30) == .success)
        let taken = TimedValue<UInt64>()
        Thread.detachNewThread { taken.set(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch)) }
        let answered = await waitForSemaphore(taken.done, timeout: .now() + 10)
        release.signal()
        #expect(await waitForSemaphore(held.done, timeout: .now() + 30) == .success)
        #expect(held.seen == true)
        #expect(answered == .success)
        #expect(taken.seen == 2, "sequence refused inside a non-rotating unlink window")

        // An explicit rotation holds the store's instance lock across its
        // body: the cache must answer nil at once (the epoch is dying), not
        // park the sequencer actor on that lock.
        let rotatingEntered = DispatchSemaphore(value: 0)
        let rotatingRelease = DispatchSemaphore(value: 0)
        let rotated = TimedValue<Bool>()
        Thread.detachNewThread {
            rotated.set(
                cache.holdDestructiveEpochForTesting(rotating: true) {
                    rotatingEntered.signal()
                    rotatingRelease.wait()
                })
        }
        #expect(await waitForSemaphore(rotatingEntered, timeout: .now() + 30) == .success)
        let refused = TimedValue<UInt64>()
        Thread.detachNewThread { refused.set(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch)) }
        let refusedPromptly = await waitForSemaphore(refused.done, timeout: .now() + 10)
        rotatingRelease.signal()
        #expect(await waitForSemaphore(rotated.done, timeout: .now() + 30) == .success)
        #expect(refusedPromptly == .success, "a take inside a rotation blocked on the store's instance lock")
        #expect(refused.seen == nil)
        // The old epoch is dead after the rotation; the new one starts at 1.
        #expect(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == nil)
        let fresh = try #require(epochStore.current)
        #expect(fresh != epoch)
        #expect(cache.takeNextPrefixCacheV2Sequence(expectedEpoch: fresh) == 1)
    }
}
