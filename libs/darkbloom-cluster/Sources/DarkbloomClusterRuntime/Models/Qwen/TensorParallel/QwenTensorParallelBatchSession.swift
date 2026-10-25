import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

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
    private let captureFrontier: Int
    private let captureLimitBytes: Int
    private let allocationBound: (Int) throws -> Int
    private var captured: QwenTensorParallelBatchPrefixState?
    private(set) var schedule: QwenLayerStageGenerationSchedule
    private(set) var retired = false
    var committedTokens: Int { state.committedTokens }

    init(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
         request: QwenLayerStageGenerationRequest, inputs: QwenTensorParallelBatchInputs? = nil,
         restored: QwenTensorParallelBatchPrefixState? = nil, captureFrontier: Int = 0,
         captureLimitBytes: Int = 0, allocationBound: ((Int) throws -> Int)? = nil) throws {
        guard case .shard(_, let ranks) = model.role, ranks == 2,
              sha256(configuration) == model.configurationSHA256,
              request.profile.hiddenSize == model.plan.hiddenSize,
              request.profile.vocabularySize == model.plan.vocabularySize,
              request.reusedPrefixTokens == (restored?.committedTokens ?? 0),
              request.reusedPrefixTokens % request.chunkSize == 0,
              captureFrontier == 0 || (captureFrontier > request.reusedPrefixTokens
                && captureFrontier < request.promptCount && captureFrontier % request.chunkSize == 0),
              captureLimitBytes >= 0, captureFrontier == 0 || allocationBound != nil else {
            throw ProbeError("Qwen TP batch session requires a matching shard and original-grid state")
        }
        let geometry = try Self.geometry(model: model, configuration: configuration, host: host,
            maximumTokens: request.maximumTokens)
        self.model = model; self.request = request; self.inputs = inputs
        self.captureFrontier = captureFrontier; self.captureLimitBytes = captureLimitBytes
        self.allocationBound = allocationBound ?? { _ in throw ProbeError("Unpriced TP prefix capture") }
        if let restored {
            state = try CBv2OwnedRequestState(geometry: geometry, promptCount: request.promptCount,
                outputCount: request.outputCount, adoptingCommittedTokens: restored.committedTokens,
                attention: restored.attention, recurrent: restored.recurrent)
        } else {
            state = try CBv2OwnedRequestState(geometry: geometry,
                promptCount: request.promptCount, outputCount: request.outputCount)
        }
        schedule = QwenLayerStageGenerationSchedule(request: request)
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

    func prefillForMTP(check: () throws -> Void) throws -> QwenTensorParallelMTPPromptResult {
        guard inputs == nil, request.qwenMedia == nil else { throw ProbeError("Qwen TP media cannot enter assistant history") }
        let result = try prompt(capturingHidden: true, check: check)
        guard let hidden = result.hidden else { throw ProbeError("Qwen TP assistant prompt omitted target hidden") }
        return .init(hidden: hidden, logits: result.logits)
    }

    private func prompt(capturingHidden: Bool, check: () throws -> Void) throws -> (hidden: MLXArray?, logits: MLXArray?) {
        try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            let proposed = try request.frame(sequence: schedule.nextSequence)
            let frame = try schedule.admitPrefill(count: proposed.tokenCount, offset: proposed.tokenOffset,
                final: proposed.finalPromptChunk)
            guard !retired, !failed, window?.isIdle ?? true, frame.phase == .prefill, state.committedTokens == frame.tokenOffset else {
                throw ProbeError("Qwen TP batch prefill frontier differs")
            }
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
            let output = try state.run(tokenCount: frame.tokenCount, check: checked, forward: { caches, evaluation in
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
            try schedule.commit(frame)
            if committedTokens == captureFrontier { try capturePrefix(check: checked) }
            return (hidden, final ? output : nil)
        }
    }

    /// A decode forward is submitted to the GPU every this many layers
    /// (`Qwen35LayerSubmission`), so the GPU and the collectives run the
    /// layers already built while the host builds the rest. Evaluation order
    /// only: the logits and every committed state keep their bits.
    static let decodeLayerStride = 1
    /// A bench or test's own stride (0: the whole forward in one evaluation).
    @TaskLocal static var layerStride: Int?
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
    /// decode projections alike, or the pair refuses to load (never a mixed
    /// configuration). Each rank's words per lane is its own arithmetic
    /// (a rank sums only its own partials) and is not bound.
    static var decodeAgreementFields: [String] {
        ["qwen-tensor-parallel-decode-projections-v1", usesExactVectors ? "batch-invariant-affine" : "mlx-kernels"]
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

    private static func decodeResult(_ sessions: [QwenTensorParallelBatchSession], tokens: [Int],
                                     capturingHidden: Bool, check: () throws -> Void) throws -> (logits: MLXArray, hidden: MLXArray?) {
        guard let first = sessions.first, (1...8).contains(sessions.count), sessions.count == tokens.count,
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
            for (session, token) in zip(sessions, tokens) {
                guard (0..<first.model.plan.vocabularySize).contains(token),
                      session.state.committedTokens == session.schedule.committedTokens else {
                    throw ProbeError("Qwen TP decode token or committed frontier differs")
                }
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
            let input = MLXArray(tokens.map(Int32.init)).reshaped([sessions.count, 1])
            let positions = positioned ? concatenated(positionRows, axis: 1) : nil
            var hidden: MLXArray?
            // A packed step is evaluated whole: its refused writes are checked after the graph is built and before
            // any of it runs (`CBv2OwnedRequestState.checkStepWrites`), which layer submission would precede.
            let stride = layerStride ?? (first.state.packedStorage ? 0 : decodeLayerStride)
            let output = try CBv2OwnedRequestState.runBatch(sessions.map(\.state), tokenCount: 1, check: checked,
                forward: { caches, evaluations in
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
                }, validateOutput: { output in
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
    private static func validateLogits(_ value: MLXArray, rows: Int, model: QwenTensorParallelModel,
                                       request: QwenLayerStageGenerationRequest) throws {
        guard value.shape == [rows, model.vocabularyRange.count],
              String(describing: value.dtype) == request.profile.selectedRowDType,
              all(isFinite(value)).item(Bool.self) else {
            throw ProbeError("Qwen TP batched logits have an invalid shape, dtype or finite value")
        }
    }

    private func capturePrefix(check: () throws -> Void) throws {
        guard captured == nil else { throw ProbeError("Qwen TP prefix is already captured") }
        captured = try .capture(state: state, frontier: captureFrontier, limitBytes: captureLimitBytes,
            allocationBound: allocationBound, check: check)
    }

    func takeCapturedPrefix() throws -> QwenTensorParallelBatchPrefixState? {
        guard retired && state.isClosed else { throw ProbeError("Qwen TP prefix donation precedes native retirement") }
        defer { captured = nil }
        return captured
    }
    func discardCapturedPrefix() { captured = nil }

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
