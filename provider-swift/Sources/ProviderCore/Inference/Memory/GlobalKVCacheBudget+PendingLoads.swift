import Foundation

/// Identifies one accepted load generation. Model/request strings are only
/// correlation metadata; delayed cleanup cannot close a successor with that ID.
struct PendingModelLoadLease: Sendable {
    let owner: ProcessMemoryLedger.Owner
}

extension GlobalKVCacheBudget {
    struct PendingLoadRecord: Sendable {
        let requestID: String
        let minimumKVBytes: UInt64
        let createdAt: ContinuousClock.Instant
        var state: ProcessMemoryLedger.OwnerState
    }

    /// Atomic final ownership claim over padded target+assistant weight bytes
    /// and one-request setup headroom. Activation is already in ledger policy.
    /// The additional OS reserve preserves the stricter existing LOAD policy at
    /// admission/recheck; normal runtime KV admissions keep their own formula.
    func claimPendingLoad(
        requestID: String, weightBytes: UInt64,
        minimumKVBytes: UInt64 = UnifiedMemoryCap.minimumLoadKVBytes
    ) -> PendingModelLoadLease? {
        guard weightBytes > 0, !reservationExists(requestID) else { return nil }
        let (chargedBytes, overflow) = weightBytes.addingReportingOverflow(minimumKVBytes)
        guard !overflow else { return nil }
        let owner = processLedger.createOwner()
        do {
            let accepted = try processLedger.replaceCharge(
                owner: owner.owner, expectedRevision: owner.revision,
                expectedPolicyEpoch: processLedger.policySnapshot().epoch,
                chargedBytes: chargedBytes, additionalSystemReserveBytes: loadReserveBytes)
            pendingLoads[owner.owner] = PendingLoadRecord(
                requestID: requestID, minimumKVBytes: minimumKVBytes,
                createdAt: reservationClockNow(), state: accepted)
            pendingLoadIDs[requestID] = owner.owner
        } catch {
            _ = processLedger.retire(owner.owner)
            recordReservationRefusal(bytes: chargedBytes)
            return nil
        }
        recordReservationProgress()
        return PendingModelLoadLease(owner: owner.owner)
    }

    /// Hashing/hooks may suspend after the initial permit. Always inspect the
    /// current policy and coherent usage, even though this owner's C is unchanged.
    func recheckPendingLoad(_ lease: PendingModelLoadLease) -> Bool {
        guard let current = pendingLoads[lease.owner] else { return false }
        do {
            try processLedger.recheckCharge(
                owner: lease.owner, expectedRevision: current.state.revision,
                expectedPolicyEpoch: processLedger.policySnapshot().epoch,
                additionalSystemReserveBytes: loadReserveBytes)
            return true
        } catch {
            recordReservationRefusal(bytes: current.state.chargedBytes)
            return false
        }
    }

    /// A completed weight phase is now accounted by ordinary MLX usage. Retain
    /// only future weight phases and the temporary setup allowance. There is no
    /// inferred materialization credit from concurrent process memory deltas.
    @discardableResult
    func reducePendingLoad(
        _ lease: PendingModelLoadLease, remainingWeightBytes: UInt64
    ) -> Bool {
        guard var current = pendingLoads[lease.owner] else { return false }
        let (nextCharge, overflow) = remainingWeightBytes.addingReportingOverflow(current.minimumKVBytes)
        guard !overflow, nextCharge <= current.state.chargedBytes else { return false }
        if nextCharge == 0 { return finishPendingLoad(lease) }
        do {
            current.state = try processLedger.replaceCharge(
                owner: lease.owner, expectedRevision: current.state.revision,
                expectedPolicyEpoch: 0, chargedBytes: nextCharge)
        } catch { return false }
        pendingLoads[lease.owner] = current
        recordReservationProgress()
        return true
    }

    /// Called only after pending phase resources retire or become reflected in
    /// ordinary MLX usage. Zero and duplicate closes cannot release another load.
    @discardableResult
    func finishPendingLoad(_ lease: PendingModelLoadLease) -> Bool {
        guard let current = pendingLoads[lease.owner] else { return false }
        do {
            _ = try processLedger.replaceCharge(
                owner: lease.owner, expectedRevision: current.state.revision,
                expectedPolicyEpoch: 0, chargedBytes: 0)
        } catch { return false }
        _ = processLedger.retire(lease.owner)
        pendingLoads.removeValue(forKey: lease.owner)
        if pendingLoadIDs[current.requestID] == lease.owner {
            pendingLoadIDs.removeValue(forKey: current.requestID)
        }
        recordReservationProgress()
        return true
    }
}
