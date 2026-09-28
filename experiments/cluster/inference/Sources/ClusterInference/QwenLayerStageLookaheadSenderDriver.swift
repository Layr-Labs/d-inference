import Foundation
import MLX

/// Native producer ownership. The pending value contains CPU metadata only;
/// the sole native output lives either in prepared or the dispatch scope.
final class QwenLayerStageLookaheadSenderDriver {
    private struct Pending {
        let ticket: QwenLayerStageLookaheadTicket
        let capture: QwenLayerStageRankFrameCapture
    }

    private let context: QwenLayerStageLookaheadContext
    private let transport: QwenLayerStageLookaheadTransport
    private let request: QwenLayerStageRecordedRequest
    private let plan: QwenLayerStageOverlapPlan
    private let trace: QwenLayerStageLookaheadActionTrace
    private var machine: QwenLayerStageOverlapSender
    private var prepared: QwenLayerStageLookaheadPreparedFrame?
    private var pending: Pending?
    private var ownsNativeBoundary = false
    private var promptLookaheadCount = 0
    private var releasedOriginalArrayHandles = 0
    private var completions: [QwenLayerStageRankFrameCompletion] = []

    init(context: QwenLayerStageLookaheadContext, transport: QwenLayerStageLookaheadTransport,
         request: QwenLayerStageRecordedRequest, plan: QwenLayerStageOverlapPlan) throws {
        guard context.identity.stageIndex == 0, plan.frames == request.steps.map(\.frame) else {
            throw ProbeError("Lookahead sender requires stage zero and the exact admitted timeline")
        }
        self.context = context; self.transport = transport; self.request = request; self.plan = plan
        machine = .init(plan: plan); trace = try .init(frameCount: plan.frames.count)
    }

    func run(check: () throws -> Void) throws -> QwenLayerStageLookaheadRequestResult {
        var actions = 0
        while true {
            try requireActive(check: check)
            actions += 1
            guard actions <= 4 * plan.frames.count + 4 else { throw ProbeError("Lookahead sender action bound exceeded") }
            switch machine.nextAction {
            case .prepare(let frame): try prepare(frame, check: check)
            case .sendPrepared(let frame): try dispatch(frame, check: check)
            case .drainConsumed(let ticket): try finishConsumed(ticket, check: check)
            case .close: return try finish(check: check)
            default: throw ProbeError("Lookahead sender lost its synchronous next action or source release")
            }
        }
    }

    private func prepare(_ frame: QwenLayerStageFrame, check: () throws -> Void) throws {
        guard prepared == nil, !ownsNativeBoundary, context.committedTokens == machine.committedTokens,
              request.steps.indices.contains(frame.sequence) else {
            throw ProbeError("Lookahead preparation lacks an empty native slot or matching local frontier")
        }
        let step = request.steps[frame.sequence], isLookahead = machine.pendingConsumed != nil
        try machine.beginPreparation(frame)
        try record("beginPreparation", frame: frame)
        let value = try autoreleasepool {
            try context.prepare(step, check: { try self.requireActive(check: check) })
        }
        try requireActive(check: check)
        try QwenLayerStageLookaheadDriverSupport.requireCapture(value.capture, step: step, identity: context.identity)
        guard context.committedTokens == step.committedTokens else { throw ProbeError("Prepared native frontier differs") }
        prepared = value; ownsNativeBoundary = true
        try machine.preparationCompleted(frame, committedTokens: context.committedTokens)
        if isLookahead {
            guard frame.phase == .prefill else { throw ProbeError("Lookahead driver attempted speculative decode") }
            promptLookaheadCount += 1
        }
        try record("preparationCompleted", frame: frame)
    }

    private func dispatch(_ frame: QwenLayerStageFrame, check: () throws -> Void) throws {
        guard pending == nil, !transport.hasPendingConsumption, ownsNativeBoundary,
              prepared?.capture.frame == frame, context.committedTokens == machine.committedTokens else {
            throw ProbeError("Lookahead dispatch lacks its sole prepared output or prior consumed completion")
        }
        weak var sentHandle: MLXArray?
        let delivered: Pending = try autoreleasepool {
            guard let value = prepared else { throw ProbeError("Lookahead prepared native slot disappeared") }
            sentHandle = value.boundary.array
            prepared = nil
            let ticket = try transport.sendUntilReceived(value.boundary, expected: value.expectation,
                onPhase: { try self.apply($0, ticket: $1) },
                check: { try self.requireActive(check: check) })
            try QwenLayerStageLookaheadDriverSupport.requireSentCapture(value.capture, ticket: ticket)
            return Pending(ticket: ticket, capture: value.capture)
        }
        // The weak check concerns the original MLXArray wrapper only. It does
        // not assert physical allocation uniqueness or exclude native aliases.
        guard sentHandle == nil else { throw ProbeError("Lookahead sender retained its dispatched array handle") }
        ownsNativeBoundary = false; pending = delivered
        try machine.sentSourceReleased(delivered.ticket.scheduleTicket)
        releasedOriginalArrayHandles += 1
        try record("sentSourceReleased", frame: frame, ticket: delivered.ticket.scheduleTicket)
        try requireActive(check: check)
    }

    private func finishConsumed(_ ticket: QwenLayerStageOverlapTicket, check: () throws -> Void) throws {
        guard let saved = pending, saved.ticket.scheduleTicket == ticket,
              context.committedTokens == machine.committedTokens else {
            throw ProbeError("Lookahead completion lacks its old CPU capture or current produced frontier")
        }
        try transport.finishConsumed(saved.ticket, onPhase: { try self.apply($0, ticket: $1) },
                                     check: { try self.requireActive(check: check) })
        try QwenLayerStageLookaheadDriverSupport.requireSentCapture(saved.capture, ticket: saved.ticket)
        guard machine.completedFrames == ticket.frame.sequence + 1,
              completions.count == ticket.frame.sequence, context.committedTokens == machine.committedTokens,
              !transport.hasPendingConsumption else {
            throw ProbeError("Lookahead consumed completion differs from its saved frame or produced frontier")
        }
        completions.append(.init(capture: saved.capture, headerSHA256: saved.ticket.headerSHA256,
                                completedTransportPhase: "consumed_ack_received_and_validated"))
        pending = nil
        try record("frameCompletion", frame: ticket.frame, ticket: ticket)
    }

    private func apply(_ phase: QwenLayerStageLookaheadSendPhase,
                       ticket: QwenLayerStageOverlapTicket) throws {
        switch phase {
        case .beginHeader: try machine.beginHeader(ticket)
        case .headerSendCompleted: try machine.headerSendCompleted(ticket)
        case .readyACKAccepted: try machine.readyACKAccepted(ticket)
        case .beginPayloadSend: try machine.beginPayloadSend(ticket)
        case .payloadSendCompleted: try machine.payloadSendCompleted(ticket)
        case .receivedACKAccepted: try machine.receivedACKAccepted(ticket)
        case .beginConsumedDrain: try machine.beginConsumedDrain(ticket)
        case .consumedACKAccepted: try machine.consumedACKAccepted(ticket)
        }
        try record("send.\(String(describing: phase))", frame: ticket.frame, ticket: ticket)
    }

    private func finish(check: () throws -> Void) throws -> QwenLayerStageLookaheadRequestResult {
        let expectedLookaheads = max(0, plan.frames.filter { $0.phase == .prefill }.count - 1)
        guard prepared == nil, pending == nil, !ownsNativeBoundary, !transport.hasPendingConsumption,
              completions.count == request.steps.count, releasedOriginalArrayHandles == request.steps.count,
              promptLookaheadCount == expectedLookaheads, context.committedTokens == plan.finalCommittedTokens else {
            throw ProbeError("Lookahead sender closed with unfinished frames, retained output or wrong prompt lookahead count")
        }
        try context.close(); try check()
        guard context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead sender request state did not retire cleanly")
        }
        try machine.close(); try record("requestClosed", frame: nil)
        return .init(identity: context.identity, recordedRequestFingerprint: request.fingerprint,
            decodeAdmission: plan.decodeAdmission.rawValue, completions: completions, actions: trace.records,
            finalCommittedTokens: context.committedTokens, completedFrames: machine.completedFrames,
            producedFrames: machine.producedFrames, receivedFrames: machine.receivedFrames,
            promptLookaheadCount: promptLookaheadCount,
            maximumProducedMinusReceived: trace.maximumProducedMinusReceived,
            maximumReceivedMinusCompleted: trace.maximumReceivedMinusCompleted,
            maximumProducedMinusCompleted: trace.maximumProducedMinusCompleted,
            maximumExplicitNativeBoundarySlots: trace.maximumExplicitNativeBoundarySlots,
            releasedOriginalArrayHandles: releasedOriginalArrayHandles, allRequestStateRetired: true)
    }

    private func record(_ action: String, frame: QwenLayerStageFrame?, ticket: QwenLayerStageOverlapTicket? = nil) throws {
        try trace.sender(action, frame: frame, ticket: ticket, machine: machine,
                         nativeCommittedTokens: context.committedTokens, ownsNativeBoundary: ownsNativeBoundary)
    }

    private func requireActive(check: () throws -> Void) throws {
        guard !machine.isClosed, !machine.isFailed, !context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead sender was retired during an action")
        }
        try check()
        guard !machine.isClosed, !machine.isFailed, !context.isClosed, !context.isFailed, !transport.isFailed else {
            throw ProbeError("Lookahead sender was retired by a check callback")
        }
    }

    func retire() {
        prepared = nil; pending = nil; ownsNativeBoundary = false
        machine.retire()
    }
}
