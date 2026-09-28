import Foundation

struct QwenLayerStagePrefillRankReceiverResult {
    let frames: [QwenLayerStagePrefillRankFrame]
    let selection: QwenLayerStagePrefillTokenReceipt
    let releasedOriginalBoundaryHandles: Int
}

/// Only typed CPU commits/selection escape the transport's native receive scope.
func runQwenLayerStagePrefillRankReceiver(context: QwenLayerStagePrefillComputeContext,
    transport: QwenLayerStagePrefillTransport, trace: QwenLayerStagePrefillRankTrace,
    check: () throws -> Void) throws -> QwenLayerStagePrefillRankReceiverResult {
    var frames: [QwenLayerStagePrefillRankFrame] = []
    var selection: QwenLayerStagePrefillTokenReceipt?
    var released = 0
    for (index, step) in context.request.steps.enumerated() {
        guard transport.completedBoundaryCount == index, context.committedTokens == step.frame.tokenOffset else {
            throw ProbeError("Prefill receiver lost its next native prompt frontier")
        }
        let received = try transport.receiveAndConsume(expectedFrame: step.frame, consume: { boundary in
            let commit = try context.consume(step, boundary: boundary, check: check)
            guard commit.identity == context.identity, commit.frame == step.frame,
                  commit.recordedRequestFingerprint == context.request.fingerprint,
                  commit.committedTokens == step.committedTokens else {
                throw ProbeError("Prefill consumer committed a different request or frontier")
            }
            let selected = try step.frame.finalPromptChunk ? context.selectFirstToken(check: check) : nil
            return .init(commit: commit, selection: selected)
        }, onPhase: { phase, ticket in
            try trace.record("receive.\(phase)", frame: ticket?.frame ?? step.frame,
                context: context, transport: transport, prepared: false)
        }, check: check)
        guard received.commit.frame == step.frame, received.ticket.frame == step.frame,
              transport.completedBoundaryCount == index + 1 else {
            throw ProbeError("Prefill receiver did not finish its actual frame acknowledgement")
        }
        // The typed transport checks release of the original receive wrapper
        // before returning; this count is that source-bound native assertion.
        released += 1
        if let actual = received.selection {
            guard step.frame.finalPromptChunk, selection == nil, received.tokenPacket != nil else {
                throw ProbeError("Prefill receiver returned duplicate or premature token selection")
            }
            selection = actual
        } else {
            guard !step.frame.finalPromptChunk, received.tokenPacket == nil else {
                throw ProbeError("Prefill receiver omitted final native selection")
            }
        }
        frames.append(.init(commit: received.commit,
            exactEnvelopeJSON: String(decoding: received.ticket.envelope.encoded(), as: UTF8.self),
            envelopeSHA256: received.ticket.headerSHA256))
        try trace.record("frameCompleted", frame: step.frame, context: context, transport: transport, prepared: false)
    }
    guard context.isPrefillComplete, let selection, released == context.request.steps.count else {
        throw ProbeError("Prefill receiver ended without its complete native prompt and first selection")
    }
    return .init(frames: frames, selection: selection, releasedOriginalBoundaryHandles: released)
}
