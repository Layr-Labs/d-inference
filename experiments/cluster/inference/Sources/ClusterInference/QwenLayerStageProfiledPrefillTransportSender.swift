import Foundation
import MLX

extension QwenLayerStageProfiledPrefillTransport {
    /// Returns after peer-owned payload validation and received ACK, with only
    /// a CPU ticket retained here. The caller must release its Prepared value and
    /// original array wrapper before preparing one next prompt frame.
    func sendUntilReceived(_ prepared: QwenLayerStageProfiledPrefillPrepared, expectedFrame: QwenLayerStageFrame,
        onPhase: (QwenLayerStageProfiledPrefillSendPhase, QwenLayerStageProfiledPrefillBoundaryTicket) throws -> Void,
        check: () throws -> Void) throws -> QwenLayerStageProfiledPrefillBoundaryTicket {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try self.checked(check); try error.check() }
                try state.requireFrame(expectedFrame, rank: 0)
                let expected = try agreement.boundaryExpectation(for: expectedFrame)
                let envelope = try makeEnvelope(prepared: prepared, expected: expected, check: checked)
                let ticket = try state.ticket(envelope)
                func phase(_ value: QwenLayerStageProfiledPrefillSendPhase) throws { try onPhase(value, ticket); try checked() }
                try phase(.beginHeader)
                try io.sendBytes(envelope.encoded(), maximumBytes: QwenLayerStageProfiledPrefillBoundaryEnvelope.maximumEncodedBytes,
                    to: 1, check: checked)
                try phase(.headerSendCompleted)
                let ready = try io.receiveACK(from: 1, check: checked)
                try QwenLayerStageProfiledPrefillBoundaryAcknowledgement.validate(ready, envelope: envelope, phase: .ready)
                try phase(.readyACKAccepted)
                try phase(.beginPayloadSend)
                try io.sendPayload(prepared.boundary.array, maximumBytes: expected.byteCount, check: checked)
                try phase(.payloadSendCompleted)
                let received = try io.receiveACK(from: 1, check: checked)
                try QwenLayerStageProfiledPrefillBoundaryAcknowledgement.validate(received, envelope: envelope, phase: .received)
                try state.senderReceived(ticket)
                try phase(.receivedACKAccepted)
                return ticket
            }
        }
    }

    func finishConsumed(_ ticket: QwenLayerStageProfiledPrefillBoundaryTicket,
        onPhase: (QwenLayerStageProfiledPrefillSendPhase, QwenLayerStageProfiledPrefillBoundaryTicket) throws -> Void,
        check: () throws -> Void) throws {
        try operation {
            try state.requirePending(ticket)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginConsumedDrain, ticket); try checked()
            let consumed = try io.receiveACK(from: 1, check: checked)
            try QwenLayerStageProfiledPrefillBoundaryAcknowledgement.validate(consumed, envelope: ticket.envelope, phase: .consumed)
            try state.senderConsumed(ticket)
            try onPhase(.consumedACKAccepted, ticket); try checked()
        }
    }

    private func makeEnvelope(prepared: QwenLayerStageProfiledPrefillPrepared,
        expected: QwenLayerStageProfiledBoundaryWireExpectation, check: () throws -> Void
    ) throws -> QwenLayerStageProfiledPrefillBoundaryEnvelope {
        try check()
        let boundary = prepared.boundary, commit = prepared.commit
        let descriptor = agreement.descriptor
        let producer = QwenLayerStageSessionIdentity(stageIndex: 0,
            requestFingerprint: descriptor.requestFingerprint,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256,
            storageCommitmentSHA256: descriptor.storageCommitmentSHA256,
            bf16ConversionEnabled: descriptor.bf16ConversionEnabled,
            sourceConfigurationSHA256: descriptor.sourceConfigurationSHA256,
            constructionConfigurationSHA256: descriptor.producerConstructionConfigurationSHA256,
            planFingerprint: descriptor.planFingerprint, stageFingerprint: descriptor.producerStageFingerprint,
            activationDType: descriptor.nativeDType)
        guard commit.identity == producer, commit.recordedRequestFingerprint == agreement.request.fingerprint,
              commit.frame == expected.frame,
              commit.committedTokens == expected.frame.tokenOffset + expected.frame.tokenCount,
              commit.outputKind == "hidden", commit.outputShape == boundary.array.shape,
              commit.outputDType == String(describing: boundary.array.dtype) else {
            throw ProbeError("Profiled sender requires its actual committed producer identity, history and output")
        }
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
            artifactAggregateSHA256: boundary.artifactAggregateSHA256,
            storageCommitmentSHA256: boundary.storageCommitmentSHA256,
            planFingerprint: boundary.planFingerprint, producerStageFingerprint: boundary.producerStageFingerprint)
        // Native boundary fields remain actual observations. Profile/history are
        // carried by the real prepared context and checked against local admission.
        let header = try QwenLayerStageProfiledBoundaryWireHeader(profile: prepared.expectation.profile,
            requestFingerprint: boundary.requestFingerprint,
            recordedRequestFingerprint: commit.recordedRequestFingerprint,
            sourceIdentity: source, frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
            payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
            dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
        try header.validate(expected: expected)
        try header.validate(expected: prepared.expectation)
        let bytes = boundary.array.asData(access: .copy).data
        try check()
        try header.validatePayload(bytes)
        return try .init(boundary: header, agreement: agreement)
    }
}
