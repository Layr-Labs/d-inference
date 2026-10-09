import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// One request on one loaded MiMo stage: the stage's own attention caches, the
/// local token frontier and nothing else. No overlap, network, sampling or
/// hidden token history. Native methods run inside an MLX error scope and
/// retire the request state on every error.
///
/// The stage runs the product's text class through its public forward: stage 0
/// passes token IDs and takes the residual the class captures after the
/// stage's last layer; stage 1 passes that residual as input embeddings and
/// takes logits. State is the class's ordinary caches, one per local layer: a
/// growing cache for a full-attention layer and a rotating one for a
/// sliding-window layer. Positions come from each cache's own offset, which
/// both stages advance by the same token counts.
final class MiMoLayerStageSession {
    let identity: QwenLayerStageSessionIdentity
    let request: QwenLayerStageGenerationRequest
    private let stage: LoadedMiMoLayerStage
    private let hiddenSize: Int
    private let producerStageFingerprint: String
    private var caches: [KVCache]?
    private var schedule: QwenLayerStageGenerationSchedule
    private(set) var isClosed = false
    private(set) var isFailed = false
    /// SHA-256 chain over every boundary payload this stage produced or
    /// consumed, in frame order: run-to-run evidence that costs nothing extra.
    private(set) var boundaryChainSHA256: String
    /// Stage 1: SHA-256 of the last logits row a token was selected from.
    private(set) var lastRowSHA256: String?

    var committedTokens: Int { schedule.committedTokens }

    init(stage: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
         generationRequest request: QwenLayerStageGenerationRequest) throws {
        guard plan.stages.count == 2, plan.stages.indices.contains(stage.stageIndex),
              stage.plan.fingerprint == plan.fingerprint else {
            throw ProbeError("MiMo stage session received a different source plan")
        }
        let descriptor = plan.stages[stage.stageIndex], receipt = stage.receipt
        guard receipt.stageIndex == stage.stageIndex, receipt.planSHA256 == plan.fingerprint,
              receipt.stagePlanSHA256 == descriptor.fingerprint,
              receipt.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
              receipt.constructionConfigurationSHA256 == sha256(descriptor.constructionConfiguration),
              stage.layerCount == descriptor.sourceRange.count,
              stage.model.configuration.numHiddenLayers == stage.layerCount,
              modelParameterLayout(stage.model) == receipt.parameterLayoutSHA256,
              stage.model.trainableParameters().flattened().isEmpty,
              stage.activationDType == .bfloat16,
              String(describing: stage.activationDType) == receipt.embeddingActivationDType else {
            throw ProbeError("MiMo stage model identity, native dtype or frozen ownership differs")
        }
        let hidden = stage.model.configuration.hiddenSize
        guard request.profile.hiddenSize == hidden, request.profile.vocabularySize == stage.vocabularySize,
              stage.model.configuration.vocabularySize == stage.vocabularySize,
              request.profile.activationDType == receipt.embeddingActivationDType,
              request.maximumTokens <= stage.model.configuration.maxPositionEmbeddings else {
            throw ProbeError("Generation profile differs from the actual loaded MiMo stage geometry/dtype")
        }
        self.stage = stage; self.request = request; hiddenSize = hidden
        producerStageFingerprint = plan.stages[0].fingerprint
        caches = stage.model.newCache()
        schedule = QwenLayerStageGenerationSchedule(request: request)
        identity = .init(stageIndex: stage.stageIndex, requestFingerprint: request.fingerprint,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            bf16ConversionEnabled: receipt.bf16ConversionEnabled,
            sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            constructionConfigurationSHA256: receipt.constructionConfigurationSHA256,
            planFingerprint: plan.fingerprint, stageFingerprint: descriptor.fingerprint,
            activationDType: receipt.embeddingActivationDType)
        boundaryChainSHA256 = sha256(Data(("mimo-stage-boundary-chain-v1|" + request.fingerprint).utf8))
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
        guard !isClosed, !isFailed, caches != nil else { throw ProbeError("MiMo stage request state is retired or failed") }
    }

    private func perform(tokens: [Int], frame: QwenLayerStageFrame, incoming: QwenLayerStageBoundary?,
                         check: () throws -> Void) throws -> QwenLayerStageOutput {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            guard let caches, tokens.allSatisfy({ (0..<stage.vocabularySize).contains($0) }),
                  caches.allSatisfy({ $0.offset == schedule.committedTokens }) else {
                throw ProbeError("MiMo stage token IDs or state frontier differs")
            }
            try validateInput(incoming, tokens: tokens, frame: frame)
            try checked()
            let count = tokens.count
            func roots() -> [MLXArray] { caches.flatMap { $0.innerState() } }
            if stage.stageIndex == 0 {
                // The class's lazy norm, readout and logits are never evaluated:
                // only the captured residual leaves this scope.
                let last = stage.layerCount - 1
                let residual: MLXArray = try {
                    let input = MLXArray(tokens.map(Int32.init)).reshaped([1, count])
                    let output = try stage.model.forward(inputIDs: input, cache: caches, captureLayers: [last])
                    guard let value = output.layerFeatures[last] else {
                        throw ProbeError("MiMo stage 0 produced no residual after its last layer")
                    }
                    return value
                }()
                eval([residual] + roots()); try checked()
                try requireFrontier(after: schedule.committedTokens + count)
                guard residual.shape == [1, count, hiddenSize], residual.dtype == stage.activationDType else {
                    throw ProbeError("MiMo stage output differs from the native residual contract")
                }
                try schedule.commit(frame)
                // eval returns at the output event, which can precede the Metal
                // completion handlers that still hold this buffer; the sender
                // refuses a residual it does not own alone.
                Stream.gpu.synchronize(); try checked()
                let digest = sha256(residual.asData().data); try checked()
                chain(digest)
                return .hidden(.init(requestFingerprint: identity.requestFingerprint,
                    sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                    artifactAggregateSHA256: identity.artifactAggregateSHA256,
                    storageCommitmentSHA256: identity.storageCommitmentSHA256,
                    planFingerprint: identity.planFingerprint, producerStageFingerprint: identity.stageFingerprint,
                    frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens),
                    payloadSHA256: digest, array: residual))
            }
            let wantsLogits = frame.phase == .decode || frame.finalPromptChunk
            let output: MLXArray = try {
                let result = try stage.model.forward(embeddings: incoming!.array, cache: caches,
                                                     logitsStart: count - 1)
                // An intermediate prompt chunk projects no vocabulary row: a
                // reduction over the whole normalized trunk proves every row ran.
                return wantsLogits ? result.logits[0..., -1, 0...]
                    : result.normalizedHiddenStates.sum(axes: [1, 2]).reshaped(-1, 1)
            }()
            eval([output] + roots()); try checked()
            try requireFrontier(after: schedule.committedTokens + count)
            guard output.shape == [1, wantsLogits ? stage.vocabularySize : 1],
                  [.float16, .bfloat16, .float32].contains(output.dtype) else {
                throw ProbeError("MiMo stage output differs from the native logit contract")
            }
            try schedule.commit(frame)
            chain(incoming!.payloadSHA256)
            if wantsLogits {
                Stream.gpu.synchronize(); try checked()
                lastRowSHA256 = sha256(output.asData().data); try checked()
                return .logits(output)
            }
            return .evaluationHandle(output)
        }
    }

    private func chain(_ payloadSHA256: String) {
        boundaryChainSHA256 = sha256(Data((boundaryChainSHA256 + "|" + payloadSHA256).utf8))
    }

    private func requireFrontier(after count: Int) throws {
        guard let caches, caches.allSatisfy({ $0.offset == count }) else {
            throw ProbeError("MiMo stage attention state did not advance to the frame's frontier")
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
        catch { throw ProbeError("MiMo stage failed (\(primary)); retirement also failed (\(error))") }
        throw primary
    }

    deinit { caches = nil }
}
