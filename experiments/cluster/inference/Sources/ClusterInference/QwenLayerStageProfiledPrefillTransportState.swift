import Foundation

/// CPU-only ticket, issued by exactly one admitted native transport. It never
/// retains the producer array or a model/request state object.
struct QwenLayerStageProfiledPrefillBoundaryTicket {
    fileprivate let owner: UUID
    fileprivate let nonce = UUID()
    let envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope
    var frame: QwenLayerStageFrame { envelope.boundary.frame }
    var envelopeFingerprint: String { envelope.fingerprint }
    var envelopeWireBytesSHA256: String { envelope.wireBytesSHA256 }
    fileprivate init(owner: UUID, envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope) {
        self.owner = owner; self.envelope = envelope
    }
}

/// Private progress behind the native owner's single-entry operation guard.
/// Frame preparation remains the driver's policy; this admits only ordered IO.
final class QwenLayerStageProfiledPrefillTransportState {
    let rank: Int
    let agreement: QwenLayerStageProfiledPrefillStartAgreement
    private let owner = UUID()
    private var inOperation = false
    private var pending: QwenLayerStageProfiledPrefillBoundaryTicket?
    private var finalEnvelope: QwenLayerStageProfiledPrefillBoundaryEnvelope?
    private var finalToken: QwenLayerStageProfiledPrefillFirstTokenWirePacket?
    private(set) var isFailed = false
    private(set) var startCompleted = false
    private(set) var completedBoundaryCount = 0
    private(set) var tokenTransferCompleted = false
    private(set) var postStopReleaseCompleted = false

    var hasPendingConsumption: Bool { pending != nil }
    var isComplete: Bool { !isFailed && postStopReleaseCompleted && tokenTransferCompleted && allBoundariesCompleted }
    private var allBoundariesCompleted: Bool { pending == nil && completedBoundaryCount == agreement.request.steps.count }

    init(rank: Int, agreement: QwenLayerStageProfiledPrefillStartAgreement) { self.rank = rank; self.agreement = agreement }

    func beginOperation() throws {
        guard !isFailed, !inOperation else { retire(); throw ProbeError("Profiled prefill transport is retired or entered recursively") }
        inOperation = true
    }
    func endOperation() { inOperation = false }
    func requireActive() throws {
        guard !isFailed else { throw ProbeError("Profiled prefill transport was retired during its operation") }
    }
    func retire() { isFailed = true; pending = nil; finalEnvelope = nil; finalToken = nil }

    func requireStart(rank expectedRank: Int) throws {
        try requireActive()
        guard rank == expectedRank, !startCompleted, completedBoundaryCount == 0 else {
            throw ProbeError("Profiled prefill start is out of role/order or replayed")
        }
    }
    func completeStart(_ packet: QwenLayerStageProfiledPrefillStartWirePacket) throws {
        try requireActive()
        guard !startCompleted, packet.agreementFingerprint == agreement.fingerprint else { throw ProbeError("Profiled prefill start agreement changed") }
        startCompleted = true
    }

    func requireFrame(_ frame: QwenLayerStageFrame, rank expectedRank: Int) throws {
        try requireActive()
        guard rank == expectedRank, startCompleted, pending == nil,
              agreement.request.steps.indices.contains(completedBoundaryCount),
              agreement.request.steps[completedBoundaryCount].frame == frame else {
            throw ProbeError("Profiled prefill boundary is out of role/order or has an undrained predecessor")
        }
    }
    func ticket(_ envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope) throws -> QwenLayerStageProfiledPrefillBoundaryTicket {
        try requireActive()
        guard envelope.agreementFingerprint == agreement.fingerprint else { throw ProbeError("Profiled prefill envelope changed agreement") }
        return .init(owner: owner, envelope: envelope)
    }
    func senderReceived(_ ticket: QwenLayerStageProfiledPrefillBoundaryTicket) throws {
        try requireFrame(ticket.frame, rank: 0)
        guard ticket.owner == owner else { throw ProbeError("Profiled prefill received ticket has a different owner") }
        pending = ticket
    }
    func requirePending(_ ticket: QwenLayerStageProfiledPrefillBoundaryTicket) throws {
        try requireActive()
        guard rank == 0, let current = pending, current.owner == owner, ticket.owner == owner,
              current.nonce == ticket.nonce, current.envelope.encoded() == ticket.envelope.encoded() else {
            throw ProbeError("Profiled prefill consumed ticket is stale or belongs to another transport")
        }
    }
    func senderConsumed(_ ticket: QwenLayerStageProfiledPrefillBoundaryTicket) throws {
        try requirePending(ticket)
        pending = nil; completedBoundaryCount += 1
        if ticket.frame.finalPromptChunk { finalEnvelope = ticket.envelope }
    }
    func receiverConsumed(_ ticket: QwenLayerStageProfiledPrefillBoundaryTicket,
                          token: QwenLayerStageProfiledPrefillFirstTokenWirePacket?) throws {
        try requireFrame(ticket.frame, rank: 1)
        guard ticket.owner == owner, (token != nil) == ticket.frame.finalPromptChunk else {
            throw ProbeError("Profiled prefill receiver commit lost its owner or final token")
        }
        if let token {
            guard token.agreementFingerprint == agreement.fingerprint,
                  token.finalBoundaryEnvelopeFingerprint == ticket.envelopeFingerprint,
                  token.finalBoundaryWireBytesSHA256 == ticket.envelopeWireBytesSHA256 else {
                throw ProbeError("Prepared profiled token has a different final boundary or raw byte hash")
            }
            finalEnvelope = ticket.envelope; finalToken = token
        }
        completedBoundaryCount += 1
    }

    func requireTokenTransfer(rank expectedRank: Int) throws -> QwenLayerStageProfiledPrefillBoundaryEnvelope {
        try requireActive()
        guard rank == expectedRank, startCompleted, allBoundariesCompleted,
              !tokenTransferCompleted, let finalEnvelope else {
            throw ProbeError("Profiled prefill token transfer requires drained final consumption and is one-shot")
        }
        return finalEnvelope
    }
    func tokenForSend() throws -> QwenLayerStageProfiledPrefillFirstTokenWirePacket {
        _ = try requireTokenTransfer(rank: 1)
        guard let finalToken else { throw ProbeError("Final selection was not prepared before consumed ACK") }
        return finalToken
    }
    func completeToken(_ token: QwenLayerStageProfiledPrefillFirstTokenWirePacket) throws {
        let envelope = try requireTokenTransfer(rank: rank)
        guard token.agreementFingerprint == agreement.fingerprint,
              token.finalBoundaryEnvelopeFingerprint == envelope.fingerprint,
              token.finalBoundaryWireBytesSHA256 == envelope.wireBytesSHA256 else {
            throw ProbeError("Transferred profiled token changed its agreement, envelope or raw byte hash")
        }
        finalToken = token; tokenTransferCompleted = true
    }
    func requirePostStop(rank expectedRank: Int) throws -> QwenLayerStageProfiledPrefillFirstTokenWirePacket {
        try requireActive()
        guard rank == expectedRank, allBoundariesCompleted, tokenTransferCompleted,
              !postStopReleaseCompleted, let finalToken else {
            throw ProbeError("Post-stop release requires a completed token transfer and is one-shot")
        }
        return finalToken
    }
    func completePostStop() throws {
        _ = try requirePostStop(rank: rank)
        postStopReleaseCompleted = true
    }
}
