import Foundation
import MLX

struct QwenLongPrefillRankSenderResult {
    let frames: [QwenLongPrefillRankFrame]
    let preparedAheadFrames: Int
    let releasedOriginalBoundaryHandles: Int
}

/// One native Prepared and one CPU-only pending consumed ticket at most.
/// Lookahead moves the next preparation before the previous consumed drain;
/// neither policy sends another header until that drain has completed.
func runQwenLongPrefillRankSender(context: QwenLayerStageProfiledPrefillComputeContext,
    transport: QwenLayerStageProfiledPrefillTransport, trace: QwenLongPrefillRankTrace,
    check: () throws -> Void
) throws -> QwenLongPrefillRankSenderResult {
    var prepared: QwenLayerStageProfiledPrefillPrepared?
    var frames: [QwenLongPrefillRankFrame] = []
    var ahead = 0, released = 0
    let steps = context.request.steps
    let lookahead = transport.agreement.descriptor.schedulingPolicy == .promptLookaheadOne
    frames.reserveCapacity(steps.count)
    func record(_ action: String, frame: QwenLayerStageFrame) throws {
        try trace.record(action, frame: frame, context: context,
            transport: transport, prepared: prepared != nil)
    }
    func prepare(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step) throws {
        guard prepared == nil else { throw ProbeError("Long sender already owns its one prepared residual") }
        try record("prepare.begin", frame: step.frame)
        prepared = try context.prepare(step, check: check)
        try record("prepare.committed", frame: step.frame)
    }
    for (index, step) in steps.enumerated() {
        try check()
        guard transport.rank == 0, transport.completedBoundaryCount == index,
              !transport.hasPendingConsumption else {
            throw ProbeError("Long sender must drain the prior consumed frame before another header")
        }
        if prepared == nil { try prepare(step) }
        weak var originalHandle: MLXArray?
        let sent: (QwenLayerStageProfiledPrefillBoundaryTicket, QwenLayerStagePrefillCommit) = try autoreleasepool {
            guard let value = prepared, value.commit.identity == context.identity,
                  value.commit.frame == step.frame, value.commit.committedTokens == step.committedTokens,
                  value.commit.recordedRequestFingerprint == context.request.fingerprint,
                  value.commit.outputKind == "hidden", value.commit.outputShape == value.expectation.shape,
                  value.commit.outputDType == value.expectation.dtype else {
                throw ProbeError("Prepared long output differs from the admitted native frontier/layout")
            }
            originalHandle = value.boundary.array
            let ticket = try transport.sendUntilReceived(value, expectedFrame: step.frame,
                onPhase: { phase, ticket in try record("send.\(phase)", frame: ticket.frame) }, check: check)
            prepared = nil
            return (ticket, value.commit)
        }
        guard originalHandle == nil, prepared == nil else {
            throw ProbeError("Long sender retained its original residual wrapper after received acknowledgement")
        }
        released += 1
        try record("producerBoundaryReleased", frame: step.frame)
        if lookahead, index + 1 < steps.count {
            try prepare(steps[index + 1]); ahead += 1
        }
        try transport.finishConsumed(sent.0,
            onPhase: { phase, ticket in try record("send.\(phase)", frame: ticket.frame) }, check: check)
        guard transport.completedBoundaryCount == index + 1, !transport.hasPendingConsumption else {
            throw ProbeError("Long sender did not drain its exact pending consumed ticket")
        }
        frames.append(.init(commit: sent.1,
            exactEnvelopeJSON: String(decoding: sent.0.envelope.encoded(), as: UTF8.self),
            envelopeFingerprint: sent.0.envelopeFingerprint,
            envelopeWireBytesSHA256: sent.0.envelopeWireBytesSHA256))
        try record("frameCompleted", frame: step.frame)
    }
    guard prepared == nil, context.isPrefillComplete, released == 16,
          ahead == (lookahead ? 15 : 0), frames.count == 16 else {
        throw ProbeError("Long sender ended with a residual or incomplete prompt schedule")
    }
    return .init(frames: frames, preparedAheadFrames: ahead, releasedOriginalBoundaryHandles: released)
}
