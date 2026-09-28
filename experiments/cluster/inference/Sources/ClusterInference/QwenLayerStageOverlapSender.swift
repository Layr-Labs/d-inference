import Foundation

/// Pure rank-zero sequencing. Each begin/completed pair brackets a synchronous
/// native or wire operation; no other operation may run inside that interval.
/// Event names assert completed work; they do not execute or prove that work.
struct QwenLayerStageOverlapSender {
    enum Activity: String {
        case idle, preparing, sendingHeader, awaitingReady, readyForPayload
        case sendingPayload, awaitingReceived, drainingConsumed, closed, failed
    }

    enum NextAction: Equatable {
        case prepare(QwenLayerStageFrame), sendPrepared(QwenLayerStageFrame)
        case releaseSentSource(QwenLayerStageOverlapTicket), drainConsumed(QwenLayerStageOverlapTicket)
        case close, inProgress, unavailable
    }

    let plan: QwenLayerStageOverlapPlan
    private(set) var activity: Activity = .idle
    private(set) var producedFrames = 0
    private(set) var receivedFrames = 0
    private(set) var completedFrames = 0
    private(set) var preparedFrame: QwenLayerStageFrame?
    private(set) var pendingConsumed: QwenLayerStageOverlapTicket?
    private(set) var sourceReleaseRequired = false
    private var preparingFrame: QwenLayerStageFrame?
    private var transmitting: QwenLayerStageOverlapTicket?

    init(plan: QwenLayerStageOverlapPlan) { self.plan = plan }

    var isFailed: Bool { activity == .failed }
    var isClosed: Bool { activity == .closed }
    var committedTokens: Int { plan.committedTokens(after: producedFrames) }
    var peerAcknowledgedTokens: Int { plan.committedTokens(after: completedFrames) }

    var canPrepareNext: Bool {
        activity == .idle && preparedFrame == nil && !sourceReleaseRequired
            && plan.allowsPreparation(at: producedFrames, withPendingConsumedACK: pendingConsumed != nil)
    }

    var nextAction: NextAction {
        guard activity == .idle else { return isClosed || isFailed ? .unavailable : .inProgress }
        if let ticket = pendingConsumed {
            if sourceReleaseRequired { return .releaseSentSource(ticket) }
            if canPrepareNext { return .prepare(plan.frames[producedFrames]) }
            return .drainConsumed(ticket)
        }
        if let frame = preparedFrame { return .sendPrepared(frame) }
        if canPrepareNext { return .prepare(plan.frames[producedFrames]) }
        return completedFrames == plan.frames.count ? .close : .unavailable
    }

    mutating func beginPreparation(_ frame: QwenLayerStageFrame) throws {
        try require(canPrepareNext && plan.frames[producedFrames] == frame,
                    "Preparation violates prompt-only lookahead or the single prepared slot")
        preparingFrame = frame; activity = .preparing
    }

    /// Call only after output + all native state roots commit, CPU capture and
    /// the throwing observer succeed. A failed callback retires the cohort.
    mutating func preparationCompleted(_ frame: QwenLayerStageFrame, committedTokens: Int) throws {
        try require(activity == .preparing && preparingFrame == frame
            && committedTokens == frame.tokenOffset + frame.tokenCount,
            "Prepared output does not match its evaluated local frontier")
        preparedFrame = frame; preparingFrame = nil; producedFrames += 1; activity = .idle
    }

    mutating func beginHeader(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && pendingConsumed == nil && !sourceReleaseRequired
            && preparedFrame == ticket.frame && plan.matches(ticket, at: completedFrames),
            "Next header requires the previous consumed ACK and exactly its prepared output")
        transmitting = ticket; activity = .sendingHeader
    }

    mutating func headerSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingHeader && transmitting == ticket,
                    "Header send completion is out of order")
        activity = .awaitingReady
    }

    mutating func readyACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .awaitingReady && transmitting == ticket,
                    "Ready ACK differs from the active envelope")
        activity = .readyForPayload
    }

    mutating func beginPayloadSend(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .readyForPayload && transmitting == ticket,
                    "Payload send lacks its validated ready ACK")
        activity = .sendingPayload
    }

    mutating func payloadSendCompleted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .sendingPayload && transmitting == ticket,
                    "Payload send completion is out of order")
        activity = .awaitingReceived
    }

    mutating func receivedACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .awaitingReceived && transmitting == ticket && pendingConsumed == nil,
                    "Received ACK differs from the single transmitted envelope")
        pendingConsumed = ticket; transmitting = nil; preparedFrame = nil
        sourceReleaseRequired = true; receivedFrames += 1; activity = .idle
    }

    /// The native owner must actually drop its boundary, output enum, Send
    /// handle, aliases and enclosing autorelease scope before calling this.
    mutating func sentSourceReleased(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && sourceReleaseRequired && pendingConsumed == ticket,
                    "Source release lacks completed payload send and received ACK")
        sourceReleaseRequired = false
    }

    mutating func beginConsumedDrain(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .idle && !sourceReleaseRequired && pendingConsumed == ticket,
                    "Consumed ACK drain overlaps preparation or lacks its pending envelope")
        activity = .drainingConsumed
    }

    /// Saved completion uses this ticket's capture, not the live native frontier:
    /// stage zero may already have committed the next prompt chunk at this point.
    mutating func consumedACKAccepted(_ ticket: QwenLayerStageOverlapTicket) throws {
        try require(activity == .drainingConsumed && pendingConsumed == ticket,
                    "Consumed ACK differs from the pending envelope")
        completedFrames += 1; pendingConsumed = nil; activity = .idle
    }

    mutating func close() throws {
        if isClosed { return }
        try require(activity == .idle && completedFrames == plan.frames.count
            && producedFrames == completedFrames && receivedFrames == completedFrames
            && preparedFrame == nil && pendingConsumed == nil && !sourceReleaseRequired,
            "Sender closed before its final consumed ACK and residual release")
        activity = .closed
    }

    /// Fences bookkeeping only. The native owner must drop arrays, cancel its
    /// request, retire transport, and ask the parent to fence the peer process.
    mutating func retire() {
        activity = .failed; preparedFrame = nil; preparingFrame = nil
        transmitting = nil; pendingConsumed = nil; sourceReleaseRequired = false
    }

    private mutating func require(_ condition: Bool, _ reason: String) throws {
        guard condition && !isClosed && !isFailed else {
            retire(); throw ProbeError(reason)
        }
    }
}
