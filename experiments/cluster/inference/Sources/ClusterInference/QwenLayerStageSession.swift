import Foundation
import MLX
import MLXLLM
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

    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,
                         observer: CBv2OwnerPhaseObserver? = nil, check: () throws -> Void) throws -> QwenLayerStageOutput {
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
            let output = try state.run(tokenCount: tokens.count, observer: observer, check: checked, forward: { caches, evaluation in
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

    func cancel() throws { try retire(failed: true) }

    private func retire(failed: Bool) throws {
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
