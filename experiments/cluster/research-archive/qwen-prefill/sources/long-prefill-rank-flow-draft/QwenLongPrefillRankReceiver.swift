import Foundation

struct QwenLongPrefillRankReceiverResult {
    let frames: [QwenLongPrefillRankFrame]
    let selection: QwenLayerStagePrefillTokenReceipt
    let releasedOriginalBoundaryHandles: Int
}

/// The transport retains its received native residual through this known
/// synchronous callback. Only CPU commit/selection records escape; actual final
/// finite argmax finishes before the transport issues its final consumed ACK.
func runQwenLongPrefillRankReceiver(context: QwenLayerStageProfiledPrefillComputeContext,
    transport: QwenLayerStageProfiledPrefillTransport, trace: QwenLongPrefillRankTrace,
    check: () throws -> Void
) throws -> QwenLongPrefillRankReceiverResult {
    var frames: [QwenLongPrefillRankFrame] = []
    var selection: QwenLayerStagePrefillTokenReceipt?
    var released = 0
    frames.reserveCapacity(16)
    for (index, step) in context.request.steps.enumerated() {
        try check()
        guard transport.rank == 1, transport.completedBoundaryCount == index,
              context.committedTokens == step.frame.tokenOffset else {
            throw ProbeError("Long receiver lost its exact next native prompt frontier")
        }
        let received = try transport.receiveAndConsume(expectedFrame: step.frame, consume: { boundary in
            let commit = try context.consume(step, boundary: boundary, check: check)
            guard commit.identity == context.identity, commit.frame == step.frame,
                  commit.recordedRequestFingerprint == context.request.fingerprint,
                  commit.committedTokens == step.committedTokens else {
                throw ProbeError("Long receiver committed a different source/request/frontier")
            }
            let selected = try step.frame.finalPromptChunk ? context.selectFirstToken(check: check) : nil
            return .init(commit: commit, selection: selected)
        }, onPhase: { phase, ticket in
            try trace.record("receive.\(phase)", frame: ticket?.frame ?? step.frame,
                context: context, transport: transport, prepared: false)
        }, check: check)
        guard received.commit.frame == step.frame, received.ticket.frame == step.frame,
              transport.completedBoundaryCount == index + 1, !transport.hasPendingConsumption else {
            throw ProbeError("Long receiver did not finish the actual frame acknowledgement")
        }
        // The typed transport proves original-wrapper release before returning,
        // not absence of all storage aliases or a whole-process memory bound.
        released += 1
        if let actual = received.selection {
            guard step.frame.finalPromptChunk, selection == nil, received.tokenPacket != nil else {
                throw ProbeError("Long receiver returned duplicate or premature token selection")
            }
            selection = actual
        } else {
            guard !step.frame.finalPromptChunk, received.tokenPacket == nil else {
                throw ProbeError("Long receiver omitted its final native selection")
            }
        }
        frames.append(.init(commit: received.commit,
            exactEnvelopeJSON: String(decoding: received.ticket.envelope.encoded(), as: UTF8.self),
            envelopeFingerprint: received.ticket.envelopeFingerprint,
            envelopeWireBytesSHA256: received.ticket.envelopeWireBytesSHA256))
        try trace.record("frameCompleted", frame: step.frame,
            context: context, transport: transport, prepared: false)
    }
    guard context.isPrefillComplete, let selection, released == 16, frames.count == 16 else {
        throw ProbeError("Long receiver ended without complete prefill and its first selection")
    }
    return .init(frames: frames, selection: selection, releasedOriginalBoundaryHandles: released)
}
