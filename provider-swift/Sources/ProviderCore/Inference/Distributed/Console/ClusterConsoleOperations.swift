import Foundation

/// What an action reported: the operation's own summary or error text.
public struct ClusterConsoleActionResult: Sendable, Equatable {
    public let succeeded: Bool
    public let lines: [String]

    public init(succeeded: Bool, lines: [String]) {
        self.succeeded = succeeded; self.lines = lines
    }

    static func failure(_ error: Error) -> ClusterConsoleActionResult {
        .init(succeeded: false, lines: [ClusterConsoleText.bounded(error)])
    }
}

/// A fresh look at the leader's session, between full refreshes.
public struct ClusterConsoleSessionObservation: Sendable {
    public let status: ClusterDiagnosticsReport

    public init(status: ClusterDiagnosticsReport) { self.status = status }
}

/// The session process the console started: `darkbloom start --local --distributed`.
public protocol ClusterConsoleSessionHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    /// Asks the session to stop the way Ctrl-C in its own terminal would. It
    /// never ends the process any other way.
    func interrupt()
}

public enum ClusterConsoleSessionEvent: Sendable, Equatable {
    case launched(processIdentifier: Int32)
    case launchFailed(String)
    case output(String)
    /// How the process ended, in words, and whether that was a clean exit.
    case ended(description: String, clean: Bool)
}

/// Every operation the console can run, as blocking calls. The live set runs
/// the same functions the `darkbloom cluster` subcommands run; checks supply
/// their own so that no tool, prompt or process is started.
public struct ClusterConsoleOperations: Sendable {
    /// A full refresh: every probe, read again.
    public var snapshot: @Sendable () -> ClusterConsoleSnapshot
    /// The link inspection alone, for the wait for a cable.
    public var inspectLink: @Sendable () -> ClusterLinkReadinessReport
    /// `cluster status` alone, while a session is starting, serving or stopping.
    public var observeSession: @Sendable () -> ClusterConsoleSessionObservation
    /// `cluster link --fix`. Blocks while the person answers the macOS
    /// prompt; a dry run asks nothing and lists what an approval would run.
    public var fixLink: @Sendable (ClusterConsoleLinkFix) -> ClusterConsoleActionResult
    /// `cluster recover`.
    public var recoverJournal: @Sendable () -> ClusterConsoleActionResult
    /// `cluster configure` on the candidate inputs, refused unless they are
    /// still the setup whose canonical digest is `expectedSHA256`.
    public var approveSetup: @Sendable (ClusterConsoleCandidate, _ expectedSHA256: String) -> ClusterConsoleActionResult
    public var exportDiagnostics: @Sendable (ClusterDiagnosticExport.Input) -> ClusterConsoleActionResult
    /// Starts the session process and reports its output and its end through `events`.
    public var launchSession: @Sendable (_ events: @escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle

    public init(snapshot: @escaping @Sendable () -> ClusterConsoleSnapshot,
                inspectLink: @escaping @Sendable () -> ClusterLinkReadinessReport,
                observeSession: @escaping @Sendable () -> ClusterConsoleSessionObservation,
                fixLink: @escaping @Sendable (ClusterConsoleLinkFix) -> ClusterConsoleActionResult,
                recoverJournal: @escaping @Sendable () -> ClusterConsoleActionResult,
                approveSetup: @escaping @Sendable (ClusterConsoleCandidate, String) -> ClusterConsoleActionResult,
                exportDiagnostics: @escaping @Sendable (ClusterDiagnosticExport.Input) -> ClusterConsoleActionResult,
                launchSession: @escaping @Sendable (@escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> any ClusterConsoleSessionHandle) {
        self.snapshot = snapshot; self.inspectLink = inspectLink; self.observeSession = observeSession
        self.fixLink = fixLink; self.recoverJournal = recoverJournal
        self.approveSetup = approveSetup; self.exportDiagnostics = exportDiagnostics; self.launchSession = launchSession
    }
}
