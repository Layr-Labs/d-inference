import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension Gemma4TensorParallelModel {
    /// This model's request state over every layer at `maximumTokens`: a
    /// shard's own KV heads per layer (26B: 4 sliding, 1 full), or every head
    /// of the whole model (the oracle's).
    func requestGeometry(maximumTokens: Int) throws -> CBv2RequestGeometry {
        let ranks: Int
        switch role {
        case .shard: ranks = plan.size
        case .full: ranks = 1
        case .splitSum: throw ProbeError("The split-sum oracle runs on its legacy caches only")
        }
        // The product's own derivation, each layer's state keyed by its index.
        let kinds = textModel.cbv2LayerKinds.enumerated().map { index, kind -> CBv2LayerKind in
            var keyed = kind; keyed.modelLayerIndex = index
            return keyed
        }
        return try CBv2RequestGeometry(gemma4TensorParallelKinds: kinds, plan: plan, ranks: ranks,
            slidingWindow: textModel.configuration.slidingWindow, kvDType: activationDType, maximumTokens: maximumTokens)
    }

    /// The paged KV host this model's requests take their pages from:
    /// `lanes` requests of at most `maximumTokens`, prompt chunks of at most
    /// `chunkTokens`.
    func pagedHost(lanes: Int, maximumTokens: Int, chunkTokens: Int,
                   quantization: PagedKVQuantizationSelection = .native) throws -> CBv2StageKVHost {
        try CBv2StageKVHost(gemma4Geometry: requestGeometry(maximumTokens: maximumTokens), kind: .paged, lanes: lanes,
            maximumTokensPerRequest: maximumTokens, maximumChunkTokens: chunkTokens, quantization: quantization)
    }
}

/// One request of a Gemma 4 tensor-parallel rank (or of the whole model, the
/// oracle) on its paged KV host, through the product's own CBv2 entry points:
/// a prompt chunk is `Gemma4TextModel.cbv2Prefill` (the final layer keeps
/// only the row it projects; an earlier chunk projects nothing) under the
/// registered prompt policy (`Gemma4PrefillProjectionScope`: every affine
/// projection keeps its singleton token reduction, as the pipeline stages
/// compute), and a decode step is the model's forward on one token. Each
/// forward's cross-rank sums are inside its graph; `select` builds the
/// step's choice into the same evaluation, so a step costs one evaluation.
///
/// Pages grow with the request (`QwenTensorParallelBatchSession`'s granule
/// and margin). Native work only on the owner's serial executor, inside
/// `MLX.withError`; `check` is the caller's.
final class Gemma4TensorParallelPagedSession {
    let model: Gemma4TensorParallelModel
    let state: CBv2OwnedRequestState
    let promptCount: Int
    private(set) var retired = false
    /// Prompt tokens restored from a kept prefix (0 for a cold request).
    let reusedPrefixTokens: Int
    /// This request's prefix capture, taken after the prompt chunks that end
    /// at its boundaries (`Gemma4TensorParallelPrefixCapture`); nil keeps none.
    var prefixCapture: Gemma4TensorParallelPrefixCapture?

    /// `restoring`: this rank's state at an agreed prefix boundary (its own
    /// heads' full rows and sliding windows, `Gemma4TensorParallelPrefix`),
    /// written into fresh pages of the request; the prompt then continues
    /// from that boundary on the same chunk grid.
    init(model: Gemma4TensorParallelModel, host: CBv2StageKVHost, promptCount: Int, outputCount: Int,
         restoring prefix: QwenStagePrefixState? = nil) throws {
        let maximum = promptCount + outputCount
        guard promptCount > 0, outputCount > 0, maximum <= host.maximumTokensPerRequest,
              (prefix?.committedTokens ?? 0) < promptCount else {
            throw ProbeError("Gemma tensor-parallel request does not fit its KV host")
        }
        let geometry = try Self.geometry(model: model, host: host, maximumTokens: maximum)
        self.model = model; self.promptCount = promptCount
        let reserved = host.kind == .paged ? min(maximum, promptCount + QwenTensorParallelBatchSession.pageGrowthTokens) : nil
        if let prefix {
            guard Gemma4TensorParallelPrefix.adopts(prefix, into: geometry) else {
                throw ProbeError("Gemma tensor-parallel prefix differs from this rank's request geometry")
            }
            let sliding = Set(geometry.kinds.compactMap { kind -> Int? in
                if case .slidingWindow = kind.attention { return kind.modelLayerIndex }
                return nil
            })
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: promptCount, outputCount: outputCount,
                adoptingCommittedTokens: prefix.committedTokens, attention: prefix.attention,
                slidingTails: prefix.recurrent.filter { sliding.contains($0.key) }.mapValues { (keys: $0.conv, values: $0.ssm) },
                recurrent: [:], reservedTokens: reserved)
        } else {
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: promptCount, outputCount: outputCount,
                reservedTokens: reserved)
        }
        reusedPrefixTokens = prefix?.committedTokens ?? 0
    }

    /// The request geometry a session of `maximumTokens` takes on `host`.
    static func geometry(model: Gemma4TensorParallelModel, host: CBv2StageKVHost, maximumTokens: Int) throws -> CBv2RequestGeometry {
        try CBv2RequestGeometry(gemma4Stage: model.requestGeometry(maximumTokens: maximumTokens), host: host,
            maximumTokens: maximumTokens)
    }

    var committedTokens: Int { state.committedTokens }

    /// Before a forward that writes `count` tokens: its pages and the margin,
    /// grown by granules up to the request's length. False when the pool
    /// cannot back them; nothing changed then.
    func reservePages(writing count: Int) -> Bool {
        guard state.pagedHost, let target = QwenTensorParallelBatchSession.pageGrowthTarget(
            reserved: state.reservedTokens, needed: state.committedTokens + count, limit: state.maximumTokens) else { return true }
        return (try? state.growReservation(toTokens: target)) != nil
    }

    /// Whether the pages already cover a forward of `count` tokens.
    func pagesCover(writing count: Int) -> Bool { state.committedTokens + count <= state.reservedTokens }

    /// One prompt chunk `range` of `prompt`. The chunk that ends the prompt
    /// returns its last row's logits (`[1, vocabulary rows]`, FP32) and
    /// `select(logits)`, evaluated with the chunk; an earlier chunk, nil.
    func prefill(_ prompt: [Int], range: Range<Int>, check: () throws -> Void,
                 select: (MLXArray) -> MLXArray) throws -> (logits: MLXArray, selected: MLXArray)? {
        guard !retired, prompt.count == promptCount, range.lowerBound == state.committedTokens, !range.isEmpty,
              range.upperBound <= prompt.count, reservePages(writing: range.count) else {
            throw ProbeError("Gemma tensor-parallel prompt chunk differs from its request's frontier or pages")
        }
        let final = range.upperBound == prompt.count
        let input = MLXArray(prompt[range].map(Int32.init)).reshaped([1, range.count])
        let text = model.textModel
        var logits: MLXArray?
        let output = try state.run(tokenCount: range.count, check: check, forward: { caches, _ in
            let kv = caches.map { $0 as! any KVCache }
            let parts = Gemma4TensorParallelModel.benchPromptParts ?? Gemma4TensorParallelModel.promptChunkParts
            let row = Gemma4PrefillProjectionScope.withPrefillFrame(tokens: input, enabled: true) {
                Gemma4TensorParallelPromptParts.$parts.withValue(parts) {
                    text.cbv2Prefill(input, inputEmbedding: nil, cache: kv,
                        requirement: final ? .lastPositionLogits : .evaluationOnly)
                }
            }
            guard final else { return row }
            logits = row
            return select(row)
        }, validateOutput: { _ in })
        if let prefixCapture, prefixCapture.frontiers.contains(range.upperBound) {
            try prefixCapture.capture(state, at: range.upperBound)
            try check()
        }
        guard final else { return nil }
        guard let logits else { throw ProbeError("Gemma tensor-parallel prompt produced no logits") }
        try Self.validate(logits, rows: 1, model: model)
        return (logits, output)
    }

    /// One decode step on `token`: the next row's logits and `select(logits)`,
    /// evaluated together.
    func decode(_ token: Int, check: () throws -> Void,
                select: (MLXArray) -> MLXArray) throws -> (logits: MLXArray, selected: MLXArray) {
        guard !retired, (0 ..< model.plan.vocabularySize).contains(token), state.committedTokens >= promptCount,
              pagesCover(writing: 1) || reservePages(writing: 1) else {
            throw ProbeError("Gemma tensor-parallel decode step differs from its request or pages")
        }
        let input = MLXArray([Int32(token)]).reshaped([1, 1])
        var logits: MLXArray?
        let output = try state.run(tokenCount: 1, check: check, forward: { caches, _ in
            let row = decodeRow(input, caches: caches)
            logits = row
            return select(row)
        }, validateOutput: { _ in })
        guard let logits else { throw ProbeError("Gemma tensor-parallel decode produced no logits") }
        try Self.validate(logits, rows: 1, model: model)
        return (logits, output)
    }

    /// One decode step on the agreed token of the previous step's lazy
    /// selection (`Gemma4TensorParallelChoice.build`, greedy: the token is its
    /// first element), submitted and committed before that selection is read
    /// (`CBv2OwnedRequestState.submit`), so the GPU and the collectives run
    /// this step while the host reads the last one. The same graph as
    /// `decode` on the read token: every value and token is unchanged.
    func submitDecode(after selected: MLXArray, check: () throws -> Void,
                      select: (MLXArray) -> MLXArray) throws -> (logits: MLXArray, selected: MLXArray) {
        guard !retired, state.committedTokens >= promptCount, selected.ndim == 1, selected.dim(0) >= 1,
              pagesCover(writing: 1) || reservePages(writing: 1) else {
            throw ProbeError("Gemma tensor-parallel decode step differs from its request or pages")
        }
        let input = selected[0 ..< 1].asType(.int32).reshaped([1, 1])
        var logits: MLXArray?
        let output = try state.submit(tokenCount: 1, check: check, forward: { caches, _ in
            let row = decodeRow(input, caches: caches)
            logits = row
            return select(row)
        })
        guard let logits else { throw ProbeError("Gemma tensor-parallel decode produced no logits") }
        try Self.validate(logits, rows: 1, model: model)
        return (logits, output)
    }

    /// One decode row's logits on `input` (`[1, 1]`) at the decode layer
    /// stride: `decode`'s and `submitDecode`'s forward.
    private func decodeRow(_ input: MLXArray, caches: [any CBv2AttendingLayerCache]) -> MLXArray {
        let stride = Gemma4TensorParallelModel.layerStride ?? Gemma4TensorParallelModel.decodeLayerStride
        return Gemma4LayerSubmission.$stride.withValue(stride) {
            Gemma4BatchDecodeScope.withDecodeFrame(tokens: input, enabled: true) {
                model.textModel(input, cache: caches.map { $0 as! any KVCache })[0..., -1, 0...]
            }
        }
    }

    /// One decode step of each of `sessions` (distinct requests on one model's
    /// host), a row each, in one forward under the explicit batch decode scope
    /// (`Gemma4BatchDecodeScope`: every row keeps each projection's singleton
    /// reduction, and each rank packs every row's expert partials into the
    /// layer's one collective): each row equals its request's own step bit for
    /// bit. The rows' logits `[B, vocabulary rows]`, evaluated.
    static func decode(_ sessions: [Gemma4TensorParallelPagedSession], tokens: [Int],
                       check: () throws -> Void) throws -> MLXArray {
        guard let first = sessions.first, sessions.count == tokens.count, (1 ... 8).contains(sessions.count),
              Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count,
              sessions.allSatisfy({ $0.model === first.model && !$0.retired && $0.state.committedTokens >= $0.promptCount }),
              tokens.allSatisfy({ (0 ..< first.model.plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor-parallel batch decode needs distinct open requests of one shard")
        }
        guard sessions.count > 1 else { return try first.decode(tokens[0], check: check) { $0 }.logits }
        for session in sessions where !(session.pagesCover(writing: 1) || session.reservePages(writing: 1)) {
            throw ProbeError("Gemma tensor-parallel lane has no page for its next row")
        }
        let input = MLXArray(tokens.map(Int32.init)).reshaped([sessions.count, 1])
        let text = first.model.textModel
        let stride = Gemma4TensorParallelModel.layerStride ?? Gemma4TensorParallelModel.decodeLayerStride
        let output = try CBv2OwnedRequestState.runBatch(sessions.map(\.state), tokenCount: 1, check: check,
            forward: { caches, _ in
                Gemma4LayerSubmission.$stride.withValue(stride) {
                    Gemma4BatchDecodeScope.withDecodeFrame(tokens: input, enabled: true) {
                        text(input, cache: caches.map { $0 as! any KVCache })[0..., -1, 0...]
                    }
                }
            }, validateOutput: { _ in })
        try validate(output, rows: sessions.count, model: first.model)
        return output
    }

    static func validate(_ logits: MLXArray, rows: Int, model: Gemma4TensorParallelModel) throws {
        guard logits.shape == [rows, model.vocabularyRange.count], logits.dtype == .float32 else {
            throw ProbeError("Gemma tensor-parallel logits have an invalid shape or dtype")
        }
    }

    /// Releases the request's pages; after a failure too.
    func retire(failed: Bool = false) throws {
        guard !retired else { return }
        try MLX.withError { error in
            try state.retire(failed: failed)
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
            guard state.isClosed else { throw ProbeError("Gemma tensor-parallel request state remains owned") }
            retired = true
        }
    }
}

extension Gemma4TensorParallelModel {
    /// Decode steps encode under these command-buffer limits (as GLM's and
    /// Qwen's tensor-parallel decode): the worker's 16-operation guard splits a
    /// MoE step's thousands of small launches into many buffers, each a GPU
    /// gap. Synchronization only: results never depend on the partitioning.
    static let decodeCommandBuffers = GPU.CommandBufferLimits(operations: 100, megabytes: 1 << 20)
    /// A decode step is submitted to the GPU every this many decoder layers as
    /// the host builds it (`Gemma4LayerSubmission`), so the GPU and the
    /// collectives run the layers already built while the host builds the
    /// rest (Qwen tensor parallel's measured choice; not yet measured for
    /// Gemma). Evaluation order only: every value and token is unchanged.
    static let decodeLayerStride = 1
    /// A bench or test's own stride (0: the whole step in one evaluation).
    @TaskLocal static var layerStride: Int?
    /// Runs `body` with a bench's own decode layer stride (`layerStride`; nil:
    /// the product's `decodeLayerStride`), to compare strides on a pair
    /// (`darkbloom-cluster-tp-check gemma run --layer-stride`).
    public static func withLayerStride<R>(_ stride: Int?, _ body: () throws -> R) rethrows -> R {
        try $layerStride.withValue(stride, operation: body)
    }
    /// Row parts of each prompt chunk's work after attention, each part's sums
    /// issued as soon as built (`Gemma4TensorParallelPromptParts`): values and
    /// tokens unchanged, only when the GPU and the link run. 1 (whole): off by
    /// default. On two M5 Ultras 4 parts measured best (9,651-token prefill
    /// +13 %).
    static let promptChunkParts = 1
    /// A bench or test's own part count (nil: `promptChunkParts`).
    @TaskLocal static var benchPromptParts: Int?
    /// Runs `body` with a bench's own prompt parts
    /// (`darkbloom-cluster-tp-check gemma run --prompt-parts`).
    public static func withPromptParts<R>(_ parts: Int?, _ body: () throws -> R) rethrows -> R {
        try $benchPromptParts.withValue(parts, operation: body)
    }
    /// The bench modes a `withLayerStride` stride reaches: ranks that decode
    /// on the calling thread (`full`, `shard`, `tp`). `simulated` runs both
    /// ranks on `Gemma4TensorParallelLocalPair`'s own threads, which never see
    /// the stride, so a stride there is refused instead of silently ignored.
    public static func benchLayerStrideApplies(mode: String) -> Bool { ["full", "shard", "tp"].contains(mode) }

    /// Greedy generation as `generate`, on this model's paged KV through the
    /// resident runtime's own request path (`Gemma4TensorParallelPagedSession`,
    /// `Gemma4TensorParallelChoice`): each step's token and stop flags agreed in
    /// the step's evaluation, `recordTop` candidates per step from the
    /// vocabulary-split top-k gather and the final step's whole row.
    public func generatePaged(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0) throws -> Generation {
        guard !prompt.isEmpty, outputCount >= 1, chunk >= 1, prompt.allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor parallel generation: empty or out-of-vocabulary request")
        }
        guard (0 ... 64).contains(recordTop) else { throw ProbeError("Gemma tensor parallel generation: at most 64 logits per step") }
        let host = try pagedHost(lanes: 1, maximumTokens: prompt.count + outputCount, chunkTokens: chunk)
        let session = try Gemma4TensorParallelPagedSession(model: self, host: host, promptCount: prompt.count,
            outputCount: outputCount)
        return try generatePaged(session: session, host: host, prompt: prompt, outputCount: outputCount, chunk: chunk,
            recordTop: recordTop)
    }

    /// The same greedy generation on `session` (cold, or restored from a
    /// prefix: its prompt continues from its committed boundary), retired
    /// at the end; `host` must drain.
    func generatePaged(session: Gemma4TensorParallelPagedSession, host: CBv2StageKVHost, prompt: [Int], outputCount: Int,
                       chunk: Int, recordTop: Int) throws -> Generation {
        let rank: Int
        if case .shard(let r) = role { rank = r } else { rank = 0 }
        let choice = Gemma4TensorParallelChoice(selection: selection, sampler: nil, rank: rank)
        var result = Generation()
        do {
            try MLX.withError { error in
                func checked() throws { try error.check() }
                let started = Self.now()
                var offset = session.committedTokens
                var step: (logits: MLXArray, selected: MLXArray)?
                while offset < prompt.count {
                    let end = min(prompt.count, offset + chunk)
                    step = try session.prefill(prompt, range: offset ..< end, check: checked) { choice.build($0, stop: 0) } ?? step
                    offset = end
                }
                guard var current = step else { throw ProbeError("Gemma tensor-parallel prompt produced no step") }
                var last = started
                try GPU.withCommandBufferLimits(Self.decodeCommandBuffers) {
                    for index in 0 ..< outputCount {
                        let agreed = try choice.read(current.selected)
                        guard agreed.flags.allSatisfy({ $0 == 0 }) else { throw ProbeError("Gemma oracle step carried a stop") }
                        if recordTop > 0 {
                            let top = try selection.topK(current.logits, count: recordTop)
                            result.topTokenIDs.append(top.tokenIDs)
                            result.topLogits.append(top.logits)
                            result.topLogprobs.append(top.logprobs)
                            if index == outputCount - 1 {
                                let row = selection.gather(current.logits)
                                eval(row)
                                try checked()
                                result.finalLogits = row.asArray(Float.self)
                            }
                        }
                        let time = Self.now()
                        if index == 0 { result.firstTokenSeconds = time - started } else { result.stepSeconds.append(time - last) }
                        last = time
                        result.tokenIDs.append(agreed.token)
                        if index + 1 < outputCount {
                            current = try session.decode(agreed.token, check: checked) { choice.build($0, stop: 0) }
                        }
                    }
                }
                result.decodeSeconds = last - started - result.firstTokenSeconds
            }
            try session.retire()
        } catch {
            try? session.retire(failed: true)
            throw error
        }
        guard host.isDrained else { throw ProbeError("Gemma tensor-parallel request kept its pages") }
        result.peakActiveBytes = Memory.peakMemory
        return result
    }
}
