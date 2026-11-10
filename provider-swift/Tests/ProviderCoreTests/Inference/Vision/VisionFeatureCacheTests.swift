import Foundation
import Testing
@testable import ProviderCore

private func ledger(_ cap: UInt64 = 1_000_000) -> ProcessMemoryLedger {
    ProcessMemoryLedger(policy: .init(epoch: 1, capBytes: cap, reserveBytes: 0),
        readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max) })
}

@Test func repeatedImageSkipsProducerAndPreservesBits() throws {
    let memory = ledger()
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 100_000)
    let cache = VisionFeatureCache(budget: budget, policy: .init(enabled: true))
    let key = VisionFeatureCache.Key(scope: "authenticated-a", model: "instance-a",
        processor: "gemma-v1", dtype: "float32", shape: [1, 3, 2, 2], frame: [1, 2, 2],
        pixelBytes: Data([1, 2, 3]))
    let expected = Data([0, 0, 0, 128, 1, 0, 192, 127]) // -0 and a NaN payload, not float equality.
    var work = 0
    func prepare() throws -> Data {
        let transaction = try cache.begin()
        defer { transaction.finish() }
        if let hit = transaction.lookup(key) { return hit.withUnsafeBytes { Data($0) } }
        work += 1
        try transaction.stage(key, dtype: "float32", shape: [1, 1, 2], byteCount: 8) { expected }
        transaction.commit()
        return expected
    }
    #expect(try prepare() == expected)
    #expect(try prepare() == expected)
    #expect(work == 1)
    #expect(memory.snapshot().chargedBytes > 8)
    cache.close()
    #expect(memory.snapshot().chargedBytes == 0)
}

private func key(_ image: UInt8 = 1, scope: String = "owner", model: String = "load-1",
                 processor: String = "processor-1", raw: UInt8 = 1,
                 shape: [Int] = [1, 3, 2, 2], frame: [Int] = [1, 2, 2],
                 dtype: String = "float32") -> VisionFeatureCache.Key {
    .init(scope: scope, model: model, processor: processor, dtype: dtype,
          shape: shape, frame: frame, pixelBytes: Data([image]), rawDigest: Data([raw]))
}
private let bits = Data([0, 0, 0, 128, 1, 0, 192, 127])
private func stage(_ transaction: VisionFeatureCache.Transaction, _ key: VisionFeatureCache.Key = key(),
                   copy: () throws -> Data = { bits }) throws {
    try transaction.stage(key, dtype: "float32", shape: [1, 1, 2], byteCount: 8, copy: copy)
}
private func fill(_ cache: VisionFeatureCache, _ key: VisionFeatureCache.Key = key()) throws {
    let transaction = try cache.begin(scope: "owner")
    defer { transaction.finish() }
    try stage(transaction, key)
    transaction.commit()
}
private func contains(_ cache: VisionFeatureCache, _ key: VisionFeatureCache.Key = key()) throws -> Bool {
    let transaction = try cache.begin()
    defer { transaction.finish() }
    return transaction.lookup(key) != nil
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@Test func identitySeparatesRawBytesPixelsScopeModelProcessorShapeFrameAndDtype() throws {
    let cache = VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true))
    defer { cache.close() }
    try fill(cache)
    #expect(try contains(cache))
    for changed in [key(2), key(scope: "other"), key(model: "load-2"),
                    key(processor: "processor-2"), key(raw: 2), key(shape: [1, 3, 1, 4]),
                    key(frame: [1, 1, 4]), key(dtype: "float16")] {
        #expect(try !contains(cache, changed))
    }
    // Text and image position intentionally have no place in the feature key.
    let transaction = try cache.begin()
    defer { transaction.finish() }
    #expect(transaction.lookup(key())?.withUnsafeBytes { Data($0) } == bits)
}

@Test func pendingBytesAreChargedBeforeCopyAndAbandonedOnFailure() throws {
    enum Fault: Error { case copy }
    let memory = ledger()
    let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
    let transaction = try cache.begin()
    #expect(throws: Fault.copy) {
        try stage(transaction) {
            #expect(memory.snapshot().chargedBytes == 1032)
            #expect(memory.snapshot().materializedBytes == 0)
            throw Fault.copy
        }
    }
    #expect(memory.snapshot().chargedBytes == 0)
    transaction.commit()
    #expect(transaction.lookup(key()) == nil)
    transaction.finish()
    cache.close()
}

@Test func missingBudgetDisabledScopeAndOversizeFailColdBeforeCopy() throws {
    for cache in [VisionFeatureCache(budget: nil, policy: .init(enabled: true)),
                  VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: false)),
                  VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true, maxBytes: 1031))] {
        let transaction = try cache.begin()
        var copies = 0
        try stage(transaction) { copies += 1; return bits }
        transaction.commit()
        #expect(copies == 0)
        #expect(transaction.lookup(key()) == nil)
        transaction.finish(); cache.close()
    }
    let cache = VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true))
    defer { cache.close() }
    for scope in ["", "  ", String(repeating: "x", count: 1025)] {
        let transaction = try cache.begin()
        try stage(transaction, key(scope: scope)) { Issue.record("invalid scope allocated snapshot"); return bits }
        transaction.commit()
        #expect(transaction.lookup(key(scope: scope)) == nil)
        transaction.finish()
    }
    #expect(!VisionFeatureCache.Policy.production(environment: [:]).enabled)
    #expect(!VisionFeatureCache.Policy.production(environment: ["DARKBLOOM_VISION_FEATURE_CACHE": "0"]).enabled)
    #expect(VisionFeatureCache.Policy.production(environment: ["DARKBLOOM_VISION_FEATURE_CACHE": "1"]).enabled)
}

@Test func byteAndEntryLRUEvictionHonorsHits() throws {
    for policy in [VisionFeatureCache.Policy(enabled: true, maxBytes: 2064),
                   .init(enabled: true, maxEntries: 2)] {
        let memory = ledger()
        let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: policy)
        try fill(cache, key(1)); try fill(cache, key(2))
        #expect(try contains(cache, key(1))) // 2 is now the least recently used.
        try fill(cache, key(3))
        #expect(try contains(cache, key(1)))
        #expect(try !contains(cache, key(2)))
        #expect(try contains(cache, key(3)))
        #expect(memory.snapshot().chargedBytes == 2064)
        cache.close()
        #expect(memory.snapshot().chargedBytes == 0)
    }
}

@Test func scopeQuotaIncludesPendingAndPinnedRetiredEntriesAcrossSlots() throws {
    for policy in [VisionFeatureCache.Policy(enabled: true, maxScopeBytes: 1032),
                   .init(enabled: true, maxScopeEntries: 1)] {
        let memory = ledger()
        let budget = VisionFeatureCacheBudget(ledger: memory)
        let a = VisionFeatureCache(budget: budget, policy: policy)
        let b = VisionFeatureCache(budget: budget, policy: policy)
        let pending = try a.begin()
        try stage(pending)
        let otherScope = key(3, scope: "different-owner")
        try fill(b, otherScope)
        #expect(try contains(b, otherScope))
        // The first unpublished snapshot spends this scope's entire allowance.
        try fill(b, key(2))
        #expect(try !contains(b, key(2)))
        #expect(try contains(b, otherScope))
        #expect(memory.snapshot().chargedBytes == 2064)
        pending.commit(); pending.finish()
        let reader = try a.begin()
        var hit: VisionFeatureCache.Tensor? = reader.lookup(key())
        reader.finish(); a.close()
        #expect(hit?.withUnsafeBytes { Data($0) } == bits)
        try fill(b, otherScope)
        try fill(b, key(2))
        #expect(try !contains(b, key(2)))
        // Denied admission cannot evict an unrelated scope or refund the alias.
        #expect(try contains(b, otherScope))
        #expect(memory.snapshot().chargedBytes == 2064)
        hit = nil
        try fill(b, key(2))
        #expect(try contains(b, key(2)))
        #expect(try contains(b, otherScope))
        b.close()
        #expect(memory.snapshot().chargedBytes == 0)
    }
}

@Test func scopeDenialPrecedesSimultaneousSlotAndProcessPressure() throws {
    let memory = ledger()
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 2064)
    let policy = VisionFeatureCache.Policy(enabled: true, maxEntries: 1, maxScopeEntries: 1)
    let a = VisionFeatureCache(budget: budget, policy: policy)
    let b = VisionFeatureCache(budget: budget, policy: policy)
    let pending = try a.begin()
    try stage(pending)
    let otherScope = key(3, scope: "different-owner")
    try fill(b, otherScope)
    try fill(b, key(2))
    #expect(try contains(b, otherScope))
    #expect(try !contains(b, key(2)))
    #expect(memory.snapshot().chargedBytes == 2064)
    pending.finish(); a.close()
    // Once scope pressure clears, slot pressure can reclaim B to admit A.
    try fill(b, key(2))
    #expect(try contains(b, key(2)))
    #expect(try !contains(b, otherScope))
    b.close()
    #expect(memory.snapshot().chargedBytes == 0)
}

@Test func scopeEvictionReclaimsOwnLRUWithoutEvictingOlderForeignScope() throws {
    for policy in [VisionFeatureCache.Policy(enabled: true, maxScopeBytes: 2064),
                   .init(enabled: true, maxScopeEntries: 2)] {
        let memory = ledger()
        let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: policy)
        let otherScope = key(4, scope: "different-owner")
        try fill(cache, otherScope)
        try fill(cache, key(1)); try fill(cache, key(2))
        #expect(try contains(cache, key(1)))
        try fill(cache, key(3))
        #expect(try contains(cache, otherScope))
        #expect(try contains(cache, key(1)))
        #expect(try !contains(cache, key(2)))
        #expect(try contains(cache, key(3)))
        #expect(memory.snapshot().chargedBytes == 3096)
        cache.close()
        #expect(memory.snapshot().chargedBytes == 0)
    }
}

@Test func processCapIncludesPendingScratchAndRetiredReaders() throws {
    let memory = ledger()
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 2064)
    let a = VisionFeatureCache(budget: budget, policy: .init(enabled: true))
    let b = VisionFeatureCache(budget: budget, policy: .init(enabled: true))
    let transaction = try a.begin()
    var scratch = transaction.scratch(byteCount: 8)
    #expect(scratch != nil)
    try fill(b, key(scope: "b"))
    try fill(a)
    #expect(transaction.lookup(key()) == nil)
    #expect(memory.snapshot().chargedBytes == 2064)
    scratch = nil
    try fill(a)
    #expect(transaction.lookup(key()) != nil)
    transaction.finish(); a.close(); b.close()
    #expect(memory.snapshot().chargedBytes == 0)
}

@Test func expiryAndPressureDropEligibilityButKeepPinnedBytes() throws {
    let clock = Clock()
    let memory = ledger()
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 20_000)
    let cache = VisionFeatureCache(budget: budget, policy: .init(enabled: true, ttl: 3), now: clock.read)
    try fill(cache)
    let reader = try cache.begin()
    var hit = reader.lookup(key())
    reader.finish()
    clock.advance(4); cache.sweep()
    #expect(try !contains(cache))
    #expect(memory.snapshot().chargedBytes == 1032)
    #expect(hit?.withUnsafeBytes { Data($0) } == bits)
    hit = nil
    #expect(memory.snapshot().chargedBytes == 0)
    try fill(cache)
    budget.trim()
    #expect(try !contains(cache))
    #expect(memory.snapshot().chargedBytes == 0)
    cache.close()
}

@Test func closeAndInvalidationFencePendingPublication() throws {
    for close in [false, true] {
        let memory = ledger()
        let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
        let transaction = try cache.begin()
        try stage(transaction) {
            if close { cache.close() } else { cache.invalidate() }
            return bits
        }
        transaction.commit()
        #expect(transaction.lookup(key()) == nil)
        #expect(memory.snapshot().chargedBytes == 0)
        transaction.finish()
        if close { #expect(throws: CancellationError.self) { try cache.begin() } }
        else { try fill(cache); #expect(try contains(cache)) }
        cache.close()
    }
}

@Test func changedLoadedBindingCannotReuseOrPublishOldFeatures() throws {
    let cache = VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true))
    defer { cache.close() }
    let transaction = try cache.begin()
    #expect(transaction.bind("model-a/processor-a/numerics-a"))
    try stage(transaction)
    #expect(!transaction.bind("model-b/processor-a/numerics-a"))
    transaction.commit()
    #expect(transaction.lookup(key()) == nil)
    transaction.finish()
    let next = try cache.begin()
    #expect(!next.bind("model-b/processor-a/numerics-a"))
    #expect(!next.bind("model-a/processor-b/numerics-a"))
    next.finish()
}

@Test func failedTransactionPreservesCommittedFeaturesAcrossScopes() throws {
    enum InputFailure: Error { case rejected }
    let memory = ledger()
    let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
    defer { cache.close() }
    let otherScope = key(2, scope: "different-owner")
    try fill(cache)
    try fill(cache, otherScope)
    func failedPreparation() throws {
        let transaction = try cache.begin(scope: "different-owner")
        defer { transaction.finish() }
        try stage(transaction, key(3, scope: "different-owner"))
        try stage(transaction, key(4, scope: "different-owner")) {
            throw InputFailure.rejected
        }
        transaction.commit()
    }
    #expect(throws: InputFailure.rejected) { try failedPreparation() }
    #expect(try contains(cache))
    #expect(try contains(cache, otherScope))
    #expect(try !contains(cache, key(3, scope: "different-owner")))
    #expect(try !contains(cache, key(4, scope: "different-owner")))
    #expect(memory.snapshot().chargedBytes == 2064)
    cache.close()
    #expect(memory.snapshot().chargedBytes == 0)
    #expect(memory.snapshot().ownerCount == 0)
}

@Test func cancellationAfterCopyCannotPublish() async throws {
    let memory = ledger()
    let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
    let task = Task {
        let transaction = try cache.begin()
        defer { transaction.finish() }
        do {
            try stage(transaction) {
                withUnsafeCurrentTask { $0?.cancel() }
                return bits
            }
            transaction.commit()
            return false
        } catch is CancellationError { return true }
    }
    #expect(try await task.value)
    #expect(try !contains(cache))
    #expect(memory.snapshot().chargedBytes == 0)
    cache.close()
}

@Test func cancellationWhileQueuedDoesNoCopy() async throws {
    let cache = VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let transaction = try cache.begin()
        defer { transaction.finish() }
        do {
            try stage(transaction) { Issue.record("cancelled producer copied bytes"); return bits }
            return false
        } catch is CancellationError { return true }
    }
    #expect(try await task.value)
    cache.close()
}

@Test func shutdownDrainsPreparationAndReaderBeforeRefund() async throws {
    let memory = ledger()
    let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
    try fill(cache)
    let transaction = try cache.begin()
    var hit = transaction.lookup(key())
    cache.close()
    let finished = Clock()
    let closing = Task { await cache.closeAndDrain(); finished.advance(1) }
    for _ in 0..<30 { await Task.yield() }
    #expect(finished.read() == 0)
    #expect(memory.snapshot().chargedBytes == 1032)
    transaction.finish()
    #expect(hit?.withUnsafeBytes { Data($0) } == bits)
    #expect(memory.snapshot().chargedBytes == 1032)
    hit = nil
    await closing.value
    #expect(finished.read() == 1)
    #expect(memory.snapshot().chargedBytes == 0)
    #expect(memory.snapshot().ownerCount == 0)
}

@Test func ledgerEpochPressureAndRetirementRemainAuthoritative() throws {
    let memory = ledger(10_000)
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 8000)
    let cache = VisionFeatureCache(budget: budget, policy: .init(enabled: true))
    try fill(cache)
    #expect(memory.updatePolicy(.init(epoch: 2, capBytes: 1000, reserveBytes: 0)))
    #expect(!memory.updatePolicy(.init(epoch: 1, capBytes: 100_000, reserveBytes: 0)))
    let reader = try cache.begin()
    var hit = reader.lookup(key())
    #expect(hit != nil)
    try fill(cache, key(2))
    #expect(try !contains(cache, key(2)))
    #expect(memory.snapshot().chargedBytes == 1032)
    cache.close(); reader.finish(); hit = nil
    #expect(memory.snapshot().chargedBytes == 0) // Reduction remains allowed in debt.
    #expect(memory.snapshot().ownerCount == 0)
    #expect(memory.snapshot().materializedBytes == 0)
}

@Test func malformedTensorDescriptorsAndCopySizesAreNotPublished() throws {
    let memory = ledger()
    let cache = VisionFeatureCache(budget: .init(ledger: memory), policy: .init(enabled: true))
    let transaction = try cache.begin()
    for shape in [[1, 0, 2], [2, 1, 1], [1, Int.max, 2], [1, 2], [1, 1, 3]] {
        try transaction.stage(key(), dtype: "float32", shape: shape, byteCount: 8) {
            Issue.record("invalid descriptor reached copy"); return bits
        }
    }
    try transaction.stage(key(), dtype: "unsupported", shape: [1, 1, 2], byteCount: 8) {
        Issue.record("unknown dtype reached copy"); return bits
    }
    try stage(transaction) { Data([1]) }
    transaction.commit()
    #expect(transaction.lookup(key()) == nil)
    transaction.finish(); cache.close()
    #expect(memory.snapshot().chargedBytes == 0)
}

@Test func concurrentPreparationsCannotOversubscribeAndCloseRefundsAll() async {
    let memory = ledger(20_000)
    let budget = VisionFeatureCacheBudget(ledger: memory, maxBytes: 4128)
    let cache = VisionFeatureCache(budget: budget, policy: .init(enabled: true, maxEntries: 4))
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                guard let transaction = try? cache.begin() else { return }
                defer { transaction.finish() }
                try? stage(transaction, key(UInt8(index))) {
                    #expect(memory.snapshot().chargedBytes <= 4128)
                    return bits
                }
                transaction.commit()
            }
        }
    }
    #expect(memory.snapshot().chargedBytes <= 4128)
    await cache.closeAndDrain()
    #expect(memory.snapshot().chargedBytes == 0)
    #expect(memory.snapshot().ownerCount == 0)
}

@Test func featureActivityIsBoundedAndContainsOnlyImageWorkCounts() {
    let activity = VisionFeatureCacheActivity()
    activity.hit(); activity.encode(2)
    #expect(activity.counts.hits == 1)
    #expect(activity.counts.encoded == 2)
    for _ in 0..<2000 { activity.hit() }
    activity.encode(Int.max)
    #expect(activity.counts.hits == 1024)
    #expect(activity.counts.encoded == 1024)
}

#if VISION_FEATURE_CACHE_STANDALONE
// Compile the SDK's unchanged serial owner in this isolated test module. This
// proves whole-async exclusion/coalescing without creating a ModelContainer/GPU.
@Test func existingSDKSerialOwnerCoalescesConcurrentSameImagePreparations() async throws {
    let owner = SerialAccessContainer(0)
    let cache = VisionFeatureCache(budget: .init(ledger: ledger()), policy: .init(enabled: true))
    let work = Clock()
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<24 {
            group.addTask {
                let transaction = try cache.begin(scope: "owner")
                defer { transaction.finish() }
                return try await owner.read { _ in
                    try Task.checkCancellation()
                    if let hit = transaction.lookup(key()) { return hit.withUnsafeBytes { Data($0) } }
                    await Task.yield()
                    work.advance(1)
                    try stage(transaction)
                    transaction.commit()
                    return bits
                }
            }
        }
        for try await value in group { #expect(value == bits) }
    }
    #expect(work.read() == 1)
    await cache.closeAndDrain()
}

@main enum VisionFeatureCacheTestRunner {
    static func main() async { exit(await Testing.__swiftPMEntryPoint()) }
}
#endif
