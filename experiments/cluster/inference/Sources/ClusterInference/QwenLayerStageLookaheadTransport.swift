import Foundation
import MLX

/// CPU-only proof of one received residual whose consumed ACK is still pending.
/// It retains no native array or producer model/state. Only its transport may
/// create or discharge it, once, during the admitted cohort.
struct QwenLayerStageLookaheadTicket {
    fileprivate let nonce = UUID()
    let envelope: QwenLayerStageLookaheadWireEnvelope
    let scheduleTicket: QwenLayerStageOverlapTicket
    var frame: QwenLayerStageFrame { envelope.boundary.frame }
    var headerSHA256: String { sha256(envelope.encoded()) }
    fileprivate init(envelope: QwenLayerStageLookaheadWireEnvelope) throws {
        self.envelope = envelope
        scheduleTicket = try .init(flow: QwenLayerStageLookaheadWireEnvelope.flow,
            requestFingerprint: envelope.boundary.requestFingerprint, frame: envelope.boundary.frame,
            headerSHA256: sha256(envelope.encoded()))
    }
}

enum QwenLayerStageLookaheadSendPhase {
    case beginHeader, headerSendCompleted, readyACKAccepted, beginPayloadSend
    case payloadSendCompleted, receivedACKAccepted, beginConsumedDrain, consumedACKAccepted
}

enum QwenLayerStageLookaheadReceivePhase {
    case beginHeaderReceive, headerValidated, beginReadyACK, readyACKSendCompleted
    case beginPayloadReceive, payloadReceivedAndValidated, beginReceivedACK, receivedACKSendCompleted
    case beginConsumption, consumptionAndCaptureCompleted, consumedBoundaryReleased
    case beginConsumedACK, consumedACKSendCompleted
}

/// Serialized MLX ownership within each process. Receiver ACKs owned bytes before
/// computing; sender can prepare one next prompt chunk before draining consumed.
/// The pure scheduling owner, not this byte transport, admits that preparation.
final class QwenLayerStageLookaheadTransport {
    private let collective: Collective
    private var pending: QwenLayerStageLookaheadTicket?
    private var inOperation = false
    private(set) var isFailed = false
    var hasPendingConsumption: Bool { pending != nil }

    init(collective: Collective) { self.collective = collective }
    func retire() { isFailed = true; pending = nil }

    func sendUntilReceived(_ boundary: QwenLayerStageBoundary,
        expected: QwenLayerStageBoundaryWireExpectation,
        onPhase: (QwenLayerStageLookaheadSendPhase, QwenLayerStageOverlapTicket) throws -> Void,
        check: () throws -> Void
    ) throws -> QwenLayerStageLookaheadTicket {
        try operation {
            guard collective.rank == 0, pending == nil else {
                throw ProbeError("Lookahead sender must drain its previous consumed ACK before another header")
            }
            let envelope = try makeEnvelope(boundary: boundary, expected: expected)
            let ticket = try QwenLayerStageLookaheadTicket(envelope: envelope)
            func checked() throws { try requireActive(); try check(); try requireActive() }
            func phase(_ value: QwenLayerStageLookaheadSendPhase) throws {
                try onPhase(value, ticket.scheduleTicket); try checked()
            }
            try checked()
            let encoded = envelope.encoded()
            try phase(.beginHeader)
            _ = try collective.sendCompleted(MLXArray([UInt32(encoded.count)]), to: 1,
                maximumBytes: 4, check: checked)
            _ = try collective.sendCompleted(MLXArray(Array(encoded)), to: 1,
                maximumBytes: QwenLayerStageLookaheadWireEnvelope.maximumEncodedBytes, check: checked)
            try phase(.headerSendCompleted)
            try receiveAcknowledgement(envelope: envelope, phase: .ready, check: checked)
            try phase(.readyACKAccepted)
            try phase(.beginPayloadSend)
            _ = try collective.sendCompleted(boundary.array, to: 1,
                maximumBytes: expected.byteCount, check: checked)
            try phase(.payloadSendCompleted)
            try receiveAcknowledgement(envelope: envelope, phase: .received, check: checked)
            try phase(.receivedACKAccepted)
            pending = ticket
            // Both this result and pending hold only the header. Caller must
            // release its old boundary before computing the next prepared one.
            return ticket
        }
    }

    func finishConsumed(_ ticket: QwenLayerStageLookaheadTicket,
                        onPhase: (QwenLayerStageLookaheadSendPhase, QwenLayerStageOverlapTicket) throws -> Void,
                        check: () throws -> Void) throws {
        try operation {
            guard collective.rank == 0, let current = pending,
                current.nonce == ticket.nonce, current.envelope.encoded() == ticket.envelope.encoded() else {
                throw ProbeError("Lookahead consumed ticket is stale or belongs to another transport")
            }
            func checked() throws { try requireActive(); try check(); try requireActive() }
            try onPhase(.beginConsumedDrain, current.scheduleTicket); try checked()
            try receiveAcknowledgement(envelope: current.envelope, phase: .consumed, check: checked)
            try onPhase(.consumedACKAccepted, current.scheduleTicket); try checked()
            pending = nil
        }
    }

    /// Received ACK follows native storage/hash validation. Consumed ACK follows
    /// the callback's completed model/state commit and CPU capture/validation.
    func receiveAndConsume<T>(expected: QwenLayerStageBoundaryWireExpectation,
        consume: (QwenLayerStageBoundary) throws -> T,
        onPhase: (QwenLayerStageLookaheadReceivePhase, QwenLayerStageOverlapTicket?) throws -> Void,
        check: () throws -> Void
    ) throws -> (value: T, headerSHA256: String) {
        try operation {
            guard collective.rank == 1 else { throw ProbeError("Only stage one receives lookahead residuals") }
            func checked() throws { try requireActive(); try check(); try requireActive() }
            func phase(_ value: QwenLayerStageLookaheadReceivePhase, _ ticket: QwenLayerStageOverlapTicket?) throws {
                try onPhase(value, ticket); try checked()
            }
            try phase(.beginHeaderReceive, nil)
            let length = try collective.receiveCompleted(shape: [1], dtype: .uint32, from: 0,
                maximumBytes: 4, check: checked).item(UInt32.self)
            guard length > 0, length <= QwenLayerStageLookaheadWireEnvelope.maximumEncodedBytes else {
                throw ProbeError("Lookahead envelope length exceeds its local bound")
            }
            let data = try collective.receiveCompleted(shape: [Int(length)], dtype: .uint8, from: 0,
                maximumBytes: QwenLayerStageLookaheadWireEnvelope.maximumEncodedBytes, check: checked).asData().data
            try checked()
            let envelope = try QwenLayerStageLookaheadWireEnvelope.decode(data, expected: expected)
            let ticket = try QwenLayerStageLookaheadTicket(envelope: envelope).scheduleTicket
            try phase(.headerValidated, ticket)
            try phase(.beginReadyACK, ticket)
            try sendAcknowledgement(envelope: envelope, phase: .ready, check: checked)
            try phase(.readyACKSendCompleted, ticket)
            let dtype = try nativeDType(expected.dtype)
            weak var receivedHandle: MLXArray?
            let result: T = try autoreleasepool {
                try phase(.beginPayloadReceive, ticket)
                let array = try collective.receiveCompleted(shape: expected.shape, dtype: dtype,
                    from: 0, maximumBytes: expected.byteCount, check: checked)
                receivedHandle = array
                let header = envelope.boundary
                let boundary = QwenLayerStageBoundary(requestFingerprint: header.requestFingerprint,
                    sourceConfigurationSHA256: header.sourceConfigurationSHA256,
                    artifactAggregateSHA256: header.artifactAggregateSHA256,
                    storageCommitmentSHA256: header.storageCommitmentSHA256,
                    planFingerprint: header.planFingerprint, producerStageFingerprint: header.producerStageFingerprint,
                    frame: header.frame, tokenIDsSHA256: header.tokenIDsSHA256,
                    payloadSHA256: header.payloadSHA256, array: array)
                try boundary.validateOwnedArray(tokens: expected.shape[1], hidden: expected.shape[2], dtype: dtype)
                try checked()
                try phase(.payloadReceivedAndValidated, ticket)
                try phase(.beginReceivedACK, ticket)
                try sendAcknowledgement(envelope: envelope, phase: .received, check: checked)
                try phase(.receivedACKSendCompleted, ticket)
                try phase(.beginConsumption, ticket)
                let capture = try consume(boundary)
                try checked()
                try phase(.consumptionAndCaptureCompleted, ticket)
                return capture
            }
            // The known stage callback returns CPU capture only. This checks
            // release of its original array wrapper, not arbitrary hidden aliases.
            guard receivedHandle == nil else { throw ProbeError("Lookahead consumer retained its received array handle") }
            try phase(.consumedBoundaryReleased, ticket)
            try phase(.beginConsumedACK, ticket)
            try sendAcknowledgement(envelope: envelope, phase: .consumed, check: checked)
            try phase(.consumedACKSendCompleted, ticket)
            return (result, sha256(data))
        }
    }

    private func makeEnvelope(boundary: QwenLayerStageBoundary,
        expected: QwenLayerStageBoundaryWireExpectation
    ) throws -> QwenLayerStageLookaheadWireEnvelope {
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
            artifactAggregateSHA256: boundary.artifactAggregateSHA256,
            storageCommitmentSHA256: boundary.storageCommitmentSHA256,
            planFingerprint: boundary.planFingerprint, producerStageFingerprint: boundary.producerStageFingerprint)
        let header = try QwenLayerStageBoundaryWireHeader(requestFingerprint: boundary.requestFingerprint,
            sourceIdentity: source, frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
            payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
            dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
        try header.validate(expected: expected)
        try header.validatePayload(boundary.array.asData().data)
        return try .init(boundary: header, expected: expected)
    }

    private func nativeDType(_ dtype: String) throws -> DType {
        switch dtype {
        case "float16": return .float16
        case "bfloat16": return .bfloat16
        case "float32": return .float32
        default: throw ProbeError("Lookahead wire native dtype is unsupported")
        }
    }

    private func receiveAcknowledgement(envelope: QwenLayerStageLookaheadWireEnvelope,
        phase: QwenLayerStageLookaheadWireAcknowledgement.Phase, check: () throws -> Void
    ) throws {
        let values = try collective.receiveCompleted(shape: [QwenLayerStageLookaheadWireAcknowledgement.elements],
            dtype: .int32, from: 1, maximumBytes: QwenLayerStageLookaheadWireAcknowledgement.byteCount,
            check: check).asArray(Int32.self)
        try check()
        try QwenLayerStageLookaheadWireAcknowledgement.validate(values, envelope: envelope, phase: phase)
    }

    private func sendAcknowledgement(envelope: QwenLayerStageLookaheadWireEnvelope,
        phase: QwenLayerStageLookaheadWireAcknowledgement.Phase, check: () throws -> Void
    ) throws {
        let values = QwenLayerStageLookaheadWireAcknowledgement.values(envelope: envelope, phase: phase)
        _ = try collective.sendCompleted(MLXArray(values), to: 0,
            maximumBytes: QwenLayerStageLookaheadWireAcknowledgement.byteCount, check: check)
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !isFailed, !inOperation else {
            retire()
            throw ProbeError("Lookahead transport is retired or was entered recursively")
        }
        inOperation = true
        defer { inOperation = false }
        do { let result = try body(); try requireActive(); return result }
        catch { retire(); throw error }
    }

    private func requireActive() throws {
        guard !isFailed else { throw ProbeError("Lookahead transport was retired during its operation") }
    }
}
