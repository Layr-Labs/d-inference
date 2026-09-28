import Foundation
import MLX

/// One-shot native prefill with optional, final-only observation. No per-frame
/// state snapshot or vocabulary copy is hidden in prepare/consume. This wraps
/// the unchanged StageSession, including all its integrity and completion costs.
final class QwenLayerStagePrefillComputeContext {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageRecordedRequest
    private let session: QwenLayerStageSession
    private let source: QwenLayerStageWireSourceIdentity
    private let hiddenSize: Int
    private var finalLogits: MLXArray?
    private var selectedToken = false
    private var failed = false
    private var inOperation = false
    private(set) var committedFrames = 0

    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.isClosed }
    var isFailed: Bool { failed || session.isFailed }
    var isPrefillComplete: Bool { committedFrames == request.steps.count && committedTokens == request.request.promptCount }
    var hasFinalLogits: Bool { finalLogits != nil }

    /// This constructs fresh native request state. The future timer must start
    /// before this initializer if reporting the proposed first-token contract.
    init(loaded: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
         request: QwenLayerStageRecordedRequest) throws {
        guard (1...128).contains(request.request.promptCount), (1...32).contains(request.request.chunkSize),
              request.request.outputCount == 1, request.teacherTokenIDs.isEmpty,
              !request.steps.isEmpty, request.steps.count <= 128,
              request.steps.allSatisfy({ $0.frame.phase == .prefill }),
              request.vocabularySize == loaded.vocabularySize,
              plan.stages.count == 2, plan.stages.indices.contains(loaded.stageIndex),
              let root = try JSONSerialization.jsonObject(with: plan.originalConfiguration) as? [String: Any] else {
            throw ProbeError("Uncaptured stage prefill requires prompt<=128, chunk<=32, output1 and a matching stage")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        guard let hidden = BoundedProbeInput.integer(text["hidden_size"]), (1...8192).contains(hidden) else {
            throw ProbeError("Uncaptured stage hidden width is outside the existing native admission")
        }
        source = try .init(sourceConfigurationSHA256: loaded.receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        let session = try MLX.withError { error in
            let session = try QwenLayerStageSession(stage: loaded, plan: plan, request: request.request)
            try error.check()
            return session
        }
        self.session = session; self.identity = session.identity; self.request = request; self.hiddenSize = hidden
    }

    func expectation(for step: QwenLayerStageRecordedRequest.Step) throws -> QwenLayerStageBoundaryWireExpectation {
        try operation { try requireNextStep(step); return try makeExpectation(step) }
    }

    func prepare(_ step: QwenLayerStageRecordedRequest.Step,
                 check: () throws -> Void) throws -> QwenLayerStagePrefillPrepared {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard identity.stageIndex == 0 else { throw ProbeError("Only stage zero prepares native prefill residuals") }
                try requireNextStep(step)
                let expected = try makeExpectation(step)
                let output = try session.prefillChunk(step.tokenIDs, offset: step.frame.tokenOffset,
                    final: step.frame.finalPromptChunk, check: checked)
                guard case .hidden(let boundary) = output else { throw ProbeError("Uncaptured producer returned the wrong output") }
                let commit = try complete(step, output: boundary.array, kind: "hidden")
                try checked()
                return .init(boundary: boundary, expectation: expected, commit: commit)
            }
        }
    }

    /// Intermediate evaluation handles are released here; only the final row is
    /// retained privately for optional token selection or later exact capture.
    func consume(_ step: QwenLayerStageRecordedRequest.Step, boundary: QwenLayerStageBoundary,
                 check: () throws -> Void) throws -> QwenLayerStagePrefillCommit {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard identity.stageIndex == 1 else { throw ProbeError("Only stage one consumes prefill residuals") }
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
                default: throw ProbeError("Uncaptured consumer returned the wrong narrowed output kind")
                }
                try checked()
                return commit
            }
        }
    }

    /// Not a transport receipt. Its argMax, finite reduction and two scalar
    /// readbacks must be included in any future prefill-to-first-token interval.
    func selectFirstToken(check: () throws -> Void) throws -> QwenLayerStagePrefillTokenReceipt {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                guard !selectedToken else { throw ProbeError("First-token selection is one-shot, not a cached timing result") }
                let logits = try requireFinalLogits()
                let receipt = try QwenLayerStagePrefillFinalObservation.select(logits, identity: identity,
                    request: request, frame: request.steps.last!.frame, check: checked)
                try checked(); selectedToken = true
                return receipt
            }
        }
    }

    /// Caller places this outside a timed interval. The context owns no clock,
    /// so it cannot itself prove an external timer has stopped on both ranks.
    func captureFinalLogitsForDiagnostics(check: () throws -> Void) throws -> QwenLayerStagePrefillLogitReceipt {
        try operation {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check(); try error.check(); try requireOpen() }
                let logits = try requireFinalLogits()
                return try QwenLayerStagePrefillFinalObservation.capture(logits, identity: identity,
                    request: request, frame: request.steps.last!.frame, check: checked)
            }
        }
    }

    func captureFinalStateForDiagnostics(includeBytes: Bool = false,
        check: () throws -> Void
    ) throws -> CBv2OwnedStateSnapshot {
        try operation {
            guard isPrefillComplete else { throw ProbeError("Uncaptured context allows state snapshots only after full prefill") }
            return try session.snapshot(includeBytes: includeBytes, check: check)
        }
    }

    private func makeExpectation(_ step: QwenLayerStageRecordedRequest.Step) throws -> QwenLayerStageBoundaryWireExpectation {
        try .init(request: request.request, frame: step.frame, tokenIDs: step.tokenIDs,
            sourceIdentity: source, hiddenSize: hiddenSize, nativeDType: identity.activationDType)
    }

    private func requireNextStep(_ step: QwenLayerStageRecordedRequest.Step) throws {
        try requireOpen()
        guard request.steps.indices.contains(committedFrames) else { throw ProbeError("Uncaptured prefill has no next frame") }
        let expected = request.steps[committedFrames]
        guard step.frame == expected.frame, step.tokenIDs == expected.tokenIDs,
              committedTokens == step.frame.tokenOffset else {
            throw ProbeError("Uncaptured prefill differs from its exact prompt history or local frontier")
        }
    }

    private func complete(_ step: QwenLayerStageRecordedRequest.Step, output: MLXArray,
                          kind: String) throws -> QwenLayerStagePrefillCommit {
        guard committedTokens == step.committedTokens else { throw ProbeError("Uncaptured native prefill did not commit its full frame") }
        committedFrames += 1
        return .init(identity: identity, recordedRequestFingerprint: request.fingerprint, frame: step.frame,
            committedTokens: committedTokens, outputKind: kind, outputShape: output.shape,
            outputDType: String(describing: output.dtype))
    }

    private func requireFinalLogits() throws -> MLXArray {
        guard identity.stageIndex == 1, isPrefillComplete, let finalLogits else {
            throw ProbeError("Final-logit observation requires completed stage-one prefill")
        }
        return finalLogits
    }

    private func requireOpen() throws {
        guard !isClosed, !isFailed else { throw ProbeError("Uncaptured prefill context is retired") }
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !inOperation else { failed = true; throw ProbeError("Uncaptured prefill context cannot be entered recursively") }
        inOperation = true
        defer { inOperation = false }
        do { try requireOpen(); let result = try body(); try requireOpen(); return result }
        catch { try fail(error) }
    }

    func close() throws {
        if isClosed && !isFailed { return }
        guard !inOperation else { failed = true; throw ProbeError("Cannot close during uncaptured prefill work") }
        do {
            try requireOpen()
            guard isPrefillComplete else { throw ProbeError("Uncaptured prefill closed before every prompt token committed") }
            finalLogits = nil
            try session.close()
            guard isClosed, !isFailed else { throw ProbeError("Uncaptured prefill did not retire cleanly") }
        } catch { try fail(error) }
    }

    func cancel() throws {
        failed = true
        guard !inOperation else { throw ProbeError("Cannot cancel recursively during uncaptured prefill work") }
        finalLogits = nil
        try session.cancel()
    }

    private func fail(_ primary: Error) throws -> Never {
        // The failed body has unwound before native cleanup. Public recursive
        // cancellation only poisons the context until this safe outer boundary.
        failed = true; finalLogits = nil
        do { try session.cancel() }
        catch { throw ProbeError("Uncaptured prefill failed (\(primary)); retirement also failed (\(error))") }
        guard isClosed, isFailed else { throw ProbeError("Uncaptured prefill failed (\(primary)); request state was not retired") }
        throw primary
    }

    deinit { if !isClosed { try? cancel() } }
}
