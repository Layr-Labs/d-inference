import Foundation
import MLX

/// A single explicitly prepared producer output. Drop this entire value after
/// received ACK; the subsequent consumed ticket contains CPU metadata only.
struct QwenLayerStageLookaheadPreparedFrame {
    let boundary: QwenLayerStageBoundary
    let expectation: QwenLayerStageBoundaryWireExpectation
    let capture: QwenLayerStageRankFrameCapture
}

/// Native stage/state ownership separate from the pure pipeline schedule. This
/// context preserves the existing forward, snapshot and finite-logit capture
/// semantics; it cannot post a transport operation or authorize lookahead.
final class QwenLayerStageLookaheadContext {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageRecordedRequest
    private let session: QwenLayerStageSession
    private let stage: QwenLayerStagePlan.Stage
    private let source: QwenLayerStageWireSourceIdentity
    private let hiddenSize: Int

    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.isClosed }
    var isFailed: Bool { session.isFailed }

    init(loaded: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
         request: QwenLayerStageRecordedRequest) throws {
        guard plan.stages.indices.contains(loaded.stageIndex), plan.stages.count == 2,
            request.vocabularySize == loaded.vocabularySize,
            let root = try JSONSerialization.jsonObject(with: plan.originalConfiguration) as? [String: Any] else {
            throw ProbeError("Lookahead context requires an admitted stage and immutable input history")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        guard let hidden = BoundedProbeInput.integer(text["hidden_size"]), (1...8192).contains(hidden) else {
            throw ProbeError("Lookahead context hidden width exceeds its local bound")
        }
        source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: loaded.receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        let session = try QwenLayerStageSession(stage: loaded, plan: plan, request: request.request)
        self.session = session; identity = session.identity; self.request = request
        stage = plan.stages[loaded.stageIndex]; hiddenSize = hidden
    }

    func expectation(for step: QwenLayerStageRecordedRequest.Step) throws -> QwenLayerStageBoundaryWireExpectation {
        try requireStep(step)
        return try .init(request: request.request, frame: step.frame, tokenIDs: step.tokenIDs,
            sourceIdentity: source, hiddenSize: hiddenSize, nativeDType: identity.activationDType)
    }

    func prepare(_ step: QwenLayerStageRecordedRequest.Step,
                 check: () throws -> Void) throws -> QwenLayerStageLookaheadPreparedFrame {
        guard identity.stageIndex == 0 else { throw ProbeError("Only stage zero prepares prompt residuals") }
        let expected = try expectation(for: step)
        let output = try forward(step, incoming: nil, check: check)
        guard case .hidden(let boundary) = output else { throw ProbeError("Lookahead producer returned the wrong output") }
        return try .init(boundary: boundary, expectation: expected,
            capture: capture(step, output: output, boundary: boundary, check: check))
    }

    func consume(_ step: QwenLayerStageRecordedRequest.Step, boundary: QwenLayerStageBoundary,
                 check: () throws -> Void) throws -> QwenLayerStageRankFrameCapture {
        guard identity.stageIndex == 1 else { throw ProbeError("Only stage one consumes received residuals") }
        try requireStep(step)
        let output = try forward(step, incoming: boundary, check: check)
        return try capture(step, output: output, boundary: boundary, check: check)
    }

    private func requireStep(_ step: QwenLayerStageRecordedRequest.Step) throws {
        guard !isClosed, !isFailed, request.steps.indices.contains(step.frame.sequence) else {
            throw ProbeError("Lookahead native context is retired or the frame is outside its request")
        }
        let expected = request.steps[step.frame.sequence]
        guard expected.frame == step.frame, expected.tokenIDs == step.tokenIDs,
            expected.committedTokens == step.committedTokens, expected.expectsLogits == step.expectsLogits else {
            throw ProbeError("Lookahead frame differs from the immutable token history")
        }
    }

    private func forward(_ step: QwenLayerStageRecordedRequest.Step, incoming: QwenLayerStageBoundary?,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {
        try requireStep(step)
        guard committedTokens == step.frame.tokenOffset else { throw ProbeError("Lookahead native token frontier diverged") }
        switch step.frame.phase {
        case .prefill:
            return try session.prefillChunk(step.tokenIDs, offset: step.frame.tokenOffset,
                final: step.frame.finalPromptChunk, incoming: incoming, check: check)
        case .decode:
            return try session.decode(step.tokenIDs[0], offset: step.frame.tokenOffset,
                incoming: incoming, check: check)
        }
    }

    private func capture(_ step: QwenLayerStageRecordedRequest.Step, output: QwenLayerStageOutput,
        boundary: QwenLayerStageBoundary, check: () throws -> Void
    ) throws -> QwenLayerStageRankFrameCapture {
        guard committedTokens == step.committedTokens, boundary.frame == step.frame,
            boundary.array.shape == [1, step.frame.tokenCount, hiddenSize],
            String(describing: boundary.array.dtype) == identity.activationDType else {
            throw ProbeError("Lookahead capture differs from its native boundary or local commit")
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
        default: throw ProbeError("Lookahead capture has the wrong rank output kind")
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
        guard !isFailed, committedTokens == request.request.promptCount + request.teacherTokenIDs.count else {
            throw ProbeError("Lookahead context has not completed its native token history")
        }
        try session.close()
    }

    func cancel() throws { try session.cancel() }
    deinit { if !session.isClosed { try? session.cancel() } }
}
