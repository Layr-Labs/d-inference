import Foundation
import MLX
import MLXLMCommon

/// Benchmark-only observation wrapper around the engine's reference prefix
/// cache. It does not alter lookup, donation, pinning, or eviction semantics.
/// Correlation is keyed by CBv2's request receipt id, so concurrent identical
/// prompts remain independently measurable.
final class QwenPrefixTrackingCache: CBv2PrefixCache, @unchecked Sendable {
    struct DonationObservation: Sendable {
        let publishedAtNs: UInt64
        let cacheBytesAfterPublish: Int
    }

    private let cache: PrefixCacheV2
    private let lock = NSLock()
    private var lookupBytesByRequest: [CBv2RequestID: Int] = [:]
    private var donationsByRequest: [CBv2RequestID: DonationObservation] = [:]

    init(config: CBv2PrefixCacheConfig) {
        cache = PrefixCacheV2(config: config)
    }

    var bytesInUse: Int { cache.bytesInUse }

    func stats() -> CBv2PrefixCacheStats {
        cache.stats()
    }

    func lookup(
        tokens: [Int],
        layerKinds: [CBv2LayerKind]
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        cache.lookup(tokens: tokens, layerKinds: layerKinds)
    }

    func lookup(
        tokens: [Int],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        cache.lookup(tokens: tokens, layerKinds: layerKinds, cacheSalt: cacheSalt)
    }

    func lookup(
        requestID: CBv2RequestID,
        tokens: [Int],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) -> (matched: Int, prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?])? {
        let hit = cache.lookup(
            tokens: tokens,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt)
        let bytes = hit.map { stateBytes($0.prefix) } ?? 0
        lock.withLock { lookupBytesByRequest[requestID] = bytes }
        return hit
    }

    func donate(
        tokens: [Int],
        state: [CBv2SequenceKV?],
        layerKinds: [CBv2LayerKind]
    ) {
        cache.donate(tokens: tokens, state: state, layerKinds: layerKinds)
    }

    func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind]
    ) {
        cache.donate(tokens: tokens, snapshots: snapshots, layerKinds: layerKinds)
    }

    func donate(
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) {
        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt)
    }

    func donate(
        requestID: CBv2RequestID,
        tokens: [Int],
        snapshots: [(keys: MLXArray, values: MLXArray, offset: Int)?],
        layerKinds: [CBv2LayerKind],
        cacheSalt: String?
    ) {
        cache.donate(
            tokens: tokens,
            snapshots: snapshots,
            layerKinds: layerKinds,
            cacheSalt: cacheSalt)
        let bytesAfterPublish = cache.bytesInUse
        // PrefixCacheV2 deliberately returns Void for an unusable donation
        // (short state, no cacheable layers, or invalid geometry). Observing
        // the callback alone is therefore not evidence that a reusable entry
        // became ready. The construction phase starts from an empty cache, so
        // positive resident bytes are the publication proof it reports.
        guard bytesAfterPublish > 0 else { return }
        let observation = DonationObservation(
            publishedAtNs: DispatchTime.now().uptimeNanoseconds,
            cacheBytesAfterPublish: bytesAfterPublish)
        lock.withLock {
            if donationsByRequest[requestID] == nil {
                donationsByRequest[requestID] = observation
            }
        }
    }

    func endAdoption(tokens: [Int], matched: Int) {
        cache.endAdoption(tokens: tokens, matched: matched)
    }

    func endAdoption(tokens: [Int], matched: Int, cacheSalt: String?) {
        cache.endAdoption(tokens: tokens, matched: matched, cacheSalt: cacheSalt)
    }

    func endAdoption(
        requestID: CBv2RequestID,
        tokens: [Int],
        matched: Int,
        cacheSalt: String?
    ) {
        cache.endAdoption(
            tokens: tokens,
            matched: matched,
            cacheSalt: cacheSalt)
    }

    func evict(toFit byteBudget: Int) {
        cache.evict(toFit: byteBudget)
    }

    func lookupStateBytes(for requestID: CBv2RequestID) -> Int {
        lock.withLock { lookupBytesByRequest[requestID] ?? 0 }
    }

    func donation(for requestID: CBv2RequestID) -> DonationObservation? {
        lock.withLock { donationsByRequest[requestID] }
    }

    func waitForDonation(
        requestID: CBv2RequestID,
        timeout: Duration
    ) async -> DonationObservation? {
        if let observation = donation(for: requestID) { return observation }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if let observation = donation(for: requestID) { return observation }
        }
        return donation(for: requestID)
    }

    /// Await every donation that should follow a measured terminal before
    /// eviction. Rows whose cache outcome proves no donation can occur are not
    /// passed here by the orchestrator.
    func waitForDonations(
        requestIDs: [CBv2RequestID],
        timeout: Duration
    ) async {
        guard !requestIDs.isEmpty else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let complete = lock.withLock {
                requestIDs.allSatisfy { donationsByRequest[$0] != nil }
            }
            if complete { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func stateBytes(
        _ prefix: [(keys: MLXArray, values: MLXArray, offset: Int)?]
    ) -> Int {
        prefix.reduce(0) { total, entry in
            guard let entry else { return total }
            let (entryBytes, entryOverflow) = entry.keys.nbytes.addingReportingOverflow(
                entry.values.nbytes)
            let (sum, sumOverflow) = total.addingReportingOverflow(entryBytes)
            return entryOverflow || sumOverflow ? Int.max : sum
        }
    }
}
