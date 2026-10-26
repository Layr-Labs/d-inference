import Foundation
import MLX
import MLXLMCommon

/// A prompt-prefix record measured on real weights
/// (`QwenTensorParallelModel.generateAfterPrefixRecord`): the record of the
/// prompt's state at `frontier` under an encoding, and, on an unsharded role,
/// the prompt's remaining tokens teacher-forced from the captured state and
/// from the restored one.
public struct QwenTensorParallelPrefixRecordReport: Codable, Equatable, Sendable {
    /// The last whole chunk before the prompt's final token: the frontier the
    /// batch owner captures and the SSD tier keeps.
    public let frontier: Int
    public let record: QwenStagePrefixDiskMeasurement
    public let tail: Tail?

    /// Positions `[frontier, promptCount - 1)`, each scored on the prompt's
    /// next token. Nil on a shard (its logits are a vocabulary share) and for
    /// a prompt one token past its frontier.
    public struct Tail: Codable, Equatable, Sendable {
        public let positions: Int
        public let meanNegativeLogLikelihoodCaptured: Double
        public let meanNegativeLogLikelihoodRestored: Double
        /// The fraction of positions whose greedy token is the same from both.
        public let top1Agreement: Double
        public let maxAbsLogitDifference: Double
    }
}

extension QwenTensorParallelModel {
    /// Greedy generation as `generate` makes it, except that the prompt's
    /// state at its last whole chunk boundary goes through an SSD prefix
    /// record under `quantization` (a checkpoint precision name: `balanced`,
    /// `k8v4`, `k8v8` or `native`; the writer's and the reader's own unit
    /// code, in memory: `QwenStagePrefixDiskMeasurement`) and the rest of the
    /// prompt and the output follow from the restored state, as after a
    /// restore. The chunks are those of `generate`, so `native` gives its
    /// tokens bit for bit; an encoded record gives the tokens a restored
    /// request gets. Measurement only (the tensor-parallel check's
    /// `--prefix-records`); a shard measures its own heads' rows.
    public func generateAfterPrefixRecord(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0,
                                          quantization: String) throws
        -> (generation: Generation, report: QwenTensorParallelPrefixRecordReport) {
        let encoding = try QwenStagePrefixDiskEncoding.fromEnvironment(
            [QwenStagePrefixDiskEncoding.environmentName: quantization], family: .qwenAttention)
        guard outputCount >= 1, chunk >= 1, prompt.count > chunk else {
            throw ProbeError("Prefix record measurement: a prompt longer than one chunk")
        }
        if recordTop > 0, case .shard = role { throw ProbeError("Prefix record measurement: a shard does not record logits") }
        guard recordTop <= 64 else { throw ProbeError("Prefix record measurement: at most 64 logits per step") }
        let frontier = (prompt.count - 1) / chunk * chunk
        let source = try model.newCache(parameters: nil)
        _ = prefill(Array(prompt[0 ..< frontier]), chunk: chunk, cache: source)
        eval(source.flatMap { $0.innerState() })
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var recurrent: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        for (layer, cache) in source.enumerated() {
            let state = cache.state
            guard state.count == 2 else { throw ProbeError("Prefix record measurement: layer \(layer) holds \(state.count) arrays") }
            // Copies with their own storage: nothing written to a cache later reaches them.
            let copies = state.map { $0 * MLXArray(1).asType($0.dtype) }
            if cache is KVCacheSimple { attention[layer] = (keys: copies[0], values: copies[1]) }
            else { recurrent[layer] = (conv: copies[0], ssm: copies[1]) }
        }
        eval(attention.values.flatMap { [$0.keys, $0.values] } + recurrent.values.flatMap { [$0.conv, $0.ssm] })
        let captured = QwenStagePrefixState(committedTokens: frontier, attention: attention, recurrent: recurrent)
        let measured = try QwenStagePrefixDiskMeasurement.measure(captured, encoding: encoding, blockTokens: chunk)
        let rest = Array(prompt[frontier...])
        var tail: QwenTensorParallelPrefixRecordReport.Tail?
        if case .shard = role {} else if rest.count >= 2 {
            tail = try scoreTail(rest, captured: captured, restored: measured.restored)
        }
        let cache = try adopted(measured.restored)
        let started = Self.now()
        let logits = prefill(rest, chunk: chunk, cache: cache)
        let generation = decode(first: select(logits), firstLogits: logits, cache: cache, outputCount: outputCount,
            recordTop: recordTop, started: started)
        return (generation, .init(frontier: frontier, record: measured.measurement, tail: tail))
    }

    /// A new cache holding `state`, as a restore adopts it.
    private func adopted(_ state: QwenStagePrefixState) throws -> [KVCache] {
        let cache = try model.newCache(parameters: nil)
        for (layer, fresh) in cache.enumerated() {
            var target = fresh
            if let pair = state.attention[layer], fresh is KVCacheSimple { target.state = [pair.keys, pair.values] }
            else if let pair = state.recurrent[layer], !(fresh is KVCacheSimple) { target.state = [pair.conv, pair.ssm] }
            else { throw ProbeError("Prefix record measurement: layer \(layer) has no state of its kind") }
        }
        eval(cache.flatMap { $0.innerState() })
        return cache
    }

    /// `rest` teacher-forced from both states: each position's negative log
    /// likelihood of the prompt's next token, greedy agreement and the largest
    /// logit difference, in slices of positions so no float32 copy of the
    /// whole vocabulary's logits is made at once.
    private func scoreTail(_ rest: [Int], captured: QwenStagePrefixState, restored: QwenStagePrefixState) throws
        -> QwenTensorParallelPrefixRecordReport.Tail {
        let input = MLXArray(rest.map { Int32($0) }).reshaped(1, rest.count)
        let reference = model(input, cache: try adopted(captured))[0]
        eval(reference)
        let candidate = model(input, cache: try adopted(restored))[0]
        eval(candidate)
        let positions = rest.count - 1
        let targets = MLXArray(rest[1...].map { Int32($0) })
        var nllReference = 0.0, nllCandidate = 0.0, agreeing = 0, largest: Float = 0
        for start in stride(from: 0, to: positions, by: 256) {
            let end = min(positions, start + 256)
            let x = reference[start ..< end].asType(.float32), y = candidate[start ..< end].asType(.float32)
            let next = targets[start ..< end].reshaped(-1, 1)
            func nll(_ logits: MLXArray) -> MLXArray {
                (logSumExp(logits, axis: -1) - takeAlong(logits, next, axis: -1).squeezed(axis: -1)).sum()
            }
            let parts = [nll(x), nll(y), (argMax(x, axis: -1) .== argMax(y, axis: -1)).asType(.int32).sum(), abs(x - y).max()]
            eval(parts)
            nllReference += Double(parts[0].item(Float.self)); nllCandidate += Double(parts[1].item(Float.self))
            agreeing += Int(parts[2].item(Int32.self)); largest = max(largest, parts[3].item(Float.self))
        }
        return .init(positions: positions, meanNegativeLogLikelihoodCaptured: nllReference / Double(positions),
            meanNegativeLogLikelihoodRestored: nllCandidate / Double(positions),
            top1Agreement: Double(agreeing) / Double(positions), maxAbsLogitDifference: Double(largest))
    }
}
