/// Bounded credit coalescing for the plain-pipeline loop. The caller still
/// services control and exchanges a no-work header/reply on deferred steps.
/// This is not a barrier: a silent client can hold ready rows for at most the
/// fixed window, measured at scheduling boundaries, then they advance alone.
struct QwenBatchDecodeCoalescing {
    static let windowNanoseconds: UInt64 = 2_000_000
    private var firstPartialReady: UInt64?

    mutating func shouldDefer(ready: Int, pending: Int, hasOtherWork: Bool,
                             now: () -> UInt64) -> Bool {
        // No clock read or wait for a sole runnable request, a complete batch,
        // an entirely blocked batch, or work that already needs a native step.
        guard ready > 0, pending > 0, !hasOtherWork else {
            firstPartialReady = nil
            return false
        }
        let current = now()
        guard let first = firstPartialReady else {
            firstPartialReady = current
            return true
        }
        // A regressing test/platform clock must not create an unbounded wait.
        guard current >= first, current - first < Self.windowNanoseconds else {
            firstPartialReady = nil
            return false
        }
        return true
    }
}
