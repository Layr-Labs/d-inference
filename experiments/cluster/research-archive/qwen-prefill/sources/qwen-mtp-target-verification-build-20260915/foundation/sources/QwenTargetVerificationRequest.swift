import Foundation

/// Private local transaction identity, not a new MTP-enabled wire agreement.
/// A future owner must bind an accepted-prefix decision to this fingerprint and
/// obtain matching actual reconciliation receipts from both ranks.
struct QwenTargetVerificationRequest {
    struct Descriptor: Encodable {
        let schema = "qwen_target_verification_v1"
        let proposal: QwenResidentMTPProposal
        let firstSequence: Int
        let maximumSteps: Int
    }
    let agreement: QwenLayerStageGenerationAgreement
    let descriptor: Descriptor
    let fingerprint: String
    var proposal: QwenResidentMTPProposal { descriptor.proposal }
    var base: Int { proposal.committedTargetInputs }
    var maximumSteps: Int { descriptor.maximumSteps }

    init(proposal: QwenResidentMTPProposal, generation: QwenLayerStageGenerationControl) throws {
        let agreement = generation.agreement, request = agreement.request
        guard agreement.prefillPolicy == .serial, !generation.isFailed, generation.phase == .frame,
              proposal.requestID == request.requestID, proposal.agreementFingerprint == agreement.fingerprint,
              proposal.draftDepth == 1, !proposal.accepted,
              proposal.committedTargetInputs == generation.committedTokens,
              generation.committedTokens >= request.promptCount,
              generation.selectedTokenCount == generation.committedTokens - request.promptCount + 1,
              generation.lastTokenID == proposal.seedTokenID,
              generation.tokenChainSHA256 == proposal.previousTokenChainSHA256,
              !request.stopTokenIDs.contains(proposal.seedTokenID),
              [proposal.seedTokenID, proposal.proposedTokenID].allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
            throw ProbeError("Target verification proposal differs from the continued committed token chain")
        }
        let remaining = request.forwardCount - generation.completedFrames
        guard remaining > 0 else { throw ProbeError("Target verification has no remaining target input") }
        self.agreement = agreement
        descriptor = .init(proposal: proposal, firstSequence: generation.completedFrames, maximumSteps: min(2, remaining))
        fingerprint = try qwenGenerationFingerprint("target-verification", descriptor)
        for step in 0..<maximumSteps { _ = try frame(step: step) }
    }

    func frame(step: Int) throws -> QwenLayerStageFrame {
        guard (0..<maximumSteps).contains(step) else { throw ProbeError("Target verification step exceeds remaining output capacity") }
        let frame = try agreement.request.frame(sequence: descriptor.firstSequence + step)
        guard frame.phase == .decode, frame.tokenCount == 1, frame.tokenOffset == base + step else {
            throw ProbeError("Target verification is not a contiguous decode input")
        }
        return frame
    }
    func token(step: Int) throws -> Int {
        _ = try frame(step: step)
        return step == 0 ? proposal.seedTokenID : proposal.proposedTokenID
    }

    func reconciledSchedule(_ original: QwenLayerStageAdmittedSchedule, staged: Int,
                            keeping count: Int, alreadyCommitted: Int = 0) throws -> QwenLayerStageAdmittedSchedule {
        guard (0...maximumSteps).contains(staged), (0...staged).contains(alreadyCommitted),
              (alreadyCommitted...staged).contains(count),
              original.committedTokens == base + alreadyCommitted,
              original.nextSequence == descriptor.firstSequence + alreadyCommitted else {
            throw ProbeError("Target verification schedule or retained prefix differs")
        }
        var next = original
        for step in alreadyCommitted..<count { try next.commit(frame(step: step)) }
        return next
    }
}

/// LOCAL commit evidence only. It neither advances the bilateral generation
/// control nor authorizes token publication or assistant history finalization.
struct QwenTargetVerificationLocalReceipt: Encodable, Equatable {
    let verificationFingerprint: String
    let rank: Int
    let base: Int
    let stagedInputs: Int
    let retainedInputs: Int
    let committedInputs: Int
    let pendingInputs: Int
    let newlyCommittedInputs: Int
    let isFinal: Bool
}
