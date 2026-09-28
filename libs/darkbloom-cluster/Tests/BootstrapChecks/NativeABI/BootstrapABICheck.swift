import Foundation
import Cmlx

private final class Lifetime: @unchecked Sendable {}
private final class Observed: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var valid = true
    func observe(_ correct: Bool) { lock.withLock { calls += 1; valid = valid && correct } }
}
private struct Failure: Error {}
private func require(_ condition: Bool) throws { if !condition { throw Failure() } }

@main struct BootstrapABICheck {
    static func main() throws {
        let epoch = UUID(), observed = Observed()
        weak var lifetime: Lifetime?
        var bootstrap: JACCLBootstrap?
        do {
            let owned = Lifetime(); lifetime = owned
            bootstrap = try JACCLBootstrap(membershipEpoch: epoch, rank: 0) { actualEpoch, rank, size, sequence, raw, count in
                withExtendedLifetime(owned) {
                    observed.observe(actualEpoch == epoch && rank == 0 && size == 2 && sequence == 0 &&
                                     raw == Data([1,2,3,4]) && count == 8)
                    return raw + raw
                }
            }
        }
        var group = mlx_distributed_group_new()
        try require(try bootstrap!.initialize(&group) == 0)
        try require(observed.calls == 1 && observed.valid)
        do { _ = try bootstrap!.initialize(&group); throw Failure() }
        catch JACCLBootstrap.BootstrapError.reused { }
        bootstrap = nil
        try require(lifetime != nil)
        _ = mlx_distributed_group_free(group)
        try require(lifetime != nil) // Dropping one handle does not release the cache callback.
        let ignored = try JACCLBootstrap(membershipEpoch: epoch, rank: 0) { _,_,_,_,raw,_ in raw + raw }
        var stale = mlx_distributed_group_new()
        try require(try ignored.initialize(&stale) != 0 && stale.ctx == nil)
        bootstrap_test_clear_cache()
        try require(lifetime == nil)
        let refused = try JACCLBootstrap(membershipEpoch: epoch, rank: 0) { _,_,_,_,_,_ in Data([0]) }
        var failed = mlx_distributed_group_new()
        try require(try refused.initialize(&failed) != 0 && failed.ctx == nil)
        bootstrap_test_clear_cache()
        print("{\"passed\":true,\"actualCAndSwiftCallbackABI\":true,\"factoryAndCacheAreTestStandins\":true,\"groups\":3,\"nativeJACCLOrNetworkExecution\":false}")
    }
}
