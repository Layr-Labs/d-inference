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

    /// Snapshot demand once for admission and queued writer priority.
    /// `localRepeat` is this store's own exact tag
    /// history verdict (`writeDemand.observe`), recorded before the gate so a
    /// second local sighting qualifies even when the coordinator hint is 0.
    func donationWritePolicy(requestID: CBv2RequestID?, localRepeat: Bool, checkpointPosition: Int)
        -> (refusal: PrefixCacheDonationOutcome?, repeated: Bool) {
        let demand = donationDemandHints.demand(for: requestID)
        let admitted = SSDCheckpointDemand.admitsWrite(
            demand: demand, localRepeat: localRepeat, minEffectiveTokens: config.minEffectiveTokens)
        // A fleet repeat of the preamble admits donation, but only endpoints
        // covered by that repeat may spend the reserved repeat share. A longer
        // unique extension retains novel priority. Missing/retired hints do
        // not manufacture fleet repetition; local exact-tag history remains.
        let repeated = localRepeat || (checkpointPosition > 0
            && (demand?.repeatedPrefixTokens ?? 0) >= checkpointPosition)
        return (admitted ? nil : .skippedNovel, repeated)
    }
}
