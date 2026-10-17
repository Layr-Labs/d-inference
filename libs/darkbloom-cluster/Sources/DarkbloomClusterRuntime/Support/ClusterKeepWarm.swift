import Foundation
import MLX

/// Keep-warm for a loaded, idle worker (S27, owner's latent-Metal keep-warm
/// design, upstream MLX #3974): two tiers so the first request after an idle
/// gap does not pay for a sleeping GPU or sleeping RDMA queue pairs.
///
/// Both run on the worker's one MLX executor thread (the single-executor rule:
/// no second thread ever issues MLX work or a collective) and only while no
/// request is reserved or running. Neither touches model weights, request
/// state or caches.
///
/// - Tier 1 (`pulse`): one one-element add submitted asynchronously on a
///   dedicated stream, every half second while idle, once the first real
///   request has run. Submission only; nothing waits for it.
/// - Tier 2 (`dataPlanePing`): one 1x16 int32 record each way between the two
///   ranks on the data plane (rank 0 sends then receives; rank 1 receives then
///   sends), sequenced by the request owner to both ranks about once a second
///   while idle. Any failure ends the session cleanly through its owner.
public final class ClusterKeepWarm {
    private var stream: MLX.Stream?
    private var operand: MLXArray?
    private var latest: MLXArray?

    public init() {}

    /// Submits one tier-1 pulse; returns how long the submission took, in
    /// nanoseconds. A caller backs off when a submission is slow.
    public func pulse() -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        if stream == nil {
            stream = MLX.Stream(.gpu)
            operand = MLXArray([Float(1)])
        }
        let output = MLX.add(operand!, operand!, stream: .stream(stream!))
        asyncEval(output)
        latest = output
        return DispatchTime.now().uptimeNanoseconds - started
    }

    /// The tier-2 exchange; returns its duration in nanoseconds. `check` is the
    /// owner's cancellation and deadline check, polled while a transfer waits.
    public static func dataPlanePing(collective: Collective, check: () throws -> Void) throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        guard collective.size == 2, (0...1).contains(collective.rank) else {
            throw ProbeError("Keep-warm ping requires a two-rank group")
        }
        let rank = collective.rank, peer = 1 - rank
        let mine = MLXArray([Int32](repeating: Int32(rank + 1), count: 16)).reshaped([1, 16])
        func receive() throws {
            let got = try collective.receiveCompleted(shape: [1, 16], dtype: .int32, from: peer, maximumBytes: 64,
                scope: .session(.keepWarm, "rank\(peer)"), check: check)
            guard got.asArray(Int32.self) == [Int32](repeating: Int32(peer + 1), count: 16) else {
                throw ProbeError("Keep-warm ping received another rank's record")
            }
        }
        if rank == 0 {
            _ = try collective.sendCompleted(mine, to: peer, maximumBytes: 64, scope: .session(.keepWarm, "rank\(rank)"), check: check)
            try receive()
        } else {
            try receive()
            _ = try collective.sendCompleted(mine, to: peer, maximumBytes: 64, scope: .session(.keepWarm, "rank\(rank)"), check: check)
        }
        return DispatchTime.now().uptimeNanoseconds - started
    }
}
