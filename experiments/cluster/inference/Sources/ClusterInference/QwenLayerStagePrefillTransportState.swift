import Foundation

/// CPU-only ticket, issued by exactly one admitted native transport. It never
/// retains the producer array or a model/request state object.
struct QwenLayerStagePrefillBoundaryTicket {
    fileprivate let owner: UUID
    fileprivate let nonce = UUID()
    let envelope: QwenLayerStagePrefillBoundaryEnvelope
    var frame: QwenLayerStageFrame { envelope.boundary.frame }
    var headerSHA256: String { envelope.fingerprint }
    fileprivate init(owner: UUID, envelope: QwenLayerStagePrefillBoundaryEnvelope) {
        self.owner = owner; self.envelope = envelope
    }
}

/// Private progress behind the native owner's single-entry operation guard.
/// Frame preparation remains the driver's policy; this admits only ordered IO.
final class QwenLayerStagePrefillTransportState {
    let rank: Int
    let agreement: QwenLayerStagePrefillStartAgreement
    private let owner = UUID()
    private var inOperation = false
    private var pending: QwenLayerStagePrefillBoundaryTicket?
    private var finalEnvelope: QwenLayerStagePrefillBoundaryEnvelope?
    private var finalToken: QwenLayerStagePrefillFirstTokenWirePacket?
    private(set) var isFailed = false
    private(set) var startCompleted = false
    private(set) var completedBoundaryCount = 0
    private(set) var tokenTransferCompleted = false
    private(set) var postStopReleaseCompleted = false

    var hasPendingConsumption: Bool { pending != nil }
    var isComplete: Bool { !isFailed && postStopReleaseCompleted && tokenTransferCompleted && allBoundariesCompleted }
    private var allBoundariesCompleted: Bool { pending == nil && completedBoundaryCount == agreement.request.steps.count }

    init(rank: Int, agreement: QwenLayerStagePrefillStartAgreement) { self.rank = rank; self.agreement = agreement }

    func beginOperation() throws {
        guard !isFailed, !inOperation else { retire(); throw ProbeError("Prefill transport is retired or entered recursively") }
        inOperation = true
    }
    func endOperation() { inOperation = false }
    func requireActive() throws {
        guard !isFailed else { throw ProbeError("Prefill transport was retired during its operation") }
    }
    func retire() { isFailed = true; pending = nil; finalEnvelope = nil; finalToken = nil }

    func requireStart(rank expectedRank: Int) throws {
        try requireActive()
        guard rank == expectedRank, !startCompleted, completedBoundaryCount == 0 else {
            throw ProbeError("Prefill start is out of role/order or replayed")
        }
    }
    func completeStart(_ packet: QwenLayerStagePrefillStartWirePacket) throws {
        try requireActive()
        guard !startCompleted, packet.agreementFingerprint == agreement.fingerprint else { throw ProbeError("Prefill start agreement changed") }
        startCompleted = true
    }

    func requireFrame(_ frame: QwenLayerStageFrame, rank expectedRank: Int) throws {
        try requireActive()
        guard rank == expectedRank, startCompleted, pending == nil,
              agreement.request.steps.indices.contains(completedBoundaryCount),
              agreement.request.steps[completedBoundaryCount].frame == frame else {
            throw ProbeError("Prefill boundary is out of role/order or has an undrained predecessor")
        }
    }
    func ticket(_ envelope: QwenLayerStagePrefillBoundaryEnvelope) throws -> QwenLayerStagePrefillBoundaryTicket {
        try requireActive()
        guard envelope.agreementFingerprint == agreement.fingerprint else { throw ProbeError("Prefill envelope changed agreement") }
        return .init(owner: owner, envelope: envelope)
    }
    func senderReceived(_ ticket: QwenLayerStagePrefillBoundaryTicket) throws {
        try requireFrame(ticket.frame, rank: 0)
        guard ticket.owner == owner else { throw ProbeError("Prefill received ticket has a different owner") }
        pending = ticket
    }
    func requirePending(_ ticket: QwenLayerStagePrefillBoundaryTicket) throws {
        try requireActive()
        guard rank == 0, let current = pending, current.owner == owner, ticket.owner == owner,
              current.nonce == ticket.nonce, current.envelope.encoded() == ticket.envelope.encoded() else {
            throw ProbeError("Prefill consumed ticket is stale or belongs to another transport")
        }
    }
    func senderConsumed(_ ticket: QwenLayerStagePrefillBoundaryTicket) throws {
        try requirePending(ticket)
        pending = nil; completedBoundaryCount += 1
        if ticket.frame.finalPromptChunk { finalEnvelope = ticket.envelope }
    }
    func receiverConsumed(_ ticket: QwenLayerStagePrefillBoundaryTicket,
                          token: QwenLayerStagePrefillFirstTokenWirePacket?) throws {
        try requireFrame(ticket.frame, rank: 1)
        guard ticket.owner == owner, (token != nil) == ticket.frame.finalPromptChunk else {
            throw ProbeError("Prefill receiver commit lost its owner or final token")
        }
        if let token {
            guard token.agreementFingerprint == agreement.fingerprint,
                  token.finalBoundaryEnvelopeSHA256 == ticket.headerSHA256 else { throw ProbeError("Prepared token has a different final boundary") }
            finalEnvelope = ticket.envelope; finalToken = token
        }
        completedBoundaryCount += 1
    }

    func requireTokenTransfer(rank expectedRank: Int) throws -> QwenLayerStagePrefillBoundaryEnvelope {
        try requireActive()
        guard rank == expectedRank, startCompleted, allBoundariesCompleted,
              !tokenTransferCompleted, let finalEnvelope else {
            throw ProbeError("Prefill token transfer requires drained final consumption and is one-shot")
        }
        return finalEnvelope
    }
    func tokenForSend() throws -> QwenLayerStagePrefillFirstTokenWirePacket {
        _ = try requireTokenTransfer(rank: 1)
        guard let finalToken else { throw ProbeError("Final selection was not prepared before consumed ACK") }
        return finalToken
    }
    func completeToken(_ token: QwenLayerStagePrefillFirstTokenWirePacket) throws {
        let envelope = try requireTokenTransfer(rank: rank)
        guard token.agreementFingerprint == agreement.fingerprint,
              token.finalBoundaryEnvelopeSHA256 == envelope.fingerprint else { throw ProbeError("Transferred token changed its agreement or envelope") }
        finalToken = token; tokenTransferCompleted = true
    }
    func requirePostStop(rank expectedRank: Int) throws -> QwenLayerStagePrefillFirstTokenWirePacket {
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
