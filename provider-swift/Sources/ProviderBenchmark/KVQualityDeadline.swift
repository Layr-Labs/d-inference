import Foundation

/// A call-owned deadline. The caller cancels and awaits the returned task
/// before releasing its submission so no timer outlives that case.
enum KVQualityDeadline {
    static func start(
        startedAt: UInt64, maximumNanoseconds: UInt64 = 300_000_000_000,
        onExpiry: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startedAt ? now - startedAt : 0
        let remaining = elapsed >= maximumNanoseconds ? 0 : maximumNanoseconds - elapsed
        return Task {
            do {
                // Swift 6.3 -O can corrupt the async allocator in the generic
                // Clock overload, as documented in ProviderLoop+Capacity.
                // Keep this nongeneric overload in optimized model benchmarks.
                try await Task.sleep(nanoseconds: remaining)
            } catch { return }
            onExpiry()
        }
    }
}
