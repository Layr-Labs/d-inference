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
    private var imageFeatures: MiMoStageImageFeatures?
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
    /// Stage 1, when asked: one record per logits row, in order. Read from the
    /// bytes the row digest already copies; no extra native work.
    let recordsSteps: Bool
    private(set) var steps: [MiMoStepEvidence] = []
    /// The model's global layer index of each local cache, in local order.
    let globalLayers: [Int]
    /// This request's prompt-prefix capture (`ClusterStagePrefixCapture.mimo`); nil
    /// when the prefix cache is off or the plan split no final token.
    var prefixCapture: ClusterStagePrefixCapture?
    /// Stage 1 of `pipeline_mtp_v1`: told every committed prompt chunk's
    /// tokens and the post-final-norm rows the stage computed for them, after
    /// the chunk committed (the speculative head's history).
    var promptObserver: ((_ tokens: [Int], _ normalizedHidden: MLXArray) throws -> Void)?
    /// Rows of a verify window that ran but are not yet kept (`openWindow`).
    private var windowRows: Int?
    /// The producer stage's state left this rank (a phase split's hand-off),
    /// or it ran nothing for a request the decoding rank served alone.
    private var handedOff = false

    var committedTokens: Int { schedule.committedTokens }

    /// `restoring` starts the stage from its own cached state at the agreed
    /// reused prefix (`request.reusedPrefixTokens`) instead of empty caches.
    /// `adopting` starts the producer stage from another rank's committed
    /// prompt state (a phase split's hand-off): the arrays in `split`'s
    /// component order, already checked against the sender's digests. At most one.
    init(stage: LoadedMiMoLayerStage, plan: MiMoLayerStagePlan,
         generationRequest request: QwenLayerStageGenerationRequest, recordsSteps: Bool = false,
         restoring: QwenStagePrefixState? = nil,
         adopting: QwenLayerStageAdoptedState? = nil, split: QwenPhaseSplitPlan? = nil) throws {
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
        self.recordsSteps = recordsSteps && stage.stageIndex == 1
        producerStageFingerprint = plan.stages[0].fingerprint
        let layers = descriptor.layers.sorted { $0.localIndex < $1.localIndex }
        guard layers.map(\.localIndex) == Array(0..<stage.layerCount) else {
            throw ProbeError("MiMo stage plan layers differ from the loaded stage")
        }
        globalLayers = layers.map(\.globalIndex)
        let fresh = stage.model.newCache()
        if let restoring {
            guard adopting == nil, split == nil, request.reusedPrefixTokens > 0,
                  restoring.committedTokens == request.reusedPrefixTokens else {
                throw ProbeError("Only the agreed reused prefix can be adopted")
            }
            try MiMoStagePrefixSnapshot.restore(restoring, into: fresh, globalLayers: globalLayers)
            schedule = QwenLayerStageGenerationSchedule(request: request)
        } else if let adopting {
            guard let split, stage.stageIndex == 0, adopting.committedTokens == request.promptCount,
                  adopting.recurrent.isEmpty, request.reusedPrefixTokens == 0 else {
                throw ProbeError("Only the producer stage adopts, at the end of its prompt, with the agreed terms")
            }
            try MiMoPhaseSplitState.install(adopting, into: fresh, shapes: split.shapes,
                frames: try MiMoPhaseSplitState.frameTokenCounts(request), configuration: stage.model.configuration)
            schedule = try QwenLayerStageGenerationSchedule(request: request,
                                                            adoptedCommittedTokens: adopting.committedTokens)
        } else {
            guard request.reusedPrefixTokens == 0 else { throw ProbeError("A reused prefix needs its restored state") }
            guard split == nil else { throw ProbeError("Phase-split terms come with adopted state only") }
            schedule = QwenLayerStageGenerationSchedule(request: request)
        }
        caches = fresh
        identity = .init(stageIndex: stage.stageIndex, requestFingerprint: request.fingerprint,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: stage.storageCommitmentSHA256,
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
        guard !isClosed, !isFailed, caches != nil, windowRows == nil else {
            throw ProbeError("MiMo stage request state is retired, failed or inside a verify window")
        }
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
                    let output: MiMoV26TextOutput
                    if let media = request.mimoImages, frame.phase == .prefill {
                        guard let vision = stage.vision else { throw ProbeError("MiMo image stage has no owned tower") }
                        if imageFeatures == nil {
                            imageFeatures = MiMoStageImageFeatures(media:media)
                            try imageFeatures!.prepare(owner:vision,check:checked)
                        }
                        let embeddings = try imageFeatures!.embeddings(tokens:tokens,offset:frame.tokenOffset,model:stage.model)
                        output = try stage.model.forward(embeddings:embeddings,cache:caches,captureLayers:[last])
                    } else {
                        output = try stage.model.forward(inputIDs:input,cache:caches,captureLayers:[last])
                    }
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
                try capturePrefix(after: frame)
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
            let result = try stage.model.forward(embeddings: incoming!.array, cache: caches, logitsStart: count - 1)
            // An intermediate prompt chunk projects no vocabulary row: a
            // reduction over the whole normalized trunk proves every row ran.
            let output = wantsLogits ? result.logits[0..., -1, 0...]
                : result.normalizedHiddenStates.sum(axes: [1, 2]).reshaped(-1, 1)
            eval([output] + roots()); try checked()
            try requireFrontier(after: schedule.committedTokens + count)
            guard output.shape == [1, wantsLogits ? stage.vocabularySize : 1],
                  [.float16, .bfloat16, .float32].contains(output.dtype) else {
                throw ProbeError("MiMo stage output differs from the native logit contract")
            }
            try schedule.commit(frame)
            try capturePrefix(after: frame)
            chain(incoming!.payloadSHA256)
            if frame.phase == .prefill, let promptObserver {
                // The rows were evaluated with the frame; the head's own work is
                // queued here and joins the stream behind them.
                try promptObserver(tokens, result.normalizedHiddenStates); try checked()
            }
            if wantsLogits {
                Stream.gpu.synchronize(); try checked()
                let bytes = output.asData().data
                let digest = sha256(bytes)
                lastRowSHA256 = digest; try checked()
                if recordsSteps {
                    let dtype = String(describing: output.dtype)
                    steps.append(.init(ordinal: steps.count, boundarySHA256: incoming!.payloadSHA256,
                        rowSHA256: digest, rowDType: dtype,
                        top: try MiMoStepEvidence.candidates(rowBytes: bytes, dtype: dtype)))
                }
                return .logits(output)
            }
            return .evaluationHandle(output)
        }
    }

    /// After a committed prompt frame: the capture keeps this frontier when
    /// it is one of its planned frontiers (its copies only; no frame depends on it).
    private func capturePrefix(after frame: QwenLayerStageFrame) throws {
        guard frame.phase == .prefill, let prefixCapture, let caches else { return }
        try prefixCapture.capture(at: frame.tokenOffset + frame.tokenCount, caches: caches, globalLayers: globalLayers)
    }

    // MARK: Verify windows (`pipeline_mtp_v1`)

    /// Stage 0: one verify window `[last, d1 ... dk]` from the committed
    /// frontier, through the stage's ordinary multi-token forward (the path
    /// a prompt chunk takes). The caches advance by every row; nothing is
    /// committed until `settleWindow` keeps a prefix. Returns the residual
    /// `[1, n, H]` (evaluated, owned, compact) and each row's digest.
    func openWindow(_ tokens: [Int], offset: Int,
                    check: () throws -> Void) throws -> (residual: MLXArray, rowSHA256: [String]) {
        do {
            try requireWindowable(tokens, offset: offset, producer: true)
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                let caches = caches!, count = tokens.count, last = stage.layerCount - 1
                let input = MLXArray(tokens.map(Int32.init)).reshaped([1, count])
                let output = try stage.model.forward(inputIDs: input, cache: caches, captureLayers: [last])
                guard let residual = output.layerFeatures[last] else {
                    throw ProbeError("MiMo stage 0 produced no residual for the verify window")
                }
                eval([residual] + caches.flatMap { $0.innerState() }); try checked()
                windowRows = count
                try requireFrontier(after: schedule.committedTokens + count)
                guard residual.shape == [1, count, hiddenSize], residual.dtype == stage.activationDType else {
                    throw ProbeError("MiMo verify window residual differs from the native contract")
                }
                Stream.gpu.synchronize(); try checked()
                let rows = try MiMoWindowRows.rowSHA256(residual)
                try checked()
                return (residual, rows)
            }
        } catch { try fail(error) }
    }

    /// Stage 1: the same window from the producer's residual. Returns the
    /// logits of every row `[1, n, V]` and the post-final-norm rows `[1, n, H]`
    /// (lazy; the caller evaluates them with its own work).
    func openWindow(_ tokens: [Int], offset: Int, residual: MLXArray,
                    check: () throws -> Void) throws -> (logits: MLXArray, hidden: MLXArray, roots: [MLXArray]) {
        do {
            try requireWindowable(tokens, offset: offset, producer: false)
            guard residual.shape == [1, tokens.count, hiddenSize], residual.dtype == stage.activationDType else {
                throw ProbeError("MiMo verify window residual differs from the native contract")
            }
            return try MLX.withError { error in
                try error.check(); try check()
                let caches = caches!
                let result = try stage.model.forward(embeddings: residual, cache: caches, logitsStart: 0)
                windowRows = tokens.count
                return (result.logits, result.normalizedHiddenStates, caches.flatMap { $0.innerState() })
            }
        } catch { try fail(error) }
    }

    /// After the window's evaluation: the caches stand at the frontier plus
    /// every window row.
    func confirmWindow(check: () throws -> Void) throws {
        do {
            guard let rows = windowRows else { throw ProbeError("MiMo stage has no verify window to confirm") }
            try requireFrontier(after: schedule.committedTokens + rows)
            try check()
        } catch { try fail(error) }
    }

    /// Keeps the window's first `keeping` rows: every cache is rolled back by
    /// the rest (`MiMoWindowRollback`), then each kept row commits as the
    /// decode frame it stands for, its residual digest extending the chain.
    func settleWindow(keeping: Int, rowSHA256: [String], check: () throws -> Void) throws {
        do {
            guard let rows = windowRows, (1...rows).contains(keeping), rowSHA256.count >= keeping,
                  let caches else {
                throw ProbeError("MiMo verify window keeps rows it did not run")
            }
            try MLX.withError { error in
                try MiMoWindowRollback.trim(caches, by: rows - keeping)
                eval(caches.flatMap { $0.innerState() })
                try error.check(); try check()
            }
            windowRows = nil
            for index in 0..<keeping {
                let frame = try schedule.admitDecode(offset: schedule.committedTokens)
                try schedule.commit(frame)
                chain(rowSHA256[index])
            }
            try requireFrontier(after: schedule.committedTokens)
            try check()
        } catch { try fail(error) }
    }

    /// Stage 1, after `settleWindow`: the last row a token was selected from,
    /// and with step evidence one record per kept row (`rowSHA256` are the
    /// residual rows' digests, as a plain step records its boundary).
    func recordWindowRows(logits: MLXArray, keeping: Int, rowSHA256: [String], check: () throws -> Void) throws {
        guard stage.stageIndex == 1, keeping >= 1, logits.ndim == 3, logits.dim(1) >= keeping,
              rowSHA256.count >= keeping else {
            throw ProbeError("MiMo verify window records rows it did not keep")
        }
        let indices = recordsSteps ? Array(0..<keeping) : [keeping - 1]
        for index in indices {
            let row = logits[0..., index, 0...]
            let bytes = row.asData().data
            let digest = sha256(bytes)
            if recordsSteps {
                let dtype = String(describing: row.dtype)
                steps.append(.init(ordinal: steps.count, boundarySHA256: rowSHA256[index], rowSHA256: digest,
                    rowDType: dtype, top: try MiMoStepEvidence.candidates(rowBytes: bytes, dtype: dtype)))
            }
            if index == keeping - 1 { lastRowSHA256 = digest }
            try check()
        }
    }

    private func requireWindowable(_ tokens: [Int], offset: Int, producer: Bool) throws {
        try requireOpen()
        guard windowRows == nil, producer == (stage.stageIndex == 0), (1...4).contains(tokens.count),
              tokens.allSatisfy({ (0..<stage.vocabularySize).contains($0) }),
              offset == schedule.committedTokens, schedule.committedPromptTokens == request.promptCount,
              offset + tokens.count <= request.maximumTokens,
              let caches, caches.allSatisfy({ $0.offset == offset }) else {
            throw ProbeError("MiMo verify window differs from the committed decode frontier")
        }
        _ = try schedule.admitDecode(offset: offset)
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
    /// `discardedDecodeForwards`: kept window rows whose tokens a client stop
    /// left unpublished (`pipeline_mtp_v1`), or decode forwards a stage that
    /// decoded alone ran past a client stop it had not yet been told about; 0 otherwise.
    func finishGeneration(_ reason: QwenLayerStageGenerationFinishReason,
                          selectedTokenCount: Int, lastTokenID: Int, discardedDecodeForwards: Int = 0) throws {
        do {
            try requireOpen()
            guard windowRows == nil else { throw ProbeError("MiMo stage finished with an unsettled verify window") }
            try schedule.finish(reason, selectedTokenCount: selectedTokenCount, lastTokenID: lastTokenID,
                                discardedDecodeForwards: discardedDecodeForwards)
            try retire(failed: false)
        } catch { try fail(error) }
    }

    /// The producer stage's committed prompt state as hand-off components, in
    /// `split`'s order, with logical bytes and their digests. Refuses a cache
    /// whose arrays or rotation differ from what the terms derived. It reads
    /// state; the session stays open until `retireAfterHandoff`.
    func handoffComponents(split: QwenPhaseSplitPlan,
                           check: () throws -> Void) throws -> [QwenPhaseSplitHandoffSender.Component] {
        do {
            try requireOpen()
            guard stage.stageIndex == 0, schedule.committedPromptTokens == request.promptCount,
                  schedule.decodeForwardCount == 0, !handedOff, let caches,
                  split.shapes.count == 2 * caches.count else {
                throw ProbeError("Only the producer stage hands over, once, after its last prompt frame")
            }
            return try MLX.withError { error in
                Stream.gpu.synchronize(); try error.check(); try check()
                let arrays = try MiMoPhaseSplitState.exportArrays(caches: caches, configuration: stage.model.configuration,
                    frames: try MiMoPhaseSplitState.frameTokenCounts(request), shapes: split.shapes)
                let bytes = arrays.map { $0.asData().data }
                try error.check(); try check()
                guard zip(bytes, split.shapes).allSatisfy({ $0.count == $1.byteCount }) else {
                    throw ProbeError("Producer state bytes differ from their agreed size")
                }
                let digests = CBv2OwnedStateSnapshot.digests(bytes)
                return zip(split.shapes, zip(digests, bytes)).map { shape, value in
                    .init(shape: shape, sha256: value.0, bytes: value.1)
                }
            }
        } catch { try fail(error) }
    }

    /// After the adopting rank accepted the complete state. Retires this
    /// stage's native request state; no further frame can run here.
    func retireAfterHandoff() throws {
        do {
            try requireOpen()
            guard stage.stageIndex == 0, schedule.committedPromptTokens == request.promptCount,
                  schedule.decodeForwardCount == 0, !handedOff else {
                throw ProbeError("Hand-off retirement differs from the producer's committed prompt frontier")
            }
            handedOff = true
            try retire(failed: false)
        } catch { try fail(error) }
    }

    /// The producer stage of a request the decoding rank served alone: it ran
    /// no frame, so it retires empty, cleanly, once both ranks agreed the route.
    func retireUnusedForDecodingRankAlone() throws {
        do {
            try requireOpen()
            guard stage.stageIndex == 0, request.decodingRankAlone, schedule.committedTokens == 0,
                  schedule.decodeForwardCount == 0, !handedOff else {
                throw ProbeError("Only an unused producer stage of a request served alone retires empty")
            }
            handedOff = true
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
            imageFeatures = nil
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
