import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A private, serialized final-rank owner for real assistant history. The
/// default probe makes one unaccepted proposal; accepted rounds opt in explicitly.
/// The outer distributed owner retains the full reservation until this object
/// retires AND the peer is actually retired/fenced. Local cleanup is not that ACK.
final class QwenResidentMTPRequest {
    let resources: QwenResidentMTPRequestResources
    let control: QwenResidentMTPProposalControl
    private let assets: QwenResidentStageWithMTPAssets
    private let session: QwenLayerStageSession
    private let deadlineUptimeNanoseconds: UInt64
    private var assistantState: (any CBv2MTPRequestState)?
    private var pending: QwenLayerStageMTPCommittedFrame?
    private var carry: MLXArray?
    private let acceptedMode: Bool
    private var acceptedProposal: QwenResidentMTPProposal?
    private(set) var isRetired = false
    var committedTargetInputs: Int { session.committedTokens }

    /// Borrowed only by the shared private generation driver. The probe routes
    /// every forward and retirement through this owner while it is active.
    var probeSession: QwenLayerStageSession { session }
    var probeAssistantInputCount: Int? { assistantState?.committedInputCount }
    var probeAssistantRequestReleased: Bool {
        isRetired && assistantState == nil && pending == nil && carry == nil
    }

    init(assets: QwenResidentStageWithMTPAssets, plan: QwenLayerStagePlan,
         agreement: QwenLayerStageGenerationAgreement, capacityLimitBytes: Int,
         deadlineUptimeNanoseconds: UInt64, acceptedMode: Bool = false,
         check: () throws -> Void) throws {
        guard agreement.descriptor.mtpEnabled == acceptedMode else {
            throw ProbeError("MTP owner mode differs from its bound agreement")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now, deadlineUptimeNanoseconds - now <= 300_000_000_000 else {
            throw ProbeError("MTP proposal requires an explicit at-most300s same-Mac deadline")
        }
        func checkDeadline() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                throw ProbeError("MTP proposal preparation exceeded owner deadline")
            }
        }
        let control = try QwenResidentMTPProposalControl(agreement: agreement)
        let prepared = try MLX.withError { nativeError in
            do {
                try nativeError.check(); try checkDeadline(); try check(); try nativeError.check()
                let resources = try QwenResidentMTPRequestResources(assets: assets, plan: plan,
                    agreement: agreement, capacityLimitBytes: capacityLimitBytes)
                try nativeError.check(); try check(); try checkDeadline(); try nativeError.check()
                return resources
            } catch { try nativeError.check(); throw error }
        }
        // The combined reservation/live resource gate precedes both target
        // request-state construction and assistant request-state construction.
        let owned: (QwenLayerStageSession, any CBv2MTPRequestState) = try MLX.withError { nativeError in
            var session: QwenLayerStageSession?
            var state: (any CBv2MTPRequestState)?
            do {
                try checkDeadline(); try prepared.requireLive(); try check(); try checkDeadline(); try nativeError.check()
                let nextSession = try QwenLayerStageSession(stage: assets.target.loaded, plan: plan,
                    generationRequest: agreement.request)
                session = nextSession
                let nextState = assets.assistant.makeRequestState(); state = nextState
                try assets.assistant.configureRequestState(nextState, maximumSequenceLength: agreement.request.maximumTokens)
                guard nextState.committedInputCount == 0, nextState.stagedInputCount == 0, nextState.materializedBytes == 0,
                      assets.assistant.evaluationTargets(for: nextState).isEmpty else {
                    throw ProbeError("MTP request did not start with empty exclusive assistant state")
                }
                try nativeError.check(); try check(); try checkDeadline(); try nativeError.check()
                return (nextSession, nextState)
            } catch {
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                if let state { assets.assistant.releaseRequestState(state) }
                do { try session?.cancel() }
                catch { throw ProbeError("MTP state preparation failed (\(primary)); target cleanup also failed (\(error))") }
                throw primary
            }
        }
        self.acceptedMode = acceptedMode
        self.assets = assets; self.session = owned.0; self.resources = prepared
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        self.control = control; assistantState = owned.1
    }

    /// Called from the consumer's existing boundary callback. This returns the
    /// same target output shape; it does not advance assistant history yet.
    func prefill(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary,
                 check: () throws -> Void) throws -> QwenLayerStageOutput {
        try operation(check: check) { checked in
            guard pending == nil, control.phase == .observing, frame.phase == .prefill,
                  frame.sequence == control.observedFrames, frame.tokenOffset == control.observedInputs,
                  frame == (try control.agreement.request.frame(sequence: control.observedFrames)),
                  tokens == Array(control.agreement.request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset+frame.tokenCount)]) else {
                throw ProbeError("MTP target prefill is duplicated, unacknowledged or out of order")
            }
            let value = try session.prefillChunkCapturingMTP(tokens, offset: frame.tokenOffset,
                final: frame.finalPromptChunk, incoming: incoming, check: checked)
            pending = value.committed
            return value.output
        }
    }

    /// Deliver only after the normal generation control has acknowledged both
    /// ranks for this frame. The selected output token is not a consumed target
    /// input and is never appended here.
    func observeCommitted(generation: QwenLayerStageGenerationControl,
                          check: () throws -> Void) throws {
        try operation(check: check) { checked in
            guard let frame = pending, frame.identity == session.identity, let state = assistantState else {
                throw ProbeError("MTP observation lacks this request's committed final hidden")
            }
            pending = nil
            defer { frame.discard() }
            try control.observe(frame: frame.frame, tokenIDs: frame.tokenIDs, generation: generation)
            let hidden = try frame.takeHidden()
            let tokens = MLXArray(frame.tokenIDs.map(Int32.init)).reshaped([1, frame.tokenIDs.count])
            assets.assistant.observeCommittedTarget(.init(tokens: tokens, hidden: hidden), requestState: state)
            // The assistant normalizes raw target hidden itself exactly once.
            // Fence the normalized backlog now, so it cannot retain a lazy graph
            // across a failed target frame or a later state generation.
            eval(assets.assistant.evaluationTargets(for: state))
            try checked()
            guard state.committedInputCount == control.observedInputs - 1, state.stagedInputCount == 0 else {
                throw ProbeError("MTP cross-chunk trusted history frontier differs")
            }
            carry = hidden[0..., (frame.tokenIDs.count - 1)..<frame.tokenIDs.count, 0...]
            eval(carry!)
            try checked()
        }
    }

    /// The normal target first token and continue decision must already be
    /// acknowledged by both ranks. This performs one real assistant forward,
    /// fences every assistant cache/root, and returns only an unaccepted scalar.
    func propose(generation: QwenLayerStageGenerationControl, roundID: UUID,
                 check: () throws -> Void) throws -> QwenResidentMTPProposal {
        try operation(check: check) { checked in
            guard !acceptedMode, pending == nil, let carry, let state = assistantState,
                  session.committedTokens == control.agreement.request.promptCount else {
                throw ProbeError("MTP proposal requires complete committed target prompt history")
            }
            try control.begin(generation: generation, roundID: roundID)
            guard let seed = control.seedTokenID else { throw ProbeError("MTP proposal seed missing") }
            let result = assets.assistant.draftStep(tokens: MLXArray([Int32(seed)]).reshaped([1, 1]),
                hidden: carry, shortlist: nil, requestState: state)
            eval([result.tokens, result.hidden] + assets.assistant.evaluationTargets(for: state))
            try checked()
            guard result.tokens.shape == [1], result.tokens.dtype == .int32,
                  result.hidden.shape == [1, 1, control.agreement.request.profile.hiddenSize],
                  result.hidden.dtype == assets.target.loaded.activationDType,
                  state.committedInputCount == control.observedInputs, state.stagedInputCount == 0 else {
                throw ProbeError("MTP proposal output or trusted assistant KV frontier differs")
            }
            let tokens = result.tokens.asArray(Int32.self)
            try checked()
            guard tokens.count == 1 else { throw ProbeError("MTP returned more than one proposal") }
            return try control.proposed(Int(tokens[0]))
        }
    }

    /// Probe-only discard cannot authorize target rollback or reuse.
    func discardProposal(check: () throws -> Void) throws {
        try operation(check: check) { checked in
            guard control.phase == .proposed, let state = assistantState else {
                throw ProbeError("No outstanding MTP proposal to discard")
            }
            assets.assistant.discardRound(requestState: state)
            eval(assets.assistant.evaluationTargets(for: state))
            try checked()
            try control.discarded()
        }
    }

    /// Ordinary target execution of the agreed seed. The draft is never an
    /// input in this probe, so this is not a speculative verification transaction.
    func decodeSeedForProbe(_ token: Int, frame: QwenLayerStageFrame,
                            incoming: QwenLayerStageBoundary, check: () throws -> Void) throws -> QwenLayerStageOutput {
        try operation(check: check) { checked in
            guard !acceptedMode, control.phase == .proposed, pending == nil, token == control.seedTokenID,
                  frame.phase == .decode, frame.tokenCount == 1,
                  frame.tokenOffset == control.agreement.request.promptCount,
                  frame == (try control.agreement.request.frame(sequence: control.observedFrames)),
                  session.committedTokens == frame.tokenOffset else {
                throw ProbeError("MTP probe only admits the ordinary first seed decode")
            }
            return try session.decode(token, offset: frame.tokenOffset, incoming: incoming, check: checked)
        }
    }

    /// Release the unaccepted round before the shared driver sends its local
    /// retirement ACK. No assistant finalize/acceptance or draft-input commit.
    func finishProbe(reason: QwenLayerStageGenerationFinishReason, selectedTokenCount: Int,
                     lastTokenID: Int, check: () throws -> Void) throws {
        try operation(check: check) { checked in
            guard !acceptedMode, control.phase == .proposed, reason == .length, selectedTokenCount == 2,
                  session.committedTokens == control.agreement.request.promptCount + 1,
                  let state = assistantState else {
                throw ProbeError("MTP probe cannot finish before two ordinary target tokens")
            }
            assets.assistant.discardRound(requestState: state)
            assets.assistant.releaseRequestState(state)
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard state.materializedBytes == 0, state.committedInputCount == 0, state.stagedInputCount == 0,
                  assets.assistant.evaluationTargets(for: state).isEmpty else {
                throw ProbeError("MTP probe assistant state did not retire")
            }
            assistantState = nil; carry = nil
            try session.finishGeneration(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
            try checked()
            guard session.isClosed, !session.isFailed else { throw ProbeError("MTP probe target failed clean retirement") }
            isRetired = true; control.retired(failed: false)
        }
    }

    /// Reuses the same actual assistant and exclusive request state after each
    /// target-prefix reconciliation. The one-proposal public probe stays closed.
    func proposeAccepted(generation: QwenLayerStageGenerationControl, roundID: UUID,
                         check: () throws -> Void) throws -> QwenResidentMTPProposal {
        try operation(check: check) { checked in
            guard acceptedMode, acceptedProposal == nil, pending == nil,
                  control.phase == .ready, let carry, let state = assistantState,
                  generation.agreement.fingerprint == control.agreement.fingerprint,
                  generation.phase == .frame, !generation.isFailed,
                  generation.committedTokens == session.committedTokens,
                  state.committedInputCount == session.committedTokens - 1,
                  state.stagedInputCount == 0, let seed = generation.lastTokenID,
                  generation.selectedTokenCount == session.committedTokens - control.agreement.request.promptCount + 1 else {
                throw ProbeError("Repeated assistant proposal lacks reconciled committed history")
            }
            let result = assets.assistant.draftStep(tokens: MLXArray([Int32(seed)]).reshaped([1, 1]),
                hidden: carry, shortlist: nil, requestState: state)
            eval([result.tokens, result.hidden] + assets.assistant.evaluationTargets(for: state))
            try checked()
            guard result.tokens.shape == [1], result.tokens.dtype == .int32,
                  result.hidden.shape == [1, 1, control.agreement.request.profile.hiddenSize],
                  result.hidden.dtype == assets.target.loaded.activationDType,
                  state.committedInputCount == session.committedTokens, state.stagedInputCount == 0 else {
                throw ProbeError("Repeated assistant output or input frontier differs")
            }
            let token = Int(result.tokens.item(Int32.self)); try checked()
            guard (0..<control.agreement.request.profile.vocabularySize).contains(token) else {
                throw ProbeError("Assistant draft is outside the target vocabulary")
            }
            let value = QwenResidentMTPProposal(requestID: control.agreement.request.requestID,
                roundID: roundID, agreementFingerprint: control.agreement.fingerprint,
                committedTargetInputs: session.committedTokens, seedTokenID: seed,
                previousTokenChainSHA256: generation.tokenChainSHA256, proposedTokenID: token)
            acceptedProposal = value
            return value
        }
    }

    func finalizeAccepted(request: QwenTargetVerificationRequest, joined: QwenMTPJoinedReceipt,
                          committedHidden: [MLXArray], check: () throws -> Void) throws {
        try operation(check: check) { checked in
            let count = joined.retainedInputs, h = control.agreement.request.profile.hiddenSize
            guard acceptedMode, acceptedProposal == request.proposal, let state = assistantState,
                  joined.isFinal, joined.verificationFingerprint == request.fingerprint,
                  (1...2).contains(count), committedHidden.count == count,
                  joined.committedInputs == request.base + count,
                  session.committedTokens == joined.committedInputs,
                  state.committedInputCount == request.base,
                  committedHidden.allSatisfy({ $0.shape == [1, 1, h] && $0.dtype == assets.target.loaded.activationDType }) else {
                throw ProbeError("Assistant finalization lacks the exact bilateral committed target prefix")
            }
            let draftTokens = MLXArray(count == 2 ? [Int32(request.proposal.proposedTokenID)] : [Int32]()).reshaped([1, count - 1])
            // hidden(seed) conditions the accepted draft; hidden(draft) is the
            // next carry. The assistant applies target final norm exactly once.
            let targetRows = count == 2 ? committedHidden[0] : committedHidden[0][0..., 0..<0, 0...]
            assets.assistant.finalizeRound(requestState: state, confirmedInputTokens: count,
                committedDraftTokens: draftTokens, committedTargetHidden: targetRows)
            carry = committedHidden[count - 1]
            eval(assets.assistant.evaluationTargets(for: state) + [carry!])
            try checked()
            guard state.committedInputCount == session.committedTokens - 1, state.stagedInputCount == 0 else {
                throw ProbeError("Finalized assistant history differs from the next target frontier")
            }
            acceptedProposal = nil
        }
    }

    func finishAccepted(reason: QwenLayerStageGenerationFinishReason, selectedTokenCount: Int,
                        lastTokenID: Int, check: () throws -> Void) throws {
        try operation(check: check) { checked in
            guard acceptedMode, acceptedProposal == nil, pending == nil, let state = assistantState else {
                throw ProbeError("Accepted MTP cannot retire an unreconciled assistant round")
            }
            assets.assistant.releaseRequestState(state)
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard state.materializedBytes == 0, state.committedInputCount == 0,
                  state.stagedInputCount == 0, assets.assistant.evaluationTargets(for: state).isEmpty else {
                throw ProbeError("Accepted MTP assistant state did not retire")
            }
            assistantState = nil; carry = nil
            try session.finishGeneration(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
            try checked()
            guard session.isClosed, !session.isFailed else { throw ProbeError("Accepted MTP target failed retirement") }
            isRetired = true; control.retired(failed: false)
        }
    }

    /// Cleanup deliberately has no expired deadline/resource callback. The
    /// incomplete generation session is cancelled, never labeled a clean finish.
    func retire(failed: Bool = false) throws {
        guard !isRetired else { return }
        var primary: Error?
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { if primary == nil { primary = error } }
        }
        attempt {
            try MLX.withError { nativeError in
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                do { try nativeError.check() } catch { primary = error }
                if let state = assistantState {
                    assets.assistant.discardRound(requestState: state)
                    assets.assistant.releaseRequestState(state)
                    guard state.materializedBytes == 0, state.committedInputCount == 0,
                          state.stagedInputCount == 0, assets.assistant.evaluationTargets(for: state).isEmpty else {
                        throw ProbeError("MTP assistant retained request arrays after release")
                    }
                }
                pending?.discard(); pending = nil; carry = nil; assistantState = nil; acceptedProposal = nil
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
        }
        attempt { try session.cancel() }
        guard primary == nil, session.isClosed, assistantState == nil, pending == nil, carry == nil else {
            control.fail()
            throw primary ?? ProbeError("MTP request local retirement remains incomplete")
        }
        isRetired = true; control.retired(failed: failed || control.failed || session.isFailed)
    }

    private func operation<T>(check: () throws -> Void,
        _ body: (_ checked: () throws -> Void) throws -> T) throws -> T {
        try withoutActuallyEscaping(check) { borrowedCheck in
            try MLX.withError { nativeError in
                func checked() throws {
                    try nativeError.check()
                    guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                        throw ProbeError("MTP proposal owner deadline expired")
                    }
                    try borrowedCheck(); try resources.requireLive(); try nativeError.check()
                    guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                        throw ProbeError("MTP proposal observation exceeded owner deadline")
                    }
                }
                do {
                    guard !isRetired, !control.failed else { throw ProbeError("MTP request is retired or failed") }
                    try checked()
                    return try body(checked)
                } catch {
                    var primary: Error = error
                    do { try nativeError.check() } catch { primary = error }
                    control.fail()
                    do { try retire(failed: true) }
                    catch { throw ProbeError("MTP request failed (\(primary)); local retirement also failed (\(error))") }
                    throw primary
                }
            }
        }
    }
    deinit { try? retire(failed: true) }
}
