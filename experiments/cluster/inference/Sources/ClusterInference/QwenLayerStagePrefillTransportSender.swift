import Foundation
import MLX

extension QwenLayerStagePrefillTransport {
    /// Returns after peer-owned payload validation and received ACK, with only
    /// a CPU ticket retained here. The caller must release its PreparedFrame and
    /// original array wrapper before preparing one next prompt frame.
    func sendUntilReceived(_ boundary: QwenLayerStageBoundary, expectedFrame: QwenLayerStageFrame,
        onPhase: (QwenLayerStagePrefillSendPhase, QwenLayerStagePrefillBoundaryTicket) throws -> Void,
        check: () throws -> Void) throws -> QwenLayerStagePrefillBoundaryTicket {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try self.checked(check); try error.check() }
                try state.requireFrame(expectedFrame, rank: 0)
                let expected = try agreement.boundaryExpectation(for: expectedFrame)
                let envelope = try makeEnvelope(boundary: boundary, expected: expected, check: checked)
                let ticket = try state.ticket(envelope)
                func phase(_ value: QwenLayerStagePrefillSendPhase) throws { try onPhase(value, ticket); try checked() }
                try phase(.beginHeader)
                try io.sendBytes(envelope.encoded(), maximumBytes: QwenLayerStagePrefillBoundaryEnvelope.maximumEncodedBytes,
                    to: 1, check: checked)
                try phase(.headerSendCompleted)
                let ready = try io.receiveACK(from: 1, check: checked)
                try QwenLayerStagePrefillBoundaryAcknowledgement.validate(ready, envelope: envelope, phase: .ready)
                try phase(.readyACKAccepted)
                try phase(.beginPayloadSend)
                try io.sendPayload(boundary.array, maximumBytes: expected.byteCount, check: checked)
                try phase(.payloadSendCompleted)
                let received = try io.receiveACK(from: 1, check: checked)
                try QwenLayerStagePrefillBoundaryAcknowledgement.validate(received, envelope: envelope, phase: .received)
                try state.senderReceived(ticket)
                try phase(.receivedACKAccepted)
                return ticket
            }
        }
    }

    func finishConsumed(_ ticket: QwenLayerStagePrefillBoundaryTicket,
        onPhase: (QwenLayerStagePrefillSendPhase, QwenLayerStagePrefillBoundaryTicket) throws -> Void,
        check: () throws -> Void) throws {
        try operation {
            try state.requirePending(ticket)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginConsumedDrain, ticket); try checked()
            let consumed = try io.receiveACK(from: 1, check: checked)
            try QwenLayerStagePrefillBoundaryAcknowledgement.validate(consumed, envelope: ticket.envelope, phase: .consumed)
            try state.senderConsumed(ticket)
            try onPhase(.consumedACKAccepted, ticket); try checked()
        }
    }

    private func makeEnvelope(boundary: QwenLayerStageBoundary,
        expected: QwenLayerStageBoundaryWireExpectation, check: () throws -> Void
    ) throws -> QwenLayerStagePrefillBoundaryEnvelope {
        try check()
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
            artifactAggregateSHA256: boundary.artifactAggregateSHA256,
            storageCommitmentSHA256: boundary.storageCommitmentSHA256,
            planFingerprint: boundary.planFingerprint, producerStageFingerprint: boundary.producerStageFingerprint)
        let header = try QwenLayerStageBoundaryWireHeader(requestFingerprint: boundary.requestFingerprint,
            sourceIdentity: source, frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
            payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
            dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
        try header.validate(expected: expected)
        let bytes = boundary.array.asData(access: .copy).data
        try check()
        try header.validatePayload(bytes)
        return try .init(boundary: header, agreement: agreement)
    }
}
