import Foundation

/// One loaded durable store supplies a coherent capability/status snapshot and
/// persists receipt sequences in its epoch ledger. Payload residency is not part
/// of this interface: attention blocks and complete checkpoints share evidence.
protocol DurablePrefixCacheEvidenceSource: AnyObject, Sendable {
    func prefixCacheV2Capability() -> PrefixCacheV2Capability?
    func takeNextPrefixCacheV2Sequence(expectedEpoch: String) -> UInt64?
    func prefixCacheAdvertisement(base: PrefixCacheModelStatus)
        -> (capability: PrefixCacheV2Capability?, status: PrefixCacheModelStatus)
}

extension SSDPrefixCache: DurablePrefixCacheEvidenceSource {}
