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

    /// The row of `handoff/TUI-wiring.md` this action is.
    public var wiring: String {
        switch self {
        case .fixLink: return "link.fix"
        case .approveSetup: return "pair.approve"
        case .startSession: return "session.start"
        case .stopSession: return "session.stop"
        case .recoverJournal: return "session.recover"
        case .exportDiagnostics: return "export.diagnostics"
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
    /// SIGINT, SIGTERM, SIGHUP or SIGQUIT was sent to this process.
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
    /// Save the setup whose canonical digest was on screen, and no other.
    case approveSetup(expectedSHA256: String)
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
        /// The link fix works out what an approval would run and asks for nothing.
        public var dryRun: Bool
        /// The link fix adds the address alone, without the system job that keeps it.
        public var temporary: Bool
        /// Opening the screen continues the guided link setup: the fix a
        /// first refresh plans is started once without a keypress, and macOS
        /// asks for approval as it does for `darkbloom cluster setup`.
        public var onboarding: Bool
        /// How long a question must have been on the screen before `y`
        /// answers it: long enough that it was not typed before it could be read.
        public var questionDwellMilliseconds: Int

        public init(dryRun: Bool = false, temporary: Bool = false, onboarding: Bool = true,
                    questionDwellMilliseconds: Int = 500) {
            self.dryRun = dryRun; self.temporary = temporary; self.onboarding = onboarding
            self.questionDwellMilliseconds = questionDwellMilliseconds
        }
    }

    /// The session process this screen started.
    public enum Session: Equatable, Sendable {
        case none
        case launching
        case running(processIdentifier: Int32)
        /// The interrupt was asked for; the process has not ended yet.
        case stopping(processIdentifier: Int32)
        case ended(String)

        var isActive: Bool {
            switch self {
            case .launching, .running, .stopping: return true
            case .none, .ended: return false
            }
        }
    }

    /// An action that waits for `y` before it runs, with what it will act on.
    public enum Question: Equatable, Sendable {
        case approveSetup(expectedSHA256: String)
        case startSession
        case recoverJournal

        var action: ClusterConsoleAction {
            switch self {
            case .approveSetup: return .approveSetup
            case .startSession: return .startSession
            case .recoverJournal: return .recoverJournal
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
    public internal(set) var asking: Question?
    /// The last frame drawn shows the open question in full. Only then does
    /// `y` answer it: a `y` typed or pasted ahead of the question is not consent.
    public internal(set) var questionShown = false
    /// When the frame that first showed the open question was drawn, on the
    /// run loop's clock; nil while it is not shown.
    var questionShownAt: UInt64?
    /// What a notice was about, when it stops being true by itself.
    enum NoticeEnds: Equatable, Sendable { case withRefresh, withAction }
    var noticeEnds: NoticeEnds?
    public internal(set) var session = Session.none
    public internal(set) var sessionOutput = [String]()
    public internal(set) var activity = [ClusterDiagnosticExport.Activity]()
    public internal(set) var notice: String?
    public internal(set) var scroll = 0
    /// The furthest the body could scroll in the last frame drawn.
    public internal(set) var maximumScroll = 0
    /// Rows the body had in the last frame drawn; a page is one less.
    public internal(set) var bodyRows = 1
    public internal(set) var showsHelp = false
    var onboardingFixSpent = false
    /// Link readings that came back unchanged while the system job was given
    /// its chance to put the address back.
    var keeperReadings = 0
    var leaving: Leaving?
    public internal(set) var exit: ClusterConsoleExit?

    public init(size: ClusterConsoleSize, options: Options = Options()) {
        self.size = size; self.options = options
    }

    /// The most recent session and journal reading.
    public var status: ClusterDiagnosticsReport? { latestStatus ?? snapshot?.diagnostics }

    /// Records what the frame just drawn showed: how far the body can scroll,
    /// and whether an open question was on it, since when. `uptime` is the
    /// run loop's clock in nanoseconds.
    public mutating func drew(_ frame: ClusterConsoleFrame, uptime: UInt64 = 0) {
        maximumScroll = frame.maximumScroll
        bodyRows = max(frame.bodyRows, 1)
        scroll = min(max(scroll, 0), maximumScroll)
        let shown = asking != nil && frame.question == asking
        if !shown { questionShownAt = nil } else if !questionShown || questionShownAt == nil { questionShownAt = uptime }
        questionShown = shown
    }
}
