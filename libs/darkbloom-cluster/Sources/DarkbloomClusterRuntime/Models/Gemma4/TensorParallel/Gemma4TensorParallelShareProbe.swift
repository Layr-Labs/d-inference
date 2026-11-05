import DarkbloomClusterProtocol
import Foundation
import MLX

/// What a Gemma 4 tensor-parallel rank measures of its own share at load,
/// after its weights and before its ready record, with no peer traffic, as
/// `QwenTensorParallelShareProbe` measures a dense Qwen share: every
/// reduction local (`QwenTensorParallelSwitchableReduction`), so the rank
/// times only what its share computes between reductions. One throwaway
/// request of `QwenTensorParallelShareProbe.promptTokens` synthetic tokens on
/// a one-lane paged host of its own is prefilled, then a few warm-up rounds
/// and the timed ones of the plain decode step (`decodeCommandBuffers`);
/// the median in microseconds. Shares are equal (500 per mille).
///
/// It never fails or holds up a load: memory the gate does not admit, a load
/// deadline too close, or any error gives no probe; the rounds keep the
/// Qwen probe's budget and limit (`QwenTensorParallelShareProbe.rounds`).
/// Only a throwaway request that cannot be retired fails the load, since its
/// native work may still be running.
enum Gemma4TensorParallelShareProbe {
    typealias Limits = QwenTensorParallelShareProbe

    static func measure(model: Gemma4TensorParallelModel, reduction: QwenTensorParallelSwitchableReduction,
                        profile: QwenLayerStageGenerationProfile, deadline: UInt64,
                        admit: (_ maximumTokens: Int, _ chunkTokens: Int) throws -> Bool, check: () throws -> Void,
                        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws -> ClusterWorkerShareProbe? {
        let rank = reduction.rank
        func skipped(_ reason: String) -> ClusterWorkerShareProbe? {
            log("darkbloom-share-probe-v1 rank=\(rank) family=gemma4 skipped=\(reason)"); return nil
        }
        guard case .shard(let shardRank) = model.role, shardRank == rank, reduction.size == 2,
              let share = Limits.sharePerMille(shares: [1, 1], rank: rank) else { return skipped("unsupported") }
        let shape = Limits.requestShape(profile: profile, windowColumns: nil)
        let started = clock()
        guard deadline > started, deadline - started >= Limits.deadlineMarginNanoseconds else { return skipped("deadline") }
        do {
            guard try admit(shape.prompt + shape.outputs, shape.prompt) else { return skipped("memory") }
        } catch { return skipped("memory") }
        var session: Gemma4TensorParallelPagedSession?
        do {
            let rounds = try reduction.locally { () throws -> Limits.Rounds in
                try MLX.withError { error -> Limits.Rounds in
                    func checked() throws { try error.check(); try check() }
                    let host = try model.pagedHost(lanes: 1, maximumTokens: shape.prompt + shape.outputs,
                        chunkTokens: shape.prompt)
                    let value = try Gemma4TensorParallelPagedSession(model: model, host: host, promptCount: shape.prompt,
                        outputCount: shape.outputs)
                    session = value
                    let prompt = (0..<shape.prompt).map { ($0 * 131 + 17) % profile.vocabularySize }
                    // Any token will do: the outputs are not a tensor-parallel result.
                    _ = try value.prefill(prompt, range: 0..<shape.prompt, check: checked) { $0 }
                    var token = 1
                    let phase = try Limits.rounds(started: started, clock: clock) {
                        token = (token * 37 + 11) % profile.vocabularySize
                        _ = try GPU.withCommandBufferLimits(Gemma4TensorParallelModel.decodeCommandBuffers) {
                            try value.decode(token, check: checked) { $0 }
                        }
                    }
                    try value.retire()
                    guard host.isDrained else { throw ProbeError("Gemma tensor-parallel share probe kept its pages") }
                    return phase
                }
            }
            let times = rounds.times
            guard times.count >= Limits.minimumRounds else { return skipped(rounds.reason) }
            let probe = ClusterWorkerShareProbe(sharePerMille: share,
                plainStepMicroseconds: max(1, Int(times.sorted()[times.count / 2] / 1000)), rounds: times.count)
            return probe.valid ? probe : skipped("bounds")
        } catch {
            // The throwaway request goes whatever failed; one that cannot be retired fails the load.
            if let session, !session.retired {
                do { try session.retire(failed: true) } catch {
                    throw ProbeError("Gemma tensor-parallel share probe could not retire its request (\(error))")
                }
            }
            return skipped("error_" + qwenPrefixLogWord(error))
        }
    }
}
