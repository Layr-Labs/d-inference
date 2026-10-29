import Foundation

/// Runs blocking work on a GCD thread. While a test holds a process-wide lock
/// (the epoch record lock, `SSDDiskBudget.shared`'s lock), parallel suites
/// blocked on it can fill the cooperative pool, so nothing that releases the
/// lock may need a pool thread. GCD may not start new work while the pool is
/// saturated, so work that must start during the hold needs its own `Thread`.
func onGCD<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: work)) }
    }
}
