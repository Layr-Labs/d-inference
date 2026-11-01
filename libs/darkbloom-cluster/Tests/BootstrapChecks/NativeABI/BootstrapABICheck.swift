import Foundation
import Cmlx

// The actual C bridge (`mlx_distributed_init_jaccl_with_bootstrap`, compiled
// from the pinned mlx-c) and the actual Swift adapter (`JACCLOwnerBootstrap`),
// with a test stand-in for MLX's native factory and backend cache. No JACCL,
// RDMA or network runs here.

/// Stand-in for the runtime's error type, which the adapter throws.
struct ProbeError: Error { init(_ message: String) {} }
private final class Observed: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var valid = true
    func observe(_ correct: Bool) { lock.withLock { calls += 1; valid = valid && correct } }
}
private struct Failure: Error {}
private func require(_ condition: Bool, _ step: Int) throws { if !condition { throw ProbeError("step \(step)") } }

@main struct BootstrapABICheck {
    static func main() throws {
        let observed = Observed()
        try JACCLOwnerBootstrap.install(rank: 0) { sequence, raw in
            observed.observe(sequence == 0 && raw == Data([1, 2, 3, 4]))
            return raw + Data([9, 9, 9, 9])
        }
        // Installed once per process; never replaced.
        do { try JACCLOwnerBootstrap.install(rank: 0) { _, raw in raw + raw }; throw Failure() } catch is ProbeError {}
        try require(JACCLOwnerBootstrap.isInstalled, 1)
        // An installed exchange the group never used stops the worker.
        do { try JACCLOwnerBootstrap.requireConsumedIfInstalled(); throw Failure() } catch is ProbeError {}
        guard let owner = JACCLOwnerBootstrap.take() else { throw ProbeError("installed exchange missing") }
        try require(JACCLOwnerBootstrap.take() == nil, 2)
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
        var group = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&group, rank: owner.rank, exchange: owner.exchange) == 0, 3)
        try require(observed.calls == 1 && observed.valid && group.ctx != nil, 4)
        // A cached JACCL is refused, never reauthenticated.
        var stale = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&stale, rank: 0) { _, raw in raw + raw } != 0 && stale.ctx == nil, 5)
        _ = mlx_distributed_group_free(group)
        bootstrap_test_clear_cache()
        // An exchange that changes this rank's own bytes is refused.
        var changed = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&changed, rank: 0) { _, raw in Data([0, 0, 0, 0]) + raw } != 0 && changed.ctx == nil, 6)
        bootstrap_test_clear_cache()
        // A short gathered result is refused.
        var short = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&short, rank: 0) { _, raw in raw } != 0 && short.ctx == nil, 7)
        bootstrap_test_clear_cache()
        // A failed exchange (the owner's channel closed) is refused.
        var thrown = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&thrown, rank: 0) { _, _ in throw Failure() } != 0 && thrown.ctx == nil, 8)
        bootstrap_test_clear_cache()
        // The stand-in factory binds rank 0: an adapter for rank 1 is refused by the bridge.
        var wrongRank = mlx_distributed_group_new()
        try require(JACCLOwnerBootstrap.initialize(&wrongRank, rank: 1) { _, raw in raw + raw } != 0 && wrongRank.ctx == nil, 9)
        bootstrap_test_clear_cache()
        print("{\"passed\":true,\"actualCBridgeAndSwiftAdapter\":true,\"factoryAndCacheAreTestStandins\":true,\"groups\":7,\"nativeJACCLOrNetworkExecution\":false}")
    }
}
