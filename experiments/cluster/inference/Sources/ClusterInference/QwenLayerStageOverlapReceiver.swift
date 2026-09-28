import Foundation

/// Pure rank-one sequencing. Header, payload and ACK completion may block; this
/// machine requires only the local single-caller order, never eager buffering.
struct QwenLayerStageOverlapReceiver {
    enum Activity: String {
        case waitingHeader, receivingHeader, readyForReadyACK, sendingReadyACK
        case readyForPayload, receivingPayload, readyForReceivedACK, sendingReceivedACK
        case readyToConsume, consuming, consumedNeedsRelease, readyForConsumedACK
        case sendingConsumedACK, closed, failed
    }

    enum NextAction: Equatable {
        case receiveHeader, sendReadyACK(QwenLayerStageOverlapTicket)
        case receivePayload(QwenLayerStageOverlapTicket), sendReceivedACK(QwenLayerStageOverlapTicket)
        case consume(QwenLayerStageOverlapTicket), releaseBoundary(QwenLayerStageOverlapTicket)
        case sendConsumedACK(QwenLayerStageOverlapTicket), close, inProgress, unavailable
    }

    let plan: QwenLayerStageOverlapPlan
    private(set) var activity: Activity = .waitingHeader
    private(set) var committedFrames = 0
    private(set) var completedFrames = 0
    private(set) var ownsBoundary = false
    private(set) var current: QwenLayerStageOverlapTicket?

    init(plan: QwenLayerStageOverlapPlan) { self.plan = plan }

    var isFailed: Bool { activity == .failed }
    var isClosed: Bool { activity == .closed }
    var committedTokens: Int { plan.committedTokens(after: committedFrames) }

    var nextAction: NextAction {
        if activity == .waitingHeader { return completedFrames == plan.frames.count ? .close : .receiveHeader }
        guard !isFailed && !isClosed else { return .unavailable }
        guard let ticket = current else { return .inProgress }
        switch activity {
        case .readyForReadyACK: return .sendReadyACK(ticket)
        case .readyForPayload: return .receivePayload(ticket)
        case .readyForReceivedACK: return .sendReceivedACK(ticket)
        case .readyToConsume: return .consume(ticket)
        case .consumedNeedsRelease: return .releaseBoundary(ticket)
        case .readyForConsumedACK: return .sendConsumedACK(ticket)
        default: return .inProgress
        }
    }

    mutating func beginHeaderReceive() throws {
        try require(activity == .waitingHeader && !ownsBoundary && current == nil
            && completedFrames == committedFrames && plan.frames.indices.contains(committedFrames),
            "Receiver accepted another header before prior consumption, release and ACK completion")
        activity = .receivingHeader
    }

    /// Envelope flow/version, source identity, tokens and local geometry must
    /// already be validated. No payload allocation precedes this transition.
    mutating func headerValidated(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .receivingHeader && plan.matches(ticket, at: committedFrames),
                    "Receiver header differs from its exact next local frame")
        current = ticket; activity = .readyForReadyACK
    }

    mutating func beginReadyACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForReadyACK && current == ticket, "Ready ACK is out of order")
        activity = .sendingReadyACK
    }

    mutating func readyACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingReadyACK && current == ticket, "Ready ACK completion is out of order")
        activity = .readyForPayload
    }

    mutating func beginPayloadReceive(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForPayload && current == ticket && !ownsBoundary,
                    "Payload receive lacks ready ACK completion or an empty owner slot")
        activity = .receivingPayload
    }

    /// Recv completion + native unique/compact/zero-offset ownership, shape,
    /// dtype, logical bytes and payload SHA checks must all have succeeded.
    mutating func payloadReceivedAndValidated(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .receivingPayload && current == ticket && !ownsBoundary,
                    "Received payload is not the active validated boundary")
        ownsBoundary = true; activity = .readyForReceivedACK
    }

    mutating func beginReceivedACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForReceivedACK && current == ticket && ownsBoundary,
                    "Received ACK precedes ownership and payload validation")
        activity = .sendingReceivedACK
    }

    mutating func receivedACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingReceivedACK && current == ticket, "Received ACK completion is out of order")
        activity = .readyToConsume
    }

    mutating func beginConsumption(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyToConsume && current == ticket && ownsBoundary,
                    "Stage-one compute precedes completed received ACK")
        activity = .consuming
    }

    /// This is the end of the entire existing consume callback: native output
    /// and state roots commit, snapshot/logits copy, and throwing CPU observer.
    mutating func consumptionAndCaptureCompleted(_ ticket: QwenLayerStageOverlapTicket,
                                                 committedTokens: Int) throws {
        try require(activity == .consuming && current == ticket
            && committedTokens == ticket.frame.tokenOffset + ticket.frame.tokenCount,
            "Stage-one consumption/capture has the wrong committed frontier")
        committedFrames += 1; activity = .consumedNeedsRelease
    }

    mutating func consumedBoundaryReleased(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .consumedNeedsRelease && current == ticket && ownsBoundary,
                    "Receiver boundary release precedes committed consumption and capture")
        ownsBoundary = false; activity = .readyForConsumedACK
    }

    mutating func beginConsumedACK(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForConsumedACK && current == ticket && !ownsBoundary,
                    "Consumed ACK precedes local commit/capture or retains the explicit boundary")
        activity = .sendingConsumedACK
    }

    mutating func consumedACKSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingConsumedACK && current == ticket,
                    "Consumed ACK completion is out of order")
        completedFrames += 1; current = nil; activity = .waitingHeader
    }

    mutating func close() throws {
        if isClosed { return }
        try require(activity == .waitingHeader && completedFrames == plan.frames.count
            && committedFrames == completedFrames && !ownsBoundary && current == nil,
            "Receiver closed before final committed consumption, release and ACK completion")
        activity = .closed
    }

    /// Pure retirement never claims that native cleanup or peer exit completed.
    mutating func retire() { activity = .failed; ownsBoundary = false; current = nil }

    private mutating func require(_ condition: Bool, _ reason: String) throws {
        guard condition && !isClosed && !isFailed else {
            retire(); throw ProbeError(reason)
        }
    }
}
