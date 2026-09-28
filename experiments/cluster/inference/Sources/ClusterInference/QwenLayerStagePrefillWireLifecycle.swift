import Foundation

/// One-shot CPU receive admission. Native integration must call these only at
/// the corresponding completed IO events. No clock or context is owned here.
/// Fresh instances require a fresh externally fenced epoch/request UUID.
struct QwenLayerStagePrefillWireLifecycle {
    let agreement: QwenLayerStagePrefillStartAgreement
    private(set) var startAccepted = false
    private(set) var finalConsumedAccepted = false
    private(set) var selectedTokenID: Int?
    private(set) var isFailed = false
    private var finalBoundary: QwenLayerStagePrefillBoundaryEnvelope?

    var firstTokenComplete: Bool { !isFailed && finalConsumedAccepted && selectedTokenID != nil }

    init(agreement: QwenLayerStagePrefillStartAgreement) { self.agreement = agreement }

    mutating func acceptStart(_ data: Data) throws -> QwenLayerStagePrefillStartWirePacket {
        do {
            guard !isFailed, !startAccepted else { throw ProbeError("Prefill start is one-shot") }
            let packet = try QwenLayerStagePrefillStartWirePacket.decode(data, expectedAgreement: agreement)
            startAccepted = true
            return packet
        } catch { isFailed = true; throw error }
    }

    mutating func bindFinalBoundary(_ envelope: QwenLayerStagePrefillBoundaryEnvelope) throws {
        do {
            guard !isFailed, startAccepted, finalBoundary == nil else { throw ProbeError("Prefill final boundary is out of order or replayed") }
            try envelope.requireFinal(for: agreement)
            finalBoundary = envelope
        } catch { isFailed = true; throw error }
    }

    mutating func acceptFinalConsumed(_ values: [Int32]) throws {
        do {
            guard !isFailed, startAccepted, !finalConsumedAccepted, let finalBoundary else {
                throw ProbeError("Prefill final consumed ACK is out of order or replayed")
            }
            try QwenLayerStagePrefillBoundaryAcknowledgement.validate(values, envelope: finalBoundary, phase: .consumed)
            finalConsumedAccepted = true
        } catch { isFailed = true; throw error }
    }

    /// The stream contract is final-consumed ACK, then selected-token packet.
    /// A successful token decode alone can never complete an unconsumed request.
    mutating func acceptFirstToken(_ data: Data) throws -> QwenLayerStagePrefillFirstTokenWirePacket {
        do {
            guard !isFailed, startAccepted, finalConsumedAccepted, selectedTokenID == nil, let finalBoundary else {
                throw ProbeError("Prefill first-token return is out of order or replayed")
            }
            let packet = try QwenLayerStagePrefillFirstTokenWirePacket.decode(data,
                expectedAgreement: agreement, finalBoundary: finalBoundary)
            selectedTokenID = packet.tokenID
            return packet
        } catch { isFailed = true; throw error }
    }

    mutating func retire() { isFailed = true; finalBoundary = nil }
}

/// Rank one's one-shot permission to begin post-stop teardown. Its token packet
/// must already be prepared from actual validated selection evidence. The native
/// owner posts the receive after completing its token send; this owns no IO.
struct QwenLayerStagePrefillPostStopGate {
    let token: QwenLayerStagePrefillFirstTokenWirePacket
    private(set) var released = false
    private(set) var isFailed = false

    init(token: QwenLayerStagePrefillFirstTokenWirePacket) { self.token = token }

    mutating func accept(_ values: [Int32]) throws {
        do {
            guard !isFailed, !released else { throw ProbeError("Post-stop release is one-shot") }
            try QwenLayerStagePrefillPostStopAcknowledgement.validate(values, token: token)
            released = true
        } catch { isFailed = true; throw error }
    }

    mutating func retire() { isFailed = true }
}
