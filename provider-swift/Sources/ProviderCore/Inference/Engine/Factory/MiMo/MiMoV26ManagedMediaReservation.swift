import Foundation
import MLXVLM

/// One actual charge in the SAME process ledger as the serving slot. This is
/// preparation/features only; target KV is reserved by the unchanged bridge.
/// Never refunds in deinit, from cancellation, a count, or a late retry fence.
final class MiMoV26ManagedMediaReservation: MiMoV26MediaWorkReservation, @unchecked Sendable {
    /// Supplied only by TX after its exact issued audio contract and serialized
    /// installed-owner check. This metadata is not an SDK capability issuer.
    struct AudioBinding: Sendable {
        let receipt: MiMoV26AudioSidecarLoadReceipt
        let reservation: MiMoV26AudioSidecarReservation
        func validate() throws {
            guard reservation.request == receipt.request,
                  receipt.sourceIdentity == receipt.request.payloadSHA256 else {
                throw MiMoV26MultimodalError.incompatibleOwner
            }
            try reservation.validateActive()
        }
    }
    let id = UUID()
    private var planBinding: (digest: String, owner: UUID)?
    private var audioBinding: AudioBinding?
    private let ledger: ProcessMemoryLedger
    private let lock = NSLock()
    private var state: ProcessMemoryLedger.OwnerState
    private let additionalSystemReserveBytes: UInt64
    private let maximumBytes: UInt64
    private var retired = false
    private var failed: [MiMoV26FailedMediaWork] = []
    private var nativeBytes: UInt64 = 0
    private var hostBytes: UInt64 = 0
    private var nativeCompleted = false
    private var hostCompleted = true
    private var encodedOwners: [AnyObject] = []

    convenience init(plan: MiMoV26MultimodalPlan, bytes: Int, maximumBytes: UInt64,
         additionalSystemReserveBytes: UInt64, ledger: ProcessMemoryLedger,
         audioBinding: AudioBinding? = nil) throws {
        guard bytes > 0, let amount = UInt64(exactly: bytes), amount <= maximumBytes,
              additionalSystemReserveBytes > 0, plan.audioPlan == nil || audioBinding != nil else {
            throw MiMoV26MultimodalError.reservationRejected
        }
        try audioBinding?.validate()
        try self.init(initialBytes:amount, hostBytes:0, maximumBytes:maximumBytes,
            additionalSystemReserveBytes:additionalSystemReserveBytes, ledger:ledger)
        planBinding = (plan.preparationSHA256,plan.loadedOwnerIdentity)
        self.audioBinding = audioBinding
        nativeBytes = amount
    }
    /// The SAME real owner is later adopted by the native feature plan. Host
    /// bytes cover only engine-owned encoded/normalized buffers, not caller
    /// copies, already-accounted transport state or target KV.
    init(initialBytes: UInt64, hostBytes: UInt64, maximumBytes: UInt64,
         additionalSystemReserveBytes: UInt64, ledger: ProcessMemoryLedger) throws {
        guard initialBytes > 0, hostBytes <= initialBytes, initialBytes <= maximumBytes,
              additionalSystemReserveBytes > 0 else { throw MiMoV26MultimodalError.reservationRejected }
        self.ledger = ledger; self.additionalSystemReserveBytes = additionalSystemReserveBytes
        self.maximumBytes = maximumBytes
        self.hostBytes = hostBytes; hostCompleted = hostBytes == 0
        // Real reader is initialized before any reservation/transaction lock.
        ledger.prepareUsageReader()
        state = ledger.createOwner()
        do {
            state = try ledger.replaceCharge(owner: state.owner, expectedRevision: state.revision,
                expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: initialBytes,
                additionalSystemReserveBytes: additionalSystemReserveBytes)
        } catch {
            _ = ledger.retire(state.owner) // exact cold, zero-charge owner only
            if let refusal = error as? ProcessMemoryLedger.Refusal {
                switch refusal {
                case .insufficientCapacity, .stalePolicy:
                    throw MiMoV26MultimodalError.reservationRejected
                default: break
                }
            }
            throw error
        }
    }
    func retainEncodedOwner(_ owner: AnyObject) throws {
        try lock.withLock {
            guard !retired, !hostCompleted, planBinding == nil, failed.isEmpty else {
                throw MiMoV26MultimodalError.invalidatedOwner
            }
            encodedOwners.append(owner)
        }
    }
    func reserveDecodeWorkingBytes(_ bytes: UInt64) throws {
        try lock.withLock {
            guard !retired, !hostCompleted, planBinding == nil, failed.isEmpty,
                  bytes >= hostBytes, bytes <= maximumBytes else {
                throw MiMoV26MultimodalError.reservationRejected
            }
            do {
                state = try ledger.replaceCharge(owner:state.owner,expectedRevision:state.revision,
                    expectedPolicyEpoch:ledger.policySnapshot().epoch,chargedBytes:bytes,
                    additionalSystemReserveBytes:additionalSystemReserveBytes)
            } catch let refusal as ProcessMemoryLedger.Refusal {
                switch refusal {
                case .insufficientCapacity, .stalePolicy:
                    throw MiMoV26MultimodalError.reservationRejected
                default: throw refusal
                }
            }
        }
    }
    /// Called from the real native authorize callback after actual codec
    /// completion. This is replacement of one charge, not a second admission.
    func adoptNativePlan(_ plan: MiMoV26MultimodalPlan, bytes: Int,
                         audioBinding: AudioBinding? = nil) throws {
        try audioBinding?.validate()
        try lock.withLock {
            guard !retired, !nativeCompleted, !hostCompleted, planBinding == nil,
                  failed.isEmpty, plan.audioPlan == nil || audioBinding != nil, bytes > 0,
                  let amount = UInt64(exactly:bytes) else { throw MiMoV26MultimodalError.incompatiblePlan }
            let (total,overflow) = amount.addingReportingOverflow(hostBytes)
            guard !overflow, total <= maximumBytes else { throw MiMoV26MultimodalError.reservationRejected }
            do {
                state = try ledger.replaceCharge(owner:state.owner,expectedRevision:state.revision,
                    expectedPolicyEpoch:ledger.policySnapshot().epoch,chargedBytes:total,
                    additionalSystemReserveBytes:additionalSystemReserveBytes)
            } catch let refusal as ProcessMemoryLedger.Refusal {
                switch refusal {
                case .insufficientCapacity, .stalePolicy:
                    throw MiMoV26MultimodalError.reservationRejected
                default: throw refusal
                }
            }
            planBinding = (plan.preparationSHA256,plan.loadedOwnerIdentity)
            self.audioBinding = audioBinding
            nativeBytes = amount
        }
    }
    func validate(plan: MiMoV26MultimodalPlan) throws {
        try lock.withLock {
            guard plan.preparationSHA256 == planBinding?.digest,
                  plan.loadedOwnerIdentity == planBinding?.owner,
                  plan.audioPlan == nil || audioBinding != nil else {
                throw MiMoV26MultimodalError.incompatiblePlan
            }
            guard !retired, !nativeCompleted, failed.isEmpty else { throw MiMoV26MultimodalError.invalidatedOwner }
            try audioBinding?.validate()
            do {
                try ledger.recheckCharge(owner: state.owner, expectedRevision: state.revision,
                    expectedPolicyEpoch: ledger.policySnapshot().epoch,
                    additionalSystemReserveBytes: additionalSystemReserveBytes)
            } catch let refusal as ProcessMemoryLedger.Refusal {
                switch refusal {
                case .insufficientCapacity, .stalePolicy:
                    throw MiMoV26MultimodalError.reservationRejected
                default: throw refusal
                }
            }
        }
    }
    func retainAfterFailedDrain(_ work: MiMoV26FailedMediaWork) {
        lock.withLock { if !failed.contains(where: { $0 === work }) { failed.append(work) } }
    }
    /// Only the SDK's actual prepared/request retirement calls this. All
    /// represented arrays are already detached. M remains zero: a commitment
    /// is not measured coverage and allocator deltas are never used as credit.
    func retireAfterNativeCompletion() throws {
        try lock.withLock {
            guard !retired, !nativeCompleted, planBinding != nil, failed.isEmpty else {
                throw MiMoV26MultimodalError.invalidatedOwner
            }
            nativeCompleted = true
            try settleLocked()
        }
    }
    /// No model work was adopted. Keep the decode promise through the actual
    /// task tail; caller cancellation/this method alone does NOT refund it.
    func abortBeforeNativeAdoption() {
        lock.withLock { if planBinding == nil { nativeCompleted = true } }
    }
    /// Only the existing lease's post-Task-join action invokes this.
    func completeHostOwnership() throws {
        try lock.withLock {
            guard !retired, !hostCompleted, failed.isEmpty else {
                throw MiMoV26MultimodalError.invalidatedOwner
            }
            encodedOwners.removeAll()
            hostCompleted = true
            try settleLocked()
        }
    }
    private func settleLocked() throws {
        guard planBinding != nil || (nativeCompleted && hostCompleted) else { return }
        let remaining = (nativeCompleted ? 0 : nativeBytes) + (hostCompleted ? 0 : hostBytes)
        state = try ledger.replaceCharge(owner:state.owner,expectedRevision:state.revision,
            expectedPolicyEpoch:ledger.policySnapshot().epoch,chargedBytes:remaining)
        if remaining == 0 {
            guard ledger.retire(state.owner) == .retired else { throw MiMoV26MultimodalError.reservationRejected }
            retired = true
        }
    }
    /// Only cold admission failure before any decoder/SDK call may use this
    /// path (e.g. completion-action registration refused before allocation).
    func disposeUnstartedEncodedPromise() throws {
        try lock.withLock {
            guard planBinding == nil, encodedOwners.isEmpty, failed.isEmpty, !retired else {
                throw MiMoV26MultimodalError.invalidatedOwner
            }
            nativeCompleted = true; hostCompleted = true
            try settleLocked()
        }
    }
    var isFullyRetired: Bool { lock.withLock { retired } }
    var chargedBytesForTesting: UInt64 { lock.withLock { state.chargedBytes } }
}
