import Foundation
import MLXLMCommon

/// Demand-gated complete-checkpoint admission.
///
/// The engine offers every completed prompt for donation through the fixed
/// `CBv2CompletePrefixCache.donate(_:requestID:tokens:cacheSalt:completion:)`
/// contract, which carries no room for coordinator metadata. The bridge
/// therefore registers the coordinator's demand hint
/// (`cache_repeated_prefix_tokens`, `cache_first_sight_tokens`) per receipt ID
/// at submit, and `prepareWriteJob` consults it before charging any write
/// budget (`SSDCheckpointDemand.writeClass`).
extension SSDHybridCheckpointStore {
    func registerDonationDemand(_ demand: SSDCheckpointDonationDemand, requestID: CBv2RequestID) {
        guard !isClosed else { return }
        donationDemandHints.register(demand, requestID: requestID)
    }

    func discardDonationDemand(requestID: CBv2RequestID) {
        donationDemandHints.discard(requestID)
    }

    /// Returns the write class of an offered checkpoint, or nil when the
    /// request shows no demand for it (`skipped_novel` unless the checkpoint
    /// is already durable). `localRepeat` is this store's own tag history
    /// verdict (`writeDemand.observe`), recorded before the gate so a second
    /// local sighting qualifies even when the coordinator hint is 0.
    func offeredWriteClass(requestID: CBv2RequestID?, localRepeat: Bool) -> SSDWriteClass? {
        SSDCheckpointDemand.writeClass(
            demand: donationDemandHints.demand(for: requestID), localRepeat: localRepeat,
            restored: restoredCheckpoint(requestID: requestID),
            minEffectiveTokens: config.minEffectiveTokens)
    }

    /// True while the request holds a checkpoint it staged and authenticated
    /// from this store in the current cache epoch. The proof is dropped when
    /// the stage is abandoned, so a request that then recomputes cold does not
    /// count as restored.
    private func restoredCheckpoint(requestID: CBv2RequestID?) -> Bool {
        guard let requestID else { return false }
        let epoch = config.epochStore?.current
        return lock.withLock {
            guard let proof = authenticatedReceipts[requestID] else { return false }
            return proof.epoch == epoch
        }
    }

    /// A speculative write may fill free disk budget but must not displace an
    /// entry. Advisory answer for the publication path, in complete stored
    /// bytes against everything the budget's ledger counts; the writer makes
    /// the binding reservation (`SSDDiskBudget.reserveSpeculative`).
    func hasDiskRoomForSpeculativeWrite(storedBytes: Int) -> Bool {
        diskBudget.hasSpeculativeRoom(bytes: storedBytes, wholeRootKey: wholeRootKey, basis: diskBudgetBasis())
    }

    func diskBudgetBasis() -> SSDDiskBudgetBasis {
        config.diskBudgetBasis?() ?? .fixed(config.diskBudgetBytes())
    }

    func reservationKey(_ tag16: Data) -> String {
        SSDDiskBudget.reservationKey(modelRootKey: modelRootKey, tag16Hex: tag16.hexString)
    }

}
