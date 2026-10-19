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
    /// Set only on the consumer stage of a decoding rank that runs the
    /// speculative head: the stage then also yields its pre-norm hidden rows.
    private let hiddenTap: QwenLayerStageHiddenTap?
    private var windowOffset: Int?
    private var windowCount: Int?
    private var windowKept: Int?
    /// Prompt frontiers at which this stage keeps a copy of its committed
    /// state for the rank-local prefix cache. Empty when the cache is off.
    var prefixCaptureFrontiers: Set<Int> = []
    /// Most bytes this request's captures may hold together (its prompt's
    /// attention copy and speculative history, and one recurrent state a
    /// kept frontier), as charged in its reservation; nil is unbounded.
    var prefixCaptureLimitBytes: Int?
    /// Most frontiers one request keeps (the cache's entry limit).
    var prefixCaptureMaximumFrontiers = Int.max
    /// The decoding rank's speculative history, a prompt token, kept with
    /// these captures (counted against the limit); 0 elsewhere.
    var prefixHistoryBytesPerToken = 0
    /// Measured at the first capture frontier; decides what is kept.
    private(set) var prefixCaptureCost: QwenStagePrefixCaptureCost?
    private var prefixKept: Set<Int>?
    /// Set when the running check withdrew this request's capture
    /// (`withdrawPrefixCapture`): nothing more is captured or kept.
    private(set) var prefixCaptureWithdrawn = false
    /// Recurrent state captured at each frontier, keyed by global layer.
    private var capturedRecurrent: [Int: [Int: (conv: MLXArray, ssm: MLXArray)]] = [:]
    /// Attention state captured once, at the deepest frontier; shallower
    /// frontiers use a prefix of it.
    private var capturedAttention: (committed: Int, layers: [Int: (keys: MLXArray, values: MLXArray)])?

    var committedTokens: Int { schedule.committedTokens }
    var isClosed: Bool { state.isClosed }
    var isFailed: Bool { state.isFailed }

    /// `adopting` starts the stage from another owner's committed prompt state
    /// instead of empty state. Only the producer stage can be adopted, and only
    /// at the frontier after its last prompt frame.
    init(stage: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
         generationRequest request: QwenLayerStageGenerationRequest,
         adopting: QwenLayerStageAdoptedState? = nil,
         hiddenTap: QwenLayerStageHiddenTap? = nil) throws {
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
                    && (stage.model is any CBv2PositionedRecurrentEmbeddingForwardable || stage.model is NemotronHModel)),
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
        var forwarded = try (stage.model as? any LayerStageFrameForwarding)?
            .layerStageRequestGeometry(maximumTokens: request.maximumTokens)
        // A Gemma stage serving batch lanes attends through its KV host.
        if let value = forwarded, stage.model is Gemma4LayerStageModel, let host = stage.kvHost.host {
            forwarded = try CBv2RequestGeometry(gemma4Stage: value, host: host, maximumTokens: request.maximumTokens)
        }
        let geometry = try forwarded
            ?? CBv2RequestGeometry(model: stage.model, family: .qwen35,
                feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(stage.model),
                layerCount: stage.layerCount, vocabularySize: stage.vocabularySize,
                configurationData: stage.configurationData, maximumTokens: request.maximumTokens,
                host: stage.kvHost.host)
        if let adopting {
            // A hand-off adopts the producer's whole prompt; a prefix restore
            // adopts this stage's own cached state at the agreed reused prefix.
            let handoff = adopting.committedTokens == request.promptCount
            guard handoff ? stage.stageIndex == 0
                : adopting.committedTokens == request.reusedPrefixTokens && request.reusedPrefixTokens > 0 else {
                throw ProbeError("Only the producer stage's prompt or the agreed reused prefix can be adopted")
            }
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
            self.schedule = handoff ? try QwenLayerStageGenerationSchedule(request: request,
                adoptedCommittedTokens: adopting.committedTokens) : QwenLayerStageGenerationSchedule(request: request)
            self.state = try MLX.withError { error in
                // A sliding layer's kept window rides in the recurrent slots
                // (`capturePrefix`): give it back to its row, not to recurrent
                // state. A hand-off carries every row as attention.
                let sliding = handoff ? [] : Set(geometry.kinds.compactMap { kind -> Int? in
                    if case .slidingWindow = kind.attention { return kind.modelLayerIndex }
                    return nil
                })
                let kept = try localized(adopting.recurrent)
                let value = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                    outputCount: request.outputCount, adoptingCommittedTokens: adopting.committedTokens,
                    attention: try localized(adopting.attention),
                    slidingTails: kept.filter { sliding.contains($0.key) }.mapValues { (keys: $0.conv, values: $0.ssm) },
                    recurrent: kept.filter { !sliding.contains($0.key) })
                try error.check()
                return value
            }
        } else {
            guard request.reusedPrefixTokens == 0 else { throw ProbeError("A reused prefix needs its restored state") }
            self.state = try CBv2OwnedRequestState(geometry: geometry,
                promptCount: request.promptCount, outputCount: request.outputCount)
            self.schedule = QwenLayerStageGenerationSchedule(request: request)
        }
        guard hiddenTap == nil || stage.stageIndex == 1 else {
            throw ProbeError("Only the consumer stage yields hidden rows")
        }
        self.hiddenTap = hiddenTap
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
            var tapped: MLXArray?
            // nil positions use each stage's own KV absoluteOffset. Both states
            // start at zero and must match the SAME full-model tokenOffset here;
            // a stage's global layer offset never changes sequence positions.
            let output = try state.run(tokenCount: tokens.count, observer: observer, check: checked, forward: { caches, evaluation in
                // A Nemotron stage starts and stops inside the trunk through its own seam.
                if let nemotron = stage.model as? NemotronHModel {
                    return NemotronStageForward.run(model: nemotron, stageIndex: stage.stageIndex, tokens: input,
                        residual: incoming?.array, caches: caches, evaluation: evaluation, frame: frame)
                }
                // A family whose product class cannot be cut forwards its own layer stage.
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
                if frame.phase == .prefill, let hiddenTap {
                    // The same trunk on the same residual, through the public
                    // forward that also returns the hidden rows; the prompt's
                    // last row is projected exactly as the prefill entry does.
                    let hidden = try hiddenTap.hidden(of: stage.model, tokens: input, residual: incoming!.array,
                        caches: caches, evaluation: evaluation, captured: false).hidden
                    tapped = hidden
                    return frame.finalPromptChunk ? hiddenTap.lastRowLogits(hidden) : hidden[0..., -1, 0 ..< 1]
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
            if let hiddenTap, let tapped {
                // Committed prompt rows, in order, once each.
                eval(tapped); try checked()
                try hiddenTap.observe(input, tapped)
            }
            if frame.phase == .prefill, prefixCaptureFrontiers.contains(frame.tokenOffset + frame.tokenCount) {
                try capturePrefix(at: frame.tokenOffset + frame.tokenCount)
                try checked()
            }
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

    /// A speculative decode window on a decoding rank: `tokens` (`[1, S]`
    /// int32, on device) are the last committed token followed by drafts,
    /// starting at `offset`. Stage 0 returns the residual rows `[1, S, H]`;
    /// stage 1 takes them as `residual` and returns the target logits
    /// `[1, S, V]` and its pre-norm hidden rows `[1, S, H]`. Nothing is
    /// evaluated or committed here: the caller evaluates the outputs with the
    /// returned roots, then calls `confirmWindow`, then `settleWindow`.
    func beginWindow(tokens: MLXArray, offset: Int, residual: MLXArray? = nil) throws
        -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            return try MLX.withError { error in
                try state.requireOpen()
                let count = tokens.ndim == 2 ? tokens.dim(1) : 0
                let first = try schedule.admitDecode(offset: offset)
                guard windowOffset == nil, tokens.ndim == 2, tokens.dim(0) == 1, (1...8).contains(count),
                      tokens.dtype == .int32, first.tokenOffset == state.committedTokens,
                      state.committedTokens == schedule.committedTokens,
                      count <= request.maximumTokens - state.committedTokens,
                      (stage.stageIndex == 0) == (residual == nil), (stage.stageIndex == 1) == (hiddenTap != nil),
                      !(stage.model is NemotronHModel), !(stage.model is any LayerStageFrameForwarding) else {
                    throw ProbeError("Stage window differs from the committed decode frontier or its stage contract")
                }
                if let residual {
                    guard residual.shape == [1, count, hiddenSize], residual.dtype == stage.activationDType else {
                        throw ProbeError("Stage window residual differs from the native [1,S,H] contract")
                    }
                }
                try error.check()
                let built = try state.beginWindow(tokenCount: count) { caches, evaluation in
                    if stage.stageIndex == 0 {
                        guard let native = stage.model as? any CBv2RecurrentCaptureMTPForwardable else {
                            throw ProbeError("Producer stage has no captured-window forward")
                        }
                        // The discarded head's lazy logits are dropped here, never evaluated.
                        return [native.cbv2ForwardWithHiddenCaptured(tokens, caches: caches.map { $0 as! any KVCache },
                            recurrentState: [evaluation], positionIds: nil).lastHidden]
                    }
                    let result = try hiddenTap!.hidden(of: stage.model, tokens: tokens, residual: residual!,
                        caches: caches, evaluation: evaluation, captured: true)
                    return [result.logits, result.hidden]
                }
                let expected = stage.stageIndex == 0 ? [[1, count, hiddenSize]]
                    : [[1, count, stage.vocabularySize], [1, count, hiddenSize]]
                guard built.outputs.map(\.shape) == expected,
                      built.outputs.allSatisfy({ [.float16, .bfloat16, .float32].contains($0.dtype) }),
                      stage.stageIndex != 0 || built.outputs[0].dtype == stage.activationDType else {
                    throw ProbeError("Stage window output differs from the native residual/logit contract")
                }
                try error.check()
                windowOffset = offset; windowCount = count
                return built
            }
        } catch { try fail(error) }
    }

    /// After the caller evaluated the window's outputs and roots.
    func confirmWindow(check: () throws -> Void) throws {
        do {
            try MLX.withError { error in
                guard windowOffset != nil else { throw ProbeError("No stage window is open") }
                try state.confirmWindow(check: { try error.check(); try check() })
            }
        } catch { try fail(error) }
    }

    /// Keeps the first `kept` tokens of the evaluated window. Returns the roots
    /// to evaluate before `confirmSettled`.
    func settleWindow(keeping kept: Int) throws -> [MLXArray] {
        do {
            return try MLX.withError { error in
                guard windowOffset != nil, let count = windowCount, (1...count).contains(kept) else {
                    throw ProbeError("No stage window is open")
                }
                let roots = try state.settleWindow(keeping: kept)
                windowKept = kept
                try error.check()
                return roots
            }
        } catch { try fail(error) }
    }

    /// After the caller evaluated the settled roots: the kept tokens become
    /// that many committed decode frames.
    func confirmSettled(check: () throws -> Void) throws {
        do {
            try MLX.withError { error in
                guard let offset = windowOffset, let kept = windowKept else { throw ProbeError("No stage window was settled") }
                try state.confirmSettled(check: { try error.check(); try check() })
                windowOffset = nil; windowCount = nil; windowKept = nil
                for index in 0..<kept {
                    try schedule.commit(try schedule.admitDecode(offset: offset + index))
                }
                guard state.committedTokens == schedule.committedTokens else {
                    throw ProbeError("Stage window left the schedule and the state at different frontiers")
                }
                try error.check()
            }
        } catch { try fail(error) }
    }

    /// Keeps this stage's committed state at a prompt frontier. Recurrent
    /// state is the confirmed generation, kept compact: `contiguous` shares an
    /// array that owns its storage and copies (bit for bit) only one that
    /// views a larger buffer, such as the convolution tail, a three-row slice
    /// of its whole prefill chunk, which would otherwise keep the chunk alive
    /// once per frontier. Attention rows are copied once, at the deepest
    /// frontier, into arrays this session owns alone, so no later write to
    /// the request's rows can reach them; shallower frontiers view that copy.
    /// What is kept stays within `prefixCaptureLimitBytes`: the deepest
    /// frontier first, then the deepest grid frontiers that fit.
    private func capturePrefix(at frontier: Int) throws {
        guard frontier == state.committedTokens, frontier < request.promptCount else {
            throw ProbeError("Prefix capture differs from the committed prompt frontier")
        }
        guard !prefixCaptureWithdrawn else { return }
        let global = Dictionary(uniqueKeysWithValues: descriptor.layers.map { ($0.localIndex, $0.globalIndex) })
        let confirmed = state.geometry.recurrent.layers.isEmpty ? [:] : (state.recurrent.confirmedStateSnapshot() ?? [:])
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for layer in state.geometry.recurrent.layers {
            guard let value = confirmed[layer.modelLayerIndex], let conv = value.conv, let ssm = value.ssm,
                  let index = global[layer.modelLayerIndex] else {
                throw ProbeError("Prefix capture lacks a confirmed recurrent layer")
            }
            recurrent[index] = (conv: conv, ssm: ssm)
        }
        var rows: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        // A sliding-window row (Gemma 4) holds only its window, oldest first:
        // its state at a frontier is its own, kept per frontier in the
        // recurrent slots (keys, values), as MiMo keeps a ring's tail.
        var tails: [Int: (keys: MLXArray, values: MLXArray)] = [:], windowBytes = 0
        for (position, optionalRow) in state.rows.enumerated() {
            let kind = state.geometry.kinds[position]
            guard let row = optionalRow, let local = kind.modelLayerIndex,
                  let index = global[local] else { throw ProbeError("Prefix capture lacks an attention row") }
            let snapshot = row.snapshot()
            let retained = kind.retainedTokens(atFrontier: frontier)
            guard snapshot.offset == frontier, snapshot.keys.dim(2) == retained, retained > 0 else {
                throw ProbeError("Prefix capture attention frontier differs")
            }
            if case .slidingWindow(let window) = kind.attention {
                tails[index] = (keys: snapshot.keys, values: snapshot.values)
                // Every frontier is charged a full window: a tail taken before
                // the prompt filled it is shorter than every later one.
                let perPosition = (snapshot.keys.nbytes + snapshot.values.nbytes + retained - 1) / retained
                windowBytes = try QwenLongPrefillCheckedBytes.sum([windowBytes,
                    try QwenLongPrefillCheckedBytes.product([perPosition, window])])
            } else {
                rows[index] = (keys: snapshot.keys, values: snapshot.values)
            }
        }
        let planned = prefixCaptureFrontiers.sorted()
        if prefixKept == nil {
            // Logical sizes: the compact size of what would be kept.
            let attention = rows.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
            let cost = QwenStagePrefixCaptureCost(attentionBytesPerToken: (attention + frontier - 1) / frontier,
                recurrentBytesPerFrontier: recurrent.values.reduce(windowBytes) { $0 + $1.conv.nbytes + $1.ssm.nbytes },
                historyBytesPerToken: prefixHistoryBytesPerToken)
            prefixCaptureCost = cost
            prefixKept = cost.kept(planned, limit: prefixCaptureLimitBytes ?? Int.max,
                maximum: prefixCaptureMaximumFrontiers)
        }
        guard prefixKept?.contains(frontier) == true else { return }
        var compact = recurrent.mapValues { (conv: contiguous($0.conv), ssm: contiguous($0.ssm)) }
        for (index, tail) in tails {
            // Own copies: the ring takes later tokens in place.
            let one = MLXArray(1).asType(tail.keys.dtype)
            compact[index] = (conv: tail.keys * one, ssm: tail.values * one)
        }
        eval(compact.values.flatMap { [$0.conv, $0.ssm] })
        capturedRecurrent[frontier] = compact
        guard frontier == planned.last else { return }
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for (index, row) in rows {
            let one = MLXArray(1).asType(row.keys.dtype)
            attention[index] = (keys: row.keys * one, values: row.values * one)
        }
        eval(attention.values.flatMap { [$0.keys, $0.values] })
        capturedAttention = (frontier, attention)
    }

    /// Bytes of the attention copy the captured states view together.
    var capturedSharedBytes: Int {
        capturedAttention?.layers.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes } ?? 0
    }

    /// The captured states, deepest attention copy shared by prefix views.
    /// Empty unless the deepest frontier was reached.
    func capturedPrefixStates() -> [QwenStagePrefixState] {
        guard let attention = capturedAttention else { return [] }
        return capturedRecurrent.keys.sorted().compactMap { frontier in
            guard frontier <= attention.committed, let recurrent = capturedRecurrent[frontier] else { return nil }
            let layers = attention.layers.mapValues { pair -> (keys: MLXArray, values: MLXArray) in
                frontier == attention.committed ? pair
                    : (keys: pair.keys[0..., 0..., 0..<frontier, 0...], values: pair.values[0..., 0..., 0..<frontier, 0...])
            }
            return QwenStagePrefixState(committedTokens: frontier, attention: layers, recurrent: recurrent)
        }
    }

    func discardCapturedPrefix() { capturedRecurrent.removeAll(); capturedAttention = nil; prefixKept = nil }

    /// The running check withdrew this request's capture to keep the request
    /// going: what was captured is let go now (its storage returns once the
    /// last reference goes), and no later frontier is captured. Exactness is
    /// untouched: captures are copies or immutable confirmed states, and the
    /// frames do not depend on them.
    func withdrawPrefixCapture() {
        prefixCaptureWithdrawn = true
        capturedRecurrent.removeAll(); capturedAttention = nil
    }

    /// Whether this request keeps its prompt for the cache: its deepest
    /// frontier was captured within its limit and not withdrawn.
    var keepsPrefixCapture: Bool { !prefixCaptureWithdrawn && capturedAttention != nil }

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

    /// The producer stage of a request the decoding rank served alone: it ran
    /// no frame, so it retires empty, cleanly, once both ranks agreed the route.
    func retireUnusedForDecodingRankAlone() throws {
        do {
            try state.requireOpen()
            guard stage.stageIndex == 0, request.decodingRankAlone, schedule.committedTokens == 0,
                  schedule.decodeForwardCount == 0, !handedOff else {
                throw ProbeError("Only an unused producer stage of a request served alone retires empty")
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

extension QwenLayerStageSession {
    /// One decode frame for several sessions of the same loaded stage at once
    /// (continuous batching), rows in the order given; each session decodes
    /// its own `tokens[i]` at its own committed frontier. Stage 0 returns the
    /// residual rows `[B, 1, H]`; stage 1 takes them as `residual` and
    /// returns the logits rows `[B, V]`. The sessions must share the stage's
    /// KV host. Any failure retires every session as failed.
    static func decodeBatch(_ sessions: [QwenLayerStageSession], tokens: [Int], residual: MLXArray?,
                            check: () throws -> Void) throws -> MLXArray {
        guard let first = sessions.first, sessions.count == tokens.count,
              Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count,
              sessions.allSatisfy({ ($0.stage.model as AnyObject) === (first.stage.model as AnyObject)
                  && $0.stage.stageIndex == first.stage.stageIndex && $0.state.hosted }) else {
            throw ProbeError("A batched decode needs distinct sessions of one hosted loaded stage")
        }
        do {
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                var frames: [QwenLayerStageFrame] = []
                for (session, token) in zip(sessions, tokens) {
                    try session.state.requireOpen()
                    guard (0..<session.stage.vocabularySize).contains(token),
                          session.state.committedTokens == session.schedule.committedTokens,
                          session.hiddenTap == nil, session.windowOffset == nil else {
                        throw ProbeError("Batched decode token, frontier or session role differs")
                    }
                    frames.append(try session.schedule.admitDecode(offset: session.schedule.committedTokens))
                }
                let rows = sessions.count, stageIndex = first.stage.stageIndex
                if stageIndex == 0 {
                    guard residual == nil else { throw ProbeError("Stage zero rejects a supplied residual") }
                } else {
                    guard let residual, residual.shape == [rows, 1, first.hiddenSize],
                          residual.dtype == first.stage.activationDType else {
                        throw ProbeError("Batched decode residual differs from the native [B,1,H] contract")
                    }
                }
                try checked()
                let input = MLXArray(tokens.map(Int32.init)).reshaped([rows, 1])
                let output = try CBv2OwnedRequestState.runBatch(sessions.map(\.state), tokenCount: 1, check: checked,
                    forward: { caches, evaluations in
                        // A stage that runs its own frames takes the rows as
                        // one `[B, 1]` decode frame.
                        if let forwarding = first.stage.model as? any LayerStageFrameForwarding {
                            return forwarding.layerStageForward(tokens: input, residual: residual, caches: caches,
                                frame: frames[0])
                        }
                        if stageIndex == 0 {
                            let native = first.stage.model as! any CBv2RecurrentMTPForwardable
                            return native.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
                                recurrentState: evaluations, positionIds: nil).lastHidden
                        }
                        let native = first.stage.model as! any CBv2PositionedRecurrentEmbeddingForwardable
                        return native.embeddingForward(input, inputEmbedding: residual!,
                            cache: caches.map { $0 as! any KVCache }, recurrentState: evaluations,
                            positionIds: nil)[0..., -1, 0...]
                    }, validateOutput: { array in
                        let expected = stageIndex == 0 ? [rows, 1, first.hiddenSize] : [rows, first.stage.vocabularySize]
                        guard array.shape == expected, [.float16, .bfloat16, .float32].contains(array.dtype),
                              stageIndex != 0 || array.dtype == first.stage.activationDType else {
                            throw ProbeError("Batched stage output differs from the native residual/logit contract")
                        }
                    })
                for (session, frame) in zip(sessions, frames) { try session.schedule.commit(frame) }
                if stageIndex == 0 {
                    // As for one request: the sender must own the residual alone.
                    Stream.gpu.synchronize(); try checked()
                }
                return output
            }
        } catch {
            for session in sessions { try? session.retire(failed: true) }
            throw error
        }
    }

    /// The next frame this session will run (prefill or decode), for a batch
    /// scheduler; nil once the schedule finished.
    var nextFrame: QwenLayerStageFrame? {
        guard !schedule.complete, schedule.nextSequence < request.forwardCount else { return nil }
        return try? request.frame(sequence: schedule.nextSequence)
    }
}
