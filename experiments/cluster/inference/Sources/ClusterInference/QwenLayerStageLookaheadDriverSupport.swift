import Foundation

enum QwenLayerStageLookaheadDriverSupport {
    static func admit(context: QwenLayerStageLookaheadContext, transport: QwenLayerStageLookaheadTransport,
                      request: QwenLayerStageRecordedRequest) throws -> QwenLayerStageOverlapPlan {
        guard !context.isClosed, !context.isFailed, context.committedTokens == 0,
              !transport.isFailed, !transport.hasPendingConsumption,
              (0...1).contains(context.identity.stageIndex),
              context.identity.requestFingerprint == request.request.fingerprint,
              context.request.fingerprint == request.fingerprint,
              context.request.request == request.request,
              context.request.vocabularySize == request.vocabularySize,
              context.request.promptTokenIDs == request.promptTokenIDs,
              context.request.teacherTokenIDs == request.teacherTokenIDs,
              context.request.steps.count == request.steps.count,
              zip(context.request.steps, request.steps).allSatisfy({
                  $0.0.frame == $0.1.frame && $0.0.tokenIDs == $0.1.tokenIDs
              }) else {
            throw ProbeError("Lookahead driver requires a fresh matching context, transport and immutable teacher timeline")
        }
        let plan = try QwenLayerStageOverlapPlan(request: request.request,
            decodeAdmission: request.teacherTokenIDs.isEmpty ? .prefillOnly : .frozenTeacherDiagnostic)
        guard plan.frames == request.steps.map(\.frame) else {
            throw ProbeError("Lookahead policy changed the existing recorded request schedule")
        }
        return plan
    }

    static func requireCapture(_ capture: QwenLayerStageRankFrameCapture,
        step: QwenLayerStageRecordedRequest.Step, identity: QwenLayerStageSessionIdentity
    ) throws {
        guard capture.identity == identity, capture.frame == step.frame,
              capture.committedTokens == step.committedTokens,
              capture.boundaryShape.count == 3, capture.boundaryShape[0] == 1,
              capture.boundaryShape[1] == step.frame.tokenCount,
              capture.boundaryDType == identity.activationDType,
              qwenStageWireIsSHA256(capture.boundaryPayloadSHA256),
              qwenStageWireIsSHA256(capture.stageStateSHA256) else {
            throw ProbeError("Lookahead CPU capture differs from its committed native request/frame identity")
        }
    }

    static func requireSentCapture(_ capture: QwenLayerStageRankFrameCapture,
                                   ticket: QwenLayerStageLookaheadTicket) throws {
        let header = ticket.envelope.boundary
        guard capture.identity.stageIndex == 0, capture.identity.requestFingerprint == header.requestFingerprint,
              capture.frame == header.frame, capture.committedTokens == header.frame.tokenOffset + header.frame.tokenCount,
              capture.boundaryPayloadSHA256 == header.payloadSHA256,
              capture.boundaryShape == header.shape, capture.boundaryDType == header.dtype,
              capture.identity.sourceConfigurationSHA256 == header.sourceConfigurationSHA256,
              capture.identity.artifactAggregateSHA256 == header.artifactAggregateSHA256,
              capture.identity.storageCommitmentSHA256 == header.storageCommitmentSHA256,
              capture.identity.planFingerprint == header.planFingerprint,
              capture.identity.stageFingerprint == header.producerStageFingerprint else {
            throw ProbeError("Lookahead pending CPU capture differs from the actually received envelope")
        }
    }

    static func cancel(_ context: QwenLayerStageLookaheadContext, primary: Error) throws -> Never {
        do { try context.cancel() }
        catch { throw ProbeError("Lookahead request failed (\(primary)); local retirement also failed (\(error))") }
        guard context.isClosed, context.isFailed else {
            throw ProbeError("Lookahead request failed (\(primary)); local state was not failed and retired")
        }
        throw primary
    }
}
