import Foundation

/// PURE SCALAR PROTOTYPE, never native admission or proof of fence completion.
/// Its event names describe when a future adapter MAY call it. That adapter
/// must retain actual arrays and use the ORIGINAL ledger, C fences, owner
/// checks and transport completion. No native implementation calls this file.
struct Gemma4MTPConditioningMirrorPlan {
    enum Phase: Equatable {
        case empty, installingInitial, branchLive, retiringBranch, baseReady
        case installingDelta, awaitingSeedACK, poisoned, closed
    }
    enum RetirementDisposition: Equatable {
        case allRootsRetiredV1
        case branchRetiredMirrorRetainedV2
    }
    let envelope: Gemma4MTPDeltaEnvelope
    private(set) var phase: Phase = .empty
    private(set) var installed: Gemma4MTPDeltaSnapshot?
    private(set) var pending: Gemma4MTPDeltaSnapshot?
    private(set) var pendingDescriptor: Gemma4MTPDeltaDescriptor?
    // Required upper bounds, not observations of actual allocated objects.
    private(set) var oldMirrorRootObligations = 0
    private(set) var newStagingRootObligations = 0

    init(envelope: Gemma4MTPDeltaEnvelope) { self.envelope = envelope }

    mutating func beginFullInitialSeed(_ snapshot: Gemma4MTPDeltaSnapshot) throws {
        try require(phase == .empty && snapshot.scopeSHA256 == envelope.scopeSHA256
                    && snapshot.ordinal == 0 && snapshot.frontier == envelope.initialFrontier)
        pending = snapshot; newStagingRootObligations = 9; phase = .installingInitial
    }

    /// Invoke only after original ledger resolution has drained every grant
    /// and verification window. This helper cannot verify those native facts.
    mutating func beginBranchRetirement(_ branch: Gemma4MTPDeltaSnapshot,
                                       outstandingGrants: Int, verificationWindowOpen: Bool) throws {
        try require(phase == .branchLive && branch == installed && pending == nil
                    && outstandingGrants == 0 && !verificationWindowOpen)
        phase = .retiringBranch
    }

    /// The future v2 ACK must explicitly distinguish four retained request KV
    /// roots from retired branch/batch/hidden-chain payload roots. Do not feed
    /// this disposition into v1's all-roots-released ledger claim.
    mutating func recordFencedBranchRetirement(_ branch: Gemma4MTPDeltaSnapshot,
                                               disposition: RetirementDisposition) throws {
        try require(phase == .retiringBranch && branch == installed
                    && disposition == .branchRetiredMirrorRetainedV2)
        phase = .baseReady
    }

    mutating func beginDelta(_ descriptor: Gemma4MTPDeltaDescriptor,
                            committedTargetFrontier: Int) throws -> Gemma4MTPDeltaAllocationPlan {
        try require(phase == .baseReady && pending == nil && descriptor.base == installed
                    && descriptor.next.frontier == committedTargetFrontier)
        do {
            let plan = try Gemma4MTPDeltaAllocationPlan(envelope: envelope, descriptor: descriptor)
            pending = descriptor.next; pendingDescriptor = descriptor
            newStagingRootObligations = 9; phase = .installingDelta
            return plan
        } catch { phase = .poisoned; throw error }
    }

    /// Runtime prerequisite: every receive, concatenation, capture installation,
    /// original C GPU+CPU fence and subsequent owner check has succeeded. Old
    /// mirror and all nine new roots still remain owned through ACK completion.
    mutating func recordInstalledAfterNativeFence(_ snapshot: Gemma4MTPDeltaSnapshot) throws {
        try require((phase == .installingInitial || phase == .installingDelta) && snapshot == pending)
        phase = .awaitingSeedACK
    }

    /// Receiver calls after completed send; sender uses exact matching received
    /// ACK before advancing its base. Lost/failed ACK poisons instead of retrying
    /// against an ambiguous mirror. Hidden then belongs to the new branch.
    mutating func recordExactSeedACKCompleted(_ snapshot: Gemma4MTPDeltaSnapshot) throws {
        try require(phase == .awaitingSeedACK && snapshot == pending)
        installed = snapshot; pending = nil; pendingDescriptor = nil
        oldMirrorRootObligations = 4; newStagingRootObligations = 0
        phase = .branchLive
    }

    mutating func poison() { if phase != .closed { phase = .poisoned } }

    /// No cleanup authority is created here. Only the ORIGINAL owner, after
    /// actual terminal cancellation/finish, successful C fences and checks,
    /// may report this event. A failed fence must leave this state untouched.
    mutating func recordOriginalOwnerCleanupCompleted(scopeSHA256: String) throws {
        try require(phase != .closed && scopeSHA256 == envelope.scopeSHA256)
        installed = nil; pending = nil; pendingDescriptor = nil
        oldMirrorRootObligations = 0; newStagingRootObligations = 0; phase = .closed
    }

    private mutating func require(_ condition: Bool) throws {
        guard condition else {
            if phase != .closed { phase = .poisoned }
            throw Gemma4MTPDeltaError.transition
        }
    }
}
