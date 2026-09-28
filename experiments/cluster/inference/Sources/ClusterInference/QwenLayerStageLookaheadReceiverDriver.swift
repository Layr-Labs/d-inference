import Foundation

/// Rank one consumes one boundary at a time. The transport owns its native
/// receive scope; this owner receives and retains only typed CPU captures.
final class QwenLayerStageLookaheadReceiverDriver {
    private let context: QwenLayerStageLookaheadContext
    private let transport: QwenLayerStageLookaheadTransport
    private let request: QwenLayerStageRecordedRequest
    private let plan: QwenLayerStageOverlapPlan
    private let trace: QwenLayerStageLookaheadActionTrace
    private var machine: QwenLayerStageOverlapReceiver
    private var frameTicket: QwenLayerStageOverlapTicket?
    private var releasedOriginalArrayHandles = 0
    private var completions: [QwenLayerStageRankFrameCompletion] = []

    init(context: QwenLayerStageLookaheadContext, transport: QwenLayerStageLookaheadTransport,
         request: QwenLayerStageRecordedRequest, plan: QwenLayerStageOverlapPlan) throws {
        guard context.identity.stageIndex == 1, plan.frames == request.steps.map(\.frame) else {
            throw ProbeError("Lookahead receiver requires stage one and the exact admitted timeline")
        }
        self.context = context; self.transport = transport; self.request = request; self.plan = plan
        machine = .init(plan: plan); trace = try .init(frameCount: plan.frames.count)
    }

    func run(check: () throws -> Void) throws -> QwenLayerStageLookaheadRequestResult {
        for step in request.steps {
            try requireActive(check: check)
            guard machine.nextAction == .receiveHeader, frameTicket == nil,
                  machine.completedFrames == step.frame.sequence,
                  context.committedTokens == step.frame.tokenOffset else {
                throw ProbeError("Lookahead receiver lost its next header or local frontier")
            }
            let expected = try context.expectation(for: step)
            let received = try transport.receiveAndConsume(expected: expected, consume: { boundary in
                let capture = try self.context.consume(step, boundary: boundary,
                    check: { try self.requireActive(check: check) })
                try QwenLayerStageLookaheadDriverSupport.requireCapture(capture, step: step, identity: self.context.identity)
                try self.requireActive(check: check)
                return capture
            }, onPhase: { try self.apply($0, ticket: $1) }, check: { try self.requireActive(check: check) })
            guard let ticket = frameTicket, ticket.frame == step.frame,
                  received.headerSHA256 == ticket.headerSHA256,
                  machine.completedFrames == step.frame.sequence + 1,
                  completions.count == step.frame.sequence,
                  context.committedTokens == step.committedTokens else {
                throw ProbeError("Lookahead receiver completion differs from its received envelope or native frontier")
            }
            completions.append(.init(capture: received.value, headerSHA256: received.headerSHA256,
                                    completedTransportPhase: "consumed_ack_send_completed"))
            frameTicket = nil
            try record("frameCompletion", frame: step.frame, ticket: ticket)
        }
        return try finish(check: check)
    }

    private func apply(_ phase: QwenLayerStageLookaheadReceivePhase,
                       ticket: QwenLayerStageOverlapTicket?) throws {
        if case .beginHeaderReceive = phase {
            guard ticket == nil, frameTicket == nil else { throw ProbeError("Lookahead receiver reused a header ticket") }
            try machine.beginHeaderReceive(); try record("receive.beginHeaderReceive", frame: nil)
            return
        }
        guard let ticket else { throw ProbeError("Lookahead receive phase lacks its validated envelope ticket") }
        switch phase {
        case .beginHeaderReceive: throw ProbeError("Lookahead header receive phase was repeated")
        case .headerValidated:
            guard frameTicket == nil else { throw ProbeError("Lookahead receiver replaced an active envelope") }
            try machine.headerValidated(ticket); frameTicket = ticket
        case .beginReadyACK: try machine.beginReadyACK(ticket)
        case .readyACKSendCompleted: try machine.readyACKSendCompleted(ticket)
        case .beginPayloadReceive: try machine.beginPayloadReceive(ticket)
        case .payloadReceivedAndValidated: try machine.payloadReceivedAndValidated(ticket)
        case .beginReceivedACK: try machine.beginReceivedACK(ticket)
        case .receivedACKSendCompleted: try machine.receivedACKSendCompleted(ticket)
        case .beginConsumption: try machine.beginConsumption(ticket)
        case .consumptionAndCaptureCompleted:
            try machine.consumptionAndCaptureCompleted(ticket, committedTokens: context.committedTokens)
        case .consumedBoundaryReleased:
            try machine.consumedBoundaryReleased(ticket); releasedOriginalArrayHandles += 1
        case .beginConsumedACK: try machine.beginConsumedACK(ticket)
        case .consumedACKSendCompleted: try machine.consumedACKSendCompleted(ticket)
        }
        try record("receive.\(String(describing: phase))", frame: ticket.frame, ticket: ticket)
    }

    private func finish(check: () throws -> Void) throws -> QwenLayerStageLookaheadRequestResult {
        try requireActive(check: check)
        guard machine.nextAction == .close, frameTicket == nil,
              completions.count == request.steps.count, releasedOriginalArrayHandles == request.steps.count,
              context.committedTokens == plan.finalCommittedTokens else {
            throw ProbeError("Lookahead receiver closed before its final consumed ACK and array release")
        }
        try context.close(); try check()
        guard context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead receiver request state did not retire cleanly")
        }
        try machine.close(); try record("requestClosed", frame: nil)
        return .init(identity: context.identity, recordedRequestFingerprint: request.fingerprint,
            decodeAdmission: plan.decodeAdmission.rawValue, completions: completions, actions: trace.records,
            finalCommittedTokens: context.committedTokens, completedFrames: machine.completedFrames,
            producedFrames: nil, receivedFrames: nil, promptLookaheadCount: nil,
            maximumProducedMinusReceived: nil, maximumReceivedMinusCompleted: nil,
            maximumProducedMinusCompleted: nil,
            maximumExplicitNativeBoundarySlots: trace.maximumExplicitNativeBoundarySlots,
            releasedOriginalArrayHandles: releasedOriginalArrayHandles, allRequestStateRetired: true)
    }

    private func record(_ action: String, frame: QwenLayerStageFrame?, ticket: QwenLayerStageOverlapTicket? = nil) throws {
        try trace.receiver(action, frame: frame, ticket: ticket, machine: machine,
                           nativeCommittedTokens: context.committedTokens)
    }

    private func requireActive(check: () throws -> Void) throws {
        guard !machine.isClosed, !machine.isFailed, !context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead receiver was retired during an action")
        }
        try check()
        guard !machine.isClosed, !machine.isFailed, !context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead receiver was retired by a check callback")
        }
    }

    func retire() { frameTicket = nil; machine.retire() }
}
