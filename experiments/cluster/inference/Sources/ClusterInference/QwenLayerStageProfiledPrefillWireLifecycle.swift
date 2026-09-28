import Foundation

/// Pure one-shot endpoint milestone admission, not IO or a per-frame frontier.
/// The native owner separately sequences every ready/received/consumed phase,
/// commits native state, fences failures and supplies the next expected frame.
struct QwenLayerStageProfiledPrefillWireLifecycle {
    let agreement: QwenLayerStageProfiledPrefillStartAgreement
    private(set) var startAccepted = false
    private(set) var acceptedStartFingerprint: String?
    private(set) var acceptedStartWireBytesSHA256: String?
    private(set) var finalConsumedAccepted = false
    private(set) var selectedTokenID: Int?
    private(set) var isFailed = false
    private var finalBoundary: QwenLayerStageProfiledPrefillBoundaryEnvelope?

    var firstTokenComplete: Bool { !isFailed && finalConsumedAccepted && selectedTokenID != nil }

    init(agreement: QwenLayerStageProfiledPrefillStartAgreement) { self.agreement = agreement }

    mutating func acceptStart(_ data: Data) throws -> QwenLayerStageProfiledPrefillStartWirePacket {
        do {
            guard !isFailed, !startAccepted else { throw ProbeError("Profiled start is one-shot") }
            let packet = try QwenLayerStageProfiledPrefillStartWirePacket.decode(data, expectedAgreement: agreement)
            startAccepted = true; acceptedStartFingerprint = packet.fingerprint
            acceptedStartWireBytesSHA256 = packet.wireBytesSHA256
            return packet
        } catch { isFailed = true; throw error }
    }

    mutating func bindFinalBoundary(_ envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope) throws {
        do {
            guard !isFailed, startAccepted, finalBoundary == nil else { throw ProbeError("Profiled final boundary is out of order or replayed") }
            try envelope.requireFinal(for: agreement)
            finalBoundary = envelope
        } catch { isFailed = true; throw error }
    }

    mutating func acceptFinalConsumed(_ values: [Int32]) throws {
        do {
            guard !isFailed, startAccepted, !finalConsumedAccepted, let finalBoundary else {
                throw ProbeError("Profiled final consumed ACK is out of order or replayed")
            }
            try QwenLayerStageProfiledPrefillBoundaryAcknowledgement.validate(values, envelope: finalBoundary, phase: .consumed)
            finalConsumedAccepted = true
        } catch { isFailed = true; throw error }
    }

    mutating func acceptFirstToken(_ data: Data) throws -> QwenLayerStageProfiledPrefillFirstTokenWirePacket {
        do {
            guard !isFailed, startAccepted, finalConsumedAccepted, selectedTokenID == nil, let finalBoundary else {
                throw ProbeError("Profiled token return requires a fresh completed final-consumed milestone")
            }
            let packet = try QwenLayerStageProfiledPrefillFirstTokenWirePacket.decode(data,
                expectedAgreement: agreement, finalBoundary: finalBoundary)
            selectedTokenID = packet.tokenID
            return packet
        } catch { isFailed = true; throw error }
    }

    mutating func retire() { isFailed = true; finalBoundary = nil }
}

struct QwenLayerStageProfiledPrefillPostStopGate {
    let token: QwenLayerStageProfiledPrefillFirstTokenWirePacket
    private(set) var released = false
    private(set) var isFailed = false

    init(token: QwenLayerStageProfiledPrefillFirstTokenWirePacket) { self.token = token }

    mutating func accept(_ values: [Int32]) throws {
        do {
            guard !isFailed, !released else { throw ProbeError("Profiled post-stop release is one-shot") }
            try QwenLayerStageProfiledPrefillPostStopAcknowledgement.validate(values, token: token)
            released = true
        } catch { isFailed = true; throw error }
    }

    mutating func retire() { isFailed = true }
}
