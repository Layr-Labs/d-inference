import Foundation

/// A proposal is never a committed output. Verification must retain both target
/// ranks' rollback state before consuming it; this increment does not do that.
struct QwenResidentMTPProposal: Equatable, Encodable {
    let requestID: UUID
    let roundID: UUID
    let agreementFingerprint: String
    let committedTargetInputs: Int
    let seedTokenID: Int
    let previousTokenChainSHA256: String
    let proposedTokenID: Int
    let draftDepth = 1
    let accepted = false
}

/// Single-proposal lifecycle over already validated generation-control events.
/// The caller must deliver actual native/peer acknowledgements to that control;
/// neither this object nor a scalar descriptor proves distributed execution.
final class QwenResidentMTPProposalControl {
    enum Phase { case observing, ready, proposing, proposed, discarded, retired }
    let agreement: QwenLayerStageGenerationAgreement
    private(set) var phase: Phase = .observing
    private(set) var failed = false
    private(set) var observedInputs = 0
    private(set) var observedFrames = 0
    private var seed: (roundID: UUID, token: Int, chain: String)?

    init(agreement: QwenLayerStageGenerationAgreement) throws {
        guard agreement.prefillPolicy == .serial, agreement.request.outputCount >= 2 else {
            throw ProbeError("Single MTP proposal requires serial prefill and room for a target-verified next token")
        }
        self.agreement = agreement
    }

    func observe(frame: QwenLayerStageFrame, tokenIDs: [Int], generation: QwenLayerStageGenerationControl) throws {
        try operation {
            let request = agreement.request
            guard phase == .observing, frame.phase == .prefill, frame.sequence == observedFrames,
                  frame.tokenOffset == observedInputs, frame == (try request.frame(sequence: observedFrames)),
                  tokenIDs == Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)]),
                  generation.agreement.fingerprint == agreement.fingerprint, !generation.isFailed,
                  generation.committedTokens == frame.tokenOffset + frame.tokenCount,
                  generation.completedFrames == frame.sequence + 1,
                  generation.phase == (frame.finalPromptChunk ? .token : .frame) else {
                throw ProbeError("MTP history requires exact prompt rows after both native frame commits")
            }
            observedInputs += frame.tokenCount; observedFrames += 1
            if observedInputs == request.promptCount { phase = .ready }
        }
    }

    func begin(generation: QwenLayerStageGenerationControl, roundID: UUID) throws {
        try operation {
            guard phase == .ready, generation.agreement.fingerprint == agreement.fingerprint,
                  !generation.isFailed, generation.phase == .frame,
                  generation.committedTokens == observedInputs, observedInputs == agreement.request.promptCount,
                  generation.selectedTokenCount == 1, let token = generation.lastTokenID,
                  !agreement.request.stopTokenIDs.contains(token) else {
                throw ProbeError("MTP proposal requires an agreed, continued first target token")
            }
            seed = (roundID, token, generation.tokenChainSHA256); phase = .proposing
        }
    }

    var seedTokenID: Int? { seed?.token }

    func proposed(_ token: Int) throws -> QwenResidentMTPProposal {
        try operation {
            guard phase == .proposing, let seed, (0..<agreement.request.profile.vocabularySize).contains(token) else {
                throw ProbeError("MTP proposal is out of order or outside target vocabulary")
            }
            phase = .proposed
            return .init(requestID: agreement.request.requestID, roundID: seed.roundID,
                agreementFingerprint: agreement.fingerprint, committedTargetInputs: observedInputs,
                seedTokenID: seed.token, previousTokenChainSHA256: seed.chain, proposedTokenID: token)
        }
    }

    /// Discard is terminal for this one-proposal object. It does not permit a
    /// retry that would append the already restored trusted seed a second time.
    func discarded() throws {
        try operation {
            guard phase == .proposed else { throw ProbeError("MTP discard requires one outstanding proposal") }
            phase = .discarded
        }
    }
    func fail() { failed = true }
    func retired(failed: Bool) { self.failed = self.failed || failed; seed = nil; phase = .retired }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        do {
            guard !failed, phase != .retired else { throw ProbeError("MTP proposal owner is failed or retired") }
            return try body()
        } catch { failed = true; throw error }
    }
}
