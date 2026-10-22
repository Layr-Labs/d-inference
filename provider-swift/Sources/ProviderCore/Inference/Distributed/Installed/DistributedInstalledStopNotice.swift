import Foundation

/// What an operator is told the moment a serving session stops without having
/// been asked to: a rank was lost, or a request had to be cancelled. Both end
/// the pair. The leader then waits for both workers to exit, and without this
/// it would be alive, closed to requests and silent for that whole wait.
public struct DistributedInstalledStopNotice: Sendable, Equatable {
    /// Longest the wait for both workers can legitimately last.
    public let longestWaitNanoseconds: UInt64
    /// The workers' collective progress limit, which is most of that wait.
    public let progressLimitMilliseconds: Int

    public var message: String {
        "Distributed serving has stopped: a worker was lost or a request had to be cancelled, and the pair cannot continue after either. "
            + "No request is accepted from now on. "
            + "Waiting for both workers to exit and give back their memory, which can take up to \(Self.seconds(longestWaitNanoseconds)) s: "
            + "a worker still inside an exchange with its lost peer ends itself only at its \(progressLimitMilliseconds / 1000) s progress limit. "
            + "Nothing needs to be done meanwhile. This command then exits with a failure status; start it again to serve."
    }

    /// What is printed when the operator interrupts a session that is serving.
    public static func requestedStopMessage(longestWaitNanoseconds: UInt64) -> String {
        "Stopping distributed serving. A request that is still running ends at its next token. "
            + "Waiting for both workers to give back their memory; this is usually done within seconds and can take up to \(seconds(longestWaitNanoseconds)) s."
    }

    private static func seconds(_ nanoseconds: UInt64) -> UInt64 { (nanoseconds + 999_999_999) / 1_000_000_000 }
}
