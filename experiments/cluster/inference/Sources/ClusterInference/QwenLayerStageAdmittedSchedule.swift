import Foundation

/// Same commit-facing API for both admitted request namespaces. Legacy state
/// delegates to the original schedule, retaining its exact decode semantics.
struct QwenLayerStageAdmittedSchedule {
    let request: QwenLayerStageAdmittedRequest
    private enum Storage {
        case legacy(QwenLayerStageSchedule)
        case profiled(QwenLayerStageProfiledPrefillSchedule)
    }
    private var storage: Storage

    init(request: QwenLayerStageAdmittedRequest) {
        self.request = request
        switch request {
        case .legacy(let r): storage = .legacy(.init(request: r))
        case .profiled(let r): storage = .profiled(.init(request: r))
        }
    }

    var committedTokens: Int {
        switch storage { case .legacy(let s): s.committedTokens; case .profiled(let s): s.committedTokens }
    }
    var committedPromptTokens: Int {
        switch storage { case .legacy(let s): s.committedPromptTokens; case .profiled(let s): s.committedTokens }
    }
    var decodeForwardCount: Int {
        switch storage { case .legacy(let s): s.decodeForwardCount; case .profiled: 0 }
    }
    var nextSequence: Int {
        switch storage { case .legacy(let s): s.nextSequence; case .profiled(let s): s.nextSequence }
    }
    var complete: Bool {
        switch storage { case .legacy(let s): s.complete; case .profiled(let s): s.complete }
    }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        switch storage {
        case .legacy(let s): try s.admitPrefill(count: count, offset: offset, final: final)
        case .profiled(let s): try s.admitPrefill(count: count, offset: offset, final: final)
        }
    }

    func admitDecode(offset: Int) throws -> QwenLayerStageFrame {
        switch storage {
        case .legacy(let s): return try s.admitDecode(offset: offset)
        case .profiled: throw ProbeError("The profiled prefill request admits no teacher or decode forwards")
        }
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        // Assign only after validation/commit returns. Rejection leaves the
        // wrapper and its delegate at the exact prior frontier.
        switch storage {
        case .legacy(var s): try s.commit(frame); storage = .legacy(s)
        case .profiled(var s): try s.commit(frame); storage = .profiled(s)
        }
    }
}

/// Internal prefill-only frontier, constructible only from a validated spec.
/// Incoming frame integers are compared to locally derived geometry first.
private struct QwenLayerStageProfiledPrefillSchedule {
    let request: QwenLayerStageProfiledPrefillRequestSpec
    private(set) var committedTokens = 0
    private(set) var nextSequence = 0

    init(request: QwenLayerStageProfiledPrefillRequestSpec) { self.request = request }

    var complete: Bool {
        committedTokens == request.promptCount && nextSequence == request.prefillFrameCount
    }

    func admitPrefill(count: Int, offset: Int, final: Bool) throws -> QwenLayerStageFrame {
        guard committedTokens < request.promptCount,
              nextSequence < request.prefillFrameCount, offset == committedTokens else {
            throw ProbeError("Profiled prefill is outside its local prompt frontier")
        }
        let remaining = request.promptCount - committedTokens // nonnegative, admitted bounds
        let expectedCount = min(request.chunkSize, remaining)
        guard count == expectedCount else { throw ProbeError("Profiled prefill changed the agreed chunk size") }
        let (end, overflow) = committedTokens.addingReportingOverflow(expectedCount)
        guard !overflow, end <= request.promptCount,
              final == (end == request.promptCount),
              final == (nextSequence == request.prefillFrameCount - 1) else {
            throw ProbeError("Profiled prefill changed the final flag or checked frame geometry")
        }
        return .init(sequence: nextSequence, phase: .prefill, tokenOffset: committedTokens,
                     tokenCount: expectedCount, finalPromptChunk: final)
    }

    mutating func commit(_ frame: QwenLayerStageFrame) throws {
        guard frame.phase == .prefill else { throw ProbeError("Profiled prefill cannot commit a decode frame") }
        let expected = try admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset,
                                       final: frame.finalPromptChunk)
        guard frame == expected else { throw ProbeError("Profiled prefill sequence changed after admission") }
        let (end, tokenOverflow) = committedTokens.addingReportingOverflow(expected.tokenCount)
        let (sequence, sequenceOverflow) = nextSequence.addingReportingOverflow(1)
        guard !tokenOverflow, !sequenceOverflow, end <= request.promptCount,
              sequence <= request.prefillFrameCount else { throw ProbeError("Profiled prefill commit exceeded its admitted geometry") }
        committedTokens = end; nextSequence = sequence
    }
}
