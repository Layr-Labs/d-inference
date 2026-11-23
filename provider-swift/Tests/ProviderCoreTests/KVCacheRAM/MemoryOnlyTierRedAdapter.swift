import Darwin
import Foundation
@testable import MLXLMCommon

@testable import ProviderCore

// Test-only adapter for the red control: the RAM-only tier's test-facing
// surface with the base's behaviour. A memory_only request's prefix is never
// kept, the prompt-token piece cache has no TTL, and nothing is counted.

final class LockedHostRegion {
    typealias Wire = (UnsafeMutableRawPointer, Int) -> Int32
    init?(bytes: Int, wire: Wire = { mlock($0, $1) }) { nil }
}

final class MemoryOnlyCheckpointPool: @unchecked Sendable {
    static let shared = MemoryOnlyCheckpointPool()

    enum EvictionReason: String, CaseIterable, Sendable {
        case lru, ttl, pressure, load, shortfall, sleep, unload, shutdown
    }
    enum StoreOutcome: String, CaseIterable, Sendable {
        case stored, duplicate, refusedBudget, refusedBusy, refusedHeadroom, refusedLock, refusedPolicy
    }
    enum LookupOutcome: String, CaseIterable, Sendable { case hit, miss, skipped }

    struct Snapshot: Sendable, Equatable {
        var budgetBytes: UInt64 = 0
        var bytes: UInt64 = 0
        var entries = 0
        var lookups: [LookupOutcome: UInt64] = [:]
        var hitTokens: UInt64 = 0
        var stores: [StoreOutcome: UInt64] = [:]
        var evictions: [EvictionReason: UInt64] = [:]
        var unmarkedRefusals: UInt64 = 0
    }

    final class Admission: @unchecked Sendable {
        let bytes: UInt64 = 0
        func cancel(outcome: StoreOutcome) {}
    }

    private let lock = NSLock()
    private var budget: UInt64 = 0

    init(ttlSeconds: Int64 = 1_800, ttlMode: SSDPrefixCachePolicy.TTLMode = .sliding,
         sweepInterval: Duration = .seconds(60), nowSeconds: @escaping @Sendable () -> Int64 = { 0 }) {}

    var budgetBytes: UInt64 { lock.withLock { budget } }
    var bytesInUse: UInt64 { 0 }
    var snapshot: Snapshot { Snapshot() }
    func setBudget(_ bytes: UInt64) { lock.withLock { budget = bytes } }
    func admit(bytes: Int, ledger: GlobalKVCacheBudget?) -> Admission? { nil }
    func releaseAll(reason: EvictionReason) {}
    func sweepExpired() {}
}

final class MemoryOnlyCheckpointTier: @unchecked Sendable {
    struct Config: Sendable {
        let identity: CBv2CompleteCheckpointIdentity
        let backendLayout: String
        let minEffectiveTokens: Int
    }

    init(config: Config, kvBudget: GlobalKVCacheBudget?, pool: MemoryOnlyCheckpointPool = .shared,
         wire: @escaping LockedHostRegion.Wire = { mlock($0, $1) }) {}

    func donate(
        _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
        tokens: [Int], cacheSalt: String?, completion: @escaping @Sendable ([Int]) -> Void
    ) {
        source.close()
        completion([])
    }

    func stage(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        .init(disposition: .skippedPolicy, stageMs: 0)
    }

    func takeStaged(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
    ) -> CBv2StagedCompleteCheckpoint? { nil }

    var isAvailable: Bool { false }
    func completeStaging(requestID: CBv2RequestID) {}
    func abandonStaging(requestID: CBv2RequestID) async {}
    func close() {}
    func closeAndWait() async {}
}

enum MemoryOnlyPrefixCachePolicy {
    static let modeEnvironmentKey = "DARKBLOOM_ZDR_PREFIX_CACHE_RAM"
    static let maximumMegabytesEnvironmentKey = "DARKBLOOM_ZDR_PREFIX_CACHE_RAM_MAX_MB"
    static func isEnabled(environment: [String: String] = [:]) -> Bool { false }
    static func capBytes(environment: [String: String] = [:]) -> UInt64 { 0 }
    static func budgetBytes(fleetKVHeadroomBytes: UInt64, environment: [String: String] = [:]) -> UInt64 { 0 }
    static func attachesTier(excludedModel: Bool, environment: [String: String] = [:]) -> Bool { false }
}

extension PrefixCacheSubmissionPolicy {
    init(cachePolicy: RequestCachePolicy, memoryOnlyTierAvailable: Bool) { self.init(cachePolicy: cachePolicy) }
    var usesMemoryOnlyTier: Bool { false }
}

extension GlobalKVCacheBudget {
    /// The pool argument of the change, ignored here.
    init(
        capFraction: Double?, activationReserveBytes: UInt64?,
        memorySnapshot: @escaping @Sendable () -> MemorySnapshot, memoryOnlyPool: MemoryOnlyCheckpointPool
    ) {
        self.init(capFraction: capFraction, activationReserveBytes: activationReserveBytes, memorySnapshot: memorySnapshot)
    }
}

extension StandaloneServer {
    var memoryPressureMonitor: MemoryPressureMonitor? { nil }
}

extension SSDPrefixCacheStageResult {
    var tier: PrefixCacheTier { .ssd }
}

extension PromptTokenCachePolicy {
    static let ttlEnvironmentKey = "DARKBLOOM_TTFT_PROMPT_CACHE_TTL_SECONDS"
    static func ttl(environment: [String: String] = [:]) -> Duration? { nil }
}

extension PromptPieceTokenStore {
    convenience init(
        capacityBytes: Int, ttl: Duration?, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.init(capacityBytes: capacityBytes)
    }

    var ttl: Duration? { nil }
    func removeExpired() {}
}
