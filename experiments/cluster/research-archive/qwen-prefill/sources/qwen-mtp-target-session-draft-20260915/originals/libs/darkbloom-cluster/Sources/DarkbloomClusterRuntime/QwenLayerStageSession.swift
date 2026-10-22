import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon
import MLXNN

struct QwenLayerStageSessionIdentity: Codable, Equatable {
    let stageIndex: Int
    let requestFingerprint: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let bf16ConversionEnabled: Bool
    let sourceConfigurationSHA256: String
    let constructionConfigurationSHA256: String
    let planFingerprint: String
    let stageFingerprint: String
    let activationDType: String
}

/// One serialized stage; no overlap, network, sampling or hidden token-history
/// changes. Native methods install an error handler and retire on every error.
final class QwenLayerStageSession {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageAdmittedRequest
    private let stage: LoadedQwenLayerStage
    private let descriptor: QwenLayerStagePlan.Stage
    private let adapter: CBv2SteppableLanguageModelAdapter
    private let state: CBv2OwnedRequestState
    private let hiddenSize: Int
    private let producerStageFingerprint: String
    private var schedule: QwenLayerStageAdmittedSchedule
    private var verification: QwenTargetVerificationExecution?
    private var usedVerificationRounds = Set<UUID>()

    var committedTokens: Int { schedule.committedTokens }
    var isClosed: Bool { state.isClosed }
    var isFailed: Bool { state.isFailed }

    convenience init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                     request: QwenLayerStageRequestSpec) throws {
        try self.init(stage: stage, plan: plan, admittedRequest: .legacy(request))
    }

    /// Larger geometry is admitted only through the explicit profile type. The
    /// same forward, ownership and boundary validation serve both request kinds.
    convenience init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                     profiledRequest: QwenLayerStageProfiledPrefillRequestSpec) throws {
        try self.init(stage: stage, plan: plan, admittedRequest: .profiled(profiledRequest))
    }

    convenience init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                     generationRequest: QwenLayerStageGenerationRequest) throws {
        try self.init(stage: stage, plan: plan, admittedRequest: .generation(generationRequest))
    }

    private init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                 admittedRequest request: QwenLayerStageAdmittedRequest) throws {
        guard plan.stages.indices.contains(stage.stageIndex), plan.stages.count == 2,
            stage.plan.fingerprint == plan.fingerprint else { throw ProbeError("Stage session received a different source plan") }
        let descriptor = plan.stages[stage.stageIndex], receipt = stage.receipt
        guard receipt.stageIndex == stage.stageIndex, receipt.planSHA256 == plan.fingerprint,
            receipt.stagePlanSHA256 == descriptor.fingerprint,
            receipt.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
            receipt.constructionConfigurationSHA256 == sha256(descriptor.constructionConfiguration),
            stage.configurationData == descriptor.constructionConfiguration,
            stage.layerCount == descriptor.sourceRange.count,
            modelParameterLayout(stage.model) == receipt.parameterLayoutSHA256,
            stage.model.trainableParameters().flattened().isEmpty,
            !stage.model.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }),
            stage.model is any CBv2RecurrentMTPForwardable,
            stage.model is any CBv2PositionedRecurrentEmbeddingForwardable,
            String(describing: stage.activationDType) == receipt.embeddingActivationDType,
            [.float16, .bfloat16, .float32].contains(stage.activationDType) else {
            throw ProbeError("Stage model identity, native dtype, frozen ownership or public forwarding contract differs")
        }
        if stage.stageIndex == 0 {
            try stage.requireInputKind(.tokens)
        } else {
            try stage.requireInputKind(.residual)
        }
        let root = try JSONSerialization.jsonObject(with: stage.configurationData) as! [String: Any]
        let text = root["text_config"] as? [String: Any] ?? root
        guard BoundedProbeInput.integer(text["num_hidden_layers"]) == stage.layerCount,
            BoundedProbeInput.integer(text["vocab_size"]) == stage.vocabularySize,
            let hidden = BoundedProbeInput.integer(text["hidden_size"]), (1...8192).contains(hidden) else {
            throw ProbeError("Compact stage metadata does not match its loaded layer/hidden/vocabulary geometry")
        }
        if case .generation(let generation) = request {
            guard generation.profile.hiddenSize == hidden,
                  generation.profile.vocabularySize == stage.vocabularySize,
                  generation.profile.activationDType == receipt.embeddingActivationDType else {
                throw ProbeError("Generation profile differs from the actual loaded stage geometry/dtype")
            }
        }
        let geometry = try CBv2RequestGeometry(model: stage.model, family: .qwen35, feedForwardKind: "dense",
            layerCount: stage.layerCount, vocabularySize: stage.vocabularySize,
            configurationData: stage.configurationData, maximumTokens: request.maximumTokens)
        self.state = try CBv2OwnedRequestState(geometry: geometry,
            promptCount: request.promptCount, outputCount: request.outputCount)
        self.stage = stage; self.descriptor = descriptor; self.request = request
        self.adapter = CBv2SteppableLanguageModelAdapter(stage.model)
        self.hiddenSize = hidden; self.producerStageFingerprint = plan.stages[0].fingerprint
        self.schedule = QwenLayerStageAdmittedSchedule(request: request)
        self.identity = .init(stageIndex: stage.stageIndex, requestFingerprint: request.fingerprint,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            bf16ConversionEnabled: receipt.bf16ConversionEnabled,
            sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            constructionConfigurationSHA256: receipt.constructionConfigurationSHA256,
            planFingerprint: plan.fingerprint, stageFingerprint: descriptor.fingerprint,
            activationDType: receipt.embeddingActivationDType)
    }

    func prefillChunk(_ tokens: [Int], offset: Int, final: Bool,
                      incoming: QwenLayerStageBoundary? = nil, observer: CBv2OwnerPhaseObserver? = nil,
                      check: () throws -> Void) throws -> QwenLayerStageOutput {
        do {
            try state.requireOpen()
            let frame = try schedule.admitPrefill(count: tokens.count, offset: offset, final: final)
            return try perform(tokens: tokens, frame: frame, incoming: incoming, observer: observer, check: check)
        } catch { try fail(error) }
    }

    func decode(_ token: Int, offset: Int, incoming: QwenLayerStageBoundary? = nil,
                check: () throws -> Void) throws -> QwenLayerStageOutput {
        do {
            try state.requireOpen()
            let frame = try schedule.admitDecode(offset: offset)
            return try perform(tokens: [token], frame: frame, incoming: incoming, check: check)
        } catch { try fail(error) }
    }

    /// Private experimental caller must reserve MTP history/capture storage
    /// before entering. Existing prefill/decode methods never select this path.
    func prefillChunkCapturingMTP(_ tokens: [Int], offset: Int, final: Bool,
        incoming: QwenLayerStageBoundary, check: () throws -> Void
    ) throws -> QwenLayerStageMTPOutput {
        try captureMTP(tokens: tokens, incoming: incoming, check: check) {
            try schedule.admitPrefill(count: tokens.count, offset: offset, final: final)
        }
    }

    func decodeCapturingMTP(_ token: Int, offset: Int, incoming: QwenLayerStageBoundary,
                           check: () throws -> Void) throws -> QwenLayerStageMTPOutput {
        try captureMTP(tokens: [token], incoming: incoming, check: check) {
            try schedule.admitDecode(offset: offset)
        }
    }

    private func captureMTP(tokens: [Int], incoming: QwenLayerStageBoundary,
        check: () throws -> Void, admit: () throws -> QwenLayerStageFrame
    ) throws -> QwenLayerStageMTPOutput {
        let capture = QwenLayerStageMTPCapture(tokens: tokens.count, hiddenSize: hiddenSize, dtype: stage.activationDType)
        defer { capture.discard() }
        do {
            try state.requireOpen()
            guard stage.stageIndex == 1, case .generation = request else {
                throw ProbeError("MTP capture requires an explicitly admitted final-rank generation session")
            }
            let frame = try admit()
            let output = try perform(tokens: tokens, frame: frame, incoming: incoming, capture: capture, check: check)
            return try .init(output: output, committed: capture.takeCommitted(identity: identity,
                frame: frame, tokens: tokens, nativeCommittedTokens: state.committedTokens))
        } catch { try fail(error) }
    }

    /// Private opt-in seam; ordinary generation never selects it. The owner
    /// must charge the returned extra ledger alongside its assistant/transport
    /// reservation, and keep that charge until all provisional/returned arrays
    /// release. No distributed commit or accepted output is implied here.
    func beginTargetVerification(profile: QwenRegisteredDenseModelProfile,
        proposal: QwenResidentMTPProposal, generation: QwenLayerStageGenerationControl,
        ownerCheck: (QwenTargetVerificationBudget) throws -> Void
    ) throws -> QwenTargetVerificationBudget {
        do {
            try state.requireOpen()
            guard case .generation = request, verification == nil,
                  !usedVerificationRounds.contains(proposal.roundID),
                  usedVerificationRounds.count < request.outputCount else {
                throw ProbeError("Target verification requires a fresh bounded generation round")
            }
            let spec = try QwenTargetVerificationRequest(proposal: proposal, generation: generation)
            let value = try QwenTargetVerificationExecution(request: spec, profile: profile, stage: stage,
                identity: identity, state: state, schedule: schedule)
            verification = value; usedVerificationRounds.insert(proposal.roundID)
            try value.begin(ownerCheck: ownerCheck)
            return value.resources.budget
        } catch { try fail(error) }
    }

    func stageTargetVerification(roundID: UUID, step: Int, incoming: QwenTargetVerificationBoundary? = nil,
        ownerCheck: (QwenTargetVerificationBudget) throws -> Void
    ) throws -> QwenTargetVerificationOutput {
        do {
            guard let verification, verification.request.proposal.roundID == roundID else {
                throw ProbeError("Target verification stage belongs to a different round")
            }
            return try verification.stage(step: step, incoming: incoming, ownerCheck: ownerCheck)
        } catch { try fail(error) }
    }

    /// After agreement on acceptance, commit only the oldest pending input.
    /// The owner joins BOTH prefix receipts before publishing its next token,
    /// then obtains the existing continue/stop decision before another commit.
    func commitNextTargetVerification(roundID: UUID,
        ownerCheck: (QwenTargetVerificationBudget) throws -> Void
    ) throws -> QwenTargetVerificationCommit {
        do {
            guard let verification, verification.request.proposal.roundID == roundID else {
                throw ProbeError("Target prefix commit belongs to a different round")
            }
            let next = try verification.request.reconciledSchedule(schedule,
                staged: verification.stagedCount, keeping: verification.committedCount + 1,
                alreadyCommitted: verification.committedCount)
            let result = try verification.commitNext(ownerCheck: ownerCheck)
            guard result.localReceipt.committedInputs == next.committedTokens,
                  state.committedTokens == next.committedTokens else {
                throw ProbeError("Progressive target commit differs from its scheduled frontier")
            }
            schedule = next
            return result
        } catch { try fail(error) }
    }

    func reconcileTargetVerification(roundID: UUID, keepingInputs count: Int,
        ownerCheck: (QwenTargetVerificationBudget) throws -> Void
    ) throws -> QwenTargetVerificationCommit {
        do {
            guard let verification, verification.request.proposal.roundID == roundID else {
                throw ProbeError("Target verification reconciliation belongs to a different round")
            }
            // Validate a VALUE COPY first. Publish the session schedule only
            // after native KV/recurrent reconciliation has succeeded completely.
            let next = try verification.request.reconciledSchedule(schedule,
                staged: verification.stagedCount, keeping: count, alreadyCommitted: verification.committedCount)
            let result = try verification.reconcile(keeping: count, ownerCheck: ownerCheck)
            guard result.localReceipt.committedInputs == next.committedTokens,
                  state.committedTokens == next.committedTokens else {
                throw ProbeError("Target verification native and scheduled frontiers differ")
            }
            schedule = next; self.verification = nil
            return result
        } catch { try fail(error) }
    }

    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,
                         observer: CBv2OwnerPhaseObserver? = nil, capture: QwenLayerStageMTPCapture? = nil,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            guard tokens.allSatisfy({ (0..<stage.vocabularySize).contains($0) }),
                state.committedTokens == schedule.committedTokens else { throw ProbeError("Stage token IDs or state frontier differs") }
            try validateInput(incoming, tokens: tokens, frame: frame)
            try checked()
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
            // nil positions use each stage's own KV absoluteOffset. Both states
            // start at zero and must match the SAME full-model tokenOffset here;
            // a stage's global layer offset never changes sequence positions.
            let output = try state.run(tokenCount: tokens.count, observer: observer, check: checked,
                additionalEvaluationTargets: capture.map { value in { value.evaluationTargets } }, forward: { caches, evaluation in
                if let capture {
                    guard stage.stageIndex == 1, let incoming else { throw ProbeError("MTP capture requires residual ingress") }
                    let requirement: Qwen35ClusterMTPForward.Output = frame.phase == .decode ? .decodeLastLogits
                        : (frame.finalPromptChunk ? .prefillLastLogits : .prefillEvaluation)
                    let value = try Qwen35ClusterMTPForward.forward(target: stage.model, tokens: input,
                        residual: incoming.array, caches: caches.map { $0 as! any KVCache },
                        recurrentState: [evaluation], output: requirement)
                    // The nested handler owns faults from graph construction.
                    // Check it before a secondary capture validation can throw.
                    try error.check()
                    try capture.stage(value.preNormHidden)
                    return value.value
                }
                if stage.stageIndex == 0 {
                    let native = stage.model as! any CBv2RecurrentMTPForwardable
                    // Ordinary noncaptured trunk: discard the lazy logits tuple
                    // member immediately. No stage-zero norm/head graph is eval'd.
                    return native.cbv2ForwardWithHidden(input,
                        caches: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil).lastHidden
                }
                if frame.phase == .prefill {
                    return adapter.recurrentPrefill(tokens: input, inputEmbeddings: incoming!.array,
                        caches: caches, recurrentState: [evaluation], positionIds: nil,
                        requirement: frame.finalPromptChunk ? .lastPositionLogits : .evaluationOnly)
                }
                let native = stage.model as! any CBv2PositionedRecurrentEmbeddingForwardable
                return native.embeddingForward(input, inputEmbedding: incoming!.array,
                    cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)[0..., -1, 0...]
            }, validateOutput: { array in
                try capture?.validate()
                let expected = stage.stageIndex == 0 ? [1, tokens.count, hiddenSize]
                    : [1, frame.phase == .prefill && !frame.finalPromptChunk ? 1 : stage.vocabularySize]
                guard array.shape == expected, [.float16, .bfloat16, .float32].contains(array.dtype),
                    stage.stageIndex != 0 || array.dtype == stage.activationDType else {
                    throw ProbeError("Stage output differs from the native residual/logit contract")
                }
            })
            try schedule.commit(frame)
            if stage.stageIndex == 0 {
                let digest = sha256(output.asData().data); try checked()
                return .hidden(.init(requestFingerprint: identity.requestFingerprint,
                    sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                    artifactAggregateSHA256: identity.artifactAggregateSHA256,
                    storageCommitmentSHA256: identity.storageCommitmentSHA256,
                    planFingerprint: identity.planFingerprint, producerStageFingerprint: identity.stageFingerprint,
                    frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens),
                    payloadSHA256: digest, array: output))
            }
            return frame.phase == .prefill && !frame.finalPromptChunk ? .evaluationHandle(output) : .logits(output)
        }
    }

    private func validateInput(_ incoming: QwenLayerStageBoundary?, tokens: [Int], frame: QwenLayerStageFrame) throws {
        if stage.stageIndex == 0 {
            guard incoming == nil else { throw ProbeError("Stage zero rejects supplied residual/embedding input") }
            return
        }
        guard let incoming, incoming.frame == frame,
            incoming.requestFingerprint == identity.requestFingerprint,
            incoming.artifactAggregateSHA256 == identity.artifactAggregateSHA256,
            incoming.storageCommitmentSHA256 == identity.storageCommitmentSHA256,
            incoming.sourceConfigurationSHA256 == identity.sourceConfigurationSHA256,
            incoming.planFingerprint == identity.planFingerprint,
            incoming.producerStageFingerprint == producerStageFingerprint,
            incoming.tokenIDsSHA256 == QwenLayerStageBoundary.tokenHash(tokens) else {
            throw ProbeError("Stage boundary request/model/producer/token/frontier identity differs")
        }
        try incoming.validateOwnedArray(tokens: tokens.count, hidden: hiddenSize, dtype: stage.activationDType)
    }

    func snapshot(includeBytes: Bool = false, check: () throws -> Void) throws -> CBv2OwnedStateSnapshot {
        do {
            return try MLX.withError { error in
                try state.snapshot(globalLayerIndices: descriptor.layers.map(\.globalIndex), includeBytes: includeBytes,
                    check: { try error.check(); try check() })
            }
        } catch { try fail(error) }
    }

    func close() throws {
        guard !isClosed else { return }
        guard schedule.complete else { try fail(ProbeError("Stage closed before the agreed token schedule completed")) }
        try retire(failed: false)
    }

    /// Called only after both ranks agree to EOS/length/client stop. This closes
    /// native request state without treating an ordinary early stop as failure.
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason,
                          selectedTokenCount: Int, lastTokenID: Int) throws {
        do {
            try state.requireOpen()
            try schedule.finishGeneration(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
            try retire(failed: false)
        } catch { try fail(error) }
    }

    func cancel() throws { try retire(failed: true) }

    private func retire(failed: Bool) throws {
        defer { verification?.discardOutputs(); verification = nil }
        do {
            try MLX.withError { error in
                try state.retire(failed: failed)
                try error.check()
            }
        } catch {
            try? state.retire(failed: true)
            throw error
        }
    }

    private func fail(_ primary: Error) throws -> Never {
        do { try retire(failed: true) }
        catch { throw ProbeError("Stage failed (\(primary)); retirement also failed (\(error))") }
        throw primary
    }

    deinit { try? retire(failed: !schedule.complete) }
}
