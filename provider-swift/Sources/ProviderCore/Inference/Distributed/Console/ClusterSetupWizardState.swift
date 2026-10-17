import Foundation

/// The six steps of the guided setup, in order.
public enum ClusterSetupStep: Int, CaseIterable, Codable, Sendable, Comparable {
    case thisMac, cable, pair, model, check, serve

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var number: Int { rawValue + 1 }

    /// The rail's short name.
    public var label: String {
        switch self {
        case .thisMac: return "This Mac"
        case .cable: return "Cable"
        case .pair: return "Pair"
        case .model: return "Model"
        case .check: return "Check"
        case .serve: return "Serve"
        }
    }

    /// The step's heading.
    public var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .cable: return "The cable and the other Mac"
        case .pair: return "Pair with the other Mac"
        case .model: return "Model and plan"
        case .check: return "Check across the cable"
        case .serve: return "Start and watch"
        }
    }
}

/// What the wizard knows about the pair this Mac belongs to: from its saved
/// setup, a setup waiting in its inbox, or the pair description it was opened
/// with. Labels only.
public struct ClusterSetupPair: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case saved, inbox, description }
    public var source: Source
    public var clusterID: String
    public var localMemberID: String
    public var peerMemberID: String
    /// Whether this Mac leads; nil while no plan has said (a pair description names no leader).
    public var leads: Bool?
    /// This Mac holds the inputs of the pinned route to the other Mac: it can ask it for its report.
    public var canReachPeer: Bool
    /// The folder name of this Mac's model directory in the setup or description.
    public var modelFolder: String?
    public var publicModelID: String?

    public init(source: Source, clusterID: String, localMemberID: String, peerMemberID: String, leads: Bool?,
                canReachPeer: Bool, modelFolder: String?, publicModelID: String?) {
        self.source = source; self.clusterID = clusterID; self.localMemberID = localMemberID
        self.peerMemberID = peerMemberID; self.leads = leads; self.canReachPeer = canReachPeer
        self.modelFolder = modelFolder; self.publicModelID = publicModelID
    }
}

/// One refresh of everything local: this Mac's report, what it knows about
/// the pair, and the wizard's own record.
public struct ClusterSetupSnapshot: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_setup_snapshot_v1"
    public var schema = ClusterSetupSnapshot.schemaName
    public var local: ClusterSetupReport
    public var pair: ClusterSetupPair?
    /// Why the pair description this wizard was given could not be read; nil otherwise.
    public var pairError: String?
    public var record: ClusterSetupRecord
    public var recordError: String?

    public init(local: ClusterSetupReport, pair: ClusterSetupPair?, pairError: String?, record: ClusterSetupRecord,
                recordError: String?) {
        self.local = local; self.pair = pair; self.pairError = pairError; self.record = record; self.recordError = recordError
    }
}

/// One model the pair could serve, with the planner's answer for it.
public struct ClusterSetupModelOption: Codable, Sendable, Equatable {
    public var model: ClusterSetupLocalModel
    /// Nil when the other Mac's models were not read.
    public var onOtherMac: Bool?
    /// Why it cannot be chosen; nil when it can.
    public var blocker: String?
    public var plan: ClusterSetupPlanSummary?

    public init(model: ClusterSetupLocalModel, onOtherMac: Bool?, blocker: String?, plan: ClusterSetupPlanSummary?) {
        self.model = model; self.onOtherMac = onOtherMac; self.blocker = blocker; self.plan = plan
    }
}

/// The planner's recommendation for one model, in the figures the screen shows.
public struct ClusterSetupPlanSummary: Codable, Sendable, Equatable {
    public struct Rank: Codable, Sendable, Equatable {
        public var rank: Int
        public var memberID: String
        public var local: Bool
        public var firstLayer: Int
        public var endLayer: Int
        public var weightsBytes: Int
        public var needBytes: Int
        public var admissibleNowBytes: Int
        public var physicalMemoryBytes: Int
        /// `now` when the load gate would admit it on the sample taken.
        public var fit: String
        /// The planner's sentence for the fit.
        public var fitDetail: String
        /// What must be freed first, when it does not fit now.
        public var shortBytes: Int?
    }
    public struct Alone: Codable, Sendable, Equatable {
        public var memberID: String
        public var fitsNow: Bool
        public var holds: Bool
        public var firstTokenSeconds: Double
        public var decodeTokensPerSecond: Double
    }
    public var cut: Int
    /// A `ClusterGenerationMode` raw value.
    public var mode: String
    public var prefillSchedule: String
    public var leaderID: String
    public var ranks: [Rank]
    public var promptTokens: Int
    public var outputTokens: Int
    public var firstTokenSeconds: Double
    public var decodeTokensPerSecond: Double
    /// False when speed did not inform the split, so the figures are relative.
    public var absolute: Bool
    /// Every figure measured on these Macs, or partly an estimate.
    public var measured: Bool
    public var alone: [Alone]
    /// Macs that alone hold the model and are predicted as fast.
    public var aloneAsFast: [String]
    public var fitsNow: Bool
    /// The largest shortfall among the ranks, when it does not fit now.
    public var needsBytes: Int?
    /// The planner's own explanation, line by line.
    public var explanation: [String]
    /// Public traffic in one line ("not yet qualified for public traffic" when no passing record covers the chosen
    /// mode); the owner's serving never waits for it. Nil in a summary written before it existed.
    public var publicTraffic: String? = nil
    /// Why the planner chose tensor parallel or a pipeline, in one line
    /// (`ClusterPlacementExplanation.deploymentReason`); nil in a summary written before it.
    public var modeReason: String? = nil
}

/// What reaching the other Mac gave.
public enum ClusterSetupPeerResult: Sendable, Equatable {
    case reached(ClusterSetupReport, seconds: Double)
    case failed(String)
}

/// The model list with plans, or why it could not be made.
public enum ClusterSetupPlansResult: Sendable, Equatable {
    case ready([ClusterSetupModelOption])
    case failed(String)
}

/// One run of the link fix: the dry run that previews it, or the change itself.
public struct ClusterSetupLinkFixResult: Sendable, Equatable {
    public var dryRun: Bool
    public var succeeded: Bool
    /// `ClusterLinkRepairOutcome.code`.
    public var outcome: String
    public var lines: [String]
    /// For a dry run: the exact commands the approval would run, in order.
    public var commands: [String]

    public init(dryRun: Bool, succeeded: Bool, outcome: String, lines: [String], commands: [String]) {
        self.dryRun = dryRun; self.succeeded = succeeded; self.outcome = outcome; self.lines = lines; self.commands = commands
    }
}

/// The leader's session as its status endpoint reports it, with this Mac's
/// memory and link beside it.
public struct ClusterSetupLive: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public var rank: Int
        public var memberID: String
        public var ready: Bool
        public var cleanupObserved: Bool
        public var releaseAcknowledged: Bool
        public var termination: String?
    }
    /// The status was read; false when no leader answered.
    public var observed: Bool
    public var detail: String?
    public var ready: Bool
    public var hostPhase: String?
    public var sessionPhase: String?
    public var port: Int?
    public var generationMode: String?
    public var members: [Member]
    /// Requests this session has served and keep-warm exchanges so far (no session limit).
    public var requestsServed: Int?
    public var keepWarmExchanges: Int?
    public var activeRequest: Bool
    public var quarantined: Bool
    public var localWiredBytes: Int?
    public var localPhysicalBytes: Int?
    /// A `ClusterLinkReadinessState` raw value; nil when not read with this observation.
    public var linkState: String?

    public init(observed: Bool, detail: String? = nil, ready: Bool = false, hostPhase: String? = nil, sessionPhase: String? = nil,
                port: Int? = nil, generationMode: String? = nil, members: [Member] = [], requestsServed: Int? = nil,
                keepWarmExchanges: Int? = nil, activeRequest: Bool = false, quarantined: Bool = false,
                localWiredBytes: Int? = nil, localPhysicalBytes: Int? = nil, linkState: String? = nil) {
        self.observed = observed; self.detail = detail; self.ready = ready; self.hostPhase = hostPhase
        self.sessionPhase = sessionPhase; self.port = port; self.generationMode = generationMode; self.members = members
        self.requestsServed = requestsServed; self.keepWarmExchanges = keepWarmExchanges
        self.activeRequest = activeRequest; self.quarantined = quarantined; self.localWiredBytes = localWiredBytes
        self.localPhysicalBytes = localPhysicalBytes; self.linkState = linkState
    }

    public var readyRanks: Int { members.filter(\.ready).count }
}

/// One test request through the local serving API.
public enum ClusterSetupPromptEvent: Sendable, Equatable {
    /// Text as it streams in.
    case text(String)
    case finished(ClusterSetupPromptResult)
    case failed(String)
}

public struct ClusterSetupPromptResult: Sendable, Equatable {
    public var completionTokens: Int
    public var firstTokenMilliseconds: Int?
    public var tokensPerSecond: Double?
    public var finishReason: String?

    public init(completionTokens: Int, firstTokenMilliseconds: Int?, tokensPerSecond: Double?, finishReason: String?) {
        self.completionTokens = completionTokens; self.firstTokenMilliseconds = firstTokenMilliseconds
        self.tokensPerSecond = tokensPerSecond; self.finishReason = finishReason
    }
}

/// The wizard's own writes and approvals, each one existing operation.
public enum ClusterSetupAction: String, Sendable, CaseIterable {
    case recordConfirmation, adoptPlan, approveInbox, recordCheck

    var title: String {
        switch self {
        case .recordConfirmation: return "Pairing confirmed"
        case .adoptPlan: return "Plan adopted"
        case .approveInbox: return "Setup approved"
        case .recordCheck: return "Check recorded"
        }
    }
}

public enum ClusterSetupEvent: Sendable {
    case key(ClusterConsoleKey)
    case resized(ClusterConsoleSize)
    case tick
    case snapshot(ClusterSetupSnapshot)
    case peer(ClusterSetupPeerResult)
    case plans(ClusterSetupPlansResult)
    case linkFix(ClusterSetupLinkFixResult)
    case actionFinished(ClusterSetupAction, ClusterConsoleActionResult)
    case sessionObserved(ClusterSetupLive)
    case session(ClusterConsoleSessionEvent)
    case prompt(ClusterSetupPromptEvent)
    /// The pairing ceremony over the link (S17), as it moves.
    case linkPairing(ClusterSetupLinkPairingEvent)
    case terminationSignal(Int32)
    case inputClosed
}

/// What the pairing ceremony over the Thunderbolt link (S17) reports to the
/// wizard. Text only: no key, no secret, no address beyond the one the person
/// gives the other Mac.
public enum ClusterSetupLinkPairingEvent: Equatable, Sendable {
    /// Listening (with what to run or type on the other Mac), dialing, connected.
    case waiting(String)
    /// The code to compare, and what the other Mac's attestation says about it.
    case code(String, peer: [String])
    case peerDecided(Bool)
    case finished(succeeded: Bool, lines: [String])
}

/// Work the reducer asks the run loop to do; each result comes back as an event.
public enum ClusterSetupEffect: Equatable, Sendable {
    case refresh
    case reachPeer
    case planModels
    case linkFix(dryRun: Bool)
    case recordConfirmation(code: String, clusterID: String?)
    /// Writes both Macs' setups for the model in `folder`, saves this Mac's,
    /// and sends the other Mac its own. `planSHA256` is the plan that was on screen.
    case adoptPlan(folder: String, planKey: String)
    case approveInbox(expectedSHA256: String)
    case launchSession
    case interruptSession
    case pollSession
    case sendPrompt(text: String, maxTokens: Int)
    case recordCheck(ClusterSetupRecord.CheckPass)
    /// Starts the pairing ceremony over the link: listening, or dialing the address given.
    case pairOverLink(connect: String?)
    /// The person's answer to the ceremony's code.
    case answerLinkCode(accept: Bool)
}

/// Everything the wizard is between two events. The reducer is its only
/// writer and the screen its only reader.
public struct ClusterSetupState: Sendable {
    public struct Options: Sendable, Equatable {
        /// The link fix previews only: nothing is ever applied from this screen.
        public var dryRun: Bool
        /// How long a question must be on screen before `y` answers it.
        public var questionDwellMilliseconds: Int
        /// Seconds the check waits for both ranks to report ready.
        public var readyTimeoutSeconds: Int
        /// Seconds between two readings of the other Mac while a session runs.
        public var peerPollSeconds: Int

        public init(dryRun: Bool = false, questionDwellMilliseconds: Int = 500, readyTimeoutSeconds: Int = 240,
                    peerPollSeconds: Int = 10) {
            self.dryRun = dryRun; self.questionDwellMilliseconds = questionDwellMilliseconds
            self.readyTimeoutSeconds = readyTimeoutSeconds; self.peerPollSeconds = peerPollSeconds
        }
    }

    public enum Peer: Sendable, Equatable {
        case unknown
        case reaching(since: UInt64)
        case reached(ClusterSetupReport, seconds: Double, at: UInt64)
        case failed(String)
    }

    public enum Plans: Sendable, Equatable {
        case notRun
        case planning
        case ready([ClusterSetupModelOption])
        case failed(String)
    }

    public enum LinkFix: Sendable, Equatable {
        case idle
        case previewing
        case previewed(ClusterSetupLinkFixResult)
        case applying
        case applied(ClusterSetupLinkFixResult)
    }

    /// The check's stages, in order.
    public enum CheckStage: Int, CaseIterable, Sendable, Comparable {
        case cable, start, ranks, generate, stop, cleanup
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .cable: return "Cable on both Macs"
            case .start: return "Start the session"
            case .ranks: return "Both ranks load the model"
            case .generate: return "Test generation"
            case .stop: return "Stop the session"
            case .cleanup: return "Memory released on both Macs"
            }
        }
    }

    public enum Check: Sendable, Equatable {
        case idle
        case running(CheckStage, since: UInt64)
        case passed(ClusterSetupRecord.CheckPass)
        case failed(CheckStage, String)
    }

    public enum Session: Sendable, Equatable {
        case none
        case launching
        case running(processIdentifier: Int32, since: UInt64)
        case stopping(processIdentifier: Int32)
        case ended(String, clean: Bool)

        var isActive: Bool {
            switch self {
            case .launching, .running, .stopping: return true
            case .none, .ended: return false
            }
        }
    }

    /// A question waiting for `y`.
    public enum Question: Equatable, Sendable {
        case applyLinkFix
        case confirmCode(code: String)
        /// The pairing ceremony's code (S17): `y` confirms it, `n` declines.
        case confirmLinkCode(code: String)
        case adoptPlan(folder: String, planKey: String)
        case approveInbox(expectedSHA256: String)
        case runCheck
        case startSession
    }

    public enum Prompt: Sendable, Equatable {
        case closed
        case editing(String)
        case sending(String, reply: String)
        case answered(String, reply: String, ClusterSetupPromptResult)
        case failed(String, reason: String)
    }

    /// The pairing ceremony over the link (S17), as step 3 shows it.
    public enum LinkPairing: Sendable, Equatable {
        case idle
        /// The address of the other Mac being typed (`c`).
        case enteringAddress(String)
        case waiting(String)
        case code(String, peer: [String])
        case confirmedHere(peerConfirmed: Bool)
        case finished(succeeded: Bool, lines: [String])

        var running: Bool {
            switch self {
            case .waiting, .code, .confirmedHere: return true
            case .idle, .enteringAddress, .finished: return false
            }
        }
    }

    enum Leaving: Equatable, Sendable { case confirmStop, afterSession, afterAction }

    static let activityLimit = 40
    static let sessionOutputLimit = 200
    static let replyLimit = 4_000
    static let promptLimit = 400

    public internal(set) var size: ClusterConsoleSize
    public let options: Options
    public internal(set) var snapshot: ClusterSetupSnapshot?
    public internal(set) var refreshing = false
    var refreshQueued = false
    /// `r` on step 4 asked for fresh plans: made as soon as the other Mac has answered again.
    public internal(set) var replanRequested = false
    /// The step on screen.
    public internal(set) var step: ClusterSetupStep = .thisMac
    /// The first snapshot moves the screen to the first unfinished step, once.
    var resumed = false
    /// Until the first key, the screen follows the first unfinished step as
    /// readings arrive (the other Mac's report often settles step 4 after the
    /// first snapshot). Any key ends that: the person's choice wins.
    var followResume = true
    public internal(set) var peer: Peer = .unknown
    public internal(set) var plans: Plans = .notRun
    public internal(set) var selectedModel = 0
    public internal(set) var linkFix: LinkFix = .idle
    public internal(set) var inFlight: ClusterSetupAction?
    public internal(set) var asking: Question?
    public internal(set) var questionShown = false
    var questionShownAt: UInt64?
    public internal(set) var check: Check = .idle
    /// The last ranks-ready count the check saw, for its progress line.
    public internal(set) var checkReadyRanks = 0
    /// Wired memory on each Mac when the check or the session started, for the cleanup comparison.
    var wiredBefore: (local: Int?, peer: Int?) = (nil, nil)
    /// The check's measurements so far.
    var checkReadySeconds: Double?
    var checkPrompt: ClusterSetupPromptResult?
    /// Which of the two fresh readings the check, or the clean-up after a stop, has seen.
    var checkSaw = (snapshot: false, peer: false)
    /// After the check's stop, when both Macs are read again while their owners finish letting go.
    var cleanupRereadAt: UInt64?
    var cleanupSaw = (snapshot: false, peer: false)
    public internal(set) var session: Session = .none
    public internal(set) var live: ClusterSetupLive?
    var sessionPollInFlight = false
    var peerPollAt: UInt64 = 0
    public internal(set) var sessionOutput = [String]()
    public internal(set) var prompt: Prompt = .closed
    public internal(set) var linkPairing: LinkPairing = .idle
    /// The other Mac confirmed the ceremony's code (it may answer before this Mac does).
    var linkPeerConfirmed = false
    /// What a session this screen stopped left behind, once it was read again.
    public internal(set) var cleanup: [String] = []
    var cleanupPending = false
    public internal(set) var activity = [ClusterDiagnosticExport.Activity]()
    public internal(set) var notice: String?
    public internal(set) var showsHelp = false
    public internal(set) var scroll = 0
    public internal(set) var maximumScroll = 0
    public internal(set) var bodyRows = 1
    /// The run loop's clock at the last event, in nanoseconds: spinners and elapsed times read it.
    public internal(set) var now: UInt64 = 0
    var leaving: Leaving?
    public internal(set) var exit: ClusterConsoleExit?

    public init(size: ClusterConsoleSize, options: Options = Options()) {
        self.size = size; self.options = options
    }

    /// Whether something is moving on screen, so the run loop redraws often.
    public var animating: Bool {
        if refreshing || inFlight != nil { return true }
        if case .reaching = peer { return true }
        if plans == .planning { return true }
        switch linkFix { case .previewing, .applying: return true; default: break }
        if case .running = check { return true }
        if case .sending = prompt { return true }
        if linkPairing.running { return true }
        return session.isActive
    }

    /// Records what the frame just drawn showed.
    public mutating func drew(maximumScroll: Int, bodyRows: Int, question: Question?, uptime: UInt64) {
        self.maximumScroll = maximumScroll
        self.bodyRows = max(bodyRows, 1)
        scroll = min(max(scroll, 0), maximumScroll)
        let shown = asking != nil && question == asking
        if !shown { questionShownAt = nil } else if !questionShown || questionShownAt == nil { questionShownAt = uptime }
        questionShown = shown
    }
}
