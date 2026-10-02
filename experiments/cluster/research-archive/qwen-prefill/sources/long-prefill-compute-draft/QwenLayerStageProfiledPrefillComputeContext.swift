import Foundation
import MLX

/// New registered long-profile owner. The existing full-width StageSession is
/// the sole forward/state implementation. No IO, clock or reference parser.
final class QwenLayerStageProfiledPrefillComputeContext {
    let identity: QwenLayerStageSessionIdentity
    let admission: QwenLayerStageProfiledComputeAdmission
    var request: QwenLayerStageProfiledPrefillRecordedRequest { admission.local.request }
    private let session: QwenLayerStageSession
    private var finalLogits: MLXArray?
    private var selectedToken = false
    private var observedFinal = false
    private var failed = false
    private var inOperation = false
    private(set) var committedFrames = 0

    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.isClosed }
    var isFailed: Bool { failed || session.isFailed }
    var isPrefillComplete: Bool { committedFrames == 16 && committedTokens == 8192 }
    var hasFinalLogits: Bool { finalLogits != nil }
    var finalObservationCompleted: Bool { observedFinal && !isFailed }

    /// All CPU/source admission precedes native state creation. Caller starts
    /// any future first-token interval before this fresh-state constructor.
    init(loaded: LoadedQwenLayerStage, local: QwenRegistered9BLongPrefillReferenceAdmission,
         agreement: QwenLayerStageProfiledPrefillStartAgreement, check: () throws -> Void) throws {
        let admission = try QwenLayerStageProfiledComputeAdmission(loaded: loaded, local: local, agreement: agreement)
        let session = try makeQwenLayerStageProfiledComputeOwner(loaded: loaded, admission: admission, check: check)
        self.admission = admission; self.session = session; self.identity = session.identity
    }

    func expectation(for step: QwenLayerStageProfiledPrefillRecordedRequest.Step) throws
        -> QwenLayerStageProfiledBoundaryWireExpectation {
        try operation { try requireNextStep(step); return try admission.agreement.boundaryExpectation(for: step.frame) }
    }

    func prepare(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step,
                 check: () throws -> Void) throws -> QwenLayerStageProfiledPrefillPrepared {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard identity.stageIndex == 0 else { throw ProbeError("Only profiled stage zero prepares residuals") }
                try requireNextStep(step)
                let expected = try admission.agreement.boundaryExpectation(for: step.frame)
                let output = try session.prefillChunk(step.tokenIDs, offset: step.frame.tokenOffset,
                    final: step.frame.finalPromptChunk, check: checked)
                guard case .hidden(let boundary) = output else { throw ProbeError("Profiled producer returned the wrong output") }
                try validateProducedBoundary(boundary, expected: expected)
                let commit = try complete(step, output: boundary.array, kind: "hidden")
                try checked()
                return .init(boundary: boundary, expectation: expected, commit: commit)
            }
        }
    }

    func consume(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step, boundary: QwenLayerStageBoundary,
                 check: () throws -> Void) throws -> QwenLayerStagePrefillCommit {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard identity.stageIndex == 1 else { throw ProbeError("Only profiled stage one consumes residuals") }
                try requireNextStep(step)
                let output = try session.prefillChunk(step.tokenIDs, offset: step.frame.tokenOffset,
                    final: step.frame.finalPromptChunk, incoming: boundary, check: checked)
                let commit: QwenLayerStagePrefillCommit
                switch output {
                case .evaluationHandle(let array) where !step.frame.finalPromptChunk:
                    commit = try complete(step, output: array, kind: "evaluation_handle")
                case .logits(let array) where step.frame.finalPromptChunk && finalLogits == nil:
                    finalLogits = array
                    commit = try complete(step, output: array, kind: "logits")
                default: throw ProbeError("Profiled consumer returned the wrong narrowed output")
                }
                try checked()
                return commit
            }
        }
    }

    /// Native finite argmax/scalar readbacks belong inside the first-token
    /// interval. Transport separately binds this actual receipt to the final ACK.
    func selectFirstToken(check: () throws -> Void) throws -> QwenLayerStagePrefillTokenReceipt {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard !selectedToken else { throw ProbeError("Profiled token selection is one-shot") }
                let receipt = try QwenLayerStageProfiledFinalObservation.select(try requireFinalLogits(),
                    identity: identity, request: request, check: checked)
                try checked(); selectedToken = true
                return receipt
            }
        }
    }

    /// The native transport/driver must first complete external post-stop
    /// release. This method neither observes a clock nor proves that wire event.
    /// Only CPU metadata/digests escape; no full vocabulary or state bytes remain.
    func captureFinalDigestsAfterPostStop(check: () throws -> Void) throws -> QwenLayerStageProfiledPrefillFinalDigest {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard isPrefillComplete, !observedFinal, identity.stageIndex == 0 || selectedToken else {
                    throw ProbeError("Profiled final observation requires full prefill and completed local token selection")
                }
                let state = try autoreleasepool {
                    let snapshot = try session.snapshot(includeBytes: false, check: checked)
                    return try QwenLayerStageProfiledStateDigest(snapshot: snapshot, admission: admission)
                }
                let logits = try autoreleasepool { () throws -> QwenLayerStagePrefillLogitMetadata? in
                    guard identity.stageIndex == 1 else { return nil }
                    return try QwenLayerStageProfiledFinalObservation.capture(try requireFinalLogits(),
                        identity: identity, request: request, check: checked)
                }
                let result = try QwenLayerStageProfiledPrefillFinalDigest(admission: admission,
                    identity: identity, state: state, logits: logits)
                try checked(); observedFinal = true
                return result
            }
        }
    }

    private func validateProducedBoundary(_ boundary: QwenLayerStageBoundary,
        expected: QwenLayerStageProfiledBoundaryWireExpectation) throws {
        let actualSource = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: boundary.sourceConfigurationSHA256,
            artifactAggregateSHA256: boundary.artifactAggregateSHA256, storageCommitmentSHA256: boundary.storageCommitmentSHA256,
            planFingerprint: boundary.planFingerprint, producerStageFingerprint: boundary.producerStageFingerprint)
        // Existing boundary lacks a recorded-history field; it is bound here by
        // exact local step admission. All fields the producer actually emits are checked.
        let header = try QwenLayerStageProfiledBoundaryWireHeader(profile: request.request.profile,
            requestFingerprint: boundary.requestFingerprint, recordedRequestFingerprint: request.fingerprint,
            sourceIdentity: actualSource, frame: boundary.frame, tokenIDsSHA256: boundary.tokenIDsSHA256,
            payloadSHA256: boundary.payloadSHA256, shape: boundary.array.shape,
            dtype: String(describing: boundary.array.dtype), byteCount: boundary.array.nbytes)
        try header.validate(expected: expected)
        // The unchanged native transport must complete/synchronize and validate
        // actual owned compact storage before a send. No premature unique claim.
    }

    private func requireNextStep(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step) throws {
        try requireOpen()
        guard request.steps.indices.contains(committedFrames) else { throw ProbeError("Profiled compute has no next frame") }
        let expected = request.steps[committedFrames]
        guard step.frame == expected.frame, step.tokenIDs == expected.tokenIDs,
              step.committedTokens == expected.committedTokens, committedTokens == step.frame.tokenOffset else {
            throw ProbeError("Profiled compute differs from its exact local history/frontier")
        }
    }

    private func complete(_ step: QwenLayerStageProfiledPrefillRecordedRequest.Step, output: MLXArray,
                          kind: String) throws -> QwenLayerStagePrefillCommit {
        let width = step.expectsLogits ? request.vocabularySize : 1
        let shape = identity.stageIndex == 0 ? [1, step.tokenIDs.count, admission.local.resource.geometry.hiddenSize] : [1, width]
        guard committedTokens == step.committedTokens, output.shape == shape, output.dtype == .bfloat16 else {
            throw ProbeError("Profiled native output or committed frontier differs")
        }
        committedFrames += 1
        return .init(identity: identity, recordedRequestFingerprint: request.fingerprint, frame: step.frame,
            committedTokens: committedTokens, outputKind: kind, outputShape: output.shape, outputDType: "bfloat16")
    }

    private func requireFinalLogits() throws -> MLXArray {
        guard identity.stageIndex == 1, isPrefillComplete, let finalLogits else {
            throw ProbeError("Profiled final row requires completed stage-one prefill")
        }
        return finalLogits
    }

    private func requireOpen() throws {
        guard !isClosed, !isFailed else { throw ProbeError("Profiled compute is retired") }
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !inOperation else { failed = true; throw ProbeError("Profiled compute cannot be entered recursively") }
        inOperation = true; defer { inOperation = false }
        do { try requireOpen(); let result = try body(); try requireOpen(); return result }
        catch { try fail(error) }
    }

    func close() throws {
        if isClosed && !isFailed { return }
        guard !inOperation else { failed = true; throw ProbeError("Cannot close during profiled compute") }
        do {
            try requireOpen()
            guard isPrefillComplete else { throw ProbeError("Profiled compute closed before every prompt token committed") }
            finalLogits = nil; try session.close()
            guard isClosed, !isFailed else { throw ProbeError("Profiled compute did not retire cleanly") }
        } catch { try fail(error) }
    }

    func cancel() throws {
        failed = true
        guard !inOperation else { throw ProbeError("Cannot cancel recursively during profiled compute") }
        finalLogits = nil; try session.cancel()
    }

    private func fail(_ primary: Error) throws -> Never {
        failed = true; finalLogits = nil
        do { try session.cancel() }
        catch { throw ProbeError("Profiled compute failed (\(primary)); retirement also failed (\(error))") }
        guard isClosed, isFailed else { throw ProbeError("Profiled compute failed (\(primary)); request remained live") }
        throw primary
    }

    deinit { if !isClosed { try? cancel() } }
}
