import DarkbloomClusterProtocol
import CryptoKit
import Foundation
import MLX

/// Developer bench (`darkbloom-cluster-tp-check qwen-decode`): the batch
/// driver's plain decode on this rank, through the real driver, native
/// executor and the rank's group (two ranks of one Mac over the loopback
/// ring, or a pair over JACCL, sealed or not), at the product's decode layer
/// stride or a `layerStride` of the caller's. Each run decodes `width` requests together, with the
/// next step's control exchanged a step or folded into the selection sum;
/// the owner answers each token after `answerDelayMicroseconds`. Logs each
/// run's decode step time and a digest of every request's retired tokens;
/// returns whether every run retired the same tokens. Loopback timings show
/// a step's host work and synchronization, never a pair's; JACCL timings are
/// the pair's.
public enum QwenTensorParallelDecodeBench {
    struct Reserved: QwenTensorParallelBatchReservation {
        let request: QwenLayerStageGenerationRequest
        var deadline: UInt64 { .max }
        var laneStateBytes: Int { 1 }
        var joinable: Bool { true }
    }

    /// Rank 0 publishes; the owner answers "go on" once the delay passed.
    final class Owner: QwenBatchServingHost {
        let delay: UInt64
        private(set) var times: [UUID: [UInt64]] = [:]
        init(delay: UInt64) { self.delay = delay }
        func serviceControl() throws {}
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
            times[requestID, default: []].append(DispatchTime.now().uptimeNanoseconds)
        }
        func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int,
                          logprobs: ClusterWorkerTokenLogprobs?) throws {
            try publishToken(requestID: requestID, ordinal: ordinal, tokenID: tokenID, committedTokens: committedTokens)
        }
        func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] { throw ProbeError("The decode bench polls answers") }
        func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {}
        func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {}
        func pollDecision(_ requestID: UUID) throws -> Bool? {
            guard let last = times[requestID]?.last else { return nil }
            return DispatchTime.now().uptimeNanoseconds - last >= delay ? true : nil
        }
        func publishLeft(requestID: UUID) throws {}
    }

    public static func pair(model: QwenTensorParallelModel, configuration: Data, group: any QwenTensorParallelReduction,
                            width: Int, promptTokens: Int, outputTokens: Int, sampled: Bool, folds: [Bool],
                            repeats: Int, answerDelayMicroseconds: Int, layerStride: Int? = nil, buildsAhead: [Bool] = [false],
                            log: (String) -> Void) throws -> Bool {
        // A stride to compare against the product's (`QwenTensorParallelBatchSession.decodeLayerStride`).
        try QwenTensorParallelBatchSession.$layerStride.withValue(layerStride ?? QwenTensorParallelBatchSession.layerStride) {
            try run(model: model, configuration: configuration, group: group, width: width, promptTokens: promptTokens,
                outputTokens: outputTokens, sampled: sampled, folds: folds, repeats: repeats,
                answerDelayMicroseconds: answerDelayMicroseconds, buildsAhead: buildsAhead, log: log)
        }
    }

    static func run(model: QwenTensorParallelModel, configuration: Data, group: any QwenTensorParallelReduction,
                    width: Int, promptTokens: Int, outputTokens: Int, sampled: Bool, folds: [Bool],
                    repeats: Int, answerDelayMicroseconds: Int, buildsAhead: [Bool], log: (String) -> Void) throws -> Bool {
        // Request IDs carry the run's index in one byte.
        guard case .shard(let rank, _) = model.role, (1...8).contains(width), promptTokens > 0, outputTokens > 1,
              (1...255).contains(repeats), !buildsAhead.isEmpty, (1...255).contains(folds.count * buildsAhead.count * repeats),
              !buildsAhead.contains(true) || folds.allSatisfy({ $0 }) else {
            throw ProbeError("The decode bench runs a rank shard with 1 to 8 requests of at least two tokens, 255 runs at most"
                + " (build-ahead with folded control only)")
        }
        let vocabulary = model.plan.vocabularySize, chunk = min(512, promptTokens), budget = promptTokens + outputTokens
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-decode-bench", vocabularySize: vocabulary,
            hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16", maximumPromptTokens: promptTokens,
            maximumChunkTokens: chunk, maximumOutputTokens: outputTokens, maximumContextTokens: budget)
        var seen: String?, same = true
        // Each control and build-ahead mode, `repeats` times, after one warm run; every run must retire the same tokens.
        let modes = folds.flatMap { fold in buildsAhead.map { (fold: fold, ahead: $0) } }
        for (index, mode) in ([modes[0]] + modes.flatMap { Array(repeating: $0, count: repeats) }).enumerated() {
            let fold = mode.fold
            Memory.clearCache()
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: width,
                maximumTokensPerRequest: budget, maximumChunkTokens: chunk)
            let executor = try QwenTensorParallelNativeBatchExecutor<Reserved>(model: model, configuration: configuration,
                host: host, group: group, prepare: { _, _ in nil }, completedDecode: { _ in }, completedPrefill: {},
                releaseResources: { _ in }, buildsAhead: mode.ahead)
            let book = ClusterBatchLaneBook<Reserved>()
            for row in 0 ..< width {
                // Both ranks name the same requests: IDs and prompts follow the run and row.
                let id = UUID(uuid: (UInt8(index), UInt8(row), 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))
                let sampling: ClusterWorkerSampling? = sampled ? .init(temperature: 0.7, topP: 0.9, topK: 32, minP: 0.01,
                    repetitionPenalty: 1.1, repetitionContextSize: 12, frequencyPenalty: 0.15, presencePenalty: 0.2,
                    seed: UInt64(77 + row), stream: UInt64(5 * row + 1), logitBias: []) : nil
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                    promptTokenIDs: (0 ..< promptTokens).map { (row * 7_919 + $0 * 104_729 + 11) % vocabulary },
                    chunkSize: chunk, outputCount: outputTokens, stopTokenIDs: [], sampling: sampling)
                try book.reserve(id, Reserved(request: request), lanes: width)
                try book.start(id)
            }
            let owner = Owner(delay: UInt64(max(0, answerDelayMicroseconds)) * 1_000)
            let driver = try QwenTensorParallelBatchDriver(executor: executor, book: book, capacity: width,
                vocabulary: vocabulary, foldsControl: fold, buildsAhead: mode.ahead)
            var retired: [UUID: [Int]] = [:]
            let started = DispatchTime.now().uptimeNanoseconds
            try MLX.withError { error in
                try driver.serve(host: owner, retiredSelection: { id, tokens, _ in retired[id] = tokens },
                    check: { try error.check() })
            }
            let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            var hash = SHA256()
            for id in retired.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                hash.update(data: Data(retired[id]!.flatMap { withUnsafeBytes(of: Int32($0).littleEndian, Array.init) }))
            }
            let digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            guard retired.count == width, retired.values.allSatisfy({ $0.count == outputTokens }) else {
                throw ProbeError("The decode bench retired another set of tokens")
            }
            // The first run warms the kernels; it is checked, never timed.
            if index == 0 { seen = digest; continue }
            same = same && seen == digest
            // Rank 0: each request's decode, from its first token to its last, per token.
            let steps = owner.times.values.map { Double($0.last! - $0.first!) / 1e6 / Double($0.count - 1) }.sorted()
            log("qwen-tp-decode-v1 rank=\(rank) control=\(fold ? "folded" : "exchanged") build_ahead=\(mode.ahead ? 1 : 0) width=\(width)"
                + " sampled=\(sampled ? 1 : 0) answer_delay_us=\(answerDelayMicroseconds) prompt=\(promptTokens)"
                + " output=\(outputTokens) total_ms=\(String(format: "%.1f", total))"
                + (steps.isEmpty ? "" : " step_ms_median=\(String(format: "%.3f", steps[steps.count / 2]))"
                    + " step_ms_min=\(String(format: "%.3f", steps.first!)) step_ms_max=\(String(format: "%.3f", steps.last!))")
                + " tokens=\(digest)")
        }
        log("qwen-tp-decode-v1 rank=\(rank) token-check \(same ? "same-tokens" : "DIFFERENT")")
        return same
    }
}
