import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// One request on one loaded GPT-OSS stage: the stage's own attention caches,
/// the local token frontier and nothing else. No overlap, network, sampling or
/// hidden token history. Native methods run inside an MLX error scope and
/// retire the request state on every error.
///
/// The stage runs the product class's trunk through its public forward. Stage
/// 0 passes token IDs and takes what the trunk returns, which is the residual
/// after the stage's last layer because its final norm is an identity. Stage 1
/// passes that residual as input embeddings and applies the model's own head:
/// to the last position of the final prompt chunk and to every decode step,
/// in the shapes the product uses for each. State is the class's ordinary
/// caches, one per local layer: a growing cache for a full-attention layer and
/// a rotating one of the window's size for a sliding-window layer. There is no
/// recurrent state. Positions come from each cache's own offset, which both
/// stages advance by the same token counts.
final class GPTOSSLayerStageSession {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageGenerationRequest
    private let stage: LoadedGPTOSSLayerStage
    private let descriptor: GPTOSSLayerStagePlan.Stage
    private let hiddenSize: Int
    private let producerStageFingerprint: String
    private var caches: [any KVCache]?
    private var schedule: QwenLayerStageGenerationSchedule
    private(set) var isClosed = false
    private(set) var isFailed = false

    var committedTokens: Int { schedule.committedTokens }

    init(stage: LoadedGPTOSSLayerStage, plan: GPTOSSLayerStagePlan,
         generationRequest request: QwenLayerStageGenerationRequest) throws {
        guard plan.stages.count == 2, plan.stages.indices.contains(stage.stageIndex),
              stage.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("GPT-OSS stage session received a different source plan")
        }
        let descriptor = plan.stages[stage.stageIndex], receipt = stage.receipt
        guard receipt.stageIndex == stage.stageIndex, receipt.planSHA256 == plan.fingerprint,
              receipt.stagePlanSHA256 == descriptor.fingerprint,
              receipt.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
              receipt.constructionConfigurationSHA256 == sha256(descriptor.constructionConfiguration),
              stage.layerCount == descriptor.sourceRange.count,
              modelParameterLayout(stage.model) == receipt.parameterLayoutSHA256,
              stage.model.trainableParameters().flattened().isEmpty,
              (stage.head != nil) == (stage.stageIndex == 1),
              stage.activationDType == .bfloat16,
              String(describing: stage.activationDType) == receipt.embeddingActivationDType else {
            throw ProbeError("GPT-OSS stage model identity, native dtype or frozen ownership differs")
        }
        let spec = plan.specification
        guard request.profile.hiddenSize == spec.hidden, request.profile.vocabularySize == stage.vocabularySize,
              stage.vocabularySize == spec.vocabulary,
              request.profile.activationDType == receipt.embeddingActivationDType,
              request.maximumTokens <= spec.maximumPositions else {
            throw ProbeError("Generation profile differs from the actual loaded GPT-OSS stage geometry/dtype")
        }
        let caches = stage.model.newCache(parameters: nil)
        guard caches.count == descriptor.layers.count,
              zip(caches, descriptor.layers).allSatisfy({ cache, layer in
                  cache.offset == 0 && (cache.maxSize == nil
                      ? layer.kind == GPTOSSRegisteredSpecification.fullAttention
                      : layer.kind == GPTOSSRegisteredSpecification.slidingAttention && cache.maxSize == spec.slidingWindow)
              }) else { throw ProbeError("GPT-OSS stage caches differ from the stage's layer types") }
        self.stage = stage; self.descriptor = descriptor; self.request = request; hiddenSize = spec.hidden
        producerStageFingerprint = plan.stages[0].fingerprint
        self.caches = caches
        schedule = QwenLayerStageGenerationSchedule(request: request)
        identity = .init(stageIndex: stage.stageIndex, requestFingerprint: request.fingerprint,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            bf16ConversionEnabled: receipt.bf16ConversionEnabled,
            sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            constructionConfigurationSHA256: receipt.constructionConfigurationSHA256,
            planFingerprint: plan.fingerprint, stageFingerprint: descriptor.fingerprint,
            activationDType: receipt.embeddingActivationDType)
    }

    func prefillChunk(_ tokens: [Int], offset: Int, final: Bool, incoming: QwenLayerStageBoundary? = nil,
                      check: () throws -> Void) throws -> QwenLayerStageOutput {
        do {
            try requireOpen()
            let frame = try schedule.admitPrefill(count: tokens.count, offset: offset, final: final)
            return try perform(tokens: tokens, frame: frame, incoming: incoming, check: check)
        } catch { try fail(error) }
    }

    func decode(_ token: Int, offset: Int, incoming: QwenLayerStageBoundary? = nil,
                check: () throws -> Void) throws -> QwenLayerStageOutput {
        do {
            try requireOpen()
            let frame = try schedule.admitDecode(offset: offset)
            return try perform(tokens: [token], frame: frame, incoming: incoming, check: check)
        } catch { try fail(error) }
    }

    private func requireOpen() throws {
        guard !isClosed, !isFailed, caches != nil else { throw ProbeError("GPT-OSS stage request state is retired or failed") }
    }

    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            guard let caches, tokens.allSatisfy({ (0..<stage.vocabularySize).contains($0) }),
                  caches.allSatisfy({ $0.offset == schedule.committedTokens }) else {
                throw ProbeError("GPT-OSS stage token IDs or state frontier differs")
            }
            try validateInput(incoming, tokens: tokens, frame: frame)
            try checked()
            let count = tokens.count
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, count])
            func roots() -> [MLXArray] { caches.flatMap { $0.innerState() } }
            if stage.stageIndex == 0 {
                // The trunk ends in the identity norm: this is the residual
                // after the stage's last layer. No head exists to evaluate.
                let residual = stage.model.model(input, cache: caches)
                eval([residual] + roots()); try checked()
                try requireFrontier(after: schedule.committedTokens + count)
                guard residual.shape == [1, count, hiddenSize], residual.dtype == stage.activationDType else {
                    throw ProbeError("GPT-OSS stage output differs from the native residual contract")
                }
                try schedule.commit(frame)
                // eval returns at the output event, which can precede the Metal
                // completion handlers that still hold this buffer; the sender
                // refuses a residual it does not own alone.
                Stream.gpu.synchronize(); try checked()
                let digest = sha256(residual.asData().data); try checked()
                return .hidden(.init(requestFingerprint: identity.requestFingerprint,
                    sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                    artifactAggregateSHA256: identity.artifactAggregateSHA256,
                    storageCommitmentSHA256: identity.storageCommitmentSHA256,
                    planFingerprint: identity.planFingerprint, producerStageFingerprint: identity.stageFingerprint,
                    frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens),
                    payloadSHA256: digest, array: residual))
            }
            guard let head = stage.head, let incoming else { throw ProbeError("GPT-OSS stage 1 lacks its head or residual") }
            // The token IDs only size the call; the embedding is never looked up.
            let hidden = stage.model.model(input, cache: caches, inputEmbeddings: incoming.array)
            let wantsLogits = frame.phase == .decode || frame.finalPromptChunk
            let output: MLXArray
            if frame.phase == .decode {
                // The product's decode forward: the head over the step, then the row.
                output = head(hidden)[0..., -1, 0...]
            } else if frame.finalPromptChunk {
                // The product's prompt-output default: the head over the last position only.
                output = head(hidden[0..., -1, 0...])
            } else {
                // An intermediate prompt chunk projects no vocabulary row; this
                // handle depends on the whole normalized trunk of the chunk.
                output = hidden[0..., -1, 0..<1]
            }
            eval([output] + roots()); try checked()
            try requireFrontier(after: schedule.committedTokens + count)
            guard output.shape == [1, wantsLogits ? stage.vocabularySize : 1],
                  [DType.float16, .bfloat16, .float32].contains(output.dtype) else {
                throw ProbeError("GPT-OSS stage output differs from the native logit contract")
            }
            try schedule.commit(frame)
            return wantsLogits ? .logits(output) : .evaluationHandle(output)
        }
    }

    private func requireFrontier(after count: Int) throws {
        guard let caches, caches.allSatisfy({ $0.offset == count }) else {
            throw ProbeError("GPT-OSS stage attention state did not advance to the frame's frontier")
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

    /// Digests of this stage's committed attention state, keyed by the model's
    /// global layer index: each layer's retained keys and values as its cache
    /// holds them. A sliding-window layer retains its window only. It reads
    /// state; the session stays open.
    func stateEntries(check: () throws -> Void) throws -> [QwenRecordedState.Entry] {
        do {
            try requireOpen()
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                guard let caches, caches.allSatisfy({ $0.offset == schedule.committedTokens }),
                      schedule.committedTokens > 0 else {
                    throw ProbeError("GPT-OSS stage state has no committed frontier to record")
                }
                var entries: [QwenRecordedState.Entry] = []
                for (cache, layer) in zip(caches, descriptor.layers) {
                    let state = cache.state
                    guard state.count == 2 else { throw ProbeError("GPT-OSS stage cache holds no keys and values") }
                    for (component, array) in zip(["kv.keys", "kv.values"], state) {
                        let bytes = array.asData().data
                        try checked()
                        guard bytes.count == array.nbytes, !bytes.isEmpty else {
                            throw ProbeError("GPT-OSS stage state logical byte count differs")
                        }
                        entries.append(.init(globalLayerIndex: layer.globalIndex, component: component,
                            shape: array.shape, dtype: String(describing: array.dtype),
                            byteCount: bytes.count, sha256: sha256(bytes)))
                    }
                }
                return entries.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
            }
        } catch { try fail(error) }
    }

    /// Called only after both ranks agree to EOS, length or client stop.
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason,
                          selectedTokenCount: Int, lastTokenID: Int) throws {
        do {
            try requireOpen()
            try schedule.finish(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID)
            try retire(failed: false)
        } catch { try fail(error) }
    }

    func cancel() throws { try retire(failed: true) }

    private func retire(failed: Bool) throws {
        isFailed = isFailed || failed
        guard !isClosed else { return }
        try MLX.withError { error in
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            caches = nil
            try error.check()
        }
        isClosed = true
    }

    private func fail(_ primary: Error) throws -> Never {
        do { try retire(failed: true) }
        catch { throw ProbeError("GPT-OSS stage failed (\(primary)); retirement also failed (\(error))") }
        throw primary
    }

    deinit { caches = nil }
}
