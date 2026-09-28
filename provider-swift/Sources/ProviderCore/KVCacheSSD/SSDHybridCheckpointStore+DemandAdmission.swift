import Foundation
import MLXLMCommon

/// Demand-gated complete-checkpoint admission.
///
/// The engine offers every completed prompt for donation through the fixed
/// `CBv2CompletePrefixCache.donate(_:requestID:tokens:cacheSalt:completion:)`
/// contract, which carries no room for coordinator metadata. The bridge
/// therefore registers the coordinator's `cache_repeated_prefix_tokens` hint
/// per receipt ID at submit, and `prepareWriteJob` consults it before charging
/// any write budget (`SSDCheckpointDemand.admitsWrite`).
extension SSDHybridCheckpointStore {
    func registerDonationDemand(_ demand: SSDCheckpointDonationDemand, requestID: CBv2RequestID) {
        guard !isClosed else { return }
        donationDemandHints.register(demand, requestID: requestID)
    }

    func discardDonationDemand(requestID: CBv2RequestID) {
        donationDemandHints.discard(requestID)
    }

    /// Returns the refusal for a NOT yet durable checkpoint, or nil to proceed
    /// to write-budget admission. `localRepeat` is this store's own tag
    /// history verdict (`writeDemand.observe`), recorded before the gate so a
    /// second local sighting qualifies even when the coordinator hint is 0.
    func demandRefusal(requestID: CBv2RequestID?, localRepeat: Bool) -> PrefixCacheDonationOutcome? {
        let demand = donationDemandHints.demand(for: requestID)
        guard SSDCheckpointDemand.admitsWrite(
            demand: demand, localRepeat: localRepeat, minEffectiveTokens: config.minEffectiveTokens)
        else { return .skippedNovel }
        return nil
    }
}
