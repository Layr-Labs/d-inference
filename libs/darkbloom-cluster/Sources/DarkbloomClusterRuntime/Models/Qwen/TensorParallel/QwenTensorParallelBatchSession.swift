import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Input ownership is request-local. A media owner supplies its authenticated
/// position slices and prompt embeddings; text keeps the cache's own offsets.
/// The callbacks and their captured features remain held until checked native
/// retirement. This seam neither loads media nor admits its memory.
struct QwenTensorParallelBatchInputs {
    let positions: (Range<Int>) throws -> MLXArray
    let promptEmbedding: (MLXArray, Range<Int>) throws -> MLXArray
}

/// A genuine TP shard's independent attention and recurrent history. The
/// scheduling owner must execute both ranks in identical lane order, admit
/// memory before construction and keep its charge until retirement succeeds.
final class QwenTensorParallelBatchSession: QwenTensorParallelMTPTarget {
    let model: QwenTensorParallelModel
    let request: QwenLayerStageGenerationRequest
    let state: CBv2OwnedRequestState
    private var inputs: QwenTensorParallelBatchInputs?
    private var window: QwenTensorParallelTargetWindow?
    private var failed = false
    private let prefixCapture: QwenTensorParallelPrefixCapture?
    /// `frameTiming` only: this prompt's frames so far.
    private var promptClock: QwenTensorParallelPromptClock?
    private(set) var schedule: QwenLayerStageGenerationSchedule
    private(set) var retired = false
    var committedTokens: Int { state.committedTokens }

    init(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
         request: QwenLayerStageGenerationRequest, inputs: QwenTensorParallelBatchInputs? = nil,
         restored: QwenTensorParallelBatchPrefixState? = nil, capture: QwenTensorParallelPrefixCapture? = nil) throws {
        guard case .shard(_, let ranks) = model.role, ranks == 2,
              sha256(configuration) == model.configurationSHA256,
              request.profile.hiddenSize == model.plan.hiddenSize,
              request.profile.vocabularySize == model.plan.vocabularySize,
              request.reusedPrefixTokens == (restored?.committedTokens ?? 0),
              request.reusedPrefixTokens % request.chunkSize == 0,
              capture?.fits(request) ?? true else {
            throw ProbeError("Qwen TP batch session requires a matching shard and original-grid state")
        }
        let geometry = try Self.geometry(model: model, configuration: configuration, host: host,
            maximumTokens: request.maximumTokens)
        self.model = model; self.request = request; self.inputs = inputs
        self.prefixCapture = capture
        // Paged pages grow with the request (`reservePages`); the reference
        // contiguous backend keeps its whole-length rows.
        let reserved = host.kind == .paged ? Self.initialReservedTokens(request) : nil
        if let restored {
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                outputCount: request.outputCount, adoptingCommittedTokens: restored.committedTokens,
                attention: restored.attention, recurrent: restored.recurrent, reservedTokens: reserved)
        } else {
            state = try CBv2OwnedRequestState(geometry: geometry,
                promptCount: request.promptCount, outputCount: request.outputCount, reservedTokens: reserved)
        }
        schedule = QwenLayerStageGenerationSchedule(request: request)
    }

    /// Tokens a request's pages grow by (owner rule: no reservation for the
    /// whole output, grow on demand, no context cap; GLM's granule).
    static let pageGrowthTokens = 1024
    /// Tokens a request keeps reserved past what the next forward writes.
    static let pageGrowthMargin = 64

    /// The tokens a request's pages cover when it opens: its prompt and one
    /// granule, at most its whole length.
    static func initialReservedTokens(_ request: QwenLayerStageGenerationRequest) -> Int {
        min(request.maximumTokens, request.promptCount + pageGrowthTokens)
    }

    /// What a growth takes a reservation of `reserved` tokens to when `needed`
    /// tokens plus the margin pass it: a granule on, or the margin past
    /// `needed`, never past `limit`; nil when no growth is due.
    static func pageGrowthTarget(reserved: Int, needed: Int, limit: Int) -> Int? {
        guard needed + pageGrowthMargin > reserved, reserved < limit else { return nil }
        return min(limit, max(needed + pageGrowthMargin, reserved + pageGrowthTokens))
    }

    /// Before a forward that writes `count` tokens: keeps them and the margin
    /// reserved, growing by granules up to the request's length. Between
    /// steps only (the pool may grow); every byte the rows hold is unchanged.
    /// A growth the pool cannot back throws, as a forward that cannot
    /// allocate fails, before any of this step is built.
    func reservePages(writing count: Int) throws {
        guard state.pagedHost, let target = Self.pageGrowthTarget(reserved: state.reservedTokens,
            needed: state.committedTokens + count, limit: request.maximumTokens) else { return }
        try state.growReservation(toTokens: target)
    }

    /// This rank's request-state geometry for a request of `maximumTokens`.
    static func geometry(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
                         maximumTokens: Int) throws -> CBv2RequestGeometry {
        try CBv2RequestGeometry(model: model.model, family: .qwen35,
            feedForwardKind: QwenRoutedExpertStageModel.feedForwardKind(model.model),
            layerCount: model.plan.layerCount, vocabularySize: model.plan.vocabularySize,
            configurationData: configuration, maximumTokens: maximumTokens, host: host)
    }

    func prefill(check: () throws -> Void) throws -> MLXArray? {
        try prompt(capturingHidden: false, check: check).logits
    }

    /// The prompt frames one step runs from the next frame: up to `limit`
    /// merged into one graph (`QwenTensorParallelPromptWavefront`), ending at
    /// the capture frontier; the next frame alone where frames do not merge.
    func promptFrames(limit: Int) -> [QwenLayerStageFrame] {
        guard !retired else { return [] }
        let merges = QwenTensorParallelPromptWavefront.merges(model: model, request: request,
            mediaInputs: inputs != nil, packedStorage: state.packedStorage)
        return QwenTensorParallelPromptWavefront.frames(request: request, from: schedule.nextSequence,
            frontiers: prefixCapture?.frontiers ?? [], limit: merges ? limit : 1)
    }

    /// Runs the planned prompt step `step` (`promptFrames`), its frames as one graph.
    func prefill(step: QwenLayerStageFrame, check: () throws -> Void) throws -> MLXArray? {
        let frames = promptFrames(limit: QwenTensorParallelPromptWavefront.maximumFrames)
        guard let count = (1...max(1, frames.count)).first(where: {
            QwenTensorParallelPromptWavefront.step(Array(frames.prefix($0))) == step
        }) else { throw ProbeError("Qwen TP prompt step differs from its frames") }
        return try prompt(capturingHidden: false, frames: count, check: check).logits
    }

    func prefillForMTP(check: () throws -> Void) throws -> QwenTensorParallelMTPPromptResult {
        guard inputs == nil, request.qwenMedia == nil else { throw ProbeError("Qwen TP media cannot enter assistant history") }
        let result = try prompt(capturingHidden: true, check: check)
        guard let hidden = result.hidden else { throw ProbeError("Qwen TP assistant prompt omitted target hidden") }
        return .init(hidden: hidden, logits: result.logits)
    }

    private func prompt(capturingHidden: Bool, frames count: Int = 1,
                        check: () throws -> Void) throws -> (hidden: MLXArray?, logits: MLXArray?) {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            // Each frame is admitted on the schedule as the frames before it leave it.
            var planned = schedule, frames: [QwenLayerStageFrame] = []
            for _ in 0..<count {
                let proposed = try request.frame(sequence: planned.nextSequence)
                let admitted = try planned.admitPrefill(count: proposed.tokenCount, offset: proposed.tokenOffset,
                    final: proposed.finalPromptChunk)
                frames.append(admitted); try planned.commit(admitted)
            }
            guard let frame = QwenTensorParallelPromptWavefront.step(frames), count == 1 || !capturingHidden,
                  !retired, !failed, window?.isIdle ?? true, frame.phase == .prefill, state.committedTokens == frame.tokenOffset else {
                throw ProbeError("Qwen TP batch prefill frontier differs")
            }
            try reservePages(writing: frame.tokenCount)
            let range = frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)
            let input = MLXArray(request.promptTokenIDs[range].map(Int32.init)).reshaped([1, frame.tokenCount])
            let positions = try inputs.map { try $0.positions(range) }
            let embeddings = try inputs.map { try $0.promptEmbedding(input, range) }
            try validatePositions(positions, count: frame.tokenCount)
            if let embeddings {
                guard embeddings.shape == [1, frame.tokenCount, model.plan.hiddenSize],
                      String(describing: embeddings.dtype) == request.profile.activationDType else {
                    throw ProbeError("Qwen TP batch prompt embeddings differ from the shard")
                }
            }
            let final = range.upperBound == request.promptCount
            var hidden: MLXArray?
            let started = DispatchTime.now().uptimeNanoseconds
            var phases: CBv2OwnerPhaseObserver?
            var timing: QwenTensorParallelPrefillFrameClock?
            if let observe = Self.prefillPhases {
                phases = { observe($0) }
            } else if Self.frameTiming {
                let clock = QwenTensorParallelPrefillFrameClock()
                timing = clock
                phases = { clock.mark($0.phase) }
            }
            // A packed frame is evaluated whole (its refused writes are checked
            // before any of it runs), as a packed decode step is.
            let stride = Self.prefillStride ?? (state.packedStorage ? 0 : Self.prefillLayerStride)
            let output = try state.run(tokenCount: frame.tokenCount, observer: phases, check: checked, forward: { caches, evaluation in
              if frames.count > 1 {
                  return QwenTensorParallelPromptWavefront.forward(model: self.model, request: self.request,
                      frames: frames, caches: caches, evaluation: evaluation)
              }
              return Qwen35LayerSubmission.$stride.withValue(stride) { () -> MLXArray in
                let native = self.model.model
                if capturingHidden {
                    let result = native.cbv2ForwardWithHidden(input,
                        caches: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)
                    hidden = result.lastHidden
                    return final ? result.logits[0..., -1, 0...] : result.lastHidden
                }
                if !final {
                    return native.cbv2RecurrentPrefill(input, inputEmbedding: embeddings,
                        cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation],
                        positionIds: positions, requirement: .evaluationOnly)
                }
                // Preserve the solo TP final prompt head's rectangular graph;
                // project the full frame before taking its surviving last row.
                let output: MLXArray
                if let embeddings {
                    output = native.embeddingForward(input, inputEmbedding: embeddings,
                        cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: positions)
                } else {
                    output = native.cbv2Forward(input, caches: caches.map { $0 as! any KVCache },
                        recurrentState: [evaluation], positionIds: positions)
                }
                return output[0..., -1, 0...]
              }
            }, validateOutput: { output in
                if final { try Self.validateLogits(output, rows: 1, model: self.model, request: self.request) }
                else if !capturingHidden && output.shape != [1, 1] && output.shape != [1, 1, 1] {
                    throw ProbeError("Qwen TP evaluation-only prompt handle differs")
                }
            })
            if capturingHidden {
                guard let hidden, hidden.shape == [1, frame.tokenCount, model.plan.hiddenSize],
                      String(describing: hidden.dtype) == request.profile.activationDType else {
                    throw ProbeError("Qwen TP assistant prompt hidden differs from the actual target")
                }
                eval(hidden); try checked()
            }
            schedule = planned
            try prefixCapture?.capture(state, at: committedTokens, check: checked)
            if let timing, case .shard(let rank, _) = model.role {
                let clock = promptClock ?? QwenTensorParallelPromptClock()
                promptClock = clock
                clock.add(timing, tokens: frame.tokenCount, started: started)
                if final {
                    FileHandle.standardError.write(Data((clock.line(rank: rank, stride: stride) + "\n").utf8))
                    promptClock = nil
                }
            }
            return (hidden, final ? output : nil)
        }
    }

    /// A decode forward is submitted to the GPU every this many layers
    /// (`QwenTensorParallelLaunch.decodeLayerStride`, where the measured
    /// choice is). Evaluation order only: the logits and every committed
    /// state keep their bits.
    static let decodeLayerStride = QwenTensorParallelLaunch.decodeLayerStride
    /// A bench or test's own stride (0: the whole forward in one evaluation).
    @TaskLocal static var layerStride: Int?
    /// A prompt frame is submitted to the GPU every this many decoder layers
    /// as the host builds it (`Qwen35LayerSubmission`), so the GPU and the
    /// collectives start on the first layers while the host builds the rest,
    /// instead of after the whole frame's graph. Evaluation order only: every
    /// primitive, input and rounded value is the whole frame's.
    /// `DARKBLOOM_QWEN_TP_PREFILL_STRIDE` (diagnostic: 0 = the whole frame at once, as before).
    static let prefillLayerStride: Int = {
        guard let raw = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_PREFILL_STRIDE"],
              let value = Int(raw), (0 ... 64).contains(value) else { return 4 }
        return value
    }()
    /// A bench or test's own prompt stride (0: the whole frame in one evaluation).
    @TaskLocal static var prefillStride: Int?
    /// Diagnostic, `DARKBLOOM_QWEN_TP_PREFILL_FRAME_TIMING=1`: every prompt
    /// writes one `qwen-tp-prefill-v1` line to stderr at its last frame (its
    /// frames' graph construction, root staging, evaluation with its
    /// collectives, validation and commit, summed; `QwenTensorParallelPromptClock`).
    /// Never on in production.
    static let frameTiming = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_PREFILL_FRAME_TIMING"] == "1"
    /// Diagnostic (benches only): each prompt frame's owner phases (graph
    /// construction, root staging, evaluation, validation and commit), as
    /// `CBv2OwnedRequestState.run` reports them. nil changes nothing.
    @TaskLocal static var prefillPhases: (@Sendable (CBv2OwnerPhaseObservation) -> Void)?
    /// Command-buffer limits of a decode step, an assistant round and their
    /// selection on the thread that encodes them (the native executor's
    /// decode), as GLM's TP decode keeps them: the worker's 16-operation guard
    /// would split a routed-expert step's ~2,000 small launches into ~120
    /// buffers, each a GPU gap. The size bound stays lifted, as the worker
    /// sets it for tensor parallel. Prefill keeps the rank's limits.
    /// Synchronization only: results never depend on the partitioning.
    static let decodeCommandBuffers = GPU.CommandBufferLimits(operations: 100, megabytes: 1 << 20)

    /// Every plain step, verify window and batched row of a Qwen TP shard
    /// projects through the SDK's batch-invariant affine kernel
    /// (`Qwen35BatchDecodeScope.exactVectors`): each position of a verify
    /// window has the bits of the plain decode step that computes the same
    /// token, and each row the bits it has alone. Diagnostic only:
    /// `DARKBLOOM_QWEN_TP_EXACT_VECTORS=0` keeps MLX's kernels (whose window
    /// and cohort arithmetic depends on the vector count).
    static let exactVectors = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_EXACT_VECTORS"] != "0"
    /// A bench or test's own choice (nil: `exactVectors`).
    @TaskLocal static var exactVectorsOverride: Bool?
    static var usesExactVectors: Bool { exactVectorsOverride ?? exactVectors }

    /// Bound into the tensor-parallel load agreement: both ranks resolve the
    /// decode projections alike and sum the same selection words (each row's
    /// non-finite counts ride the greedy sum), or the pair refuses to load
    /// (never a mixed configuration). Each rank's words per lane is its own
    /// arithmetic (a rank sums only its own partials) and is not bound.
    static var decodeAgreementFields: [String] {
        ["qwen-tensor-parallel-decode-projections-v1", usesExactVectors ? "batch-invariant-affine" : "mlx-kernels",
         "qwen-tensor-parallel-fenced-sums-v1", sumsAreFencedInputs ? "on" : "off",
         "qwen-tensor-parallel-selection-nonfinite-in-sum-v1"]
    }

    /// Whether the residual step's kernel waits for each all-sum itself: MLX
    /// takes fenced inputs only with `MLX_METAL_FENCED_INPUTS` and fast fences
    /// both set (read as MLX reads them, an integer, nonzero on). Both ranks
    /// must agree: bound into the load agreement.
    static var sumsAreFencedInputs: Bool {
        let environment = ProcessInfo.processInfo.environment
        func on(_ name: String) -> Bool { environment[name].flatMap { Int($0) }.map { $0 != 0 } ?? false }
        return on("MLX_METAL_FENCED_INPUTS") && on("MLX_METAL_FAST_SYNCH")
    }

    /// The decode arithmetic a loaded shard runs, logged once per load so
    /// acceptance evidence shows it per rank: whether projections take the
    /// batch-invariant kernel, its words per lane on this GPU family (part of
    /// the arithmetic), the layouts it picks (which never change a result)
    /// and whether the byte-exact residual norm fusion is on.
    static func kernelLine(rank: Int, plan: QwenTensorParallelPlan) -> String {
        "darkbloom-aqv-kernel-v1 rank=\(rank) exact_vectors=\(usesExactVectors ? "on" : "off")"
            + " bits=\(plan.bits) group_size=\(plan.groupSize) "
            + AffineQuantizedVectors.resolvedDescription(bits: plan.bits, groupSize: plan.groupSize, inputs: plan.hiddenSize)
            + " residual_rms_norm=\(ResidualRMSNorm.isEnabled && ResidualRMSNorm.verifiedFamilies.contains(AffineQuantizedVectors.family()) ? "on" : "off")"
            + " fenced_sums=\(sumsAreFencedInputs ? "on" : "off")"
    }

    /// Vector counts the census describes: plain rows of one to eight, and
    /// their four-column verify windows.
    static let censusCounts = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 28, 32]

    /// The decode route of every projection of a loaded shard
    /// (`darkbloom-qwen-tp-decode-census-v1`), so a pair's log shows what each
    /// row count runs: the batch-invariant kernel (`aqv`), a row-parallel FP32
    /// partial on it (`partial`), or MLX's own kernels and why (`mlx-...`),
    /// with each shape's layout per vector count (layouts never change a
    /// result), and the attention, residual-norm and selection routes. Host
    /// only: no array is evaluated. Layouts are per checkpoint projection:
    /// the SDK multiplies a Gated DeltaNet layer's four input projections as
    /// one call of their summed rows, and fuses gate, up and SwiGLU at
    /// `swiglu_fused_vectors` only while its decode fusions are on.
    static func censusLine(rank: Int, model: QwenTensorParallelModel) -> String {
        var routes: [String: Int] = [:], layouts: [String: String] = [:], tally: [String: Int] = [:]
        for (path, module) in model.model.leafModules().flattened() {
            guard let linear = module as? Linear else { continue }
            let name = path.split(separator: ".").last.map(String.init) ?? path
            let (outputs, inputs) = linear.shape
            let route: String
            if let packed = linear as? QuantizedLinear {
                let probe = MLXArray.zeros([1, inputs], dtype: .bfloat16)
                let reason: String?
                if !usesExactVectors { reason = "off" }
                else if Device.defaultDevice().deviceType != .gpu { reason = "cpu" }
                else if AffineQuantizedVectors.supports(input: probe, weight: packed.weight, scales: packed.scales,
                    biases: packed.biases, groupSize: packed.groupSize, bits: packed.bits, mode: packed.mode) { reason = nil }
                else if packed.mode != .affine { reason = "mode" }
                else if packed.biases == nil { reason = "biases" }
                else { reason = "bits\(packed.bits)-group\(packed.groupSize)-\(packed.scales.dtype)" }
                if packed is QwenTensorParallelRowLinear {
                    route = reason.map { "mlx-partial-\($0)" } ?? (packed.bias == nil ? "partial" : "mlx-partial-bias")
                } else if type(of: packed) == QuantizedLinear.self {
                    route = reason.map { "mlx-\($0)" } ?? "aqv"
                } else {
                    route = "mlx-subclass-\(type(of: packed))"
                }
                if !route.hasPrefix("mlx") {
                    var runs: [(String, Int, Int)] = []
                    for count in censusCounts {
                        let layout = AffineQuantizedVectors.layout(vectors: count, inputs: inputs, outputs: outputs,
                            bits: packed.bits).description
                        if let last = runs.last, last.0 == layout { runs[runs.count - 1].2 = count }
                        else { runs.append((layout, count, count)) }
                    }
                    layouts["\(inputs)x\(outputs)"] = runs.map { "\($0.1 == $0.2 ? "\($0.1)" : "\($0.1)-\($0.2)")=\($0.0)" }
                        .joined(separator: "/")
                }
            } else {
                route = "mlx-unquantized"
            }
            routes["\(name):\(inputs)x\(outputs):\(route)", default: 0] += 1
            tally[route.hasPrefix("mlx") ? "mlx" : route, default: 0] += 1
        }
        let attention = Set(model.model.cbv2LayerKinds.map { kind -> String in
            let gqa = kind.queryHeads / max(1, kind.kvHeads)
            let hpt = PagedAttentionKernel.headsPerThreadgroup(headDim: kind.headDim, gqa: gqa)
            return "d\(kind.headDim)-kv\(kind.kvHeads)-gqa\(gqa)-hpt\(hpt)"
        }).sorted()
        let environment = ProcessInfo.processInfo.environment
        let switches = ["MLX_QMV_BATCH_INVARIANT", "MLX_ENABLE_TF32", "DARKBLOOM_QWEN35_FUSE_ELEMENTWISE",
                        "DARKBLOOM_QWEN35_DECODE_FUSIONS_V2", "DARKBLOOM_GDN_FUSED_CONV", "DARKBLOOM_GDN_FUSED_QK_NORM",
                        "DARKBLOOM_RESIDUAL_RMS_NORM", "DARKBLOOM_CBV2_PAGED_PTOK_TARGET", "DARKBLOOM_TTFT_GDN_BLOCKED"]
            .compactMap { key in environment[key].map { "\(key)=\($0)" } }
        let hidden = model.plan.hiddenSize
        return "darkbloom-qwen-tp-decode-census-v1 rank=\(rank) exact_vectors=\(usesExactVectors ? "on" : "off")"
            + " aqv=\(tally["aqv", default: 0]) partial=\(tally["partial", default: 0]) mlx=\(tally["mlx", default: 0])"
            + " routes=" + routes.sorted { $0.key < $1.key }.map { "\($0.key)*\($0.value)" }.joined(separator: ",")
            + " layouts=" + layouts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            + " swiglu_fused_vectors=" + censusCounts.filter { AffineQuantizedVectors.fusesSwiGLU(vectors: $0) }
                .map(String.init).joined(separator: "/")
            + " residual_rms_norm=\(ResidualRMSNorm.isEnabled && ResidualRMSNorm.verifiedFamilies.contains(AffineQuantizedVectors.family()) ? (hidden > 4096 ? "looped" : "single") : "off")"
            + " attention=paged-\(attention.joined(separator: "/")) ptok=\(PagedAttentionKernel.partitionTokens)"
            + " ptok_target=\(PagedAttentionKernel.partitionTargetThreadgroups)"
            + " selection=greedy-rank-argmax/sampled-gather switches=" + (switches.isEmpty ? "none" : switches.joined(separator: ","))
    }

    private static let censusLock = NSLock()
    nonisolated(unsafe) private static var censusModels = Set<ObjectIdentifier>()

    /// Logs `censusLine` once per loaded model.
    static func logCensusOnce(rank: Int, model: QwenTensorParallelModel) {
        let first = censusLock.withLock { censusModels.insert(ObjectIdentifier(model)).inserted }
        if first { log(censusLine(rank: rank, model: model)) }
    }

    static func decode(_ sessions: [QwenTensorParallelBatchSession], tokens: [Int],
                       check: () throws -> Void) throws -> MLXArray {
        try decodeResult(sessions, tokens: tokens, capturingHidden: false, check: check).logits
    }

    static func decodeWithHidden(_ sessions: [QwenTensorParallelBatchSession], tokens: [Int],
                                 check: () throws -> Void) throws -> (logits: MLXArray, hidden: MLXArray) {
        let result = try decodeResult(sessions, tokens: tokens, capturingHidden: true, check: check)
        guard let hidden = result.hidden else { throw ProbeError("Qwen TP decode omitted observed target hidden") }
        return (result.logits, hidden)
    }

    /// `decode`'s step, submitted and not read, on lazy input tokens (`[B]`
    /// int32, the previous step's unread selection; `CBv2OwnedRequestState.submitBatch`),
    /// so the next step can be built before this one is read
    /// (`QwenTensorParallelBatchDriver`'s build-ahead). The same forward and
    /// arithmetic as `decode` on the read tokens; native (unpacked) rows.
    static func submitDecode(_ sessions: [QwenTensorParallelBatchSession], tokens: MLXArray,
                             check: () throws -> Void) throws -> MLXArray {
        guard tokens.shape == [sessions.count], tokens.dtype == .int32 else {
            throw ProbeError("Qwen TP submitted decode needs one int32 token a row")
        }
        return try decodeResult(sessions, input: .submitted(tokens), capturingHidden: false, check: check).logits
    }

    /// A batch decode step's input: tokens the host read, or a previous step's lazy selection.
    private enum DecodeInput {
        case read([Int])
        case submitted(MLXArray)

        var rows: Int {
            switch self {
            case .read(let tokens): tokens.count
            case .submitted(let tokens): tokens.dim(0)
            }
        }
    }

    private static func decodeResult(_ sessions: [QwenTensorParallelBatchSession], tokens: [Int],
                                     capturingHidden: Bool, check: () throws -> Void) throws -> (logits: MLXArray, hidden: MLXArray?) {
        try decodeResult(sessions, input: .read(tokens), capturingHidden: capturingHidden, check: check)
    }

    private static func decodeResult(_ sessions: [QwenTensorParallelBatchSession], input decodeInput: DecodeInput,
                                     capturingHidden: Bool, check: () throws -> Void) throws -> (logits: MLXArray, hidden: MLXArray?) {
        guard let first = sessions.first, (1...8).contains(sessions.count), sessions.count == decodeInput.rows,
              Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count,
              sessions.allSatisfy({ $0.model === first.model && !$0.retired && !$0.failed && ($0.window?.isIdle ?? true) }) else {
            throw ProbeError("Qwen TP batch decode needs distinct sessions of one loaded shard")
        }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            var frames: [QwenLayerStageFrame] = []
            var positionRows: [MLXArray] = []
            // If any lane carries explicit media positions, all rows supply
            // their own three axes, including ordinary text rows in the cohort.
            let positioned = sessions.contains { $0.inputs != nil }
            if case .read(let tokens) = decodeInput,
               !tokens.allSatisfy({ (0..<first.model.plan.vocabularySize).contains($0) }) {
                throw ProbeError("Qwen TP decode token or committed frontier differs")
            }
            for session in sessions {
                guard session.state.committedTokens == session.schedule.committedTokens else {
                    throw ProbeError("Qwen TP decode token or committed frontier differs")
                }
                try session.reservePages(writing: 1)
                let frame = try session.schedule.admitDecode(offset: session.committedTokens)
                frames.append(frame)
                if positioned {
                    let range = frame.tokenOffset..<(frame.tokenOffset + 1)
                    let positions = try session.inputs.map { try $0.positions(range) }
                        ?? MLXArray(Array(repeating: Int32(frame.tokenOffset), count: 3)).reshaped([3, 1, 1])
                    try session.validatePositions(positions, count: 1)
                    positionRows.append(positions)
                }
            }
            let input: MLXArray, submitted: Bool
            switch decodeInput {
            case .read(let tokens): input = MLXArray(tokens.map(Int32.init)).reshaped([sessions.count, 1]); submitted = false
            case .submitted(let tokens): input = tokens.reshaped([sessions.count, 1]); submitted = true
            }
            guard !(submitted && capturingHidden) else { throw ProbeError("A submitted Qwen TP decode captures no hidden rows") }
            let positions = positioned ? concatenated(positionRows, axis: 1) : nil
            var hidden: MLXArray?
            // A packed step is evaluated whole: its refused writes are checked after the graph is built and before
            // any of it runs (`CBv2OwnedRequestState.checkStepWrites`), which layer submission would precede.
            let stride = layerStride ?? (first.state.packedStorage ? 0 : decodeLayerStride)
            let step = submitted ? CBv2OwnedRequestState.submitBatch : CBv2OwnedRequestState.runBatch
            let output = try step(sessions.map(\.state), 1, checked, { caches, evaluations in
                    Qwen35BatchDecodeScope.$enabled.withValue(true) { Qwen35LayerSubmission.$stride.withValue(stride) {
                      Qwen35BatchDecodeScope.$exactVectors.withValue(usesExactVectors) {
                        Qwen35BatchDecodeScope.$explicitPositionRows.withValue(sessions.map { $0.inputs != nil }) {
                            if capturingHidden {
                                let result = first.model.model.cbv2ForwardWithHidden(input,
                                    caches: caches.map { $0 as! any KVCache }, recurrentState: evaluations, positionIds: positions)
                                hidden = result.lastHidden
                                return result.logits[0..., -1, 0...]
                            }
                            return first.model.model.cbv2Forward(input, caches: caches.map { $0 as! any KVCache },
                                recurrentState: evaluations, positionIds: positions)[0..., -1, 0...]
                        }
                      }
                    } }
                }, { output in
                    try validateLogits(output, rows: sessions.count, model: first.model, request: first.request)
                })
            if capturingHidden {
                guard let hidden, hidden.shape == [sessions.count, 1, first.model.plan.hiddenSize],
                      String(describing: hidden.dtype) == first.request.profile.activationDType else {
                    throw ProbeError("Qwen TP batch observation hidden differs from the actual target")
                }
                eval(hidden); try checked()
            }
            for (session, frame) in zip(sessions, frames) { try session.schedule.commit(frame) }
            return (output, hidden)
        }
    }

    static func beginWindows(_ sessions: [QwenTensorParallelBatchSession], tokens: MLXArray)
        throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            guard let first = sessions.first, (1...8).contains(sessions.count),
                  Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count,
                  sessions.allSatisfy({ $0.model === first.model && !$0.retired && !$0.failed
                    && $0.inputs == nil && $0.request.qwenMedia == nil && ($0.window?.isIdle ?? true)
                    && $0.schedule.committedTokens == $0.state.committedTokens }) else {
                throw ProbeError("Qwen TP batch cannot begin this captured cohort")
            }
            for session in sessions {
                try session.reservePages(writing: tokens.ndim == 2 ? tokens.dim(1) : 0)
                _ = try session.schedule.admitDecode(offset: session.committedTokens)
                if session.window == nil {
                    session.window = QwenTensorParallelTargetWindow(model: session.model, request: session.request, state: session.state)
                }
            }
            return try Qwen35BatchDecodeScope.$exactVectors.withValue(usesExactVectors) {
                try QwenTensorParallelTargetWindow.beginBatch(sessions.map { $0.window! }, tokens: tokens,
                    offsets: sessions.map(\.committedTokens))
            }
        } catch { sessions.forEach { $0.failed = true }; throw error }
    }

    static func confirmWindows(_ sessions: [QwenTensorParallelBatchSession], check: () throws -> Void) throws {
        do { try QwenTensorParallelTargetWindow.confirmBatch(sessions.map { try $0.requireWindow() }, check: check) }
        catch { sessions.forEach { $0.failed = true }; throw error }
    }

    static func settleWindows(_ sessions: [QwenTensorParallelBatchSession], keeping kept: [Int]) throws -> [MLXArray] {
        do { return try QwenTensorParallelTargetWindow.settleBatch(sessions.map { try $0.requireWindow() }, keeping: kept) }
        catch { sessions.forEach { $0.failed = true }; throw error }
    }

    static func confirmSettledWindows(_ sessions: [QwenTensorParallelBatchSession], check: () throws -> Void) throws {
        do {
            let ranges = try QwenTensorParallelTargetWindow.confirmBatchSettled(sessions.map { try $0.requireWindow() }, check: check)
            var schedules = sessions.map(\.schedule)
            for (row, range) in ranges.enumerated() {
                for offset in range { try schedules[row].commit(schedules[row].admitDecode(offset: offset)) }
                guard schedules[row].committedTokens == sessions[row].state.committedTokens else {
                    throw ProbeError("Qwen TP captured batch settlement lost a request schedule")
                }
            }
            for (session, schedule) in zip(sessions, schedules) { session.schedule = schedule }
        } catch { sessions.forEach { $0.failed = true }; throw error }
    }

    func beginWindow(tokens: MLXArray, offset: Int) throws -> (outputs: [MLXArray], roots: [MLXArray]) {
        do {
            guard !retired, !failed, inputs == nil, request.qwenMedia == nil,
                  window?.isIdle ?? true, schedule.committedTokens == offset else {
                throw ProbeError("Qwen TP batched target cannot begin this assistant window")
            }
            try reservePages(writing: tokens.ndim == 2 ? tokens.dim(1) : 0)
            _ = try schedule.admitDecode(offset: offset)
            let transaction = window ?? QwenTensorParallelTargetWindow(model: model, request: request, state: state)
            window = transaction
            return try Qwen35BatchDecodeScope.$exactVectors.withValue(Self.usesExactVectors) {
                try transaction.begin(tokens: tokens, offset: offset)
            }
        } catch { failed = true; throw error }
    }

    func confirmWindow(check: () throws -> Void) throws {
        do { try requireWindow().confirm(check: check) }
        catch { failed = true; throw error }
    }

    func settleWindow(keeping kept: Int) throws -> [MLXArray] {
        do { return try requireWindow().settle(keeping: kept) }
        catch { failed = true; throw error }
    }

    func confirmSettled(check: () throws -> Void) throws {
        do {
            let range = try requireWindow().confirmSettled(check: check)
            for offset in range { try schedule.commit(schedule.admitDecode(offset: offset)) }
            guard schedule.committedTokens == state.committedTokens else { throw ProbeError("Qwen TP batch settlement lost its schedule") }
        } catch { failed = true; throw error }
    }

    private func requireWindow() throws -> QwenTensorParallelTargetWindow {
        guard !retired, !failed, let window else { throw ProbeError("Qwen TP batch has no live target transaction") }
        return window
    }

    private func validatePositions(_ positions: MLXArray?, count: Int) throws {
        guard let positions else { return }
        guard positions.shape == [3, 1, count], positions.dtype == .int32,
              all(positions .>= 0).item(Bool.self) else {
            throw ProbeError("Qwen TP positions differ from request-owned three-axis slices")
        }
    }
    /// Shape and dtype only: selection counts non-finite logits inside its own
    /// sealed sum (`QwenTensorParallelNativeBatchExecutor.select`), so both
    /// ranks refuse such a row together and no step pays a separate read.
    private static func validateLogits(_ value: MLXArray, rows: Int, model: QwenTensorParallelModel,
                                       request: QwenLayerStageGenerationRequest) throws {
        guard value.shape == [rows, model.vocabularyRange.count],
              String(describing: value.dtype) == request.profile.selectedRowDType else {
            throw ProbeError("Qwen TP batched logits have an invalid shape or dtype")
        }
    }

    /// The kept boundaries' states and the attention copy they share, once,
    /// after native retirement.
    func takeCapturedPrefix() throws -> (states: [QwenTensorParallelBatchPrefixState], sharedBytes: Int)? {
        guard retired && state.isClosed else { throw ProbeError("Qwen TP prefix donation precedes native retirement") }
        guard let prefixCapture else { return nil }
        defer { prefixCapture.discard() }
        let states = prefixCapture.states()
        return states.isEmpty ? nil : (states, prefixCapture.sharedBytes)
    }
    func discardCapturedPrefix() { prefixCapture?.discard() }

    func retire() throws {
        guard !retired else { return }
        try MLX.withError { error in
            try state.retire()
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
            guard state.isClosed else { throw ProbeError("Qwen TP batch history remains owned") }
            inputs = nil; window = nil
            retired = true
        }
    }
}

/// One prompt frame's owner phases on this rank (`QwenTensorParallelBatchSession.frameTiming`).
final class QwenTensorParallelPrefillFrameClock {
    private(set) var marks: [CBv2OwnerPhase: UInt64] = [:]
    func mark(_ phase: CBv2OwnerPhase) { marks[phase] = DispatchTime.now().uptimeNanoseconds }
    func span(_ begin: CBv2OwnerPhase, _ end: CBv2OwnerPhase) -> UInt64 {
        guard let b = marks[begin], let e = marks[end], e >= b else { return 0 }
        return e - b
    }
}

/// One prompt's frames on this rank, summed: one `qwen-tp-prefill-v1` line
/// at its last frame (digits and lowercase only, as a pair-check keeps
/// runtime lines).
final class QwenTensorParallelPromptClock {
    private var frames = 0, tokens = 0
    private var build: UInt64 = 0, stage: UInt64 = 0, evaluation: UInt64 = 0, commit: UInt64 = 0, total: UInt64 = 0
    private var slowest: UInt64 = 0

    func add(_ frame: QwenTensorParallelPrefillFrameClock, tokens count: Int, started: UInt64) {
        frames += 1; tokens += count
        build += frame.span(.graphConstructionBegin, .graphConstructionEnd)
        stage += frame.span(.rootStagingBegin, .rootStagingEnd)
        evaluation += frame.span(.evaluationBegin, .evaluationEnd)
        commit += frame.span(.validationCommitBegin, .validationCommitEnd)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        total += elapsed; slowest = max(slowest, elapsed)
    }

    func line(rank: Int, stride: Int) -> String {
        "qwen-tp-prefill-v1 rank=\(rank) tokens=\(tokens) frames=\(frames) stride=\(stride)"
            + " build_us=\(build / 1000) stage_us=\(stage / 1000) eval_us=\(evaluation / 1000)"
            + " commit_us=\(commit / 1000) frames_us=\(total / 1000) slowest_frame_us=\(slowest / 1000)"
    }
}
