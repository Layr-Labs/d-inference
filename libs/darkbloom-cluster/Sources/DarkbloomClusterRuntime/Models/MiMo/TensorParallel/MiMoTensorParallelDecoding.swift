import Cmlx
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// How a request's tokens are chosen over the vocabulary-split head. Both
/// ranks derive the same rule from the request, so they issue the same
/// collectives in the same order.
enum MiMoTensorParallelSelectionRule: Equatable, Sendable {
    /// Plain greedy: each rank's FP32 maximum and its token ID cross in the
    /// step's agreement sum; the larger maximum wins, ties to the lower ID,
    /// exactly the whole row's argmax.
    case greedy
    /// A greedy row that reports logprobs: the same choice, then the
    /// vocabulary-split top-k gather (each rank's top `top` and its rows'
    /// log-sum-exp in one small collective, `Gemma4TensorParallelSelection.topK`).
    case greedyLogprobs(top: Int)
    /// Every other row (a temperature, logit bias or penalties): the whole
    /// row gathered bit for bit to every rank; rank 0 draws with the product's
    /// sampler (and gathers the product's logprobs), and the token crosses in
    /// the step's agreement sum.
    case gatheredRow

    static func rule(_ sampling: ClusterWorkerSampling?) -> Self {
        guard let sampling, !sampling.isGreedyNoOp else { return .greedy }
        if !sampling.isStochastic, !sampling.dependsOnHistory { return .greedyLogprobs(top: sampling.topLogprobs) }
        return .gatheredRow
    }

    /// The rule's name in log lines.
    var label: String {
        switch self {
        case .greedy: return "greedy"
        case .greedyLogprobs(let top): return "greedy_top\(top)"
        case .gatheredRow: return "gathered_row"
        }
    }
}

/// One request on one rank of a MiMo V2.6 tensor-parallel model (or on the
/// whole model), on request-owned paged KV histories
/// (`MiMoV26IndependentHistoryCache`: 64-token pages, grown on demand, built
/// from the rank's own layers, so full layers hold this rank's KV heads at
/// key/value widths 192/128 and sliding layers keep the 128-token window and
/// the learned sink bias of this rank's query heads).
///
/// Prefill runs the request's chunks; decode runs one token per step under
/// `decodeCommandBuffers`. Each step ends with one small agreement sum: per
/// rank `[value, token, stop, position]`. Greedy rows put their maximum and
/// its token ID (the vocabulary-split argmax); gathered rows put rank 0's
/// draw (rank 1 an ignored value that still depends on the row, so its sums
/// keep their order). A positive stop slot on either rank ends both after
/// that step (`QwenTensorParallelStopRule`); positions that differ end the
/// request as diverged state. Without a reduction (`full`) every choice is
/// local and no collective runs.
struct MiMoTensorParallelDecoding {
    /// Decode steps' command-buffer commit limits on the encoding thread, as
    /// GLM and Qwen tensor parallel set them (`GLM5NextTensorParallelResidentRuntime.decodeCommandBuffers`):
    /// 100 operations instead of the rank's 16-operation guard, with the size
    /// bound lifted (each routed layer's expert launch takes its whole bank as
    /// an input). Prefill keeps the rank's limits. Synchronization only:
    /// results never depend on the partitioning.
    static let decodeCommandBuffers = GPU.CommandBufferLimits(operations: 100, megabytes: 1 << 20)
    static let agreementSlots = 4

    let model: MiMoTensorParallelModel
    /// Records every forward's routed expert sets when set (oracles only):
    /// each prefill chunk's are evaluated with its caches, each step's with
    /// its selection. Values never change.
    var routes: MiMoTensorParallelRouteRecorder? = nil

    struct Request {
        let prompt: [Int]
        let outputCount: Int
        let chunk: Int
        let stopTokenIDs: Set<Int>
        let rule: MiMoTensorParallelSelectionRule
        /// The product's sampler; required for `gatheredRow` (rank 0 draws).
        let sampler: QwenStageTokenSampler?
    }

    /// What a step's selection made, for logprobs and oracle evidence.
    struct Step {
        let index: Int
        let token: Int
        /// This rank's rows of the step's logits `[1, V or V/2]`.
        let logits: MLXArray
        /// The whole row `[1, V]` (FP32), when the rule gathered it.
        let row: MLXArray?
        /// The whole row's top candidates, when the rule gathered them.
        let top: (tokenIDs: [Int], logits: [Float], logprobs: [Float])?
        /// The product sampler's logprobs (rank 0 of a gathered row that asks for them).
        let sampledLogprobs: ClusterWorkerTokenLogprobs?
    }

    struct Outcome {
        var tokens: [Int] = []
        var finish: QwenTensorParallelStopRule.Finish = .length
        /// This rank raised the stop (cancel, deadline, memory); the owner's
        /// client stop is not one.
        var stoppedHere = false
        /// Rank 0's owner answered a token with a stop.
        var ownerStopped = false
        var caches: [MiMoV26IndependentHistoryCache] = []
        var firstTokenSeconds = 0.0
        var decodeSeconds = 0.0
    }

    var reduction: QwenTensorParallelReduction? { model.reduction }
    var rank: Int { reduction?.rank ?? 0 }

    /// Both ranks were given the same request: one sum of the 64-bit
    /// `digest` in four 16-bit slots per rank (exact in FP32).
    func requestAgreed(_ digest: UInt64) throws -> Bool {
        guard let reduction else { return true }
        let mine = (0 ..< 4).map { Float((digest >> (16 * UInt64($0))) & 0xffff) }
        var slots = [Float](repeating: 0, count: 4 * reduction.size)
        for index in 0 ..< 4 { slots[4 * reduction.rank + index] = mine[index] }
        let summed = reduction.allSum(MLXArray(slots))
        eval(summed)
        let values = summed.asArray(Float.self)
        return (0 ..< reduction.size).allSatisfy { Array(values[(4 * $0) ..< (4 * $0 + 4)]) == mine }
    }

    /// Runs `request` from a cold paged history. `localStop` is this rank's
    /// own reason to stop (cancel, deadline, memory), asked after each commit;
    /// `publish(ordinal, token, logprobs)` (rank 0 only) hands a committed
    /// token to the owner and returns its answer (false: a client stop);
    /// `observe` sees each agreed step before its commit (oracles; it may
    /// issue collectives of its own, in the same order on every rank).
    func run(_ request: Request, localStop: () -> Bool = { false },
             publish: (Int, Int, ClusterWorkerTokenLogprobs?) throws -> Bool = { _, _, _ in true },
             observe: ((Step) throws -> Void)? = nil) throws -> Outcome {
        let prompt = request.prompt
        guard !prompt.isEmpty, request.outputCount >= 1, request.chunk >= 1,
              prompt.allSatisfy({ (0 ..< model.plan.vocabularySize).contains($0) }) else {
            throw ProbeError("MiMo tensor parallel generation: empty or out-of-vocabulary request")
        }
        if case .greedyLogprobs(let top) = request.rule {
            guard (1 ... ClusterWorkerSampling.maximumTopLogprobs).contains(top) else {
                throw ProbeError("MiMo tensor parallel generation: 1 to 20 logprob alternatives")
            }
        }
        guard request.rule != .gatheredRow || request.sampler != nil else {
            throw ProbeError("MiMo tensor parallel generation: a gathered row needs the product's sampler")
        }
        let started = MiMoTensorParallelModel.now()
        let caches = try model.model.makeIndependentHistoryCaches()
        var outcome = Outcome(caches: caches)
        var logits = try prefill(prompt, chunk: request.chunk, caches: caches)
        var previousOperations: Int32 = 0, previousMegabytes: Int32 = 0
        mlx_metal_set_thread_command_buffer_limits(Int32(Self.decodeCommandBuffers.operations),
            Int32(Self.decodeCommandBuffers.megabytes), &previousOperations, &previousMegabytes)
        defer { mlx_metal_set_thread_command_buffer_limits(previousOperations, previousMegabytes, nil, nil) }
        var stopKeep: Float = 0
        steps: for index in 0 ..< request.outputCount {
            let position = caches[0].offset
            let choice = try select(logits, request: request, stop: stopKeep, position: position)
            routes?.flush()
            if let slot = choice.stop {
                // A rank asked both to stop: both keep the tokens it named.
                let stop = QwenTensorParallelStopRule.stop(slot: slot)
                outcome.tokens = Array(outcome.tokens.prefix(stop.keep))
                outcome.finish = stop.finish
                break
            }
            if index == 0 { outcome.firstTokenSeconds = MiMoTensorParallelModel.now() - started }
            try observe?(choice.step(index))
            request.sampler?.commit(choice.token)
            outcome.tokens.append(choice.token)
            var wanted = true
            if rank == 0 { wanted = try publish(index, choice.token, choice.logprobs) }
            switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(choice.token),
                                                      committed: outcome.tokens.count,
                                                      outputCount: request.outputCount, wanted: true) {
            case .eos: outcome.finish = .eos; break steps
            case .length: outcome.finish = .length; break steps
            case .clientStop, .proceed: break
            }
            if !wanted {
                stopKeep = Float(outcome.tokens.count)
                outcome.ownerStopped = true
            } else if localStop() {
                stopKeep = Float(outcome.tokens.count)
                outcome.stoppedHere = true
            }
            logits = try forward([choice.token], caches: caches)
        }
        // Both ranks ended after the same step with the same tokens: checked in one sum.
        try agreeEnd(&outcome)
        outcome.decodeSeconds = MiMoTensorParallelModel.now() - started - outcome.firstTokenSeconds
        return outcome
    }

    /// The prompt in chunks; the last position's logits `[1, V or V/2]`, not evaluated.
    func prefill(_ prompt: [Int], chunk: Int, caches: [MiMoV26IndependentHistoryCache]) throws -> MLXArray {
        var offset = 0
        while true {
            let end = min(prompt.count, offset + chunk)
            let logits = try forward(Array(prompt[offset ..< end]), caches: caches)
            if end == prompt.count { return logits }
            eval(caches.flatMap { $0.innerState() } + (routes?.pending ?? []))
            routes?.flush()
            offset = end
        }
    }

    func forward(_ tokens: [Int], caches: [MiMoV26IndependentHistoryCache]) throws -> MLXArray {
        let input = MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)
        return try model.model.forwardIndependentHistory(inputIDs: input, caches: caches,
            logitsStart: tokens.count - 1).logits[0..., -1, 0...]
    }

    struct Choice {
        let token: Int
        let stop: Float?
        let logits: MLXArray
        let row: MLXArray?
        let top: (tokenIDs: [Int], logits: [Float], logprobs: [Float])?
        let sampledLogprobs: ClusterWorkerTokenLogprobs?

        func step(_ index: Int) -> Step {
            .init(index: index, token: token, logits: logits, row: row, top: top, sampledLogprobs: sampledLogprobs)
        }

        /// The committed token's logprobs, when the request asks for them.
        var logprobs: ClusterWorkerTokenLogprobs? {
            if let sampledLogprobs { return sampledLogprobs }
            guard let top, let first = top.tokenIDs.first, first == token else { return nil }
            return .init(logprob: top.logprobs[0],
                         top: zip(top.tokenIDs, top.logprobs).map { .init(tokenID: $0, logprob: $1) })
        }
    }

    /// One step's selection: the agreement sum (and the row gather or the
    /// top-k gather its rule takes), evaluated.
    func select(_ logits: MLXArray, request: Request, stop: Float, position: Int) throws -> Choice {
        let values = logits.asType(.float32)
        let selection = model.selection
        var row: MLXArray?
        var pending: [MLXArray] = []
        let mine: MLXArray
        switch request.rule {
        case .greedy, .greedyLogprobs:
            let index = argMax(values, axis: -1).asType(.float32) + MLXArray(Float(selection.vocabularyRange.lowerBound))
            mine = concatenated([values.max(axis: -1), index, MLXArray([stop, Float(position)])], axis: 0)
        case .gatheredRow:
            let whole = selection.gather(values)
            row = whole
            let drawn = rank == 0 ? request.sampler!.sample(whole) : argMax(whole, axis: -1)
            mine = concatenated([MLXArray([Float(0)]), drawn.asType(.float32).reshaped(1),
                                 MLXArray([stop, Float(position)])], axis: 0)
        }
        let all: MLXArray
        let ranks = reduction?.size ?? 1
        if let reduction {
            let empty = MLXArray.zeros([Self.agreementSlots], dtype: .float32)
            all = reduction.allSum(concatenated((0 ..< ranks).map { $0 == reduction.rank ? mine : empty }, axis: 0))
        } else {
            all = mine
        }
        pending.append(all)
        try MLX.withError { error in
            eval(pending)
            try error.check()
        }
        let agreed = all.asArray(Float.self)
        guard agreed.count == Self.agreementSlots * ranks else {
            throw ProbeError("MiMo tensor parallel selection has a wrong shape")
        }
        func slot(_ rank: Int, _ field: Int) -> Float { agreed[Self.agreementSlots * rank + field] }
        guard (0 ..< ranks).allSatisfy({ slot($0, 3) == Float(position) }) else {
            throw ProbeError("MiMo tensor-parallel ranks are at different positions")
        }
        let stops = (0 ..< ranks).map { slot($0, 2) }.filter { $0 > 0 }
        var token = Int(slot(0, 1))
        if request.rule != .gatheredRow {
            // The strictly greater maximum wins: ties go to the lower rank, which holds the lower IDs.
            var best = slot(0, 0)
            for other in 1 ..< ranks where slot(other, 0) > best { best = slot(other, 0); token = Int(slot(other, 1)) }
        }
        guard (0 ..< model.plan.vocabularySize).contains(token) else {
            throw ProbeError("MiMo tensor parallel selection chose no token of the vocabulary")
        }
        var top: (tokenIDs: [Int], logits: [Float], logprobs: [Float])?
        var sampled: ClusterWorkerTokenLogprobs?
        if stops.isEmpty {
            switch request.rule {
            case .greedyLogprobs(let count): top = try selection.topK(logits, count: count)
            case .gatheredRow where rank == 0: sampled = request.sampler!.takePendingLogprobs()
            default: break
            }
        }
        return Choice(token: token, stop: stops.min(), logits: logits, row: row, top: top, sampledLogprobs: sampled)
    }

    /// Every rank's token count and finish in one sum; ranks that ended
    /// differently have diverged.
    func agreeEnd(_ outcome: inout Outcome) throws {
        guard let reduction else { return }
        var slots = [Float](repeating: 0, count: 2 * reduction.size)
        slots[2 * reduction.rank] = Float(outcome.tokens.count)
        slots[2 * reduction.rank + 1] = Float(outcome.finish.code)
        let summed = reduction.allSum(MLXArray(slots))
        eval(summed)
        let values = summed.asArray(Float.self)
        guard (0 ..< reduction.size).allSatisfy({ values[2 * $0] == values[0] && values[2 * $0 + 1] == values[1] }) else {
            throw ProbeError("MiMo tensor-parallel ranks ended the request differently")
        }
    }
}

/// Every forward's routed expert sets, per position and routed layer, for the
/// route-set oracle: the model hands it each selection
/// (`MiMoV26TextModel.observeRoutes`), and the engine reads them back after
/// each forward's evaluation (`flush`).
final class MiMoTensorParallelRouteRecorder {
    /// The current forward's selections `[1, L, K]`, one per routed layer.
    private(set) var pending: [MLXArray] = []
    /// `[position][routed layer]`: the selected experts, ascending.
    private(set) var sets: [[[Int]]] = []

    func observe(_ indices: MLXArray) { pending.append(indices) }

    func flush() {
        guard !pending.isEmpty else { return }
        eval(pending)
        let positions = pending[0].dim(1), count = pending[0].dim(2)
        let layers = pending.map { $0.asType(.int32).reshaped(-1).asArray(Int32.self) }
        for position in 0 ..< positions {
            sets.append(layers.map { $0[(position * count) ..< ((position + 1) * count)].map(Int.init).sorted() })
        }
        pending = []
    }
}

extension MiMoTensorParallelModel {
    /// The resident runtime's path for one request (`MiMoTensorParallelDecoding`:
    /// paged KV, the per-step agreement sum, decode command buffers), with the
    /// oracle's evidence. Greedy with `recordTop` 1...20 takes the runtime's
    /// logprob path (the split top-k gather) and records its candidates;
    /// `sampling` draws with the product's sampler over the gathered row
    /// (keyed on `seed`, stream 0). After each agreed step every rank also
    /// gathers the whole row for its digest (oracle only), in one fixed order.
    /// `recordRoutes` records every position's routed expert sets.
    public func generatePaged(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0,
                              sampling: Sampling? = nil, recordRoutes: Bool = false) throws -> Generation {
        guard (0 ... 64).contains(recordTop) else { throw ProbeError("MiMo tensor parallel generation: at most 64 logits per step") }
        let wire = sampling.map {
            ClusterWorkerSampling(temperature: $0.temperature, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: $0.seed, stream: 0, logitBias: [])
        }
        let rule: MiMoTensorParallelSelectionRule = wire.map { .rule($0) }
            ?? ((1 ... ClusterWorkerSampling.maximumTopLogprobs).contains(recordTop) ? .greedyLogprobs(top: recordTop) : .greedy)
        let sampler = try wire.map { QwenStageTokenSampler(try QwenStageSamplingState($0, promptTokens: prompt)) }
        let selection = self.selection
        var result = Generation()
        let recorder = recordRoutes ? MiMoTensorParallelRouteRecorder() : nil
        if let recorder { model.observeRoutes { _, indices in recorder.observe(indices) } }
        defer { if recordRoutes { model.observeRoutes(nil) } }
        let outcome = try MiMoTensorParallelDecoding(model: self, routes: recorder).run(
            .init(prompt: prompt, outputCount: outputCount, chunk: chunk, stopTokenIDs: [], rule: rule, sampler: sampler),
            observe: { step in
                guard recordTop > 0 else { return }
                let top = try step.top ?? selection.topK(step.logits, count: recordTop)
                result.topTokenIDs.append(top.tokenIDs)
                result.topLogits.append(top.logits)
                result.topLogprobs.append(top.logprobs)
                let row = step.row ?? selection.gather(step.logits)
                eval(row)
                let values = row.asArray(Float.self)
                result.stepRowSHA256.append(Self.digest(values))
                if step.index == outputCount - 1 { result.finalLogits = values }
            })
        result.tokenIDs = outcome.tokens
        result.routeSets = recorder?.sets
        result.firstTokenSeconds = outcome.firstTokenSeconds
        result.decodeSeconds = outcome.decodeSeconds
        let state = outcome.caches.flatMap(\.state)
        eval(state)
        result.cacheSHA256 = sha256(state.reduce(into: Data()) { $0.append($1.asData(access: .copy).data) })
        result.peakActiveBytes = Memory.peakMemory
        return result
    }
}
