import Foundation

/// The largest context the host memory gate admits on this Mac, found by a
/// binary search over the request's own charge (state, fusion and attention
/// transient at that context, plus the schedule's and mode's named storage).
/// The owner's planner does the same per stage and takes the minimum over
/// stages as the cluster's context; here each rank finds its own at load and
/// every request is gated again, live, when it is reserved (oMLX U#3643: a
/// ceiling frozen at load refused what the settled host could hold).
///
/// A load is refused only when not even the smallest useful request fits, so
/// a Mac that cannot hold the model's largest context still serves the ones it
/// can, and a refusal names the context it was for.
enum QwenResidentContextAdmission {
    /// One prefill frame and one output token: the least a loaded stage serves.
    static func minimumContextTokens(limits: QwenResidentContextLimits) -> Int {
        min(limits.maximumContextTokens, limits.maximumChunkTokens + 1)
    }

    /// The largest `c` in `minimum...maximum` that `admits` accepts, or nil if
    /// it refuses `minimum`. `admits` must be monotone: if it accepts a context
    /// it accepts every smaller one. At most about log2(maximum) calls.
    static func largest(minimum: Int, maximum: Int, admits: (Int) throws -> Bool) throws -> Int? {
        guard minimum >= 1, maximum >= minimum else {
            throw ProbeError("Context admission needs 1 <= minimum <= maximum")
        }
        if try admits(maximum) { return maximum }
        guard try admits(minimum) else { return nil }
        var low = minimum, high = maximum   // admits(low), !admits(high)
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if try admits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}
