import Foundation

/// Synchronous host-side boundaries in the existing throwing request owners.
/// No event independently measures GPU kernels; evaluationEnd follows the
/// owner's existing post-eval error/deadline check, so that interval includes it.
enum CBv2OwnerPhase: String, CaseIterable, Sendable {
    case graphConstructionBegin = "graphConstruction.begin"
    case graphConstructionEnd = "graphConstruction.end"
    case rootStagingBegin = "rootStaging.begin"
    case rootStagingEnd = "rootStaging.end"
    case evaluationBegin = "evaluation.begin"
    case evaluationEnd = "evaluation.end"
    case validationCommitBegin = "validationCommit.begin"
    case validationCommitEnd = "validationCommit.end"
}

/// CPU scalars only. The caller binds request/role/selected frame separately.
/// committedTokens is the owner's current committed frontier: only the last
/// marker follows advancement. It is not a proof that the outer frame returned.
struct CBv2OwnerPhaseObservation: Equatable, Sendable {
    let phase: CBv2OwnerPhase
    let tokenCount: Int
    let committedTokens: Int

    /// Called only inside an `if let observer` block. Successful observations
    /// introduce no extra check; a throwing observer must not mask a native or
    /// deadline error already pending in the owner's original check closure.
    func deliver(to observer: CBv2OwnerPhaseObserver,
                 check: () throws -> Void) throws {
        do {
            try observer(self)
        } catch {
            let observationError = error
            try check()
            throw observationError
        }
    }
}

/// Observer contract: synchronous CPU-only recording. It must not call back
/// into the owner, mutate model/state, perform native work or retain tensors.
/// Caller publication remains gated on the complete outer request succeeding.
typealias CBv2OwnerPhaseObserver = (CBv2OwnerPhaseObservation) throws -> Void
