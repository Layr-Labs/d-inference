// Red control only: the test hooks of the change, as no-ops, so its tests
// build without it.
enum ReleasedBufferWipe {
    static func waitForPendingForTesting() {}
    static func suspendForTesting() {}
    static func resumeForTesting() {}
    static func observeForTesting(_ observer: (@Sendable (Int) -> Void)?) {}
}
