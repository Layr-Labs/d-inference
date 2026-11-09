import CryptoKit
import Foundation

/// Host-only feature ownership shares the exact ledger used by GlobalKVCacheBudget.
/// No MLX materialization credit: Data is not included in MLX allocator counters.
final class VisionFeatureCacheBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: ProcessMemoryLedger
    private let maxBytes: UInt64
    private let maxEntries: Int
    private var bytes: UInt64 = 0
    private var retirementFailures = 0
    private var scopes: [Data: (bytes: UInt64, count: Int)] = [:]
    private var trimmers: [UUID: @Sendable () -> Void] = [:]
    private var slots: [UUID: (bytes: UInt64, count: Int)] = [:]

    init(ledger: ProcessMemoryLedger, maxBytes: UInt64 = 64 * 1024 * 1024, maxEntries: Int = 128) {
        self.ledger = ledger
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
    }

    func register(_ id: UUID, trim: @escaping @Sendable () -> Void) {
        lock.withLock { trimmers[id] = trim }
    }
    func unregister(_ id: UUID) { _ = lock.withLock { trimmers.removeValue(forKey: id) } }
    func trim() {
        let callbacks = lock.withLock { Array(trimmers.values) }
        for callback in callbacks { callback() }
    }
    func trimIfPressured() {
        if ledger.snapshot().remainingBytes < maxBytes { trim() }
    }

    final class Charge: Sendable {
        private let budget: VisionFeatureCacheBudget
        private let slot: UUID
        private let scope: Data
        private let state: ProcessMemoryLedger.OwnerState
        init(budget: VisionFeatureCacheBudget, slot: UUID, scope: Data, state: ProcessMemoryLedger.OwnerState) {
            self.budget = budget; self.slot = slot; self.scope = scope; self.state = state
        }
        deinit { budget.release(slot: slot, scope: scope, state: state) }
    }

    enum Refusal: Error {
        case invalidRequest
        case scopeCapacity
        case slotCapacity
        case processCapacity
        case ledgerPressure
        case ledgerUnavailable
    }

    func reserve(slot: UUID, scope: Data, bytes requested: UInt64,
                 policy: VisionFeatureCache.Policy) -> Result<Charge, Refusal> {
        ledger.prepareUsageReader()
        return lock.withLock {
            let current = slots[slot] ?? (bytes: 0, count: 0)
            let scoped = scopes[scope] ?? (bytes: 0, count: 0)
            guard requested > 0, requested <= maxBytes, requested <= policy.maxBytes,
                requested <= policy.maxScopeBytes, policy.maxScopeEntries > 0,
                policy.maxEntries > 0 else { return .failure(.invalidRequest) }
            // Check the narrowest quota first. Broader pressure must not evict
            // another scope while pending or pinned bytes block this scope.
            guard scoped.bytes <= policy.maxScopeBytes - requested,
                scoped.count < policy.maxScopeEntries else { return .failure(.scopeCapacity) }
            guard current.bytes <= policy.maxBytes - requested,
                current.count < policy.maxEntries else { return .failure(.slotCapacity) }
            guard bytes <= maxBytes - requested,
                slots.values.reduce(0, { $0 + $1.count }) < maxEntries else { return .failure(.processCapacity) }
            let owner = ledger.createOwner()
            do {
                let state = try ledger.replaceCharge(owner: owner.owner,
                    expectedRevision: owner.revision, expectedPolicyEpoch: ledger.policySnapshot().epoch,
                    chargedBytes: requested)
                bytes += requested
                slots[slot] = (current.bytes + requested, current.count + 1)
                scopes[scope] = (scoped.bytes + requested, scoped.count + 1)
                return .success(Charge(budget: self, slot: slot, scope: scope, state: state))
            } catch {
                _ = ledger.retire(owner.owner)
                return .failure((error as? ProcessMemoryLedger.Refusal) == .insufficientCapacity
                    ? .ledgerPressure : .ledgerUnavailable)
            }
        }
    }

    private func release(slot: UUID, scope: Data, state: ProcessMemoryLedger.OwnerState) {
        lock.withLock {
            // Only this charge owns the revision; no native aliases or materialization exist.
            do {
                _ = try ledger.replaceCharge(owner: state.owner, expectedRevision: state.revision,
                    expectedPolicyEpoch: 0, chargedBytes: 0)
                _ = ledger.retire(state.owner)
                bytes -= state.chargedBytes
                if let old = slots[slot], old.count > 1 {
                    slots[slot] = (old.bytes - state.chargedBytes, old.count - 1)
                } else { slots.removeValue(forKey: slot) }
                if let old = scopes[scope], old.count > 1 {
                    scopes[scope] = (old.bytes - state.chargedBytes, old.count - 1)
                } else { scopes.removeValue(forKey: scope) }
            } catch {
                // Fail closed: an ownership violation must never refund live RAM.
                retirementFailures = min(Int.max - 1, retirementFailures) + 1
            }
        }
    }
}

/// Per-loaded-bridge cache. Preparation is serialized by ModelContainer; this
/// short lock only fences lookups/publication against shutdown (never GPU work).
final class VisionFeatureCache: @unchecked Sendable {
    struct Policy: Sendable {
        var enabled: Bool
        var maxBytes: UInt64 = 32 * 1024 * 1024
        var maxEntries: Int = 64
        var maxScopeBytes: UInt64 = 16 * 1024 * 1024
        var maxScopeEntries: Int = 16
        var ttl: TimeInterval = 60
        static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            // Default off until actual-model parity, memory and latency qualification.
            Self(enabled: environment["DARKBLOOM_VISION_FEATURE_CACHE"] == "1")
        }
    }

    /// A coordinator scope a request may cache under: not blank, at most 1 KiB.
    /// Without one, a request takes the cold path and acquires no cache lease.
    static func isEligible(scope: String?) -> Bool {
        guard let scope else { return false }
        return !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scope.utf8.count <= 1024
    }

    /// Digests never leave this memory-only cache. Length-delimited encoding
    /// avoids delimiter ambiguity and bounds retained key size, including scope.
    struct Key: Hashable, Sendable {
        private let digest: Data
        let eligible: Bool
        let scopeDigest: Data
        init(scope: String, model: String, processor: String, dtype: String,
             shape: [Int], frame: [Int], pixelBytes: Data, rawDigest: Data = Data()) {
            scopeDigest = Self.digestScope(scope)
            eligible = VisionFeatureCache.isEligible(scope: scope)
            var hash = SHA256()
            for part in [Data("gemma-image-features-v1".utf8), Data(scope.utf8), Data(model.utf8),
                         Data(processor.utf8), Data(dtype.utf8),
                         Data(shape.map(String.init).joined(separator: ",").utf8),
                         Data(frame.map(String.init).joined(separator: ",").utf8), rawDigest, pixelBytes] {
                var length = UInt64(part.count).littleEndian
                withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
                hash.update(data: part)
            }
            digest = Data(hash.finalize())
        }
        static func digestScope(_ scope: String) -> Data { Data(SHA256.hash(data: Data(scope.utf8))) }
    }

    /// Callers pin the object through restore/eval. Eviction drops only the
    /// cache's reference; the charge survives every immutable hit reference.
    final class Tensor: @unchecked Sendable {
        let dtype: String
        let shape: [Int]
        var byteCount: Int { bytes!.count }
        private var bytes: Data?
        private var charge: VisionFeatureCacheBudget.Charge?
        private var lifetime: VisionFeatureCacheLifetime.Lease?
        init(dtype: String, shape: [Int], bytes: Data, charge: VisionFeatureCacheBudget.Charge, lifetime: VisionFeatureCacheLifetime.Lease) {
            self.dtype = dtype; self.shape = shape; self.bytes = bytes; self.charge = charge; self.lifetime = lifetime
        }
        deinit { bytes = nil; charge = nil; lifetime = nil } // Drop Data before the stored charge and lifetime retire.
        // The closure must copy into independent storage before returning. Do
        // not let a raw Data alias escape without also retaining this Tensor.
        func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            try withExtendedLifetime(self) { try bytes!.withUnsafeBytes(body) }
        }
    }

    private struct Entry { let tensor: Tensor; let expires: TimeInterval; var used: UInt64 }
    private let lock = NSLock()
    private let budget: VisionFeatureCacheBudget?
    private let policy: Policy
    private let now: @Sendable () -> TimeInterval
    private let slot = UUID()
    private let lifetime = VisionFeatureCacheLifetime()
    let preparationOwner = VisionFeaturePreparationOwner()
    private var maintenance: Task<Void, Never>?
    private var entries: [Key: Entry] = [:]
    private var generation: UInt64 = 0
    private var clock: UInt64 = 0
    private var closed = false
    private var binding: String?
    func bind(_ identity: String) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if let binding, binding != identity {
                generation &+= 1; entries.removeAll(); return false
            }
            binding = identity; return true
        }
    }

    init(budget: VisionFeatureCacheBudget?, policy: Policy = .production(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.budget = budget; self.policy = policy; self.now = now
        budget?.register(slot) { [weak self] in self?.trim() }
    }

    var isEnabled: Bool { lock.withLock { policy.enabled && budget != nil && !closed } }
    func begin(scope: String? = nil) throws -> Transaction {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            return Transaction(cache: self, generation: generation, scope: Key.digestScope(scope ?? ""), lease: lifetime.acquire())
        }
    }
    func trim() { lock.withLock { entries.removeAll() } }
    func sweep() { lock.withLock { expire() }; budget?.trimIfPressured() }
    func invalidate() { lock.withLock { generation &+= 1; entries.removeAll() } }
    func closeAndDrain() async {
        close()
        await preparationOwner.drain()
        let task = lock.withLock { maintenance }
        await task?.value
        await lifetime.drain()
    }
    func close() {
        preparationOwner.close()
        lock.withLock { closed = true; generation &+= 1; entries.removeAll(); maintenance?.cancel() }
    }
    deinit { maintenance?.cancel(); entries.removeAll(); budget?.unregister(slot) }

    /// One preparation transaction: a failure discards all staged images;
    /// commit happens only after spans, all outputs and MLX fault checks pass.
    // Only the model owner's serialized prepare closure uses a transaction;
    // shutdown touches the cache generation/lifetime, never this mutable state.
    final class Transaction: @unchecked Sendable {
        private let cache: VisionFeatureCache
        private let generation: UInt64
        private let scope: Data
        private var staged: [Key: Tensor] = [:]
        private var lease: VisionFeatureCacheLifetime.Lease?
        init(cache: VisionFeatureCache, generation: UInt64, scope: Data, lease: VisionFeatureCacheLifetime.Lease) {
            self.cache = cache; self.generation = generation; self.scope = scope; self.lease = lease
        }
        deinit { finish() }
        func bind(_ identity: String) -> Bool { cache.bind(identity) }
        func finish() { staged.removeAll(); lease = nil }
        func scratch(byteCount: Int) -> VisionFeatureCacheBudget.Charge? {
            guard lease != nil else { return nil }
            return cache.charge(byteCount: byteCount, scope: scope, generation: generation)
        }
        func lookup(_ key: Key) -> Tensor? {
            guard key.eligible, lease != nil, !Task.isCancelled, cache.accepts(generation) else { return nil }
            return staged[key] ?? cache.lookup(key, generation: generation)
        }
        func stage(_ key: Key, dtype: String, shape: [Int], byteCount: Int,
                   copy: () throws -> Data) throws {
            try Task.checkCancellation()
            guard key.eligible, lease != nil, staged[key] == nil, cache.accepts(generation), byteCount > 0,
                byteCount <= 8 * 1024 * 1024,
                Self.validByteCount(dtype: dtype, shape: shape) == byteCount,
                let charge = cache.charge(byteCount: byteCount, scope: key.scopeDigest, generation: generation) else { return }
            let bytes = try copy()
            try Task.checkCancellation()
            guard bytes.count == byteCount, cache.accepts(generation) else { return }
            staged[key] = Tensor(dtype: dtype, shape: shape, bytes: bytes, charge: charge, lifetime: cache.lifetime.acquire())
        }
        private static func validByteCount(dtype: String, shape: [Int]) -> Int? {
            let width: Int
            switch dtype {
            case "float32": width = 4
            case "float16", "bfloat16": width = 2
            default: return nil
            }
            guard shape.count == 3, shape[0] == 1 else { return nil }
            var count = width
            for dimension in shape {
                guard dimension > 0, dimension <= Int(Int32.max) else { return nil }
                let (next, overflow) = count.multipliedReportingOverflow(by: dimension)
                guard !overflow else { return nil }
                count = next
            }
            return count
        }
        func commit() {
            guard lease != nil else { return }
            cache.publish(staged, generation: generation)
            staged.removeAll()
        }
    }

    private func accepts(_ expected: UInt64) -> Bool {
        lock.withLock { policy.enabled && budget != nil && !closed && generation == expected }
    }
    private func expire() { entries = entries.filter { $0.value.expires > now() } }
    private func lookup(_ key: Key, generation expected: UInt64) -> Tensor? {
        lock.withLock {
            guard !closed, generation == expected else { return nil }
            expire()
            guard var entry = entries[key] else { return nil }
            clock &+= 1; entry.used = clock; entries[key] = entry
            return entry.tensor
        }
    }
    private func charge(byteCount: Int, scope: Data, generation expected: UInt64) -> VisionFeatureCacheBudget.Charge? {
        lock.withLock {
            guard policy.enabled, !closed, generation == expected, let budget, policy.ttl > 0, byteCount > 0 else { return nil }
            // Bounded metadata allowance (fixed digest, descriptors, dictionary and owner records).
            let (cost, overflow) = UInt64(byteCount).addingReportingOverflow(1024)
            guard !overflow, cost <= policy.maxBytes else { return nil }
            expire()
            while true {
                let candidates: [Key: Entry]
                switch budget.reserve(slot: slot, scope: scope, bytes: cost, policy: policy) {
                case .success(let charge): return charge
                case .failure(.scopeCapacity):
                    candidates = entries.filter { $0.key.scopeDigest == scope }
                case .failure(.slotCapacity), .failure(.processCapacity), .failure(.ledgerPressure):
                    candidates = entries
                case .failure(.invalidRequest), .failure(.ledgerUnavailable): return nil
                }
                guard let victim = candidates
                    .min(by: { $0.value.used < $1.value.used })?.key else { return nil }
                entries.removeValue(forKey: victim)
            }
        }
    }
    private func publish(_ staged: [Key: Tensor], generation expected: UInt64) {
        lock.withLock {
            guard !closed, generation == expected, !Task.isCancelled else { return }
            expire()
            if maintenance == nil, !staged.isEmpty {
                maintenance = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        self?.sweep()
                    }
                }
            }
            for (key, tensor) in staged {
                clock &+= 1
                entries[key] = Entry(tensor: tensor, expires: now() + policy.ttl, used: clock)
            }
        }
    }
}

/// A drain barrier independent of the cache lock. Leases cover preparation,
/// pending copies and every immutable Tensor alias; elapsed time never refunds.
final class VisionFeatureCacheLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    final class Lease: Sendable {
        private let owner: VisionFeatureCacheLifetime
        init(_ owner: VisionFeatureCacheLifetime) { self.owner = owner }
        deinit { owner.release() }
    }
    func acquire() -> Lease { lock.withLock { active += 1; return Lease(self) } }
    private func release() {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            active -= 1
            guard active == 0 else { return [] }
            let result = waiters; waiters.removeAll(); return result
        }
        for waiter in resume { waiter.resume() }
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if active == 0 { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Per-request content-free work accounting. Never used for cached-token usage,
/// prefix receipts or admission; only the request profile consumes this value.
final class VisionFeatureCacheActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: Int64 = 0
    private var encoded: Int64 = 0
    func hit() { lock.withLock { hits = min(1024, hits + 1) } }
    func encode(_ count: Int = 1) { lock.withLock { encoded = min(1024, encoded + Int64(max(0, min(1024, count)))) } }
    var counts: (hits: Int64, encoded: Int64) { lock.withLock { (hits, encoded) } }
}
