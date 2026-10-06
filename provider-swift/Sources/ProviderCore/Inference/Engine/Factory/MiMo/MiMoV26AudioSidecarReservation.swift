import Foundation
import MLXVLM

/// Separate codec-load/lifetime commitment in the existing process ledger.
/// M remains zero: stored/materialized byte counts are not physical coverage.
/// The registered native transaction must retain this owner before loading.
final class MiMoV26AudioSidecarReservation: MiMoV26AudioSidecarLoadReservation, @unchecked Sendable {
    let request: MiMoV26AudioSidecarLoadRequest
    var reservedLoadBytes: UInt64 { request.requiredLoadBytes }
    private let ledger: ProcessMemoryLedger
    private let extraReserve: UInt64
    private let lock = NSLock()
    private var state: ProcessMemoryLedger.OwnerState
    private var revoked = false, retired = false, retainedFault = false

    init(request: MiMoV26AudioSidecarLoadRequest, maximumBytes: UInt64,
         additionalSystemReserveBytes: UInt64, ledger: ProcessMemoryLedger) throws {
        guard request.requiredLoadBytes > 0, request.requiredLoadBytes <= maximumBytes,
              additionalSystemReserveBytes > 0, request.inputTensorCount == 389,
              request.unusedTensorCount == 439, request.inputStoredBytes == 634_204_160,
              request.unusedStoredBytes == 1_238_321_176,
              request.fileBytes == 1_872_618_384,
              request.headerBytes == request.fileBytes - request.inputStoredBytes - request.unusedStoredBytes,
              request.payloadSHA256 == MiMoV26AudioTokenizerWeights.selectedPayloadSHA256 else {
            throw MiMoV26AudioSidecarError.invalidBinding
        }
        self.request = request; self.ledger = ledger; extraReserve = additionalSystemReserveBytes
        ledger.prepareUsageReader()
        state = ledger.createOwner()
        do {
            state = try ledger.replaceCharge(owner: state.owner, expectedRevision: state.revision,
                expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: request.requiredLoadBytes,
                additionalSystemReserveBytes: extraReserve)
        } catch {
            // No native/audio work exists and the real owner is still empty.
            _ = ledger.retire(state.owner)
            throw error
        }
    }

    func validateActive() throws {
        try lock.withLock {
            guard !revoked, !retired, !retainedFault else { throw MiMoV26AudioSidecarError.invalidatedOwner }
            do {
                try ledger.recheckCharge(owner: state.owner, expectedRevision: state.revision,
                    expectedPolicyEpoch: ledger.policySnapshot().epoch,
                    additionalSystemReserveBytes: extraReserve)
            } catch let refusal as ProcessMemoryLedger.Refusal {
                switch refusal {
                case .insufficientCapacity, .stalePolicy:
                    throw MiMoV26MultimodalError.reservationRejected
                default: throw refusal
                }
            }
        }
    }

    /// Neither cancellation nor a construction fault refunds this charge.
    func revoke() { lock.withLock { revoked = true } }
    func markRetainedFault() { lock.withLock { revoked = true; retainedFault = true } }

    /// ROOT-ONLY retirement call after the existing real SDK/bridge proof and
    /// all known codec/processor/container aliases have been detached. Never
    /// call this from deinit, cancellation or a speculative successful retry.
    func retireAfterNativeAliasesReleased() throws {
        try lock.withLock {
            if retired { return } // This exact owner already settled successfully.
            guard !retainedFault else { throw MiMoV26AudioSidecarError.invalidatedOwner }
            state = try ledger.replaceCharge(owner: state.owner, expectedRevision: state.revision,
                expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: 0)
            guard ledger.retire(state.owner) == .retired else { throw MiMoV26AudioSidecarError.invalidBinding }
            retired = true; revoked = true
        }
    }

    var chargedBytesForTesting: UInt64 { lock.withLock { state.chargedBytes } }
    var materializedCoverageForTesting: UInt64 { lock.withLock { state.materializedBytes } }
}
