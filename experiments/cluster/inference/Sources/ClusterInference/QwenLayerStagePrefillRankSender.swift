import Foundation
import MLX

struct QwenLayerStagePrefillRankSenderResult {
    let frames: [QwenLayerStagePrefillRankFrame]
    let preparedAheadFrames: Int
    let releasedOriginalBoundaryHandles: Int
}

/// One prepared native residual and one CPU-only consumed ticket at most.
/// Serial and lookahead differ only in where the next prepare occurs.
func runQwenLayerStagePrefillRankSender(context: QwenLayerStagePrefillComputeContext,
    transport: QwenLayerStagePrefillTransport, trace: QwenLayerStagePrefillRankTrace,
    check: () throws -> Void) throws -> QwenLayerStagePrefillRankSenderResult {
    var prepared: QwenLayerStagePrefillPrepared?
    var frames: [QwenLayerStagePrefillRankFrame] = []
    var ahead = 0, released = 0
    let steps = context.request.steps
    let lookahead = transport.agreement.descriptor.schedulingPolicy == .promptLookaheadOne
    func record(_ action: String, frame: QwenLayerStageFrame) throws {
        try trace.record(action, frame: frame, context: context, transport: transport, prepared: prepared != nil)
    }
    func prepare(_ step: QwenLayerStageRecordedRequest.Step) throws {
        guard prepared == nil else { throw ProbeError("Prefill sender already owns its one prepared residual") }
        try record("prepare.begin", frame: step.frame)
        prepared = try context.prepare(step, check: check)
        try record("prepare.committed", frame: step.frame)
    }
    for (index, step) in steps.enumerated() {
        try check()
        guard transport.completedBoundaryCount == index, !transport.hasPendingConsumption else {
            throw ProbeError("Prefill sender must drain the prior consumed frame before another header")
        }
        if prepared == nil { try prepare(step) }
        weak var originalHandle: MLXArray?
        let sent: (QwenLayerStagePrefillBoundaryTicket, QwenLayerStagePrefillCommit) = try autoreleasepool {
            guard let value = prepared, value.commit.identity == context.identity,
                  value.commit.frame == step.frame, value.commit.committedTokens == step.committedTokens,
                  value.commit.recordedRequestFingerprint == context.request.fingerprint,
                  value.commit.outputKind == "hidden", value.commit.outputShape == value.expectation.shape,
                  value.commit.outputDType == value.expectation.dtype else {
                throw ProbeError("Prepared prefill output differs from its native request, shape or frontier")
            }
            originalHandle = value.boundary.array
            let ticket = try transport.sendUntilReceived(value.boundary, expectedFrame: step.frame,
                onPhase: { phase, ticket in try record("send.\(phase)", frame: ticket.frame) }, check: check)
            prepared = nil
            return (ticket, value.commit)
        }
        guard originalHandle == nil else { throw ProbeError("Prefill sender retained its original residual wrapper after received ACK") }
        released += 1
        try record("producerBoundaryReleased", frame: step.frame)
        if lookahead, index + 1 < steps.count {
            try prepare(steps[index + 1]); ahead += 1
        }
        try transport.finishConsumed(sent.0,
            onPhase: { phase, ticket in try record("send.\(phase)", frame: ticket.frame) }, check: check)
        guard transport.completedBoundaryCount == index + 1, !transport.hasPendingConsumption else {
            throw ProbeError("Prefill sender did not complete its pending consumed ACK")
        }
        frames.append(.init(commit: sent.1,
            exactEnvelopeJSON: String(decoding: sent.0.envelope.encoded(), as: UTF8.self),
            envelopeSHA256: sent.0.headerSHA256))
        try record("frameCompleted", frame: step.frame)
    }
    guard prepared == nil, context.isPrefillComplete, released == steps.count,
          ahead == (lookahead ? max(0, steps.count - 1) : 0) else {
        throw ProbeError("Prefill sender finished with residual ownership or an incomplete prompt schedule")
    }
    return .init(frames: frames, preparedAheadFrames: ahead, releasedOriginalBoundaryHandles: released)
}
