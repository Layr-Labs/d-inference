import Foundation

/// Turns the byte counts of a model copy or download into the onboarding's live
/// reports (`ClusterOnboardingProgress.live`), laid out by `TransferProgressLine`.
/// The first count starts the rate's clock; the reports a transcript keeps are
/// the first, then about one per 10% and 30 s.
final class ClusterTransferReports: @unchecked Sendable {
    private let label: String
    private let clock: @Sendable () -> TimeInterval
    private let send: @Sendable (ClusterOnboardingProgress) -> Void
    private let lock = NSLock()
    private var line: TransferProgressLine?

    init(label: String, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         send: @escaping @Sendable (ClusterOnboardingProgress) -> Void) {
        self.label = label
        self.clock = clock
        self.send = send
    }

    func report(done: Int64, total: Int64) {
        let now = clock()
        let (line, logged) = lock.withLock {
            var line = self.line ?? TransferProgressLine(label: label, totalBytes: total, startBytes: done, startTime: now)
            let logged = line.takeLogLine(done: done, now: now)
            self.line = line
            return (line, logged)
        }
        send(.live({ width in line.text(done: done, now: now, width: width) }, logged: logged))
    }
}
