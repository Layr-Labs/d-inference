import Foundation
import MLX

/// One regular, single-request pipeline on exclusively owned, admitted stages.
/// The owner supplies live resource/deadline/cancellation checks and retains this
/// driver and its resident until completion or an explicit peer fence. No load,
/// context/workspace admission or worker capability is implied by this driver.
final class GLM5NextPipelineGeneration {
    let session: GLM5NextStageSession
    let control: QwenLayerStageGenerationControl
    let transport: QwenLayerStageGenerationTransport
    private let operation = NSLock()
    private var started = false
    private var retiredRanks = Set<Int>()
    /// The session drops its local reference after checked stream drains. Keep
    /// this request's feature/tower owner until both ranks retire or are fenced,
    /// including an exchange failure after the local session has closed.
    private var retiringImageFeatures: GLM5NextStageImageFeatures?

    init(session: GLM5NextStageSession, collective: Collective, batchSize: Int = 1) throws {
        try Self.requireSupported(session.agreement, batchSize: batchSize)
        guard collective.size == 2, collective.rank == session.identity.stageIndex,
              !session.isClosed, !session.isFailed,
              session.committedTokens == session.agreement.request.reusedPrefixTokens else {
            throw ProbeError("GLM pipeline requires a fresh session on its bound rank")
        }
        let request = session.agreement.request
        let boundaryBytes = try QwenLongPrefillCheckedBytes.product([
            min(request.chunkSize, request.promptCount), request.profile.boundaryElementsPerToken,
            qwenStageWireElementBytes(request.profile.activationDType),
        ])
        guard boundaryBytes <= CollectivePointToPointShape.hardByteLimit || collective.dataPlaneStatus?.active == true else {
            throw ProbeError("Large GLM prefill requires an established authenticated chunked data plane")
        }
        self.session = session
        control = .init(agreement: session.agreement)
        transport = try .init(agreement: session.agreement, collective: collective)
    }

    /// Metadata-only refusal, also usable before the owner allocates a session.
    static func requireSupported(_ agreement: QwenLayerStageGenerationAgreement,
                                 batchSize: Int = 1) throws {
        let request = agreement.request
        guard batchSize == 1, request.profile.residualStreams == 4,
              !request.decodingRankAlone, agreement.prefillPolicy == .serial,
              agreement.phaseSplit == nil, !agreement.compactDecode,
              agreement.speculativeHead == nil, agreement.speculativeRoundsFraming == nil else {
            throw ProbeError("GLM pipeline supports only serial prefill and single-request regular decode; MTP, batching and alternate framing are unsupported")
        }
    }

    /// Blocking, single-use executor. Only rank 0 invokes the client callback,
    /// after the target packet and token ACK. False requests a clean client stop;
    /// throwing cancels the request. A throw retains cache/model ownership until
    /// closeAfterPeerFence; it never pretends a timeout is peer retirement.
    /// `onSelectedRow` (qualification evidence only): on the target rank,
    /// after each selection, the token's ordinal, the frame's boundary
    /// fingerprint and the evaluated row it was selected from. No decision reads it.
    func run(onCommittedToken: (Int) throws -> Bool,
             onSelectedRow: ((Int, String, MLXArray) throws -> Void)? = nil,
             check: () throws -> Void) throws -> QwenLayerStageGenerationResult {
        guard operation.try() else { throw ProbeError("GLM pipeline is already executing") }
        defer { operation.unlock() }
        guard !started else { throw ProbeError("GLM pipeline request cannot be restarted") }
        started = true
        // The resident assigns features after driver construction. Capture at
        // execution entry so a failed retirement cannot lose that late owner.
        retiringImageFeatures = session.imageFeatures
        return try MLX.withError { nativeError in
            func checked() throws {
                try nativeError.check(); try check(); try nativeError.check()
                guard !session.isFailed, !control.isFailed, !transport.isFailed else {
                    throw ProbeError("GLM pipeline was invalidated")
                }
            }
            do {
                try Self.requireSupported(session.agreement)
                guard !session.isClosed, session.committedTokens == session.agreement.request.reusedPrefixTokens,
                      transport.rank != 1 || (session.agreement.request.sampler?.nextOutputIndex ?? 0) == 0 else {
                    throw ProbeError("GLM pipeline session or sampler was already consumed")
                }
                try checked()
                let agreement = session.agreement
                _ = try requireQwenLongPrefillReadinessDigest(collective: transport.collective,
                    material: { .generation(agreementFingerprint: agreement.fingerprint) },
                    disagreementMessage: "GLM pipeline membership/request/source readiness differs",
                    scope: .request(.requestAgreement, requestID: agreement.request.requestID,
                        agreementFingerprint: agreement.fingerprint, "generation-readiness"), check: checked)
                var selected: [Int] = []
                var finalDecision: QwenLayerStageGenerationDecisionPacket?
                while control.phase == .frame {
                    try autoreleasepool {
                        try checked()
                        let expected = try control.beginFrame()
                        let (boundary, row) = try runGLM5NextStageFrame(session: session,
                            control: control, transport: transport, expected: expected, check: checked)
                        guard control.phase == .token else { return }
                        if let onSelectedRow, transport.rank == 1, let row {
                            try onSelectedRow(control.selectedTokenCount, boundary.fingerprint, row)
                        }
                        let token = try agreeToken(row: row, boundary: boundary, check: checked)
                        let value = try control.takeCommittedToken()
                        selected.append(value)
                        let decision: QwenLayerStageGenerationDecisionPacket
                        if transport.rank == 0 {
                            try checked()
                            let keepGoing = try onCommittedToken(value)
                            try checked()
                            decision = try control.decide(continueRequested: keepGoing)
                            try control.acknowledgeDecision(rank: 0, packet: decision)
                            try transport.sendDecision(decision, check: checked)
                            try control.acknowledgeDecision(rank: 1, packet: decision)
                        } else {
                            decision = try transport.receiveDecision(token: token, check: checked)
                            let local = try control.decide(continueRequested: decision.content.decision == .proceed)
                            guard local.content == decision.content else {
                                throw ProbeError("GLM owner decision differs from the agreed stop policy")
                            }
                            try control.acknowledgeDecision(rank: 0, packet: decision)
                            try control.acknowledgeDecision(rank: 1, packet: decision)
                            try transport.acknowledgeDecision(decision, check: checked)
                        }
                        if control.phase == .retiring { finalDecision = decision }
                    }
                }
                guard control.phase == .retiring, let reason = control.finishReason,
                      let finalDecision, selected.count == control.selectedTokenCount,
                      session.committedTokens == control.committedTokens else {
                    throw ProbeError("GLM pipeline ended without an agreed clean stop")
                }
                // Both ranks agreed to stop. Join both local streams before
                // releasing the cache, then exchange actual retirement evidence.
                try checked()
                Stream.cpu.synchronize(); try checked()
                try session.close(check: checked)
                try acknowledgeRetirement(rank: transport.rank, disposition: .retired)
                try transport.exchangeRetirement(decision: finalDecision, check: checked)
                try acknowledgeRetirement(rank: 1 - transport.rank, disposition: .retired)
                try checked()
                guard control.isRetired, session.isClosed else {
                    throw ProbeError("GLM pipeline retirement is incomplete")
                }
                retiringImageFeatures = nil
                return .init(agreementFingerprint: agreement.fingerprint,
                    membershipEpoch: agreement.descriptor.membershipEpoch, identity: session.identity,
                    selectedTokenIDs: selected, tokenChainSHA256: control.tokenChainSHA256,
                    completedFrames: control.completedFrames, committedTokens: control.committedTokens,
                    finishReason: reason)
            } catch {
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                session.invalidate(); control.cancel(); transport.retire()
                transport.collective.invalidateDataPlane()
                throw primary
            }
        }
    }

    /// The owner must establish peer quiescence out of band. A failed fence or
    /// local check leaves ownership intact and permits only another close attempt.
    /// This deliberately uses a cleanup check independent of request cancellation.
    func closeAfterPeerFence(peerFence: () throws -> Void, check: () throws -> Void) throws {
        guard operation.try() else { throw ProbeError("GLM pipeline cannot close during execution") }
        defer { operation.unlock() }
        if control.isRetired, session.isClosed {
            // A final check may have thrown after both ACKs. Their completed
            // retirement still grants release; no second fence is required.
            retiringImageFeatures = nil
            return
        }
        guard started, session.isFailed, control.isFailed else {
            throw ProbeError("GLM pipeline fenced cleanup requires a failed request")
        }
        try peerFence()
        try MLX.withError { error in
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            try error.check(); try check(); try error.check()
            try session.close { try error.check(); try check(); try error.check() }
        }
        // An exchange can fail after local retirement. Keep that evidence and
        // record only the missing peer fence, never acknowledge a rank twice.
        if !control.isRetired {
            try acknowledgeRetirement(rank: transport.rank, disposition: .fenced)
            try acknowledgeRetirement(rank: 1 - transport.rank, disposition: .fenced)
        }
        retiringImageFeatures = nil
    }

    private func acknowledgeRetirement(rank: Int,
        disposition: QwenLayerStageGenerationControl.Retirement) throws {
        guard !retiredRanks.contains(rank) else { return }
        try control.acknowledgeRetirement(rank: rank, disposition: disposition)
        retiredRanks.insert(rank)
    }

    /// The existing regular Qwen token protocol, kept model-local until its
    /// shared extraction is reviewed. Sampling uses the product's keyed sampler.
    private func agreeToken(row: MLXArray?, boundary: QwenLayerStageGenerationBoundaryPacket,
                            check: () throws -> Void) throws -> QwenLayerStageGenerationTokenPacket {
        let packet: QwenLayerStageGenerationTokenPacket
        if transport.rank == 1 {
            guard let row else { throw ProbeError("GLM target selection lacks committed logits") }
            let value = try QwenLayerStageGenerationSelection.token(row,
                request: control.agreement.request, check: check)
            packet = try .init(agreement: control.agreement, boundaryFingerprint: boundary.fingerprint,
                previousTokenChainSHA256: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
                committedTokens: control.committedTokens, tokenID: value)
            try control.acknowledgeToken(rank: 1, packet: packet)
            try transport.sendToken(packet, check: check)
            try control.acknowledgeToken(rank: 0, packet: packet)
        } else {
            guard case nil = row else { throw ProbeError("GLM producer unexpectedly owns logits") }
            packet = try transport.receiveToken(boundaryFingerprint: boundary.fingerprint,
                previousChain: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
                committedTokens: control.committedTokens, check: check)
            try control.acknowledgeToken(rank: 1, packet: packet)
            try control.acknowledgeToken(rank: 0, packet: packet)
            try transport.acknowledgeToken(packet, check: check)
        }
        return packet
    }
}
