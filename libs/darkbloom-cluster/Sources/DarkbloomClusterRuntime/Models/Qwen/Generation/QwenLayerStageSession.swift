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

/// One stage's complete committed request state as authenticated arrays, keyed
/// by the model's global layer index. Produced by a hand-off; nothing else.
struct QwenLayerStageAdoptedState {
    let committedTokens: Int
    let attention: [Int: (keys: MLXArray, values: MLXArray)]
    let recurrent: [Int: (conv: MLXArray, ssm: MLXArray)]
}

/// One serialized stage; no overlap, network, sampling or hidden token-history
/// changes. Native methods install an error handler and retire on every error.
final class QwenLayerStageSession {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageGenerationRequest
    private let stage: LoadedQwenLayerStage
    private let descriptor: QwenLayerStagePlan.Stage
    private let adapter: CBv2SteppableLanguageModelAdapter
    private let state: CBv2OwnedRequestState
    private let hiddenSize: Int
    private let producerStageFingerprint: String
    private var schedule: QwenLayerStageGenerationSchedule
    private var handedOff = false

    var committedTokens: Int { schedule.committedTokens }
    var isClosed: Bool { state.isClosed }
    var isFailed: Bool { state.isFailed }

    /// `adopting` starts the stage from another owner's committed prompt state
    /// instead of empty state. Only the producer stage can be adopted, and only
    /// at the frontier after its last prompt frame.
    init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
         generationRequest request: QwenLayerStageGenerationRequest,
         adopting: QwenLayerStageAdoptedState? = nil) throws {
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
            stage.model is any LayerStageFrameForwarding
                || (stage.model is any CBv2RecurrentMTPForwardable
                    && stage.model is any CBv2PositionedRecurrentEmbeddingForwardable),
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
        guard request.profile.hiddenSize == hidden,
              request.profile.vocabularySize == stage.vocabularySize,
              request.profile.activationDType == receipt.embeddingActivationDType else {
            throw ProbeError("Generation profile differs from the actual loaded stage geometry/dtype")
        }
        let geometry = try (stage.model as? any LayerStageFrameForwarding)?
            .layerStageRequestGeometry(maximumTokens: request.maximumTokens)
            ?? CBv2RequestGeometry(model: stage.model, family: .qwen35,
                feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(stage.model),
                layerCount: stage.layerCount, vocabularySize: stage.vocabularySize,
                configurationData: stage.configurationData, maximumTokens: request.maximumTokens)
        if let adopting {
            guard stage.stageIndex == 0 else { throw ProbeError("Only the producer stage's state can be adopted") }
            // Global to the compact stage's own indices, through its layer map.
            let local = Dictionary(uniqueKeysWithValues: descriptor.layers.map { ($0.globalIndex, $0.localIndex) })
            func localized<Value>(_ values: [Int: Value]) throws -> [Int: Value] {
                var result: [Int: Value] = [:]
                for (global, value) in values {
                    guard let index = local[global], result.updateValue(value, forKey: index) == nil else {
                        throw ProbeError("Adopted state names a layer outside this stage")
                    }
                }
                return result
            }
            self.schedule = try QwenLayerStageGenerationSchedule(request: request,
                adoptedCommittedTokens: adopting.committedTokens)
            self.state = try MLX.withError { error in
                let value = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                    outputCount: request.outputCount, adoptingCommittedTokens: adopting.committedTokens,
                    attention: try localized(adopting.attention), recurrent: try localized(adopting.recurrent))
                try error.check()
                return value
            }
        } else {
            self.state = try CBv2OwnedRequestState(geometry: geometry,
                promptCount: request.promptCount, outputCount: request.outputCount)
            self.schedule = QwenLayerStageGenerationSchedule(request: request)
        }
        self.stage = stage; self.descriptor = descriptor; self.request = request
        self.adapter = CBv2SteppableLanguageModelAdapter(stage.model)
        self.hiddenSize = hidden; self.producerStageFingerprint = plan.stages[0].fingerprint
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
                if let own = stage.model as? any LayerStageFrameForwarding {
                    return own.layerStageForward(tokens: input, residual: incoming?.array, caches: caches, frame: frame)
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
                let expected = stage.stageIndex == 0 ? [1, tokens.count, hiddenSize]
                    : [1, frame.phase == .prefill && !frame.finalPromptChunk ? 1 : stage.vocabularySize]
                guard array.shape == expected, [.float16, .bfloat16, .float32].contains(array.dtype),
                    stage.stageIndex != 0 || array.dtype == stage.activationDType else {
                    throw ProbeError("Stage output differs from the native residual/logit contract")
                }
            })
            try schedule.commit(frame)
            if stage.stageIndex == 0 {
                // eval returns at the output event, which can precede the Metal
                // completion handlers that still hold this buffer. The sender
                // inspects the residual's storage and refuses one it does not
                // own alone, so drain the GPU stream before handing it over.
                Stream.gpu.synchronize(); try checked()
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
    /// `discardedDecodeForwards` is nonzero only for a stage that decoded alone
    /// past a client stop it had not yet been told about.
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason,
                          selectedTokenCount: Int, lastTokenID: Int,
                          discardedDecodeForwards: Int = 0) throws {
        do {
            try state.requireOpen()
            try schedule.finish(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID,
                discardedDecodeForwards: discardedDecodeForwards)
            try retire(failed: false)
        } catch { try fail(error) }
    }

    /// The producer stage's committed prompt state as hand-off components, in
    /// snapshot order with logical bytes and digests. It reads state; the
    /// session stays open until `retireAfterHandoff`.
    func handoffComponents(check: () throws -> Void) throws -> [QwenPhaseSplitHandoffSender.Component] {
        do {
            guard stage.stageIndex == 0, schedule.committedPromptTokens == request.promptCount,
                  schedule.decodeForwardCount == 0, !handedOff else {
                throw ProbeError("Only the producer stage hands over, once, after its last prompt frame")
            }
            let snapshot = try self.snapshot(includeBytes: true, check: check)
            guard snapshot.committedTokens == request.promptCount else { throw ProbeError("Hand-off snapshot frontier differs") }
            return snapshot.entries.map { entry in
                let shape = QwenPhaseSplitStateShape(globalLayerIndex: entry.globalLayerIndex, component: entry.component,
                    shape: entry.shape, dtype: entry.dtype, byteCount: entry.byteCount)
                // Position offsets follow from the frontier; an empty component has nothing to send.
                let sent = entry.component != QwenPhaseSplitStateShape.positionOffsets && entry.byteCount > 0
                return .init(shape: shape, sha256: entry.sha256, bytes: sent ? entry.bytes : nil)
            }
        } catch { try fail(error) }
    }

    /// After the adopting rank accepted the complete state. Retires this
    /// stage's native request state; no further frame can run here.
    func retireAfterHandoff() throws {
        do {
            try state.requireOpen()
            guard stage.stageIndex == 0, schedule.committedPromptTokens == request.promptCount,
                  schedule.decodeForwardCount == 0, !handedOff else {
                throw ProbeError("Hand-off retirement differs from the producer's committed prompt frontier")
            }
            handedOff = true
            try retire(failed: false)
        } catch { try fail(error) }
    }

    /// The state-snapshot fingerprint of the current committed state.
    func stateFingerprint(check: () throws -> Void) throws -> String {
        try snapshot(includeBytes: false, check: check).fingerprint
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

    deinit { try? retire(failed: !(schedule.complete || handedOff)) }
}
