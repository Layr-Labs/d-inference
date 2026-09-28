import Foundation
import MLX

extension QwenLayerStagePrefillTransport {
    /// Payload/consumer live in an inner autorelease scope. Only typed CPU commit,
    /// selection and encoded token packet may escape; final selection is checked
    /// before original-wrapper release and before final consumed ACK is sent.
    func receiveAndConsume(expectedFrame: QwenLayerStageFrame,
        consume: (QwenLayerStageBoundary) throws -> QwenLayerStagePrefillConsumption,
        onPhase: (QwenLayerStagePrefillReceivePhase, QwenLayerStagePrefillBoundaryTicket?) throws -> Void,
        check: () throws -> Void) throws -> QwenLayerStagePrefillReceiveResult {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try self.checked(check); try error.check() }
                func phase(_ value: QwenLayerStagePrefillReceivePhase, _ ticket: QwenLayerStagePrefillBoundaryTicket?) throws {
                    try onPhase(value, ticket); try checked()
                }
                try state.requireFrame(expectedFrame, rank: 1)
                let expected = try agreement.boundaryExpectation(for: expectedFrame)
                try phase(.beginHeaderReceive, nil)
                let data = try io.receiveBytes(maximumBytes: QwenLayerStagePrefillBoundaryEnvelope.maximumEncodedBytes,
                    from: 0, check: checked)
                let envelope = try QwenLayerStagePrefillBoundaryEnvelope.decode(data, agreement: agreement, expectedFrame: expectedFrame)
                let ticket = try state.ticket(envelope)
                try phase(.headerValidated, ticket)
                try phase(.beginReadyACK, ticket)
                try io.sendACK(QwenLayerStagePrefillBoundaryAcknowledgement.values(envelope: envelope, phase: .ready), to: 0, check: checked)
                try phase(.readyACKSendCompleted, ticket)
                weak var receivedHandle: MLXArray?
                let result: QwenLayerStagePrefillReceiveResult = try autoreleasepool {
                    try phase(.beginPayloadReceive, ticket)
                    let array = try io.receivePayload(expected: expected, check: checked)
                    receivedHandle = array
                    let header = envelope.boundary
                    let boundary = QwenLayerStageBoundary(requestFingerprint: header.requestFingerprint,
                        sourceConfigurationSHA256: header.sourceConfigurationSHA256,
                        artifactAggregateSHA256: header.artifactAggregateSHA256,
                        storageCommitmentSHA256: header.storageCommitmentSHA256,
                        planFingerprint: header.planFingerprint, producerStageFingerprint: header.producerStageFingerprint,
                        frame: header.frame, tokenIDsSHA256: header.tokenIDsSHA256,
                        payloadSHA256: header.payloadSHA256, array: array)
                    try boundary.validateOwnedArray(tokens: expected.shape[1], hidden: expected.shape[2], dtype: io.nativeDType(expected.dtype))
                    try checked()
                    try phase(.payloadReceivedAndValidated, ticket)
                    try phase(.beginReceivedACK, ticket)
                    try io.sendACK(QwenLayerStagePrefillBoundaryAcknowledgement.values(envelope: envelope, phase: .received), to: 0, check: checked)
                    try phase(.receivedACKSendCompleted, ticket)
                    try phase(.beginConsumption, ticket)
                    let consumed = try consume(boundary)
                    try checked()
                    let token = try validateConsumption(consumed, envelope: envelope)
                    try phase(.consumptionAndSelectionValidated, ticket)
                    return .init(ticket: ticket, commit: consumed.commit, selection: consumed.selection, tokenPacket: token)
                }
                // This proves release of the original wrapper, not arbitrary
                // aliases a forbidden side-effecting callback might stash away.
                guard receivedHandle == nil else { throw ProbeError("Prefill consumer retained the original received array wrapper") }
                try phase(.consumedBoundaryReleased, ticket)
                try phase(.beginConsumedACK, ticket)
                try io.sendACK(QwenLayerStagePrefillBoundaryAcknowledgement.values(envelope: envelope, phase: .consumed), to: 0, check: checked)
                try state.receiverConsumed(ticket, token: result.tokenPacket)
                try phase(.consumedACKSendCompleted, ticket)
                return result
            }
        }
    }

    private func validateConsumption(_ value: QwenLayerStagePrefillConsumption,
        envelope: QwenLayerStagePrefillBoundaryEnvelope
    ) throws -> QwenLayerStagePrefillFirstTokenWirePacket? {
        let frame = envelope.boundary.frame, commit = value.commit
        guard commit.identity == agreement.consumerIdentity,
              commit.recordedRequestFingerprint == agreement.request.fingerprint,
              commit.frame == frame, commit.committedTokens == frame.tokenOffset + frame.tokenCount,
              commit.outputKind == (frame.finalPromptChunk ? "logits" : "evaluation_handle"),
              commit.outputShape == [1, frame.finalPromptChunk ? agreement.request.vocabularySize : 1],
              ["float16", "bfloat16", "float32"].contains(commit.outputDType) else {
            throw ProbeError("Prefill consumer returned different source, request, committed frontier or narrowed output metadata")
        }
        if frame.finalPromptChunk {
            guard let selection = value.selection, commit.outputDType == agreement.descriptor.logitsDType else {
                throw ProbeError("Final prefill consumption requires its actual native first-token selection")
            }
            return try .init(selection: selection, agreement: agreement, finalBoundary: envelope)
        }
        guard value.selection == nil else { throw ProbeError("Intermediate prefill cannot return a selected target token") }
        return nil
    }
}
