import Foundation

public struct ClusterConsoleSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns; self.rows = rows
    }
}

/// The actions the console runs. Each is one existing operation.
public enum ClusterConsoleAction: String, Sendable, CaseIterable {
    case fixLink, approveSetup, startSession, stopSession, recoverJournal, exportDiagnostics

    public var key: Character {
        switch self {
        case .fixLink: return "f"
        case .approveSetup: return "a"
        case .startSession: return "s"
        case .stopSession: return "x"
        case .recoverJournal: return "c"
        case .exportDiagnostics: return "e"
        }
    }

    public var title: String {
        switch self {
        case .fixLink: return "Fix link"
        case .approveSetup: return "Approve setup"
        case .startSession: return "Start session"
        case .stopSession: return "Stop session"
        case .recoverJournal: return "Recover journal"
        case .exportDiagnostics: return "Export diagnostics"
        }
    }
}

public enum ClusterConsoleEvent: Sendable {
    case key(ClusterConsoleKey)
    case resized(ClusterConsoleSize)
    case snapshot(ClusterConsoleSnapshot)
    case linkObserved(ClusterLinkReadinessReport)
    case sessionObserved(ClusterConsoleSessionObservation)
    case actionFinished(ClusterConsoleAction, ClusterConsoleActionResult)
    case session(ClusterConsoleSessionEvent)
    /// The poll interval passed with nothing else to do.
    case tick
    /// SIGINT, SIGTERM or SIGHUP was sent to this process.
    case terminationSignal(Int32)
    /// The terminal closed its end.
    case inputClosed
}

/// Work the reducer asks the run loop to do. The loop runs each one off its
/// own thread and reports back with an event.
public enum ClusterConsoleEffect: Equatable, Sendable {
    case refresh
    case pollLink
    case pollSession
    case fixLink(device: String?, dryRun: Bool)
    case recoverJournal
    case approveSetup
    case exportDiagnostics
    case launchSession
    case interruptSession
}

/// How the screen ended: the process status, and what to say on the restored terminal.
public struct ClusterConsoleExit: Equatable, Sendable {
    public let code: Int32
    public let farewell: [String]
}

/// Everything the screen is, between two events. A value: the reducer in
/// `ClusterConsoleReducer.swift` is its only writer, and the renderer its only reader.
public struct ClusterConsoleState: Sendable {
    public struct Options: Sendable, Equatable {
        /// The link fix stops where macOS would ask for approval.
        public var dryRun: Bool
        /// Opening the screen continues the guided link setup: the fix a
        /// first refresh plans is started once without a keypress, and macOS
        /// asks for approval as it does for `darkbloom cluster setup`.
        public var onboarding: Bool

        public init(dryRun: Bool = false, onboarding: Bool = true) {
            self.dryRun = dryRun; self.onboarding = onboarding
        }
    }

    /// The session process this screen started.
    public enum Session: Equatable, Sendable {
        case none
        case launching
        case running(processIdentifier: Int32)
        /// The interrupt was sent; the process has not ended yet.
        case stopping(processIdentifier: Int32)
        case ended(String)

        var processIdentifier: Int32? {
            switch self {
            case .running(let identifier), .stopping(let identifier): return identifier
            case .none, .launching, .ended: return nil
            }
        }

        var isActive: Bool {
            switch self {
            case .launching, .running, .stopping: return true
            case .none, .ended: return false
            }
        }
    }

    enum Leaving: Equatable, Sendable {
        /// Leave when the action in flight reports.
        case afterAction
        /// The next quit key stops the session this screen started.
        case confirmStop
        /// Leave when the session process has ended.
        case afterSession
        /// As `afterSession`, and the next quit key leaves without waiting.
        case closeNow
    }

    static let activityLimit = 100
    static let sessionOutputLimit = 500

    public internal(set) var size: ClusterConsoleSize
    public let options: Options
    public internal(set) var snapshot: ClusterConsoleSnapshot?
    /// A newer `cluster status` reading than the snapshot's, when one was taken.
    public internal(set) var latestStatus: ClusterDiagnosticsReport?
    public internal(set) var refreshing = false
    var refreshQueued = false
    var linkPollInFlight = false
    var sessionPollInFlight = false
    public internal(set) var inFlight: ClusterConsoleAction?
    public internal(set) var confirming: ClusterConsoleAction?
    public internal(set) var session = Session.none
    public internal(set) var sessionOutput = [String]()
    public internal(set) var activity = [ClusterDiagnosticExport.Activity]()
    public internal(set) var notice: String?
    public internal(set) var scroll = 0
    /// Set by the run loop after each frame: the furthest the body can scroll.
    public var maximumScroll = 0
    /// Rows the body shows, set with `maximumScroll`; a page is one less.
    public var bodyRows = 1
    public internal(set) var showsHelp = false
    var onboardingFixSpent = false
    var leaving: Leaving?
    public internal(set) var exit: ClusterConsoleExit?

    public init(size: ClusterConsoleSize, options: Options = Options()) {
        self.size = size; self.options = options
    }

    /// The most recent session and journal reading.
    public var status: ClusterDiagnosticsReport? { latestStatus ?? snapshot?.diagnostics }
}
