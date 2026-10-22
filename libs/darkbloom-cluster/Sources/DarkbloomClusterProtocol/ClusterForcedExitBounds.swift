/// The bound of a rank's forced exit (the runtime's `ProcessForcedExit`),
/// shared by the rank that arms it and by everything that waits for a rank to
/// end by it (the orphan reaper's contract grace). Self-contained: the exit
/// checks compile it next to the forced exit without the rest of this module.
public enum ClusterForcedExitBounds {
    /// The dead-man: the release and any unwind after a claim end within it
    /// (the owner's rank-exit dead-man).
    public static let deadManNanoseconds: UInt64 = 20_000_000_000
    /// How many times the dead-man may move by one more bound for a release
    /// whose durable writes are still completing (`ProcessForcedExit`'s one
    /// extension). The next deadline after the last extension is final.
    public static let extensions: UInt64 = 1
    /// The longest a claimed forced exit can keep a process alive with a
    /// dead-man of `deadMan`: the bound plus every extension.
    public static func longestNanoseconds(deadMan: UInt64 = deadManNanoseconds) -> UInt64 {
        let product = deadMan.multipliedReportingOverflow(by: 1 + extensions)
        return product.overflow ? UInt64.max : product.partialValue
    }
}
