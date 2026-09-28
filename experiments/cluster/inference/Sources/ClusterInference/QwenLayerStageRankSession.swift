import Foundation
import MLX

/// One already loaded stage and one synchronous transport, owned by one caller.
/// No baseline model, subprocess, loader, collective admission or overlap lives
/// here. The parent must fence both rank processes if any operation throws.
final class QwenLayerStageRankSession {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageRecordedRequest
    private let session: QwenLayerStageSession
    private let stage: QwenLayerStagePlan.Stage
    private let transport: QwenLayerStageBoundaryTransport
    private let source: QwenLayerStageWireSourceIdentity
    private let hiddenSize: Int
    private var failed = false
    private(set) var completedFrames = 0

    /// Local native commit can precede transport completion. On failure that
    /// advanced state is retired; completedFrames never authorizes replay.
    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.isClosed }
    var isFailed: Bool { failed || session.isFailed || transport.isFailed }

    init(stage loaded: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
         request: QwenLayerStageRecordedRequest, transport: QwenLayerStageBoundaryTransport) throws {
        guard !transport.isFailed, plan.stages.indices.contains(loaded.stageIndex), plan.stages.count == 2,
              request.vocabularySize == loaded.vocabularySize,
              let root = try JSONSerialization.jsonObject(with: plan.originalConfiguration) as? [String: Any] else {
            throw ProbeError("Rank session requires a matching admitted source plan and token timeline")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        guard let hidden = BoundedProbeInput.integer(text["hidden_size"]), (1...8192).contains(hidden) else {
            throw ProbeError("Rank session source hidden width is not admitted")
        }
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: loaded.receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        let session = try QwenLayerStageSession(stage: loaded, plan: plan, request: request.request)
        self.session = session; self.identity = session.identity; self.request = request
        self.stage = plan.stages[loaded.stageIndex]; self.transport = transport
        self.source = source; self.hiddenSize = hidden
    }

    /// Observer may capture/validate CPU values only. It runs after this rank's
    /// native commit, before stage-zero send or stage-one consumed ACK.
    func runNextFrame(observe: (QwenLayerStageRankFrameCapture) throws -> Void,
                      check: () throws -> Void) throws -> QwenLayerStageRankFrameCompletion {
        do {
            guard !isClosed, !isFailed, request.steps.indices.contains(completedFrames) else {
                throw ProbeError("Rank request is closed, failed, or past its agreed timeline")
            }
            let step = request.steps[completedFrames]
            guard committedTokens == step.frame.tokenOffset else { throw ProbeError("Rank request token frontier diverged") }
            let expected = try QwenLayerStageBoundaryWireExpectation(request: request.request,
                frame: step.frame, tokenIDs: step.tokenIDs, sourceIdentity: source,
                hiddenSize: hiddenSize, nativeDType: identity.activationDType)
            let result = try autoreleasepool {
                try MLX.withError { error in
                    if identity.stageIndex == 0 {
                        let output = try forward(step: step, incoming: nil,
                            check: { try error.check(); try check() })
                        guard case .hidden(let boundary) = output else { throw ProbeError("Rank zero did not return native residuals") }
                        let capture = try captureFrame(step: step, output: output, boundary: boundary,
                            check: { try error.check(); try check() })
                        try observe(capture)
                        try error.check(); try check()
                        try requireCommittedFrontier(step)
                        let headerSHA = try transport.send(boundary, expected: expected,
                            check: { try error.check(); try check() })
                        return QwenLayerStageRankFrameCompletion(capture: capture, headerSHA256: headerSHA,
                            completedTransportPhase: "consumed_ack_received_and_validated")
                    }
                    let received = try transport.receive(expected: expected, consume: { boundary in
                        let output = try forward(step: step, incoming: boundary,
                            check: { try error.check(); try check() })
                        let capture = try captureFrame(step: step, output: output, boundary: boundary,
                            check: { try error.check(); try check() })
                        try observe(capture)
                        try error.check(); try check()
                        try requireCommittedFrontier(step)
                        return capture
                    }, check: { try error.check(); try check() })
                    return QwenLayerStageRankFrameCompletion(capture: received.value,
                        headerSHA256: received.headerSHA256, completedTransportPhase: "consumed_ack_send_completed")
                }
            }
            try requireCommittedFrontier(step)
            completedFrames += 1
            return result
        } catch { try fail(error) }
    }

    private func requireCommittedFrontier(_ step: QwenLayerStageRecordedRequest.Step) throws {
        guard !isClosed, !isFailed, committedTokens == step.committedTokens else {
            throw ProbeError("Rank frame lost its open committed request before handshake completion")
        }
    }

    private func forward(step: QwenLayerStageRecordedRequest.Step, incoming: QwenLayerStageBoundary?,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {
        switch step.frame.phase {
        case .prefill:
            return try session.prefillChunk(step.tokenIDs, offset: step.frame.tokenOffset,
                final: step.frame.finalPromptChunk, incoming: incoming, check: check)
        case .decode:
            return try session.decode(step.tokenIDs[0], offset: step.frame.tokenOffset, incoming: incoming, check: check)
        }
    }

    private func captureFrame(step: QwenLayerStageRecordedRequest.Step, output: QwenLayerStageOutput,
                              boundary: QwenLayerStageBoundary, check: () throws -> Void) throws -> QwenLayerStageRankFrameCapture {
        guard committedTokens == step.committedTokens, boundary.frame == step.frame,
              boundary.array.shape == [1, step.frame.tokenCount, hiddenSize],
              String(describing: boundary.array.dtype) == identity.activationDType else {
            throw ProbeError("Rank frame capture has a mismatched native boundary or local commit")
        }
        let snapshot = try session.snapshot(includeBytes: false, check: check)
        let state = try QwenLayerStageRankStateCapture(snapshot: snapshot, stage: stage,
                                                      committedTokens: step.committedTokens)
        let array: MLXArray, kind: String, logits: QwenRecordedLogitValues?
        switch output {
        case .hidden(let value) where identity.stageIndex == 0:
            array = value.array; kind = "hidden"; logits = nil
        case .evaluationHandle(let value) where identity.stageIndex == 1 && !step.expectsLogits:
            array = value; kind = "evaluation_handle"; logits = nil
        case .logits(let value) where identity.stageIndex == 1 && step.expectsLogits:
            array = value; kind = "logits"
            logits = try QwenRecordedLogits(value, vocabularySize: request.vocabularySize, check: check).record
        default: throw ProbeError("Rank frame capture returned the wrong local output kind")
        }
        try check()
        return .init(identity: identity, frame: step.frame, committedTokens: step.committedTokens,
            sourceLayerStart: stage.sourceRange.lowerBound, sourceLayerEnd: stage.sourceRange.upperBound,
            stateEntries: state.entries, logicalStateBytes: state.logicalBytes, stageStateSHA256: state.fingerprint,
            boundaryPayloadSHA256: boundary.payloadSHA256, boundaryShape: boundary.array.shape,
            boundaryDType: String(describing: boundary.array.dtype), outputKind: kind,
            outputShape: array.shape, outputDType: String(describing: array.dtype), logits: logits)
    }

    func close() throws {
        if isClosed && !isFailed { return }
        do {
            guard !isFailed, completedFrames == request.steps.count,
                  committedTokens == request.request.promptCount + request.teacherTokenIDs.count else {
                throw ProbeError("Rank request closed before all agreed frame handshakes completed")
            }
            try session.close()
            guard isClosed, !isFailed else { throw ProbeError("Rank request did not retire cleanly") }
        } catch { try fail(error) }
    }

    func cancel() throws {
        failed = true
        transport.retire()
        try session.cancel()
    }

    private func fail(_ primary: Error) throws -> Never {
        failed = true
        transport.retire()
        do { try session.cancel() }
        catch { throw ProbeError("Rank request failed (\(primary)); retirement also failed (\(error))") }
        guard session.isClosed, session.isFailed else {
            throw ProbeError("Rank request failed (\(primary)); its local state was not failed and retired")
        }
        throw primary
    }

    deinit {
        if !session.isClosed {
            transport.retire()
            try? session.cancel()
        }
    }
}
