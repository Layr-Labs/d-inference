import Foundation
import Dispatch
import MLX

/// One fresh full-model request. Source admission and ready callback precede
/// the clock; fresh state through finite argmax is timed. Final numerical
/// captures and retirement follow stop. No external reference is parsed.
func runQwenLongPrefillSoloRequest(loaded: LoadedModel,
    admission: QwenRegistered9BLongPrefillReferenceAdmission,
    onReady: () throws -> Void = {}, phaseRecorder: QwenPrefillPhaseRecorder? = nil,
    ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil,
    check: () throws -> Void
) throws -> QwenLongPrefillSoloRequestResult {
    var session: CBv2RequestSession?
    var finalLogits: MLXArray?
    var retiredCleanly = false
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let (source, receipt) = try admitQwenLongPrefillReferenceSource(loaded: loaded, admission: admission)
            try checked(); try onReady(); try checked()
            if let phaseRecorder {
                try phaseRecorder.begin(expectedIdentity: .init(requestFingerprint: admission.request.fingerprint,
                    profile: admission.request.request.profile.rawValue, role: .solo))
                try phaseRecorder.observe(phase: "request.ready", committedTokens: 0)
            }
            var commits: [QwenLayerStageSoloPrefillCommit] = []
            commits.reserveCapacity(16)
            try phaseRecorder?.observe(phase: "freshRequest.begin", committedTokens: 0)
            let start = DispatchTime.now().uptimeNanoseconds
            let fresh = try CBv2RequestSession(loaded: loaded, promptCount: 8192, outputCount: 1)
            session = fresh
            try checked()
            guard fresh.committedTokens == 0, fresh.committedPromptTokens == 0,
                  fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                throw ProbeError("Long solo did not acquire exclusive fresh request state")
            }
            try phaseRecorder?.observe(phase: "freshRequest.created", committedTokens: fresh.committedTokens)
            for step in admission.request.steps {
                try phaseRecorder?.observe(phase: "prefill.begin", frameSequence: step.frame.sequence, committedTokens: fresh.committedTokens)
                let commit = try autoreleasepool {
                    guard fresh.committedTokens == step.frame.tokenOffset,
                          step.frame.phase == .prefill, step.tokenIDs.count == 512 else {
                        throw ProbeError("Long solo lost its admitted prompt frontier")
                    }
                    let observer = try qwenPrefillSelectedOwnerObserver(for: step.frame, factory: ownerObserverFactory)
                    let output = try fresh.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk,
                        observer: observer, check: checked)
                    let width = step.expectsLogits ? admission.request.vocabularySize : 1
                    guard fresh.committedTokens == step.committedTokens,
                          fresh.committedPromptTokens == step.committedTokens, fresh.decodeForwardCount == 0,
                          output.shape == [1, width], output.dtype == .bfloat16 else {
                        throw ProbeError("Long solo narrowed output/frontier or native dtype differs")
                    }
                    if step.expectsLogits {
                        guard finalLogits == nil else { throw ProbeError("Long solo duplicated its final row") }
                        finalLogits = output
                    }
                    try checked()
                    return QwenLayerStageSoloPrefillCommit(frame: step.frame, committedTokens: fresh.committedTokens,
                        outputKind: step.expectsLogits ? "logits" : "evaluation_handle",
                        outputShape: output.shape, outputDType: String(describing: output.dtype))
                }
                commits.append(commit)
                try phaseRecorder?.observe(phase: "prefill.committed", frameSequence: step.frame.sequence, committedTokens: fresh.committedTokens)
            }
            guard commits.count == 16, fresh.committedTokens == 8192, fresh.committedPromptTokens == 8192,
                  fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                throw ProbeError("Long solo final capture began before all sixteen commits")
            }
            try phaseRecorder?.observe(phase: "selection.begin", committedTokens: fresh.committedTokens)
            let selection = try autoreleasepool {
                guard let finalLogits else { throw ProbeError("Long solo has no final native row") }
                return try QwenLongPrefillSoloObservation.select(finalLogits, request: admission.request, check: checked)
            }
            let stop = DispatchTime.now().uptimeNanoseconds
            guard stop > start else { throw ProbeError("Long solo clock did not advance") }
            try phaseRecorder?.observe(phase: "selection.completed", committedTokens: fresh.committedTokens)
            try phaseRecorder?.observe(phase: "diagnostics.begin", committedTokens: fresh.committedTokens)
            let logits = try autoreleasepool {
                try QwenLongPrefillSoloObservation.capture(finalLogits!, request: admission.request, check: checked)
            }
            // The sole state snapshot retains metadata/digests only. The shared
            // capture hashes one copied component at a time, not a state history.
            let state = try autoreleasepool {
                let snapshot = try fresh.snapshot(includeBytes: false, check: checked)
                return try QwenRecordedState(snapshots: [snapshot], plan: admission.plan, committedTokens: 8192)
            }
            guard state.entries.count == 72, state.logicalByteCount == 319_946_784 else {
                throw ProbeError("Long solo final state has the wrong registered component/byte coverage")
            }
            try phaseRecorder?.observe(phase: "diagnostics.completed", committedTokens: fresh.committedTokens)
            try phaseRecorder?.observe(phase: "retirement.begin", committedTokens: fresh.committedTokens)
            finalLogits = nil
            try fresh.close()
            guard fresh.isClosed, !fresh.isFailed else { throw ProbeError("Long solo request did not retire cleanly") }
            retiredCleanly = true
            try checked()
            let closed = DispatchTime.now().uptimeNanoseconds
            guard closed >= stop else { throw ProbeError("Long solo post-stop clock moved backwards") }
            try phaseRecorder?.observe(phase: "request.closed", committedTokens: fresh.committedTokens)
            let result = QwenLongPrefillSoloRequestResult(source: source, sourceLoad: receipt, request: admission.request,
                commits: commits, selection: selection, finalState: state, finalLogits: logits,
                timing: .init(startUptimeNanoseconds: start, stopUptimeNanoseconds: stop,
                    elapsedNanoseconds: stop - start,
                    promptTokensPerFirstTokenSecond: 8192e9 / Double(stop - start),
                    postStopThroughRequestCloseNanoseconds: closed - stop),
                completedFrames: commits.count, committedTokens: fresh.committedTokens)
            try phaseRecorder?.seal()
            return result
        }
    } catch {
        phaseRecorder?.fail()
        let primary = error
        finalLogits = nil
        if let session, !retiredCleanly {
            do {
                try MLX.withError { cleanupError in
                    try session.cancel(); try cleanupError.check()
                }
            } catch { throw ProbeError("Long solo request failed (\(primary)); cleanup also failed (\(error))") }
            guard session.isClosed, session.isFailed else {
                throw ProbeError("Long solo request failed (\(primary)); owner was not failed and retired")
            }
        }
        throw primary
    }
}
