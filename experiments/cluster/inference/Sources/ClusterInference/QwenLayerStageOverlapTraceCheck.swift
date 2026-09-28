import Foundation

/// CPU-only event traces. A completed event is an assertion supplied by a
/// future native adapter; these checks do not claim transport or model parity.
enum QwenLayerStageOverlapTraceCheck {
    struct Result: Encodable {
        let ackCompletion: String
        let frameCount: Int
        let promptLookaheadCount: Int
        let maximumProducedMinusCompleted: Int
        let finalCommittedTokens: Int
    }

    static func run(plan: QwenLayerStageOverlapPlan, bufferedConsumedACK: Bool) throws -> Result {
        var sender = QwenLayerStageOverlapSender(plan: plan)
        var receiver = QwenLayerStageOverlapReceiver(plan: plan)
        var lookaheads = 0, maximumAhead = 0
        for frame in plan.frames {
            let ticket = try ticket(plan: plan, frame: frame)
            if sender.preparedFrame == nil {
                guard sender.nextAction == .prepare(frame) else { throw ProbeError("Trace lost its next preparation") }
                try sender.beginPreparation(frame)
                try sender.preparationCompleted(frame, committedTokens: end(frame))
            }
            guard sender.nextAction == .sendPrepared(frame) else { throw ProbeError("Trace lost its prepared output") }
            try deliver(ticket, sender: &sender, receiver: &receiver)
            try receiver.beginConsumption(ticket)
            if sender.canPrepareNext {
                let next = plan.frames[sender.producedFrames]
                guard next.phase == .prefill else { throw ProbeError("Trace admitted speculative decode") }
                try sender.beginPreparation(next)
                try completeConsumption(ticket, receiver: &receiver)
                if bufferedConsumedACK { try receiver.consumedACKSendCompleted(ticket) }
                try sender.preparationCompleted(next, committedTokens: end(next))
                guard sender.nextAction == .drainConsumed(ticket) else { throw ProbeError("Trace skipped consumed drain") }
                lookaheads += 1
                try validateCounters(sender, receiver)
                maximumAhead = max(maximumAhead, sender.producedFrames - sender.completedFrames)
                try sender.beginConsumedDrain(ticket)
                if !bufferedConsumedACK { try receiver.consumedACKSendCompleted(ticket) }
            } else {
                // Final prompt/decode frame drains immediately; the receiver
                // can finish native work while this synchronous receive waits.
                try sender.beginConsumedDrain(ticket)
                try completeConsumption(ticket, receiver: &receiver)
                try receiver.consumedACKSendCompleted(ticket)
                maximumAhead = max(maximumAhead, sender.producedFrames - sender.completedFrames)
            }
            try sender.consumedACKAccepted(ticket)
            try validateCounters(sender, receiver)
            guard sender.completedFrames == frame.sequence + 1,
                  receiver.completedFrames == frame.sequence + 1 else {
                throw ProbeError("Trace completion skipped or duplicated a frame")
            }
        }
        guard sender.nextAction == .close, receiver.nextAction == .close else {
            throw ProbeError("Trace did not require final drain before close")
        }
        try sender.close(); try receiver.close()
        guard sender.isClosed, receiver.isClosed, !sender.isFailed, !receiver.isFailed,
              sender.committedTokens == plan.finalCommittedTokens,
              receiver.committedTokens == plan.finalCommittedTokens else {
            throw ProbeError("Trace did not finish both exact frontiers")
        }
        return .init(ackCompletion: bufferedConsumedACK ? "buffered_before_peer_receive" : "blocked_until_peer_receive",
            frameCount: plan.frames.count, promptLookaheadCount: lookaheads,
            maximumProducedMinusCompleted: maximumAhead, finalCommittedTokens: sender.committedTokens)
    }

    static func ticket(plan: QwenLayerStageOverlapPlan, frame: QwenLayerStageFrame,
                       salt: String = "valid") throws -> QwenLayerStageOverlapTicket {
        try .init(flow: QwenLayerStageOverlapFlow.name, requestFingerprint: plan.requestFingerprint,
            frame: frame, headerSHA256: sha256(Data("pure-overlap-test-envelope|\(frame.sequence)|\(salt)".utf8)))
    }

    static func senderAfterReceived(plan: QwenLayerStageOverlapPlan,
                                    ticket: QwenLayerStageOverlapTicket,
                                    releaseSource: Bool) throws -> QwenLayerStageOverlapSender {
        var sender = QwenLayerStageOverlapSender(plan: plan)
        try sender.beginPreparation(ticket.frame)
        try sender.preparationCompleted(ticket.frame, committedTokens: end(ticket.frame))
        try sender.beginHeader(ticket); try sender.headerSendCompleted(ticket)
        try sender.readyACKAccepted(ticket); try sender.beginPayloadSend(ticket)
        try sender.payloadSendCompleted(ticket); try sender.receivedACKAccepted(ticket)
        if releaseSource { try sender.sentSourceReleased(ticket) }
        return sender
    }

    static func receiverAwaitingPayload(plan: QwenLayerStageOverlapPlan,
                                        ticket: QwenLayerStageOverlapTicket) throws -> QwenLayerStageOverlapReceiver {
        var receiver = QwenLayerStageOverlapReceiver(plan: plan)
        try receiver.beginHeaderReceive(); try receiver.headerValidated(ticket)
        try receiver.beginReadyACK(ticket); try receiver.readyACKSendCompleted(ticket)
        try receiver.beginPayloadReceive(ticket)
        return receiver
    }

    static func end(_ frame: QwenLayerStageFrame) -> Int { frame.tokenOffset + frame.tokenCount }

    private static func deliver(_ ticket: QwenLayerStageOverlapTicket,
                                sender: inout QwenLayerStageOverlapSender,
                                receiver: inout QwenLayerStageOverlapReceiver) throws {
        try sender.beginHeader(ticket); try receiver.beginHeaderReceive()
        try sender.headerSendCompleted(ticket); try receiver.headerValidated(ticket)
        try receiver.beginReadyACK(ticket); try sender.readyACKAccepted(ticket)
        try receiver.readyACKSendCompleted(ticket); try receiver.beginPayloadReceive(ticket)
        try sender.beginPayloadSend(ticket); try sender.payloadSendCompleted(ticket)
        try receiver.payloadReceivedAndValidated(ticket); try receiver.beginReceivedACK(ticket)
        try sender.receivedACKAccepted(ticket); try receiver.receivedACKSendCompleted(ticket)
        guard sender.nextAction == .releaseSentSource(ticket), receiver.nextAction == .consume(ticket) else {
            throw ProbeError("Trace lost its source-release or receiver-consumption boundary")
        }
        try sender.sentSourceReleased(ticket)
        try validateCounters(sender, receiver)
    }

    private static func completeConsumption(_ ticket: QwenLayerStageOverlapTicket,
                                           receiver: inout QwenLayerStageOverlapReceiver) throws {
        try receiver.consumptionAndCaptureCompleted(ticket, committedTokens: end(ticket.frame))
        try receiver.consumedBoundaryReleased(ticket); try receiver.beginConsumedACK(ticket)
    }

    private static func validateCounters(_ sender: QwenLayerStageOverlapSender,
                                         _ receiver: QwenLayerStageOverlapReceiver) throws {
        guard sender.completedFrames <= sender.receivedFrames,
              sender.receivedFrames <= sender.producedFrames,
              sender.receivedFrames - sender.completedFrames <= 1,
              sender.producedFrames - sender.receivedFrames <= 1,
              sender.producedFrames - sender.completedFrames <= 2,
              receiver.completedFrames <= receiver.committedFrames,
              receiver.committedFrames - receiver.completedFrames <= 1,
              receiver.committedFrames <= sender.receivedFrames else {
            throw ProbeError("Trace exceeded its one pending/one prepared frame bounds")
        }
    }
}
