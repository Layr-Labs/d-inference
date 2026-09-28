import Foundation

/// A joined receipt proves only the two values supplied by the owned transport.
/// Actual process/lease release remains the resident owner's separate obligation.
struct QwenMTPJoinedReceipt {
    let verificationFingerprint: String
    let retainedInputs: Int
    let committedInputs: Int
    let isFinal: Bool
    fileprivate init(_ receipt: QwenTargetVerificationLocalReceipt) {
        verificationFingerprint = receipt.verificationFingerprint
        retainedInputs = receipt.retainedInputs; committedInputs = receipt.committedInputs
        isFinal = receipt.isFinal
    }
}

/// Bounded depth-one control. Provisional staging never advances the existing
/// generation control; only a joined, independently expected prefix can do that.
final class QwenMTPAcceptedRoundControl {
    private var used = Set<UUID>()
    private(set) var roundCount = 0
    private(set) var failed = false
    private(set) var active: QwenTargetVerificationRequest?
    private(set) var committed = 0
    private var staged = 0
    private var reconciled = false
    private var commitAuthorized = false
    private var nextBase: Int?

    func begin(proposal: QwenResidentMTPProposal, generation: QwenLayerStageGenerationControl) throws
        -> QwenTargetVerificationRequest {
        try operation {
            let request = generation.agreement.request
            guard generation.agreement.descriptor.mtpEnabled,
                  generation.agreement.descriptor.mtpPolicySHA256 == QwenMTPAcceptedPolicy.registered9BDepth1Short.fingerprint,
                  active == nil, roundCount < 7, !used.contains(proposal.roundID),
                  (2...8).contains(request.outputCount), request.promptCount <= 32,
                  request.chunkSize <= 16, request.stopTokenIDs.isEmpty,
                  nextBase == nil || nextBase == generation.committedTokens else {
                throw ProbeError("MTP round is reused, skipped or outside the private short scope")
            }
            let value = try QwenTargetVerificationRequest(proposal: proposal, generation: generation)
            used.insert(proposal.roundID); active = value; roundCount += 1
            committed = 0; staged = 0; reconciled = false; commitAuthorized = false
            return value
        }
    }

    func didStage(step: Int) throws {
        try operation {
            guard let active, !reconciled, committed == 0, step == staged,
                  step < active.maximumSteps else { throw ProbeError("MTP staging is out of order") }
            staged += 1
        }
    }

    /// This check runs BEFORE either native prefix commit. In particular, a
    /// staged draft can only commit after its token equals the target-selected
    /// value and the client's continue decision is acknowledged by both ranks.
    func authorizeCommit(generation: QwenLayerStageGenerationControl) throws {
        try operation {
            guard let active, !reconciled, !commitAuthorized, staged == active.maximumSteps,
                  committed < staged, !generation.isFailed, generation.phase == .frame,
                  generation.agreement.fingerprint == active.agreement.fingerprint,
                  generation.committedTokens == active.base + committed,
                  generation.completedFrames == active.descriptor.firstSequence + committed,
                  generation.lastTokenID == (try active.token(step: committed)) else {
                throw ProbeError("MTP prefix lacks actual target-token and continuation agreement")
            }
            commitAuthorized = true
        }
    }

    func joinCommit(_ values: [QwenTargetVerificationLocalReceipt]) throws -> QwenMTPJoinedReceipt {
        try operation {
            guard let active, !reconciled, commitAuthorized, staged == active.maximumSteps, committed < staged else {
                throw ProbeError("MTP prefix commit precedes complete bounded staging")
            }
            let retained = committed + 1
            try require(values, active: active, retained: retained,
                pending: staged - retained, newlyCommitted: 1, final: false)
            committed = retained; commitAuthorized = false
            return .init(values[0])
        }
    }

    func joinReconciliation(_ values: [QwenTargetVerificationLocalReceipt]) throws -> QwenMTPJoinedReceipt {
        try operation {
            guard let active, !reconciled, !commitAuthorized, staged == active.maximumSteps, committed > 0 else {
                throw ProbeError("MTP final reconciliation lacks an already published prefix")
            }
            // Reconciliation discards only the uncommitted suffix. It may not
            // silently commit another input after the publication decision.
            try require(values, active: active, retained: committed,
                pending: 0, newlyCommitted: 0, final: true)
            reconciled = true
            return .init(values[0])
        }
    }

    func finish(generation: QwenLayerStageGenerationControl) throws {
        try operation {
            guard let active, reconciled, !generation.isFailed,
                  generation.agreement.fingerprint == active.agreement.fingerprint,
                  generation.phase == .frame || generation.phase == .retiring,
                  generation.committedTokens == active.base + committed,
                  generation.completedFrames == active.descriptor.firstSequence + committed,
                  generation.selectedTokenCount == generation.committedTokens
                    - active.agreement.request.promptCount + 1 else {
                throw ProbeError("MTP round finalization differs from committed generation progress")
            }
            nextBase = generation.committedTokens; self.active = nil
        }
    }

    private func require(_ values: [QwenTargetVerificationLocalReceipt], active: QwenTargetVerificationRequest,
                         retained: Int, pending: Int, newlyCommitted: Int, final: Bool) throws {
        guard values.count == 2, Set(values.map(\.rank)) == [0, 1] else {
            throw ProbeError("MTP commit requires exactly one receipt from each rank")
        }
        for value in values {
            guard value.verificationFingerprint == active.fingerprint, value.base == active.base,
                  value.stagedInputs == staged, value.retainedInputs == retained,
                  value.committedInputs == active.base + retained, value.pendingInputs == pending,
                  value.newlyCommittedInputs == newlyCommitted, value.isFinal == final else {
                throw ProbeError("MTP peer receipt differs from the expected native prefix")
            }
        }
    }

    func cancel() { failed = true; active = nil }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        do {
            guard !failed else { throw ProbeError("MTP round control is failed") }
            return try body()
        } catch { failed = true; throw error }
    }
}
