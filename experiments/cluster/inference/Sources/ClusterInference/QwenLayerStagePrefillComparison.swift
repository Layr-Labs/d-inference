import Foundation
import MLX

/// A one-process correctness control for the final-only observation path.
/// The caller must release the independently loaded baseline model before this
/// call. Its evidence and this result contain CPU values only. No clock is read.
func compareQwenLayerStagePrefillCompute(baseline: QwenLayerStageBaselineEvidence,
    stages: [LoadedQwenLayerStage], plan: QwenLayerStagePlan, check: () throws -> Void
) throws -> QwenLayerStagePrefillComparisonResult {
    let originalFinal = try QwenLayerStagePrefillComparisonValidation.admit(
        baseline: baseline, stages: stages, plan: plan)
    guard let originalLogits = originalFinal.logits else { throw ProbeError("Prefill baseline omitted final logits") }
    return try MLX.withError { mlxError in
        var contexts: [QwenLayerStagePrefillComputeContext] = []
        do {
            let first = try QwenLayerStagePrefillComputeContext(loaded: stages[0],
                plan: plan, request: baseline.request)
            contexts.append(first)
            try mlxError.check(); try check(); try mlxError.check()
            let second = try QwenLayerStagePrefillComputeContext(loaded: stages[1],
                plan: plan, request: baseline.request)
            contexts.append(second)
            try mlxError.check(); try check(); try mlxError.check()
            let identities = contexts.map(\.identity)
            var frames: [QwenLayerStagePrefillFrameComparison] = []
            var boundaryCopies = 0
            for (step, original) in zip(baseline.request.steps, baseline.frames) {
                // Only CPU commits escape this scope. The source and physical
                // copy are released before the next native stage-zero call.
                let frame = try autoreleasepool {
                    let prepared = try first.prepare(step,
                        check: { try mlxError.check(); try check(); try mlxError.check() })
                    let boundary = try prepared.boundary.ownedCopy(
                        check: { try mlxError.check(); try check(); try mlxError.check() })
                    boundaryCopies += 1
                    let consumed = try second.consume(step, boundary: boundary,
                        check: { try mlxError.check(); try check(); try mlxError.check() })
                    guard first.committedTokens == step.committedTokens,
                          second.committedTokens == step.committedTokens else {
                        throw ProbeError("Uncaptured pair did not commit the same complete prompt frontier")
                    }
                    let frame = try QwenLayerStagePrefillComparisonValidation.frame(
                        [prepared.commit, consumed], expected: prepared.expectation,
                        original: original, step: step, request: baseline.request, identities: identities)
                    try mlxError.check(); try check(); try mlxError.check()
                    return frame
                }
                frames.append(frame)
            }
            guard contexts.allSatisfy({ $0.isPrefillComplete && $0.committedFrames == frames.count }),
                  frames.count == baseline.request.steps.count, !first.hasFinalLogits, second.hasFinalLogits else {
                throw ProbeError("Uncaptured comparison stopped before complete prompt execution")
            }
            // Native first-token selection occurs before diagnostic captures.
            // A future timer/return protocol must be placed by its own owner.
            let token = try second.selectFirstToken(
                check: { try mlxError.check(); try check(); try mlxError.check() })
            let tokenComparison = try QwenLayerStagePrefillComparisonValidation.token(token,
                baseline: originalLogits, request: baseline.request, identity: second.identity)
            let finalLogits = try second.captureFinalLogitsForDiagnostics(
                check: { try mlxError.check(); try check(); try mlxError.check() })
            try finalLogits.requireExact(originalLogits)
            var snapshots: [CBv2OwnedStateSnapshot] = []
            for context in contexts {
                snapshots.append(try context.captureFinalStateForDiagnostics(includeBytes: false,
                    check: { try mlxError.check(); try check(); try mlxError.check() }))
            }
            let state = try QwenRecordedState(snapshots: snapshots, plan: plan,
                committedTokens: baseline.request.request.promptCount)
            try originalFinal.state.requireExact(state)
            let captureCounts = QwenLayerStagePrefillCaptureCounts(perFrameStateSnapshots: 0,
                perFrameLogitCaptures: 0, finalStateSnapshots: snapshots.count,
                finalLogitCaptures: 1, nativeTokenSelections: 1, nativeBoundaryCopies: boundaryCopies)
            for context in contexts { try context.close(); try mlxError.check() }
            try check(); try mlxError.check()
            guard contexts.allSatisfy({ $0.isClosed && !$0.isFailed && !$0.hasFinalLogits }),
                  captureCounts.finalStateSnapshots == 2, boundaryCopies == frames.count else {
                throw ProbeError("Uncaptured comparison did not retire both complete requests cleanly")
            }
            return .init(baselineEvidenceSHA256: baseline.fingerprint, requestSHA256: baseline.request.fingerprint,
                source: baseline.source, stageStorageCommitmentSHA256: stages[0].receipt.storageCommitmentSHA256,
                stageIdentities: identities, frames: frames, completedFrames: frames.count,
                committedTokens: baseline.request.request.promptCount, token: token, tokenComparison: tokenComparison,
                finalLogits: finalLogits.metadata, finalState: state, stateMetadataAndDigestsExact: true,
                nativeLogitBytesExact: true, captureCounts: captureCounts, allRequestStateRetired: true)
        } catch {
            let primary = error
            var cleanup: [String] = []
            // Cancel every constructed context, even if the other close/cancel
            // failed or the original error arose after a native commit.
            for (index, context) in contexts.enumerated() {
                do {
                    try MLX.withError { cleanupError in
                        try context.cancel(); try cleanupError.check()
                    }
                } catch { cleanup.append("stage \(index): \(error)") }
                if !context.isClosed || !context.isFailed || context.hasFinalLogits {
                    cleanup.append("stage \(index) request was not failed and retired")
                }
            }
            if !cleanup.isEmpty {
                throw ProbeError("Uncaptured prefill comparison failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
            }
            throw primary
        }
    }
}
