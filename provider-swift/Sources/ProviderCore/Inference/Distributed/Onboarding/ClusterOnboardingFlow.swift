import Foundation

// Leader-first onboarding (owner spec 2026-10-12, `darkbloom cluster`):
//
//   Mac 1: `darkbloom cluster` -> checks (RDMA, cable, isolation behind ONE
//   macOS approval, or sudo in this terminal where none can show, GID) and
//   this command's Local Network access -> nobody waits on the cable, so this
//   Mac leads, answers discovery on the cable and says "Run `darkbloom
//   cluster` on the other Mac." -> waits (q cancels).
//   Mac 2: `darkbloom cluster` -> its own checks -> finds the waiting leader
//   on the cable by itself -> the same code on both screens, "Yes" on each ->
//   "Paired. The other Mac leads." -> its cluster service runs (macOS asks
//   about Darkbloom's Local Network access), and nothing else is asked there.
//   Mac 1 (the leader, where onboarding started): its service's Local Network
//   access, both Macs in one line, the choice among the models approved for
//   clusters, the planner's placement (this Mac is rank 0), the setup synced
//   to the member over the link control channel, the member started
//   remotely, serving, one test request.
//
// Everything here is pure (Foundation and Darwin only): the operations are
// closures, so a check drives the whole flow on a pseudo-terminal with
// scripted operations. The live operations are `ClusterOnboardingOperations.live`.

/// Which part this Mac plays in its cluster, settled when it paired.
public enum ClusterOnboardingRole: String, Codable, Sendable, Equatable {
    /// Onboarding started here: it chooses the model and options, syncs the setup and starts the members.
    case leader
    /// It joined a waiting leader; it follows that leader and is never asked anything again.
    case member
}

/// How the cluster serves, kept on the leader until changed: through Darkbloom with the leading Mac's local API beside it
/// (`darkbloom cluster`, `ClusterServingChoice.both`), through Darkbloom alone (a pair saved that way by an earlier
/// build or an agent run), or on the leading Mac's local API only (`darkbloom cluster local`), where no Mac of the
/// cluster contacts a coordinator: no registration, heartbeat, public traffic or billing.
public enum ClusterServingScope: Sendable, Equatable {
    case publicServing
    /// The local API listens on `bind` and needs its API key.
    case localOnly(bind: String)
    /// Both: through Darkbloom as `publicServing`, and the pair's local API on the part that hosts the pair's slot, on
    /// `bind`, with that Mac's own key and the pair's. Darkbloom pauses while the owner uses it only where the leading
    /// Mac's `[local] me_first` asks for it (`ProviderLoop.enableClusterPairMeFirstIfConfigured`).
    case publicServingWithLocalAPI(bind: String)

    /// Every interface of the leading Mac (LAN or tailnet) unless the person chose an address (owner, 2026-10-15).
    public static let localOnlyDefaultBind = "0.0.0.0"

    /// Loopback: what a saved address that is not one the API takes falls back to (never a wider exposure).
    static let loopbackBind = "127.0.0.1"

    /// The scope a record keeps (nil from an older build or before the first choice: public). Local only wins over a
    /// local API beside Darkbloom.
    public init(localOnly: Bool?, localAPI: Bool? = nil, bind: String?) {
        guard localOnly == true || localAPI == true else { self = .publicServing; return }
        let address = bind.map { Self.isValidBind($0) ? $0 : Self.loopbackBind } ?? Self.localOnlyDefaultBind
        self = localOnly == true ? .localOnly(bind: address) : .publicServingWithLocalAPI(bind: address)
    }

    /// The scope a message carries (`localOnly`, `localAPI`, `bind`): nil when it carries none, or an address the API
    /// does not take (a scope with a local API but no address listens everywhere, as the default does).
    public static func carried(localOnly: Bool?, localAPI: Bool? = nil, bind: String?) -> ClusterServingScope? {
        guard let localOnly else { return nil }
        guard localOnly || localAPI == true else { return .publicServing }
        let address = bind ?? localOnlyDefaultBind
        guard isValidBind(address) else { return nil }
        return localOnly ? .localOnly(bind: address) : .publicServingWithLocalAPI(bind: address)
    }

    public var isLocalOnly: Bool {
        if case .localOnly = self { return true }
        return false
    }

    /// Local only's address (`darkbloom cluster local`); nil for the other two, so what reads it for local only (the
    /// leading part's `--no-coordinator`, the solo server) never sees Both. The relay serves Both too, so it reads
    /// `answersOnEveryMac` instead.
    public var bind: String? {
        if case .localOnly(let bind) = self { return bind }
        return nil
    }

    /// Where the pair's local API listens: local only's address or Both's; nil for the Darkbloom network.
    public var localAPIBind: String? {
        switch self {
        case .publicServing: return nil
        case .localOnly(let bind), .publicServingWithLocalAPI(let bind): return bind
        }
    }

    /// Both, me first: through Darkbloom, with the pair's local API.
    public var addsLocalAPI: Bool {
        if case .publicServingWithLocalAPI = self { return true }
        return false
    }

    /// An address the local API may listen on: `localhost` or a numeric IPv4/IPv6 address (`0.0.0.0` = every one).
    public static func isValidBind(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 64 else { return false }
        if text == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// The local API listens on every address of the Mac that runs it (local only's default, and Both's): every other Mac
    /// of the pair then answers on its own port too, passing each connection over the cable (`ClusterLocalRelay`). A
    /// loopback or one-address API isn't reached over the cable, and no other Mac opens what the person kept closed.
    public var answersOnEveryMac: Bool { Self.answersOnEveryMac(bind: localAPIBind) }

    /// The same rule for a pair's local API on `bind` (nil: none), where only its address is known: a status summary,
    /// or the discovery record of the API itself.
    public static func answersOnEveryMac(bind: String?) -> Bool { bind == localOnlyDefaultBind }

    /// True when hosts other than this Mac can reach the API (any address that is not loopback).
    public var reachableFromNetwork: Bool {
        guard let bind = localAPIBind else { return false }
        return !(bind == "localhost" || bind == "::1" || bind.hasPrefix("127."))
    }

    /// One plain line for the screens: how the cluster serves when it runs. It reaches `cluster status` as it is, never
    /// through the console's rename, so it names this build's command itself (`ClusterOnboardingCommand.name`).
    public var line: String {
        switch self {
        case .publicServing:
            return "Serving through Darkbloom"
        case .publicServingWithLocalAPI:
            return "Serving through Darkbloom, and on its local API; API key: `\(ClusterOnboardingCommand.name) local`"
        case .localOnly(let bind):
            let reach = bind == Self.localOnlyDefaultBind ? "on this Mac's networks"
                : reachableFromNetwork ? "at \(bind)" : "on this Mac only (\(bind))"
            return "Local only, \(reach); API key: `\(ClusterOnboardingCommand.name) local`"
        }
    }
}

/// How a pair serves, saved as the leading Mac's `[local] mode` (its raw values): `darkbloom cluster` serves Both with no
/// question (owner, 2026-11-11: "it should be both always, no selection needed"), `darkbloom cluster local` Only me, and
/// a pair an earlier build or an agent run saved for the Darkbloom network alone keeps serving that way until
/// `darkbloom cluster` runs.
public enum ClusterServingChoice: String, Sendable, Equatable, CaseIterable {
    /// Only me (this pair, local): `darkbloom cluster local`.
    case onlyMe = "local"
    /// Darkbloom network: the pair serves Darkbloom with no local API.
    case network
    /// Both: Darkbloom and the pair's local API; Darkbloom keeps serving while the owner uses it (owner, 2026-11-11:
    /// "keep serving the network"), unless the leading Mac's `[local] me_first = true` asks for the pause.
    case both

    /// How `scope` serves, as a choice.
    public init(scope: ClusterServingScope) {
        switch scope {
        case .publicServing: self = .network
        case .localOnly: self = .onlyMe
        case .publicServingWithLocalAPI: self = .both
        }
    }

    /// The scope this choice serves with. The pair's API keeps the address the person chose for it (`current`'s), else
    /// it listens on every interface of the leading Mac, as `darkbloom cluster local` does.
    public func scope(keeping current: ClusterServingScope) -> ClusterServingScope {
        let bind = current.localAPIBind ?? ClusterServingScope.localOnlyDefaultBind
        switch self {
        case .onlyMe: return .localOnly(bind: bind)
        case .network: return .publicServing
        case .both: return .publicServingWithLocalAPI(bind: bind)
        }
    }

    /// After "Switching to ", while the switch is saved.
    var switching: String {
        switch self {
        case .onlyMe: return "local only"
        case .network: return "serving through Darkbloom"
        case .both: return "serving through Darkbloom with the local API"
        }
    }

    /// After "the pair serves " and "keeps serving ".
    var serves: String {
        switch self {
        case .onlyMe: return "locally only"
        case .network: return "through Darkbloom"
        case .both: return "through Darkbloom, and on its local API"
        }
    }
}

/// What `darkbloom cluster` was asked for on the command line: `darkbloom cluster local` asks for local-only serving
/// (and may name the model); plain `darkbloom cluster` asks for nothing and keeps the saved scope.
public struct ClusterOnboardingRequest: Sendable, Equatable {
    /// Nil: keep how the cluster serves now.
    public var scope: ClusterServingScope?
    /// A model id or title to choose without the list (`darkbloom cluster local <model>`).
    public var model: String?

    /// Explicit private qualification only; never promotes the default text profile.
    public var privateMiMoImageQualification: Bool
    public var privateGLMImageQualification: Bool
    public var privateImageQualification: Bool { privateMiMoImageQualification || privateGLMImageQualification }
    public static let privateGLMModelID = "glm-5.3-flash"
    public static let privateMiMoModelID = "mimo-v2.6-flash-mopd"

    public init(scope: ClusterServingScope? = nil, model: String? = nil, privateMiMoImageQualification: Bool = false, privateGLMImageQualification: Bool = false) {
        self.scope = scope; self.model = model; self.privateMiMoImageQualification = privateMiMoImageQualification
        self.privateGLMImageQualification = privateGLMImageQualification
    }

    /// Pure validation shared by CLI and driver, with no runtime/module dependency.
    public var privateQualificationInputRefusal: String? {
        guard !(privateGLMImageQualification && privateMiMoImageQualification) else { return "Select one private image candidate." }
        if privateGLMImageQualification {
            guard scope?.isLocalOnly == true, model == Self.privateGLMModelID else {
                return "Private GLM image qualification requires cluster local with the explicit model id \(Self.privateGLMModelID)."
            }
            return nil
        }
        guard privateMiMoImageQualification else { return nil }
        guard scope?.isLocalOnly == true, model == Self.privateMiMoModelID else {
            return "Private MiMo image qualification requires cluster local with the explicit model id \(Self.privateMiMoModelID)."
        }
        return nil
    }

    public func privateQualificationRefusal(role: ClusterOnboardingRole?) -> String? {
        if let invalid = privateQualificationInputRefusal { return invalid }
        guard privateImageQualification else { return nil }
        guard role == .leader else {
            return "Run private image qualification on the already paired current control leader; this selection is not forwarded."
        }
        return nil
    }
}

/// What `darkbloom cluster` finds on this Mac when it starts.
public struct ClusterOnboardingResume: Sendable, Equatable {
    public var role: ClusterOnboardingRole?
    /// The other Mac's hardware name as pairing showed it (the leader's on a member, the member's on the leader).
    public var peerName: String?
    /// The leader asked the cluster to serve (kept across restarts).
    public var serving: Bool
    public var modelName: String?
    /// How the cluster serves (kept across restarts, as the leader saved it).
    public var scope: ClusterServingScope = .publicServing
    /// On a member: the derived control leader's name (the Mac the cluster is managed on).
    public var leaderName: String?
    /// Why derivation picked the leader, and its term.
    public var leaderReason: String?
    public var term: UInt64?
    /// What this Mac's own service runs now, in words (`ClusterControlWords`).
    public var localLine: String?
    /// The cable is on a port Darkbloom has not set up ("Thunderbolt 1 (en1)"): the Macs cannot reach each other
    /// there until it is. Nil when the active port is set up, or nothing could be read.
    public var unsetCablePort: String?
    /// The saved pairing cannot be used, as this Mac alone can tell (its Secure Enclave key changed); nil when it can,
    /// or nothing could be read.
    public var pairingProblem: ClusterOnboardingPairingProblem?
    /// The saved model as the catalog names it ("Qwen 3.8 27B"), for the lines that name it; nil when not known.
    public var modelTitle: String?
    /// The mode the saved setup serves it in (a `ClusterGenerationMode` raw value); nil when not known.
    public var servingMode: String?

    public init(role: ClusterOnboardingRole? = nil, peerName: String? = nil, serving: Bool = false, modelName: String? = nil) {
        self.role = role; self.peerName = peerName; self.serving = serving; self.modelName = modelName
    }
}

/// Why a saved pairing cannot be used, said in one sentence on the Mac that holds it, which then offers to pair again
/// (2026-11-03: a pairing made with the other app's Secure Enclave key looped "pair again" in the part's log while
/// `darkbloom cluster` showed its usual menu; recovering took the hidden `cluster pair --forget` on both Macs). A
/// silent other Mac is not one (`ClusterOnboardingDriver.otherMacSilentLine`).
public enum ClusterOnboardingPairingProblem: Sendable, Equatable {
    /// This Mac's Secure Enclave key is not the one it paired with: Darkbloom was reinstalled, or this Mac moved between
    /// the Darkbloom and DevNet apps (each keeps its own key). The roster names the old key, so the coordinator refuses
    /// the pair's registration.
    case keyChanged

    public var line: String {
        switch self {
        case .keyChanged:
            return "This Mac's Secure Enclave key changed after it paired (\(ClusterOnboardingCommand.app) was reinstalled, or "
                + "this Mac moved between the Darkbloom and DevNet apps), so the Macs must pair again to serve through Darkbloom."
        }
    }
}

/// How the screens name the two Macs of a pair: "this Mac" for the Mac the screen is on and "the other Mac" for the
/// other one, which the lines that identify it also call by its hardware name ("the other Mac (Apple M5 Ultra,
/// 256 GB)"). Two Macs of one kind share that name, so the name alone never says which Mac is meant (2026-10-25: both
/// Macs were "Apple M5 Ultra, 256 GB" and the API landed on the Mac the screen was not on). The hardware name is what
/// pairing shows: never a host or computer name.
public enum ClusterOnboardingMacName {
    public static let this = "this Mac"
    public static let other = "the other Mac"

    /// "the other Mac (Apple M5 Ultra, 256 GB)"; plain "the other Mac" when the name is unknown, not plain text, or
    /// itself a fallback such as "the other Mac".
    public static func other(named name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name.count <= 96,
              ClusterOnboardingDeployment.shownPlainly(name), !name.hasPrefix("the ") else { return other }
        return "\(other) (\(name))"
    }

    /// The text at the start of a sentence: "This Mac", "The other Mac (…)".
    public static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// Member names as the Mac `viewerID` names them on its screen or log: itself "this Mac", the one other member of
    /// a pair "the other Mac (<its name>)". With more than one other member the hardware names stay (no member is
    /// "the other").
    public static func names(_ hardware: [String: String], viewerID: String) -> [String: String] {
        guard hardware.keys.filter({ $0 != viewerID }).count == 1 else { return hardware }
        return Dictionary(uniqueKeysWithValues: hardware.map { id, name in (id, id == viewerID ? this : other(named: name)) })
    }
}

/// One Mac as the leader shows it before the model is chosen.
public struct ClusterOnboardingMachine: Codable, Sendable, Equatable {
    public var name: String
    public var memoryGB: Int
    public var gpuCores: Int?
    public var leads: Bool
    public var models: Int
    /// The member's stable identity (from its Secure Enclave key pin), so a forwarded answer can mark "this Mac".
    public var memberID: String?
    /// The Mac whose screen shows the line.
    public var here: Bool

    public init(name: String, memoryGB: Int, gpuCores: Int?, leads: Bool, models: Int, memberID: String? = nil, here: Bool? = nil) {
        self.name = name; self.memoryGB = memoryGB; self.gpuCores = gpuCores; self.leads = leads; self.models = models
        self.memberID = memberID; self.here = here ?? leads
    }
}

/// One model the leader may choose, with the planner's placement in words.
public struct ClusterOnboardingModelChoice: Codable, Sendable, Equatable {
    public var title: String
    /// Where each part runs and what the planner expects, one fact per line.
    public var lines: [String]
    /// Why it cannot be chosen; nil when it can.
    public var blocker: String?
    /// What has to move before it can be served (a Mac lacks it); nil when every Mac has it.
    public var provision: ClusterOnboardingProvisionOffer?
    /// It does not fit in the Macs' free memory now: what frees it, in plain words ("Quit apps on <Mac> first").
    /// Nil when it fits now. Choices that fit are listed first, so enter picks one that fits.
    public var fitRemedy: String?
    /// The model's id (`title` is its catalog display name when the catalog gave one); nil from an older build.
    public var modelID: String?
    /// Whether public traffic may reach it yet, in one line; said once it is chosen, and only when the cluster serves
    /// through Darkbloom. Nil from an older build (which put the line in `lines`).
    public var publicTraffic: String?
    /// Why the planner's split is not tensor parallel, in a few words ("tensor parallel: slower here"), for a model
    /// with a tensor-parallel plan that the planner did not give one. Nil when the split is tensor parallel, when the
    /// model has no such plan (no line for it), and from an older build.
    public var tensorParallelNote: String?
    /// The owner approved this model for clusters (`ClusterPublicModels`): the setup lists only such models
    /// (2026-11-02 onboarding review: "only allow ones that are allowed to cluster serve and validated"). Nil from
    /// an older leader, which does not say: its list is shown as it came.
    public var validated: Bool?
    /// How the planner splits it, as the list marks it (`ClusterOnboardingDeployment.splitMarker`: "tensor parallel"
    /// or "pipeline"). Nil before it is planned (it has to reach a Mac first) and from an older build.
    public var split: String?
    /// The modes it runs on these Macs, the planner's first, each with its speed measured on this pair when one is
    /// (never shown): the start loads `ClusterOnboardingMode.automaticIndex`'s, and `darkbloom cluster local` asks with it
    /// tagged Recommended. Nil from an older leader.
    public var modes: [ClusterOnboardingMode]?
    /// The earlier recommendation among `modes`, and why (`ClusterOnboardingModeAdvice.advise`), made on the leading Mac.
    /// No screen shows it or follows it since the mode is chosen by `automaticIndex` (2026-11-11); nil from an older leader.
    public var modeAdvice: ClusterOnboardingModeAdvice?

    public init(title: String, lines: [String], blocker: String?, provision: ClusterOnboardingProvisionOffer? = nil, fitRemedy: String? = nil,
                modelID: String? = nil, publicTraffic: String? = nil, tensorParallelNote: String? = nil, validated: Bool? = nil,
                split: String? = nil, modes: [ClusterOnboardingMode]? = nil, modeAdvice: ClusterOnboardingModeAdvice? = nil) {
        self.title = title; self.lines = lines; self.blocker = blocker; self.provision = provision; self.fitRemedy = fitRemedy
        self.modelID = modelID; self.publicTraffic = publicTraffic; self.tensorParallelNote = tensorParallelNote
        self.validated = validated; self.split = split; self.modes = modes; self.modeAdvice = modeAdvice
    }

    /// Offered on the setup's list: it can be served on these Macs and is not known to be unapproved.
    public var listed: Bool { blocker == nil && validated != false }

    /// The list's one line: the title (with the model's id when another choice shows the same title) and its size,
    /// the first fact of its first line, then "copy" or "download" when it has to reach a Mac first. No mode: the
    /// setup chooses it (`ClusterOnboardingMode.automaticIndex`; owner, 2026-11-11: "don't even give the option to
    /// pick, the choice should be automated").
    public func listLine(sameTitleElsewhere: Bool) -> String {
        let name = sameTitleElsewhere ? "\(title) (\(modelID ?? title))" : title
        let size = lines.first?.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 }
        let move = provision.map { $0.leaderDownloads && !$0.fromOtherMac ? "download" : "copy" }
        return ([name] + [size, move].compactMap { $0 }).joined(separator: " · ")
    }
}

/// The command the cluster screens tell the person to run: the running identity's CLI name
/// (`BuildEnvironment.current.cliName`; `darkbloom-dev` in the DevNet app), so a Mac with both apps is never told to run
/// the production command (the candidate on pair-2, c3 B13). The console names every command in backticks with it, and
/// the live operations' lines read it (`OnboardingLive.cli`). The checks that compile these screens without the package
/// start from production's names and set theirs with `use` and `useApp`.
public enum ClusterOnboardingCommand {
    private static let lock = NSLock()
    #if SWIFT_PACKAGE
    nonisolated(unsafe) private static var current = BuildEnvironment.current.cliName
    /// The app's own name, from the build identity: `ClusterService.appName`.
    nonisolated(unsafe) private static var currentApp = ClusterService.appName
    /// The row Privacy & Security → Local Network shows for the app, in every build: `ClusterService.localNetworkRow`.
    public static let localNetworkRow = ClusterService.localNetworkRow
    #else
    nonisolated(unsafe) private static var current = "darkbloom"
    nonisolated(unsafe) private static var currentApp = "Darkbloom"
    public static let localNetworkRow = "Darkbloom"
    #endif
    public static var name: String { lock.withLock { current } }
    public static func use(_ name: String) { lock.withLock { current = name } }
    public static var app: String { lock.withLock { currentApp } }
    public static func useApp(_ app: String) { lock.withLock { currentApp = app } }
    /// `text` with each command in backticks ("`darkbloom …`") named for the running identity.
    public static func named(_ text: String) -> String { rename(text, to: name) }
    static func rename(_ text: String, to name: String) -> String {
        guard name != "darkbloom" else { return text }
        return text.replacingOccurrences(of: "`darkbloom ", with: "`\(name) ").replacingOccurrences(of: "`darkbloom`", with: "`\(name)`")
    }
}

/// A start's pending check with Darkbloom (`ClusterSetupRecord.registrationPendingPID` and `registrationPendingStarted`),
/// as the leader's status reads it: pending while that start's process runs, the same process (its start time matches,
/// so a pid the system has given to another process never counts). A start that died before it asked leaves its mark
/// behind; it is cleared once seen gone, and only while the record still holds that mark, so a new start's is never wiped.
public enum ClusterOnboardingPendingRegistration {
    /// The start's process: its pid and when it started (microseconds since 1970); `started` nil never counts.
    public struct Mark: Equatable, Sendable {
        public var pid: Int32
        public var started: UInt64?
        public init(pid: Int32, started: UInt64?) { self.pid = pid; self.started = started }
    }

    /// Whether the recorded mark counts, and the mark to clear because its process is gone (or its pid is another's).
    /// `started`: when the process that has `pid` now started; nil when none runs or it can't be read.
    public static func look(_ recorded: Mark?, started: (Int32) -> UInt64?) -> (pending: Bool, clear: Mark?) {
        guard let mark = recorded else { return (false, nil) }
        if let since = mark.started, started(mark.pid) == since { return (true, nil) }
        return (false, mark)
    }

    /// The record's mark once `gone` is cleared: unchanged unless it still holds `gone`.
    public static func cleared(_ current: Mark?, gone: Mark) -> Mark? { current == gone ? nil : current }
}

/// One way both Macs can run a model (owner, 2026-11-04: tensor parallel and pipeline both offered, the fastest measured
/// on this pair by default, the other one keypress away): the planner's mode, each Mac's share in the screen's words,
/// and the decode speed this pair served it at when it has (`ClusterServedModes`), never an estimate. The speed only
/// orders the modes: no screen quotes it (owner, 2026-11-05: the model and mode choice never quote tok/s).
public struct ClusterOnboardingMode: Codable, Sendable, Equatable {
    /// A `ClusterGenerationMode` raw value.
    public var mode: String
    /// Each Mac's share as the screen names the Macs ("this Mac 6 layers / the other Mac 24 layers", "this Mac 50% /
    /// the other Mac 50%"); nil when not known.
    public var split: String?
    /// Decode tokens per second this pair served the model at in this mode with this build; nil: not measured with this
    /// build yet (`automaticIndex` reads it).
    public var measuredTokensPerSecond: Double?
    /// Requests the pair serves at once in this mode, from the plan that loads (1: one at a time); nil when not known
    /// and from an older leader.
    public var concurrentRequests: Int?
    /// The context the pair serves in this mode (`ClusterModelFeaturePolicy.servedProfile`), and its longest prompt;
    /// nil when not known and from an older leader.
    public var contextTokens: Int?
    public var promptTokens: Int?
    /// Every Mac's part of this mode's plan fits in the memory it has free now; nil when not known and from an older leader.
    public var fitsNow: Bool?
    /// Darkbloom's coordinator serves this mode publicly; nil when not known and from an older leader.
    public var publicTraffic: Bool?

    public init(mode: String, split: String?, measuredTokensPerSecond: Double?, concurrentRequests: Int? = nil,
                contextTokens: Int? = nil, promptTokens: Int? = nil, fitsNow: Bool? = nil, publicTraffic: Bool? = nil) {
        self.mode = mode; self.split = split; self.measuredTokensPerSecond = measuredTokensPerSecond
        self.concurrentRequests = concurrentRequests
        self.contextTokens = contextTokens; self.promptTokens = promptTokens
        self.fitsNow = fitsNow; self.publicTraffic = publicTraffic
    }

    /// How many requests it serves at once, plainly (R4-15: GLM's pipeline took one request at a time, and Darkbloom
    /// turned the rest away at capacity, while its tensor parallel took 8); nil when not known.
    var requestsWords: String? {
        concurrentRequests.map { $0 <= 1 ? "serves one request at a time" : "serves up to \($0) requests at once" }
    }

    /// A mode's split while a model serves (`OnboardingLive.modeSplit`): planned with that model's memory taken, it is
    /// not the one that loads.
    static let decidedWhenItLoads = "decided when it loads"

    /// The owner's labels (2026-11-04): tensor parallel, pipeline, and MiMo's speculative pipeline.
    public var label: String {
        let words = ClusterOnboardingDeployment.modeWords(mode)
        if words == "tensor parallel" { return "Tensor parallel" }
        if words.hasPrefix("pipeline with speculative") { return "Speculative pipeline" }
        if words == "pipeline" { return "Pipeline" }
        return ClusterOnboardingMacName.sentence(words)
    }

    /// The same, short: "serves one at a time", "serves up to 8 at once".
    var shortRequestsWords: String? {
        concurrentRequests.map { $0 <= 1 ? "serves one at a time" : "serves up to \($0) at once" }
    }

    /// The context it serves, and its longest prompt when that is shorter (journey 3's second delta: Gemma 4's
    /// pipeline served 65,536 tokens with prompts up to 32,768 in 0.10.11, tensor parallel 262,144, and the question
    /// said neither): "context 65,536 tokens, prompts up to 32,768" for a pipeline that serves the memory plan's
    /// request; nil when not known.
    var contextWords: String? {
        guard let context = contextTokens else { return nil }
        let prompts = promptTokens.flatMap { $0 < context - 1 ? ", prompts up to " + Self.grouped($0) : nil } ?? ""
        return "context " + Self.grouped(context) + " tokens" + prompts
    }

    /// The same, short: "context 65,536".
    var shortContextWords: String? { contextTokens.map { "context " + Self.grouped($0) } }

    /// "262,144".
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        return digits.enumerated().map { index, digit in
            (index > 0 && (digits.count - index) % 3 == 0 ? "," : "") + String(digit)
        }.joined()
    }

    /// Whether this is tensor parallel (`ClusterOnboardingDeployment.modeWords`), never a pipeline or a phase split.
    var isTensorParallel: Bool { ClusterOnboardingDeployment.modeWords(mode) == "tensor parallel" }

    /// The mode a start loads, chosen for the person (owner, 2026-11-11: "Default always tensor, pipeline as backup if it
    /// cannot"; "TP if measured faster (it should almost always be)"): tensor parallel unless it can't run on these Macs
    /// or this pair measured it slower; then the fastest of the modes measured faster than it. With no tensor parallel
    /// that can run, the planner's first mode that can.
    /// "Can't run": it doesn't fit in the Macs' free memory now while another mode does (`serving`: a model serves, and the
    /// start frees its memory first, so fitting now doesn't decide), or, `throughDarkbloom`, Darkbloom doesn't serve it
    /// publicly while it serves another. "Measured slower": with this build, on this pair, slower than another mode by more
    /// than `ClusterOnboardingModeAdvice.sameSpeed`. Not measured yet, or a link not measured yet, is no reason: tensor
    /// parallel. Nil only for no modes. `darkbloom cluster` loads it without a question; `darkbloom cluster local` asks,
    /// with this mode marked Recommended and preselected.
    public static func automaticIndex(_ modes: [ClusterOnboardingMode], throughDarkbloom: Bool, serving: Bool) -> Int? {
        guard !modes.isEmpty else { return nil }
        var open = Array(modes.indices)
        let fitting = open.filter { serving || modes[$0].fitsNow != false }
        if !fitting.isEmpty { open = fitting }
        if throughDarkbloom {
            let served = open.filter { modes[$0].publicTraffic != false }
            if !served.isEmpty { open = served }
        }
        guard let tensor = open.first(where: { modes[$0].isTensorParallel }) else { return open[0] }
        guard let tensorSpeed = modes[tensor].measuredTokensPerSecond else { return tensor }
        let faster = open.filter { index in
            modes[index].measuredTokensPerSecond.map { $0 > tensorSpeed * (1 + ClusterOnboardingModeAdvice.sameSpeed) } == true
        }
        return faster.max { modes[$0].measuredTokensPerSecond! < modes[$1].measuredTokensPerSecond! } ?? tensor
    }
}

/// The mode the setup recommends for these two Macs (owner, 2026-11-04: "it also does not suggest which one to select
/// for the hardware"), from what the plans already know: whether each mode fits now, the context it serves, its speed
/// on this pair (measured with this build, else as this pair served it with an earlier build, else the planner's
/// prediction), how many requests it serves at once, and whether Darkbloom serves it publicly. Exactly one mode, or
/// none with the reason: it never guesses past the evidence.
public struct ClusterOnboardingModeAdvice: Codable, Sendable, Equatable {
    /// The recommended `ClusterOnboardingMode.mode`; nil when none is recommended.
    public var mode: String?
    /// Why, in a few plain words; why none, when `mode` is nil.
    public var reason: String

    public init(mode: String?, reason: String) { self.mode = mode; self.reason = reason }

    /// One mode as the plans describe it.
    public struct Option: Sendable, Equatable {
        public var mode: String
        /// A plan was made for it on these Macs.
        public var planned: Bool
        /// Every Mac's part fits in the memory it has free now.
        public var fitsNow: Bool
        /// Its decode rate as this build served it on these Macs; nil before this build has.
        public var measuredTokensPerSecond: Double?
        /// Its decode rate as these Macs last served it with an earlier Darkbloom build, the same way (through Darkbloom or
        /// locally, with or without Qwen's tensor assistant); nil when none did.
        public var earlierMeasuredTokensPerSecond: Double?
        /// The planner's decode prediction in tokens per second; nil when its figures are only relative.
        public var predictedTokensPerSecond: Double?
        public var concurrentRequests: Int?
        /// Darkbloom's coordinator serves this mode publicly; nil when not known.
        public var publicTraffic: Bool?
        /// The context the pair serves in this mode; nil when not known.
        public var contextTokens: Int?
        public init(mode: String, planned: Bool, fitsNow: Bool, measuredTokensPerSecond: Double? = nil,
                    earlierMeasuredTokensPerSecond: Double? = nil, predictedTokensPerSecond: Double? = nil,
                    concurrentRequests: Int? = nil, publicTraffic: Bool? = nil, contextTokens: Int? = nil) {
            self.mode = mode; self.planned = planned; self.fitsNow = fitsNow; self.measuredTokensPerSecond = measuredTokensPerSecond
            self.earlierMeasuredTokensPerSecond = earlierMeasuredTokensPerSecond
            self.predictedTokensPerSecond = predictedTokensPerSecond; self.concurrentRequests = concurrentRequests
            self.publicTraffic = publicTraffic; self.contextTokens = contextTokens
        }
    }

    /// Speeds closer than this are the same to the advice: the planner's own figures differ by about as much.
    static let sameSpeed = 0.05

    /// Why the faster mode is recommended, with no figures (owner, 2026-11-05: "it should not show tok/s"): the
    /// speeds only rank the modes, measured or predicted; the words never quote them.
    static let fasterWords = "faster here"
    /// Why a measured mode is recommended over modes only predicted so far.
    static let onlyMeasuredWords = "the only one measured on these Macs so far"
    static let fastestMeasuredWords = "the fastest measured on these Macs so far"

    /// The recommendation among `options` (nil with fewer than two). `throughDarkbloom`: the pair serves through Darkbloom,
    /// where requests beyond those a mode serves at once are turned away as "at capacity". `serving`: a model serves now,
    /// so the list counts its memory as taken; the start frees it, so fitting now does not decide.
    public static func advise(_ options: [Option], throughDarkbloom: Bool, serving: Bool) -> ClusterOnboardingModeAdvice? {
        guard options.count > 1 else { return nil }
        let planned = options.filter(\.planned)
        var open = planned.filter { serving || $0.fitsNow }
        guard !open.isEmpty else {
            return .init(mode: nil, reason: planned.isEmpty ? "none of them could be planned on these Macs"
                : "none of them fits in these Macs' free memory now")
        }
        var publicOnly = false
        if throughDarkbloom {
            let served = open.filter { $0.publicTraffic == true }
            if !served.isEmpty, served.count < open.count { open = served; publicOnly = true }
        }
        if open.count == 1 {
            return .init(mode: open[0].mode, reason: publicOnly ? "the only one Darkbloom serves publicly on these Macs"
                : "the only one that fits these Macs now")
        }
        // Context before speed (journey 3's second delta: right after an update the planner ranked Gemma 4's pipeline
        // faster, and Enter took it: 65,536 tokens against tensor parallel's 262,144). Where every mode left says the
        // context it serves and they differ, the modes that serve the most stay; one that serves less is recommended
        // only when none of those fits now (above).
        let contexts = open.compactMap(\.contextTokens)
        if contexts.count == open.count, let longest = contexts.max(), Set(contexts).count > 1 {
            let whole = open.filter { $0.contextTokens == longest }
            if whole.count == 1 {
                return .init(mode: whole[0].mode, reason: Self.longestContextWords(longest, others: contexts.filter { $0 != longest }))
            }
            open = whole
        }
        func lanes(_ option: Option) -> Int? { option.concurrentRequests.map { max(1, $0) } }
        func atOnce(_ option: Option) -> String {
            guard let n = lanes(option) else { return "" }
            return n == 1 ? "serves one request at a time" : "serves up to \(n) requests at once"
        }
        let lanesKnown = open.allSatisfy { lanes($0) != nil }
        let mostLanes = lanesKnown ? open.max { lanes($0)! < lanes($1)! } : nil
        let lanesDiffer = lanesKnown && Set(open.map { lanes($0)! }).count > 1
        // What these Macs measured: this build's served speeds, or, while this build has served none of these modes, what
        // they served with an earlier build whose records say how they were served (`ClusterSetupPlanning.earlierFigures`:
        // from #1819, provider 0.10.11, on; none after an update from 0.10.10). Every Darkbloom update starts a build
        // with nothing served, and the planner's figures can rank the modes the other way round (pair-2, an M3 Ultra and
        // an M5 Max, DevNet .118: right after the update the question said "Pipeline, faster here" for Gemma, from
        // predictions, though these Macs had served its tensor parallel faster on every earlier build). The two are never
        // ranked together: once one of these modes has served with this build, another's earlier figure, even a faster
        // one, waits until that mode serves with it too.
        let servedWithThisBuild = open.contains { $0.measuredTokensPerSecond != nil }
        func measurement(_ option: Option) -> Double? {
            servedWithThisBuild ? option.measuredTokensPerSecond : option.earlierMeasuredTokensPerSecond
        }
        let measured = open.allSatisfy { measurement($0) != nil }
        let speeds: [Double]? = measured ? open.map { measurement($0)! }
            : open.allSatisfy({ $0.predictedTokensPerSecond != nil }) ? open.map { $0.predictedTokensPerSecond! } : nil
        let basis = measured ? "measured" : "predicted"
        // Some modes measured on these Macs and some not: a measurement outranks a prediction (owner, 2026-11-05: "use
        // measurements when present"). The planner's figures for a mode that hasn't served can be far off (two M5 Ultras,
        // Gemma: a pipeline predicted at 152 tok/s served 64, beside tensor parallel measured at 111), so the fastest
        // measured mode is recommended until the others have served too. Through Darkbloom a mode that serves more at
        // once still comes first, which needs no speed.
        let measuredOpen = open.filter { measurement($0) != nil }
        if !measured, let best = measuredOpen.max(by: { measurement($0)! < measurement($1)! }) {
            if throughDarkbloom, lanesDiffer, let most = mostLanes, lanes(most)! > lanes(best)! {
                return .init(mode: most.mode, reason: atOnce(most) + "; the others take fewer, and Darkbloom turns the rest away")
            }
            let lanesNote = lanesKnown && lanes(best)! > 1 ? " and " + atOnce(best) : ""
            return .init(mode: best.mode, reason: (measuredOpen.count == 1 ? Self.onlyMeasuredWords : Self.fastestMeasuredWords) + lanesNote)
        }
        if let speeds {
            let fastest = speeds.indices.max { speeds[$0] < speeds[$1] }!
            let runnerUp = speeds.indices.filter { $0 != fastest }.max { speeds[$0] < speeds[$1] }!
            let clearlyFaster = speeds[fastest] > speeds[runnerUp] * (1 + sameSpeed)
            // Through Darkbloom, a mode that serves one at a time turns the rest away: serving more at once wins there.
            if lanesDiffer, let most = mostLanes, lanes(most)! > lanes(open[fastest])!, throughDarkbloom || !clearlyFaster {
                let index = open.firstIndex(of: most)!
                let other = open.indices.first { $0 != index }!
                let slower = speeds[index] < speeds[other]
                let faster = speeds[index] > speeds[other] * (1 + sameSpeed)
                return .init(mode: most.mode, reason: atOnce(most) + (slower ? "; the others take fewer, and Darkbloom turns the rest away"
                    : faster ? " and is " + Self.fasterWords : " and is as fast here"))
            }
            guard clearlyFaster else {
                return .init(mode: nil, reason: "they are about as fast on these Macs (\(basis)) and serve as many requests at once")
            }
            let lanesNote = lanesKnown && lanes(open[fastest])! > 1 ? " and " + atOnce(open[fastest]) : ""
            return .init(mode: open[fastest].mode, reason: Self.fasterWords + lanesNote)
        }
        if lanesDiffer, let most = mostLanes {
            return .init(mode: most.mode, reason: atOnce(most) + "; no speed is known for these Macs yet")
        }
        return .init(mode: nil, reason: "no speed is measured or predicted for these Macs yet")
    }

    /// Why the mode that serves the most context is recommended: "the longest context here (262,144 tokens; the other
    /// serves 65,536)".
    static func longestContextWords(_ longest: Int, others: [Int]) -> String {
        let rest = others.count == 1 ? "the other serves " + ClusterOnboardingMode.grouped(others[0])
            : "the others serve up to " + ClusterOnboardingMode.grouped(others.max() ?? 0)
        return longestContextLead + " here (\(ClusterOnboardingMode.grouped(longest)) tokens; \(rest))"
    }

    /// How `longestContextWords` begins, which `brief` reads.
    static let longestContextLead = "the longest context"

    /// The reason in a few words, for a narrow window (`line`): "faster, up to 8 at once", "the only one that fits".
    var brief: String {
        if reason.hasPrefix(Self.longestContextLead) { return "longest context" }
        let atOnce = reason.range(of: #"up to (\d+) requests at once"#, options: .regularExpression)
            .map { String(reason[$0]).replacingOccurrences(of: " requests", with: "") }
        if reason.hasPrefix("faster here") { return atOnce.map { "faster, \($0)" } ?? "faster here" }
        if reason.hasPrefix(Self.onlyMeasuredWords) || reason.hasPrefix(Self.fastestMeasuredWords) {
            return atOnce.map { "measured, \($0)" } ?? "measured here"
        }
        if let atOnce, reason.hasPrefix("serves") { return atOnce }
        if reason.hasPrefix("the only one that fits") { return "the only one that fits" }
        if reason.hasPrefix("the only one Darkbloom") { return "the only one served publicly" }
        if reason.hasPrefix("none of them fits") { return "none fits now" }
        if reason.hasPrefix("none of them could") { return "none could be planned" }
        if reason.hasPrefix("they are about as fast") { return "about as fast" }
        if reason.hasPrefix("no speed") { return "no speed known yet" }
        return reason
    }

    /// The question's first line, naming the model (owner, 2026-11-04: "say which is recommended for the model
    /// selected"): the recommended mode apart, so a colour terminal can stress it. `width`: the window's columns (nil
    /// when unknown); the line keeps two columns of indent. Too wide, the reason is shortened (`brief`), then left out;
    /// the model's and the mode's names never are.
    public func line(model: String, width: Int? = nil) -> (lead: String, mode: String, tail: String) {
        let name = mode.map { ClusterOnboardingMode(mode: $0, split: nil, measuredTokensPerSecond: nil).label } ?? ""
        let lead = mode == nil ? "No recommendation for \(model) on these two Macs: " : "Recommended for \(model) on these two Macs: "
        let tails = mode == nil ? [reason + ".", brief + "."] : [", \(reason).", ", \(brief).", "."]
        let room = width.map { $0 - 2 } ?? .max
        let tail = tails.first { lead.count + name.count + $0.count <= room } ?? tails[tails.count - 1]
        return (lead, name, tail)
    }

    /// The same line as plain text.
    public func plainLine(model: String, width: Int? = nil) -> String {
        let parts = line(model: model, width: width)
        return parts.lead + parts.mode + parts.tail
    }

    /// The marker on the recommended option's line.
    static let marker = "recommended for these Macs"
}

/// How a chosen model is spread over the Macs, in one plain line, from what the planner chose (the mode and each
/// Mac's share). Universal: the words come from the plan's mode and shares, never from a model or chip table.
public enum ClusterOnboardingDeployment {
    public struct Share: Sendable, Equatable {
        /// The Mac's name as pairing showed it ("Apple M5 Ultra, 256 GB").
        public var name: String
        /// Layers this Mac holds (pipeline), or nil.
        public var layers: Int?
        /// Weight bytes this Mac holds (tensor parallel shares are given as a percentage of these).
        public var weightsBytes: Int?
        /// How the screen that shows the line names this Mac ("this Mac", "the other Mac"); nil in a line recorded for
        /// both Macs (the start carries it), which names each Mac by its hardware.
        public var label: String?
        public init(name: String, layers: Int?, weightsBytes: Int? = nil, label: String? = nil) {
            self.name = name; self.layers = layers; self.weightsBytes = weightsBytes; self.label = label
        }
    }

    /// "Apple M5 Ultra, 256 GB" -> "M5 Ultra".
    public static func shortName(_ name: String) -> String {
        var short = name.split(separator: ",").first.map(String.init) ?? name
        if short.hasPrefix("Apple ") { short.removeFirst("Apple ".count) }
        return short.trimmingCharacters(in: .whitespaces)
    }

    /// The plan's mode in words: tensor parallel or pipeline (the sharded modes), anything else plainly.
    public static func modeWords(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("prefill_tensor_decode") { return "pipeline prefill, tensor parallel decode" }
        if lower.contains("tensor") || lower.hasPrefix("tp") { return "tensor parallel" }
        if lower.hasPrefix("pipeline_mtp") { return "pipeline with speculative decoding" }
        if lower.hasPrefix("pipeline") { return "pipeline" }
        if lower.hasPrefix("phase_split") { return "prompt split, then one Mac decodes" }
        return unknownModeWords
    }

    static let unknownModeWords = "split across the Macs"

    /// The split as the model list and the serving lines mark it (owner, 2026-11-03: "keep a marker or small wording
    /// showing if the split is tensor parallelism or pipeline"): "tensor parallel" or "pipeline", speculative rounds
    /// or not; an opt-in hand-off mode in its own words; nil for a mode these words do not know.
    public static func splitMarker(_ raw: String) -> String? {
        let words = modeWords(raw)
        if words.hasPrefix("pipeline with") { return "pipeline" }
        return words == unknownModeWords ? nil : words
    }

    /// Every marker `splitMarker` gives, longest first.
    static let knownSplitMarkers = Set(["prefill_tensor_decode", "tensor", "pipeline_mtp", "pipeline", "phase_split"].compactMap(splitMarker))
        .sorted { $0.count > $1.count }

    /// A split's marker as a screen shows it, whichever Mac's build sent it: a few plain words, else nothing.
    static func shownMarker(_ split: String?) -> String? {
        guard let split, !split.isEmpty, split.count <= 48, shownPlainly(split) else { return nil }
        return split
    }

    /// "M3 Ultra 40 layers / M5 Ultra 24 layers" (pipeline) or "M3 Ultra 60% / M5 Ultra 40%" (tensor parallel); on a
    /// screen that knows which Mac is which, "this Mac 50% / the other Mac 50%".
    public static func sharesWords(mode: String, shares: [Share]) -> String {
        let names = shares.map { shortName($0.name) }
        let screen = shares.compactMap(\.label)
        // The screen's own words when every share has one; else the chips, and for two Macs of one kind the full names
        // (which still match when the Macs are identical: only the screen's words tell them apart).
        let labels = screen.count == shares.count ? screen : Set(names).count == names.count ? names : shares.map(\.name)
        if modeWords(mode).contains("tensor parallel") {
            let total = shares.compactMap(\.weightsBytes).reduce(0, +)
            guard total > 0, shares.allSatisfy({ $0.weightsBytes != nil }) else { return labels.joined(separator: " / ") }
            return zip(labels, shares).map { "\($0) \(Int((Double($1.weightsBytes!) * 100 / Double(total)).rounded()))%" }.joined(separator: " / ")
        }
        return zip(labels, shares).map { label, share in share.layers.map { "\(label) \(layers($0))" } ?? label }.joined(separator: " / ")
    }

    /// "1 layer", "44 layers": a layer count as every split says it (c3's B19 read "1 layers").
    static func layers(_ count: Int) -> String { count == 1 ? "1 layer" : "\(count) layers" }

    /// "Serving Qwen3.8-27B across both Macs: pipeline, M3 Ultra 40 layers / M5 Ultra 24 layers".
    public static func line(model: String, mode: String, shares: [Share]) -> String {
        let macs = shares.count == 2 ? "both Macs" : "\(shares.count) Macs"
        return "Serving \(model) across \(macs): \(modeWords(mode)), \(sharesWords(mode: mode, shares: shares))"
    }

    /// A model as the screens name it: its catalog display name ("MiMo V2.6 Flash"), its id only when the catalog gave
    /// no name for it (it did not answer, or the model is not listed).
    public static func title(modelID: String, displayNames: [String: String]) -> String {
        guard let name = displayNames[modelID]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 120,
              shownPlainly(name) else { return modelID }
        return name
    }

    /// Text from another source (the catalog, the other Mac) is shown only without terminal control characters.
    static func shownPlainly(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// The deployment line a Mac records when the leader starts the cluster: the line the start carries, so whichever
    /// Mac leads later (the plan's rank 0 may be the other Mac) shows the same mode and layers. A start that names a
    /// model but carries no line (an older leader) drops the recorded one, which may be another model's; a start that
    /// names no model changes nothing.
    public static func recorded(afterStartOf model: String?, deployment: String?, recorded: String?) -> String? {
        guard model != nil else { return recorded }
        guard let deployment, deployment.count <= 512, shownPlainly(deployment) else { return nil }
        return deployment
    }

    /// One model choice in one line: "6.1 GB · pipeline · M3 Ultra 16 layers / M5 Ultra 16 layers". No speed (owner,
    /// 2026-11-05: the model and mode choice never quote tok/s).
    public static func choiceLine(size: String, mode: String, shares: [Share]) -> String {
        [size, modeWords(mode), sharesWords(mode: mode, shares: shares)].joined(separator: " · ")
    }
}

/// A chosen model some Mac lacks (compared by the catalog manifest's digests): how it gets there. No model is ever
/// downloaded by hand for clustering: a Mac that has it copies it over the Thunderbolt cable (the default), and when
/// no Mac has it the leader downloads it from Darkbloom's catalog as single-Mac Darkbloom does, then copies it.
public struct ClusterOnboardingProvisionOffer: Codable, Sendable, Equatable {
    /// One line per Mac that needs it, with size and time ("Apple M5 Ultra: copy from … over the Thunderbolt cable (6.1 GB, about 3 s)").
    public var lines: [String]
    /// The members may take it from the catalog instead of the cable.
    public var downloadAlternative: Bool
    /// This Mac lacks it too: it downloads it first and plans from its files afterwards.
    public var leaderDownloads: Bool
    /// Why it cannot start (not enough free disk on a Mac), nil when it can.
    public var blocker: String?
    /// The predicted time of a short copy over the cable (derived from the copy rate measured on these Macs and the
    /// bytes to move; `ClusterModelProvisioning.quickCopySeconds`): the list's copy item says it. Nil: a long copy, a
    /// download, or no rate measured yet.
    public var quickSeconds: Double?
    /// This Mac lacks it and copies it from the other Mac over the cable (with `leaderDownloads`: planned from its
    /// files afterwards, but nothing is downloaded).
    public var fromOtherMac: Bool
    /// Whether every Mac that receives it has room for it on disk now (`ClusterModelProvisioningPlan.fitsOnDisk`: the
    /// bytes free now and the room kept free; space macOS could purge is not counted). Nil from an older build.
    public var fitsOnDisk: Bool?

    public init(lines: [String], downloadAlternative: Bool, leaderDownloads: Bool, blocker: String? = nil, quickSeconds: Double? = nil,
                fromOtherMac: Bool = false, fitsOnDisk: Bool? = nil) {
        self.lines = lines; self.downloadAlternative = downloadAlternative; self.leaderDownloads = leaderDownloads; self.blocker = blocker
        self.quickSeconds = quickSeconds; self.fromOtherMac = fromOtherMac; self.fitsOnDisk = fitsOnDisk
    }
}

/// What happens to this Mac's part after a restart or a power cut, said plainly from what macOS is set to do. The
/// cluster service is a login agent (it needs the logged-in session for its keys and attestation), so it comes back by
/// itself only when the Mac logs in by itself; FileVault keeps the disk locked until someone logs in.
public enum ClusterOnboardingRestart {
    public static func line(mac: String, autoLogin: Bool, fileVault: Bool?) -> String {
        if autoLogin { return "After a restart, \(mac) serves again by itself." }
        if fileVault == true { return "After a restart, \(mac) serves again once someone logs in." }
        return "After a restart, \(mac) serves again once someone logs in (or turn on automatic login)."
    }
}

/// After a Darkbloom update the worker's bytes change at the same path, so the saved setup's pinned digests no
/// longer match and both Macs would refuse their parts forever. The control leader's service notices it and sets
/// the cluster up again by itself (the same model re-planned, re-adopted and synced): no command for the person.
public enum ClusterOnboardingUpdate {
    public static let statusLine = "Updating the cluster setup after a Darkbloom update."
    /// How often the control leader compares the pinned worker digests with what each Mac runs.
    public static let checkEverySeconds: Double = 60
    /// After a failed attempt, the next one waits this long (the screen and log say why).
    public static let retryAfterFailureSeconds: Double = 600
    /// The longest the re-plan waits for both Macs to give back the stopped parts' memory (a part's forced exit
    /// releases it within 93 s): the placement must price the memory the model will have, not what the old parts hold.
    public static let releaseWaitSeconds: Double = 120
    /// While the two Macs do not answer with one build yet (they restart into an update seconds apart), the control
    /// leader asks again this soon instead of after `checkEverySeconds`.
    public static let recheckWhileWaitingSeconds: Double = 5

    /// Whether a member waits for the control leader's setup instead of starting its part: its worker no longer is
    /// the build its saved setup pins, so the part would refuse the installed inputs at once (R5-4: six failed
    /// starts after 0.10.8's restart). An unreadable worker is no reason: the part's own strict check says why.
    public static func memberWaitsForLeaderSetup(pinned: String, installed: String?) -> Bool {
        installed.map { $0 != pinned } ?? false
    }

    /// The member's log and status line while it waits for the leader's setup after an update.
    public static func memberWaitLine(version: String, otherVersion: String? = nil) -> String {
        "this Mac runs Darkbloom v\(version), but its saved setup is for an earlier build: "
            + "waiting for the other Mac's setup for v\(version) (the old setup is not started)"
            + splitClause(thisVersion: version, otherVersion: otherVersion)
    }

    /// The control leader's line while the two Macs don't answer with one build: with the other Mac's version, when it
    /// runs another, the Mac to update and the command.
    public static func leaderWaitLine(macs: String, model: String, thisVersion: String, otherVersion: String?) -> String {
        "Darkbloom changed on \(macs): waiting until both Macs answer with the same build to set the cluster up again for \(model)"
            + splitClause(thisVersion: thisVersion, otherVersion: otherVersion)
    }

    /// "; the other Mac runs v0.10.8, this Mac v0.10.9: run `darkbloom update` on the other Mac", or nothing when one
    /// version (or the other Mac's is unknown).
    static func splitClause(thisVersion: String, otherVersion: String?) -> String {
        guard let split = ClusterOnboardingVersionSplit.detect(thisVersion: thisVersion, otherVersion: otherVersion,
                                                               other: ClusterOnboardingMacName.other) else { return "" }
        return "; the other Mac runs v\(split.otherVersion), this Mac v\(split.thisVersion): run "
            + ClusterOnboardingCommand.named("`darkbloom update`") + " on " + split.olderMac
    }

    /// Both Macs' teardown summaries (`ClusterService.teardownLines`, one per Mac) say nothing is left running.
    public static func released(_ lines: [String]) -> Bool {
        lines.count >= 2 && lines.allSatisfy { $0.hasSuffix(": nothing left running") }
    }

    /// Whether the other Mac's report (its memory, as its plan tool sampled it) may price a plan: only when it was
    /// taken after this Mac last stopped the cluster's parts. One taken before still counts that Mac's old part,
    /// which the new one never shares memory with: the re-plan after an update stops both parts, waits for their
    /// memory (`released`), and must then ask the other Mac again. Without a stop any report does.
    public static func reportPricesPlan(reportedAt: Date?, partsStoppedAt: Date?) -> Bool {
        guard let partsStoppedAt else { return true }
        guard let reportedAt else { return false }
        return reportedAt > partsStoppedAt
    }

    /// The choice of `model` (its id; the screens show catalog names) that can start as listed: offered on these Macs,
    /// with nothing to copy or download first. A list planned again after the parts stopped (an update, or a model
    /// change of a serving cluster) is searched by the model, not by the earlier list's index.
    public static func servableIndex(of model: String, in choices: [ClusterOnboardingModelChoice]) -> Int? {
        choices.firstIndex { servable($0, model) }
    }

    /// As `servableIndex(of:in:)`, but the entry in `folder` comes first (`folders[i]` is entry i's folder): two
    /// folders can hold different artifacts under one model id, and a re-plan keeps the one that was chosen.
    public static func servableIndex(of model: String, folder: String, in choices: [ClusterOnboardingModelChoice],
                                     folders: [String]) -> Int? {
        choices.indices.first { folders.indices.contains($0) && folders[$0] == folder && servable(choices[$0], model) }
            ?? servableIndex(of: model, in: choices)
    }

    static func servable(_ choice: ClusterOnboardingModelChoice, _ model: String) -> Bool {
        (choice.modelID ?? choice.title) == model && choice.blocker == nil && choice.provision == nil
    }

    /// The members whose running worker differs from the digest the saved setup pins. A member whose current digest
    /// is not known now (it did not answer) is not counted: nothing is re-planned on a guess.
    public static func changed(pinned: [String: String], current: [String: String?]) -> [String] {
        pinned.keys.sorted().filter { member in
            guard let now = current[member] ?? nil else { return false }
            return now != pinned[member]
        }
    }

    /// Whether every pinned member answered and all run the same worker: only then can the model be planned again on
    /// both Macs. The two Macs restart into an update seconds apart; a plan made while one still runs the other build
    /// (or has not answered yet) fails and waits `retryAfterFailureSeconds`.
    public static func oneBuild(pinned: [String: String], current: [String: String?]) -> Bool {
        let digests = pinned.keys.map { current[$0] ?? nil }
        guard !digests.isEmpty, !digests.contains(nil) else { return false }
        return Set(digests).count == 1
    }
}

/// What the pairing reports while it runs.
public enum ClusterOnboardingPairEvent: Sendable, Equatable {
    case searching
    /// Nobody waits on the cable: this Mac listens and answers discovery.
    case waitingAsLeader
    /// A waiting Mac answered: this Mac dials it.
    case joining
    case connected
    case code(String, peer: [String])
    case peerDecided(Bool)
    case note(String)
}

public enum ClusterOnboardingPairResult: Sendable, Equatable {
    case paired(role: ClusterOnboardingRole, peerName: String)
    case failed([String])
}

public struct ClusterOnboardingLinkResult: Sendable, Equatable {
    public var ready: Bool
    public var exitCode: Int32
    /// More than one cable port is active and none is set up yet: the ports to choose from ("en5", "en6").
    public var ports: [String]
    /// macOS could not show its approval prompt here (an SSH session with no desktop): the owner-only script of the
    /// port's setup commands, which the onboarding runs with sudo in this terminal instead of sending the person to
    /// run it by hand. Nil otherwise.
    public var manualScript: String?
    public init(ready: Bool, exitCode: Int32, ports: [String] = [], manualScript: String? = nil) {
        self.ready = ready; self.exitCode = exitCode; self.ports = ports; self.manualScript = manualScript
    }
}

/// Whether macOS lets a program reach the cable's network (Local Network privacy), from a probe that sends one
/// datagram there: macOS shows its prompt the first time a program does, and refuses the program's traffic until the
/// person allows it.
public enum ClusterOnboardingLocalNetwork: String, Codable, Sendable, Equatable {
    case allowed
    /// Not allowed yet: macOS's prompt is up, or the person denied it.
    case blocked
    /// Nothing could be probed or read (no cable address yet, or a service that does not report it).
    case unknown
}

/// Who macOS names in its Local Network prompt: each is asked once per Mac.
public enum ClusterOnboardingLocalNetworkSubject: Sendable, Equatable {
    /// This command, as macOS attributes it: the terminal app it runs in, or sshd in an SSH session.
    case thisCommand
    /// This Mac's cluster service (Darkbloom), which carries the cluster's traffic once the onboarding ends.
    case service
}

public struct ClusterOnboardingReady: Codable, Sendable, Equatable {
    /// Where the serving API listens, as the screen that shows it names the Mac: "this Mac" or "the other Mac (<its
    /// hardware name>)" (`ClusterOnboardingMacName`).
    public var servedBy: String
    public var port: Int
    /// The plan's deployment in one line (`ClusterOnboardingDeployment.line`); nil when it is not known here.
    public var deployment: String?
    /// `ClusterLocalServing.notice` when rank 0 serves on its local API only (no coordinator with cluster support).
    public var notice: String? = nil
    /// The API also listens on the serving Mac's network addresses (local-only serving's default); nil from an older build.
    public var network: Bool? = nil
    /// Both Macs' members are registered and the pair is offered to the coordinator for pairing: the one line that
    /// says so (approval and its end). Such a pair has no local API; nil for every other way of serving.
    public var offered: String? = nil
    /// How the plan that runs splits the model, as the serving line marks it (`ClusterOnboardingDeployment.splitMarker`);
    /// nil when it is not known here, one Mac serves alone, or from an older build.
    public var split: String? = nil
    /// Both, me first with the pair's API on every address (`ClusterServingScope.answersOnEveryMac`): every other Mac
    /// answers on its own port too (`ClusterLocalRelay`), so each Mac's screen names its own API. Nil otherwise, and from
    /// an older build.
    public var relayed: Bool? = nil
    public init(servedBy: String, port: Int, deployment: String? = nil, notice: String? = nil, network: Bool? = nil,
                offered: String? = nil, split: String? = nil, relayed: Bool? = nil) {
        self.servedBy = servedBy; self.port = port; self.deployment = deployment; self.notice = notice; self.network = network
        self.offered = offered; self.split = split; self.relayed = relayed
    }

    /// The screens' one line (2026-11-03: less is better), "Serving Qwen3.8 27B (pipeline) at http://localhost:8000",
    /// with the split's marker the owner kept: when rank 0, which serves the API, is the other Mac the line says so
    /// (this Mac's own loopback serves nothing), and listening on the network too, it says that. Offered for pairing,
    /// the registered line, which is not serving: `pairServingLine` says Serving once the pair serves.
    public func summary(model: String) -> String {
        let name = ClusterOnboardingDeployment.shownMarker(split).map { "\(model) (\($0))" } ?? model
        if let offered { return "\(name): \(offered)" }
        return "Serving \(name) at http://localhost:\(port)" + (servesHere ? "" : " on the other Mac")
            + (network == true ? " and on the network" : "")
    }

    /// "API at http://localhost:8000 on this Mac": the serving API listens on loopback on the Mac that runs rank 0, so
    /// when that is the other Mac the line names it (this Mac's own loopback serves nothing). Listening on the network
    /// too, the line says so: other computers use that Mac's LAN or tailnet address with the same port.
    public var apiLine: String {
        let base = "API at http://localhost:\(port) on \(servedBy)"
        guard network == true else { return base }
        // Local only, the API on the other Mac: this Mac's own port passes to it (`ClusterLocalRelay`).
        return base + ", and at port \(port) of \(servesHere ? "its" : "that Mac's") LAN or tailnet address"
            + (servesHere ? "" : "; this Mac answers too (`\(ClusterOnboardingCommand.name) local` shows its address)")
    }

    private var servesHere: Bool { servedBy == ClusterOnboardingMacName.this }

    /// The reason the leading Mac's status gives for a pair set to serve through Darkbloom that serves on its local API:
    /// no cluster approval is attached, so the coordinator can't form the pair and it earns nothing. No window calls
    /// it serving or earning through Darkbloom (owner: never without proof; DevNet, 2026-11-04: a pair switched to
    /// Darkbloom kept a plan the coordinator can't register, and both windows said ✓ and "earning through Darkbloom").
    public static let notOfferedWords = "not offered to Darkbloom"

    /// That reason with why (`why`: the leading Mac's latest approval note, or nil when none is recorded).
    public static func notOfferedReason(_ why: String?) -> String {
        let prefix = "Not offered for pairing: "
        let said = why.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return notOfferedWords + " (" + (said.flatMap { $0.isEmpty ? nil : $0 } ?? "no cluster approval is attached to its setup") + ")"
    }

    /// Whether a status line's reason (`ClusterOnboardingNotServing.reason(inStatusLine:)`) is `notOfferedReason`'s.
    public static func isNotOffered(_ reason: String?) -> Bool { reason?.hasPrefix(notOfferedWords) == true }

    /// A status that says the pair isn't offered: its reason, then the lines under it; nil for any other status.
    public static func notOfferedLines(inStatus status: [String]) -> [String]? {
        guard let reason = status.first.flatMap(ClusterOnboardingNotServing.reason(inStatusLine:)), isNotOffered(reason) else { return nil }
        return [reason] + status.dropFirst()
    }

    /// A start's not-offered reason when the leading Mac's status doesn't give one: no approval attached, or a
    /// coordinator that can't take a cluster member (`ClusterLocalServing.notice`, by its words), then where the pair
    /// answers meanwhile and the test's time (`notServing`'s lines: the reason first).
    public func notOfferedLines(model: String, test: String?) -> [String] {
        let unsupported = notice.map { $0.hasSuffix("public serving needs a coordinator with cluster support") } == true
        return [Self.notOfferedReason(unsupported ? "the coordinator could not be reached or has no cluster support" : nil), meanwhileLine]
            + (test.map { ["Test response " + $0] } ?? [])
    }

    /// Under that status line: where the pair answers meanwhile, the serving Mac's local API only.
    public var meanwhileLine: String {
        "Meanwhile it answers only on the local API at http://localhost:\(port)" + (servesHere ? "" : " on the other Mac")
            + " (no Darkbloom traffic)."
    }

    /// The local-serving line as this screen shows it. The part that serves words it for its own Mac ("this Mac's
    /// API"); on the screen of the other Mac (a member's status, or a leader whose API moved) it is that Mac's API,
    /// which `apiLine` names just above.
    public var noticeLine: String? {
        guard let notice else { return nil }
        return servesHere ? notice : notice.replacingOccurrences(of: "this Mac's API", with: "that Mac's API")
    }

    /// A pair that serves through Darkbloom: "Serving Qwen3.8 27B through Darkbloom on both Macs (pipeline)". A pair
    /// offered for pairing says it only once the coordinator paired both Macs, both loaded the model and it answered its
    /// first request: registered alone is not serving.
    public func pairServingLine(model: String) -> String { "Serving \(model) through Darkbloom on both Macs" + splitMarker }

    /// The ending's one line once the pair serves (owner, 2026-11-11: "Ending screen is too verbose, visually standout,
    /// just serving successfully"): "Serving <model> on both Macs", through Darkbloom implied; served locally, where:
    /// ", on your local API at http://localhost:<port>". The rest is `darkbloom status`'s.
    public func endingTitle(model: String, scope: ClusterServingScope) -> String {
        guard offered == nil, servesLocallyOnly(scope: scope) else { return Self.endingTitle(model: model) }
        return Self.endingTitle(model: model) + ", " + Self.localAPIWords(port: String(port), otherMac: !servesHere)
    }

    public static func endingTitle(model: String) -> String { "Serving \(model) on both Macs" }

    static func localAPIWords(port: String, otherMac: Bool) -> String {
        "on your local API at http://localhost:\(port)" + (otherMac ? " on the other Mac" : "")
    }

    /// The same line from the leading Mac's status line ("Serving … through Darkbloom on both Macs (pipeline).", or
    /// locally "Serving … (pipeline) at http://localhost:8000 (local only)."), so the Mac that joined ends the same way;
    /// nil for any other line.
    public static func endingTitle(inStatusLine line: String) -> String? {
        guard line.hasPrefix("Serving ") else { return nil }
        let text = String((line.hasSuffix(".") ? String(line.dropLast()) : line).dropFirst("Serving ".count))
        if let through = text.range(of: " through Darkbloom on both Macs") { return endingTitle(model: String(text[..<through.lowerBound])) }
        // Locally: the summary with `ClusterOnboardingDriver.servesWords`' " (local only)" (an earlier build's other words: nil).
        guard text.hasSuffix(" (local only)"), let at = text.range(of: " at http://localhost:") else { return nil }
        var model = String(text[..<at.lowerBound])
        for marker in ClusterOnboardingDeployment.knownSplitMarkers where model.hasSuffix(" (\(marker))") { model = String(model.dropLast(marker.count + 3)) }
        let rest = text[at.upperBound...]
        let port = String(rest.prefix { $0.isNumber })
        guard !port.isEmpty else { return nil }
        return endingTitle(model: model) + ", " + localAPIWords(port: port, otherMac: rest.contains(" on the other Mac"))
    }

    /// Serving on the local API only: asked for, or a coordinator without cluster support (its local-serving notice;
    /// the registered member's notice is not one).
    func servesLocallyOnly(scope: ClusterServingScope) -> Bool {
        scope.isLocalOnly || notice.map { !$0.hasPrefix(Self.registeredNotice) } == true
    }

    /// " (pipeline)" after the outcome's title; empty when the split is unknown or not shown plainly.
    private var splitMarker: String { ClusterOnboardingDeployment.shownMarker(split).map { " (\($0))" } ?? "" }

    /// In the leading Mac's status line while its start still asks Darkbloom whether to offer the pair (the record's
    /// `registrationPendingPID`, set by the screen's start and cleared once `register` decides): the start is not over,
    /// so the Mac that joined keeps following (`ClusterOnboardingDriver.followed`) and never shows an early ✓.
    public static let offerPendingWords = "checking with Darkbloom before it offers the pair"

    /// That status line: a start, not its outcome, so no screen shows it as ✓ (nor its API, which the registration
    /// may stop).
    public static func offerPendingLine(model: String) -> String {
        "Starting \(model): loaded on both Macs; \(offerPendingWords)."
    }

    /// Under the leading Mac's not-serving line once its start's test request failed (`ClusterSetupRecord
    /// .startTestFailure`): the start's outcome, so the Mac that joined ends with the same ✗.
    public static let testFailedNote = "Setup saved, but the test failed: the pair was not offered to Darkbloom."

    /// The same under a local-only start's not-serving line (a local start offers nothing to Darkbloom).
    public static let localTestFailedNote = "Setup saved, but the test failed."

    /// Under the not-serving line when the leading Mac's latest test was not a start's and failed
    /// (`ClusterSetupRecord.lastTestFailure`): no start's "Setup saved" or "not offered", which would not be true of it.
    public static let lastTestFailedNote = "The last test from the leading Mac failed."

    /// Whether `line` is a failed test's note under the not-serving line (a start's, or the latest test's).
    public static func isTestFailedNote(_ line: String) -> Bool {
        line == testFailedNote || line == localTestFailedNote || line == lastTestFailedNote
    }

    /// The leading Mac's status line while a local-only start's test is not answered yet: a start, not its outcome (no
    /// ✓, and never "checking with Darkbloom", which a local start doesn't do).
    public static func testingLine(model: String) -> String { "Starting \(model): loaded on both Macs; the leading Mac is testing it." }

    /// Under the serving line once the start's test passed (`ClusterSetupRecord.startTestPassed`): the Mac that joined
    /// ends with the same ✓ and this time, without a test of its own.
    public static func startTestPassedLine(_ passed: String) -> String {
        "Test response" + (passed.isEmpty ? "" : " " + passed) + startTestPassedMarker
    }
    public static let startTestPassedMarker = " (the leading Mac's test)"

    /// How the line of a pair registered with the coordinator as a cluster member starts (`ClusterLocalServing`). It is
    /// a log line and a prefix matcher, never shown: the screen says `offeredLine(model:)`.
    public static let registeredNotice = "Registered with the coordinator as a cluster member"

    /// What the screen says once the pair is registered (owner, 2026-11-04: the approval line read as "accepted").
    public static func offeredLine(model: String) -> String {
        "Offered to Darkbloom as a pair for \(model); waiting for Darkbloom to accept this pair\u{2026}"
    }

    /// Said instead of the test request when the pair is offered for pairing (and the answer of `t` then).
    public static let offeredTestLine = "This pair has no local API while it is offered for pairing: requests from your own account reach it through Darkbloom."

    /// The deployment line, then where the API is, then (serving locally only) the plain local-serving line. Offered
    /// for pairing: the deployment line, then the offered line (there is no local API).
    public func lines(model: String) -> [String] {
        let first = deployment ?? "Serving \(model) across both Macs"
        if let offered { return [first, offered] }
        return [first, apiLine] + (noticeLine.map { [$0] } ?? [])
    }
}

/// The leader keeps its members in step: its cluster service asks each member
/// for its status every `dueEverySeconds` and sends what differs from the
/// leader's own record (serve with the model, or stop). A member that missed a
/// start or a stop (asleep, restarting, cable out) so follows the leader once
/// it answers again, with nobody running a command.
public enum ClusterOnboardingSync {
    public enum Action: Sendable, Equatable {
        case none
        case serve(String?)
        case stop
    }

    public static let dueEverySeconds: Double = 15

    /// `memberServing` nil: the member did not answer (asked again at the next check). `memberLocalOnly` or
    /// `memberLocalAPI` nil: the member's build does not report that part of the serving scope, so it isn't compared.
    public static func action(leaderServing: Bool, leaderModel: String?, memberServing: Bool?, memberModel: String?,
                              leaderLocalOnly: Bool = false, memberLocalOnly: Bool? = nil,
                              leaderLocalAPI: Bool = false, memberLocalAPI: Bool? = nil) -> Action {
        guard let memberServing else { return .none }
        if leaderServing {
            let scopeAgrees = (memberLocalOnly.map { $0 == leaderLocalOnly } ?? true)
                && (memberLocalAPI.map { $0 == leaderLocalAPI } ?? true)
            return memberServing && memberModel == leaderModel && scopeAgrees ? .none : .serve(leaderModel)
        }
        return memberServing ? .stop : .none
    }
}

/// The two Macs of a pair run different Darkbloom versions (one updated alone): a cause that never clears by itself
/// until the older Mac updates, so the start ends at once with it named, before single-Mac serving or any part end.
/// `other` is the other Mac as the screens name it ("the other Mac (Apple M4 Max, 128 GB)"); commands are named for the
/// running build (`ClusterOnboardingCommand`).
public struct ClusterOnboardingVersionSplit: Sendable, Equatable {
    public var thisVersion: String
    public var otherVersion: String
    public var other: String

    /// A split when both versions are known, numeric, and differ; nil otherwise (one version, or the other Mac's unknown:
    /// an older peer without a supervisor publishes none).
    public static func detect(thisVersion: String?, otherVersion: String?, other: String) -> ClusterOnboardingVersionSplit? {
        guard let thisVersion, let otherVersion, older(thisVersion, otherVersion) != nil else { return nil }
        return .init(thisVersion: thisVersion, otherVersion: otherVersion, other: other)
    }

    /// Whether `a` is older than `b`; nil when equal or not numeric.
    static func older(_ a: String, _ b: String) -> Bool? {
        func numbers(_ text: String) -> [Int]? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let left = numbers(a), let right = numbers(b) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let (x, y) = (index < left.count ? left[index] : 0, index < right.count ? right[index] : 0)
            if x != y { return x < y }
        }
        return nil
    }

    public var behindHere: Bool { Self.older(thisVersion, otherVersion) == true }
    public var newer: String { behindHere ? otherVersion : thisVersion }
    public var older: String { behindHere ? thisVersion : otherVersion }
    /// The Mac to run the update on, mid-sentence.
    public var olderMac: String { behindHere ? ClusterOnboardingMacName.this : other }

    /// The ✗ title, without its final period.
    public var title: String {
        "The two Macs run different Darkbloom versions: \(ClusterOnboardingMacName.sentence(other)) runs \(otherVersion), "
            + "this Mac runs \(thisVersion)"
    }

    /// What to do, one line each.
    public var remedies: [String] {
        ["On \(olderMac), run `darkbloom update`; the pair starts once both Macs run \(newer).",
         "Check with `darkbloom --version` on both Macs."].map(ClusterOnboardingCommand.named)
    }

    /// The reason in the status line, the same on both Macs (the joining Mac shows the leading Mac's), so it names the
    /// versions and the command, not "this Mac" (`ClusterPairSummary` names the Mac per window).
    public var reason: String {
        "the two Macs run different Darkbloom versions, \(newer) and \(older): run "
            + ClusterOnboardingCommand.named("`darkbloom update`") + " on the Mac with \(older)"
    }

    public static let reasonMarker = "the two Macs run different Darkbloom versions"

    /// The next step for `reason` as read on a Mac running `thisVersion`: the Mac to update, named, and the command.
    public static func next(reason: String, thisVersion: String, other: String, cli: String) -> String? {
        guard reason.contains(reasonMarker),
              let colon = reason.range(of: ", ", range: reason.range(of: reasonMarker)!.upperBound..<reason.endIndex)
        else { return nil }
        let tail = reason[colon.upperBound...]
        guard let and = tail.range(of: " and "), let end = tail.range(of: ":") else { return nil }
        let newer = String(tail[..<and.lowerBound]), older = String(tail[and.upperBound..<end.lowerBound])
        let mac = thisVersion == older ? ClusterOnboardingMacName.this : thisVersion == newer ? other : "the Mac with \(older)"
        return "On \(mac), run `\(cli) update`; then check that `\(cli) --version` shows \(newer) on both Macs."
    }

    public var failure: ClusterOnboardingFailure {
        var failure = ClusterOnboardingFailure([title + "."] + remedies)
        failure.versionSplit = self
        return failure
    }
}

/// A step that failed, in words for the screen.
public struct ClusterOnboardingFailure: Error, Sendable, Equatable {
    public var lines: [String]
    /// The two Macs run different versions (`ClusterOnboardingVersionSplit`): no Retry until the older Mac updates.
    public var versionSplit: ClusterOnboardingVersionSplit?
    /// The pair was stopped from anywhere while the screen waited (`ClusterOnboardingStopped`): the wait just ends.
    public var stopped = false
    public static var stopped: ClusterOnboardingFailure {
        var failure = ClusterOnboardingFailure([ClusterOnboardingStopped.line])
        failure.stopped = true
        return failure
    }
    /// Single-Mac serving that blocks the pair (`ClusterOnboardingSoloServing`): a cause that never clears by itself, so
    /// the start offers to stop it instead of a Retry. Empty for any other failure.
    public var soloServing: [ClusterOnboardingSoloServing] = []
    /// Set only by a pair stop that stopped this Mac's serving and then could not reach the other Mac: what the
    /// other Mac did ("The other Mac (…) did not answer (…)"). `cluster stop --service` then still stops this Mac.
    public var otherMacUnanswered: String?
    public init(_ lines: [String], otherMacUnanswered: String? = nil) {
        self.lines = lines
        self.otherMacUnanswered = otherMacUnanswered
    }
    public init(_ line: String) { self.lines = [line] }
}

/// What a model copy or download reports while it runs.
public enum ClusterOnboardingProgress: Sendable {
    /// A line for the record. It ends the live report.
    case line(String)
    /// How far it is, laid out for a width (nil: the plain form, no limit). Each report replaces the last: a live
    /// terminal redraws it in place, and a transcript says only the reports marked `logged` (the first, then about
    /// one per 10% and 30 s), so a long download leaves a few lines rather than one a second.
    case live(@Sendable (_ width: Int?) -> String, logged: Bool)
}

/// Everything the onboarding does, as blocking calls.
public struct ClusterOnboardingOperations: Sendable {
    public var resume: @Sendable () -> ClusterOnboardingResume
    /// RDMA, cable, isolation (one macOS approval when needed) and GID; says each observation as it is made.
    public var checkLink: @Sendable (_ say: @escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult
    /// Finds a Mac waiting on the cable and joins it, or waits there as the leader-to-be. Records the role.
    public var pair: @Sendable (_ events: @escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult
    public var answerCode: @Sendable (_ accept: Bool) -> Void
    /// Starts this Mac's cluster service unless it runs (a failure's lines say why it did not).
    public var ensureService: @Sendable () -> Result<Void, ClusterOnboardingFailure>
    /// Every Mac of the cluster, the leader first, read over the link control channel; `waiting` says each new reason
    /// the other Mac has not answered yet while it keeps asking.
    public var reachMembers: @Sendable (_ waiting: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
    public var planModels: @Sendable () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>
    /// Saves this Mac's setup for the choice and syncs every member's to it over the link.
    public var adopt: @Sendable (_ index: Int) -> Result<[String], ClusterOnboardingFailure>
    /// Asks every Mac's service to serve (remote start of the members).
    public var serve: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    public var waitReady: @Sendable (_ progress: @escaping @Sendable (String) -> Void) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure>
    public var testRequest: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// The cluster as it is now, for a leader that opens `darkbloom cluster` again.
    public var status: @Sendable () -> [String]
    public var stop: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// Puts the chosen model on every Mac that lacks it (choice `index`): copied over the cable from a Mac that has
    /// it, or from the catalog when `download` (or when no Mac has it); reports its progress as it goes.
    public var provision: @Sendable (_ index: Int, _ download: Bool, _ progress: @escaping @Sendable (ClusterOnboardingProgress) -> Void) -> Result<[String], ClusterOnboardingFailure>
    /// Each Mac's verify-teardown summary (after a stop: no cluster process, wired memory at baseline).
    public var verifyTeardown: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// The cable port the person chose when more than one is active; the next `checkLink` sets that one up.
    public var useLinkPort: @Sendable (String) -> Void
    /// Right before the start: nil when choice `index` fits in the Macs' free memory now, else what frees it.
    public var recheckFit: @Sendable (_ index: Int) -> String?
    /// Saves a redacted diagnostics file; its lines say where.
    public var saveDiagnostics: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// DEVELOPER ONLY: one loud line for the setup screen when a developer setting overrides the planner (a forced
    /// deployment mode, `ClusterForcedModeSetting`); nil, the default and every user's case, says nothing.
    public var developerNotice: @Sendable () -> String?
    /// Saves how the cluster serves on the control leader (kept until changed). While it serves, the leading Mac's
    /// part starts again in the new scope by itself; its lines say so.
    public var setScope: @Sendable (_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure>
    /// After the Test stage passed: registers the pair with the coordinator as a cluster member when the coordinator
    /// serves a cluster approval for this pair's installed app and model; its lines (none: nothing changed).
    public var register: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// Local Network access on this Mac for `subject`: this command probed now, or the cluster service as it last
    /// reported its own probe. The first probe is what makes macOS ask.
    public var localNetwork: @Sendable (_ subject: ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork
    /// The app macOS names when it asks about this command: the terminal app, or sshd in an SSH session.
    public var commandApp: @Sendable () -> String
    /// Runs the owner-only link `script` with sudo in this terminal, where macOS could not show its own prompt: the
    /// person types this Mac's password into sudo, never into Darkbloom. True when it exited 0.
    public var runAsAdministrator: @Sendable (_ script: String) -> Bool
    /// This Mac's cluster service keeps running once this window closes (a login agent of the signed app). False for a
    /// service for this session only (a development build, or a login agent launchd did not take), which lives only as
    /// long as the session that started it.
    public var serviceOutlivesWindow: @Sendable () -> Bool
    /// This command runs over SSH: macOS shows its prompts on this Mac's own screen, not in this terminal.
    public var remote: @Sendable () -> Bool
    /// This Mac's name as System Settings shows it, said on its own screen beside the part it plays (two identical
    /// Macs read the same hardware); nil when unknown.
    public var thisMacName: @Sendable () -> String?
    /// The other Mac answers over the cable with the saved pairing (one short request).
    public var otherMacAnswers: @Sendable () -> Bool
    /// Forgets this Mac's saved pairing as `darkbloom cluster pair --forget` does (a leader tells its member first), so
    /// the Macs can pair again; its lines say what was done.
    public var unpair: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// A pair offered for pairing (both members registered): waits, bounded, until the coordinator committed it and
    /// both Macs loaded their share and the pair answered its first request; its line is that request's time ("in
    /// 0.84 s"). A failure's first line says why it does not serve, in plain words (`ClusterOnboardingNotServing`).
    public var pairServing: @Sendable (_ progress: @escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure>
    /// The Macs of the cluster without a Darkbloom login, as this screen names them ("this Mac", "the other Mac
    /// (…)"): the coordinator pairs only logged-in Macs. Empty when every Mac is logged in, or it cannot be told.
    public var missingLogins: @Sendable () -> [String]
    /// Runs `darkbloom login` in this terminal (the person approves it in the browser); true when it ended logged in.
    public var login: @Sendable () -> Bool
    /// The mode the person chose for choice `index` (a `ClusterGenerationMode` raw value); the next adopt of that
    /// choice places it.
    public var useMode: @Sendable (_ index: Int, _ mode: String) -> Void
    /// How the Mac that joined follows the start (`ClusterOnboardingDriver.followStart`).
    public var followTiming = ClusterOnboardingFollowTiming()
    /// The leading Mac's status with its published setup step (`ClusterControlReply.step`), as the Mac that joined
    /// follows it; nil: `status` alone. Not in `init`: only the live operations set it.
    public var leaderStatus: (@Sendable () -> ClusterOnboardingLeaderStatus)? = nil
    /// Records the leading Mac's current setup step where its status publishes it (nil clears it). Not in `init`.
    public var publishStep: @Sendable (ClusterOnboardingLeaderStep?) -> Void = { _ in }
    /// This Mac's Darkbloom version, for the different-builds ✗; nil when unknown. Not in `init`.
    public var thisVersion: String? = nil
    /// How long the setup waits for Allow on a Local Network prompt before its ✗ (`allowLocalNetwork`). Not in `init`.
    public var localNetworkWaitSeconds: Double = 600
    /// How long the pairing waits without finding the other Mac before it says what to check (`otherMacNotFoundLines`).
    public var pairHintSeconds: Double = 25
    /// Marks the screen's start (`finishStart` with `registers`, local only or through Darkbloom) until its test is
    /// answered, and through Darkbloom until the coordinator decides, so the leading Mac's status says it is not over and
    /// then publishes its outcome (`OnboardingLive.markRegistrationPending`). `serve` alone never marks. Not in `init`:
    /// only the live operations set it.
    public var markRegistrationPending: @Sendable () -> Void = {}
    /// The way of serving the coming plan and adopt are for (`chooseAndServe`): the list is planned for the scope the
    /// start names, and a start whose scope changes before it adopts is planned again (`OnboardingLive.usePlanningScope`).
    /// Not in `init`: only the live operations set it.
    public var planScope: @Sendable (ClusterServingScope) -> Void = { _ in }
    /// The leading Mac's status when it says the pair is set to serve through Darkbloom but isn't offered: its reason,
    /// then the lines under it (`ClusterOnboardingReady.notOfferedLines(inStatus:)`); nil for any other status. A start
    /// through Darkbloom then ends with that ✗, as the other Mac's window does from the same status. Not in `init`: only
    /// the live operations set it.
    public var notOfferedStatus: @Sendable () -> [String]? = { nil }
    /// Single-Mac serving on either Mac (this Mac's provider instance lock; the other Mac's status), read right before
    /// the pair's parts start: empty when none runs or it can't be told. Not in `init`: only the live operations set it.
    public var soloServing: @Sendable () -> [ClusterOnboardingSoloServing] = { [] }
    /// The two Macs' versions when they differ (this Mac's; the other Mac's status), read before the parts start, during
    /// the wait and before a Retry: nil when one version or unknown. Not in `init`: only the live operations set it.
    public var versionSplit: @Sendable () -> ClusterOnboardingVersionSplit? = { nil }
    /// Marks (true) or clears the leading Mac's start as stopped at the single-Mac block (`ClusterSetupRecord.soloBlockedAt`).
    /// Not in `init`: only the live operations set it.
    public var markSoloBlocked: @Sendable (Bool) -> Void = { _ in }
    /// Stops single-Mac serving on each Mac that runs it (`darkbloom stop --solo` there), asked only after the person
    /// chose it; its lines say what was stopped. Not in `init`: only the live operations set it.
    public var stopSoloServing: @Sendable () -> Result<[String], ClusterOnboardingFailure> = {
        .failure(.init("This build cannot stop single-Mac serving from here: run `darkbloom stop --solo` on each Mac named."))
    }
    /// Publishes how far the start is (`ClusterOnboardingStartProgress`) in the leading Mac's status, so the Mac that
    /// joined shows the same step; nil clears it. Not in `init`: only the live operations set it.
    public var publishStart: @Sendable (ClusterOnboardingStartProgress?) -> Void = { _ in }
    /// The rank this Mac's part runs in the saved setup (each screen names its own part "This Mac"); nil when unknown.
    /// Not in `init`: only the live operations set it.
    public var thisRank: @Sendable () -> Int? = { nil }
    /// The pair serves through Darkbloom (its start ends with the coordinator's step), not locally only. Not in
    /// `init`: only the live operations set it.
    public var servesThroughDarkbloom: @Sendable () -> Bool = { true }
    /// This screen serves the pair through Darkbloom with the leading Mac's local API beside it, Darkbloom serving on
    /// while the owner uses that API (`ClusterServingChoice.both`), with no question (owner, 2026-11-11). False: the
    /// pair serves as its record says, and the list's line switches between Darkbloom and local only, as before. Not
    /// in `init`: plain `darkbloom cluster` in a terminal sets it (never `darkbloom cluster local`).
    public var servesBoth: @Sendable () -> Bool = { false }
    /// Saves how the pair serves as the leading Mac's `[local]` (`ClusterServingChoice`); its lines say a save that
    /// failed. Not in `init`.
    public var saveServingChoice: @Sendable (ClusterServingChoice) -> Result<[String], ClusterOnboardingFailure> = { _ in .success([]) }

    public init(resume: @escaping @Sendable () -> ClusterOnboardingResume,
                checkLink: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult,
                pair: @escaping @Sendable (@escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult,
                answerCode: @escaping @Sendable (Bool) -> Void,
                ensureService: @escaping @Sendable () -> Result<Void, ClusterOnboardingFailure>,
                reachMembers: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>,
                planModels: @escaping @Sendable () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>,
                adopt: @escaping @Sendable (Int) -> Result<[String], ClusterOnboardingFailure>,
                serve: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                waitReady: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure>,
                testRequest: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                status: @escaping @Sendable () -> [String],
                stop: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                provision: @escaping @Sendable (Int, Bool, @escaping @Sendable (ClusterOnboardingProgress) -> Void) -> Result<[String], ClusterOnboardingFailure>
                    = { _, _, _ in .success([]) },
                verifyTeardown: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .success([]) },
                useLinkPort: @escaping @Sendable (String) -> Void = { _ in },
                recheckFit: @escaping @Sendable (Int) -> String? = { _ in nil },
                saveDiagnostics: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .failure(.init("No diagnostics file can be saved here.")) },
                developerNotice: @escaping @Sendable () -> String? = { nil },
                setScope: @escaping @Sendable (ClusterServingScope) -> Result<[String], ClusterOnboardingFailure>
                    = { _ in .failure(.init("This build cannot change how the cluster serves.")) },
                register: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .success([]) },
                localNetwork: @escaping @Sendable (ClusterOnboardingLocalNetworkSubject) -> ClusterOnboardingLocalNetwork = { _ in .allowed },
                commandApp: @escaping @Sendable () -> String = { "Terminal" },
                runAsAdministrator: @escaping @Sendable (String) -> Bool = { _ in false },
                serviceOutlivesWindow: @escaping @Sendable () -> Bool = { true },
                remote: @escaping @Sendable () -> Bool = { false },
                thisMacName: @escaping @Sendable () -> String? = { nil },
                otherMacAnswers: @escaping @Sendable () -> Bool = { true },
                unpair: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>
                    = { .failure(.init("This build cannot pair again from here.")) },
                pairServing: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure>
                    = { _ in .failure(.init("This build cannot tell whether the coordinator formed the pair.")) },
                missingLogins: @escaping @Sendable () -> [String] = { [] },
                login: @escaping @Sendable () -> Bool = { false },
                useMode: @escaping @Sendable (Int, String) -> Void = { _, _ in }) {
        self.resume = resume; self.checkLink = checkLink; self.pair = pair; self.answerCode = answerCode
        self.ensureService = ensureService; self.reachMembers = reachMembers; self.planModels = planModels
        self.adopt = adopt; self.serve = serve; self.waitReady = waitReady; self.testRequest = testRequest
        self.status = status; self.stop = stop; self.provision = provision; self.verifyTeardown = verifyTeardown
        self.useLinkPort = useLinkPort; self.recheckFit = recheckFit; self.saveDiagnostics = saveDiagnostics
        self.developerNotice = developerNotice; self.setScope = setScope; self.register = register
        self.localNetwork = localNetwork; self.commandApp = commandApp; self.runAsAdministrator = runAsAdministrator
        self.serviceOutlivesWindow = serviceOutlivesWindow; self.remote = remote; self.thisMacName = thisMacName
        self.otherMacAnswers = otherMacAnswers; self.unpair = unpair
        self.pairServing = pairServing; self.missingLogins = missingLogins; self.login = login
        self.useMode = useMode
    }
}

/// The discovery and pairing half as a state machine: which role the run is
/// taking and what to say, from the pairing's own progress. A Mac that found
/// nobody waiting listens and leads; a Mac that dials a waiting Mac joins it.
/// When two Macs started waiting at once, the pairing's own rule picks the one
/// that keeps listening (it leads); the other says so and joins.
public struct ClusterOnboardingPairing: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case searching, waiting, joining, confirming(String), confirmed, done }
    public private(set) var phase: Phase = .searching
    /// The role this run is heading for; nil until it listens or dials.
    public private(set) var role: ClusterOnboardingRole?
    private var announcedWait = false
    /// The other Mac has answered the code.
    private var peerAnswered = false
    /// The code is on screen and waits for its answer (`codeAnswers`).
    public private(set) var asking: String?

    /// `darkbloom cluster local` started the pairing: the other Mac is told the same command.
    public let localOnly: Bool

    public init(localOnly: Bool = false) { self.localOnly = localOnly }

    /// The one thing to do on the other Mac while this one waits: said last, set apart and stressed (`console.callout`),
    /// so it is the line the person reads (owner, 2026-11-11: "Make it more forward bold run 'darkbloom cluster' on the
    /// other mac").
    public static func otherMacCallout(localOnly: Bool = false) -> String {
        "\u{2192} Now run `darkbloom cluster\(localOnly ? " local" : "")` on the other Mac"
    }
    public static let otherMacLine = otherMacCallout()
    public var otherMacLine: String { Self.otherMacCallout(localOnly: localOnly) }

    /// Said once while the pairing still has not found the other Mac (2026-11-04, the candidate on pair 2: a firewall
    /// that drops the discovery probe left both Macs waiting with no hint); the wait goes on. The firewall lists the app
    /// by its own name (`ClusterOnboardingCommand.app`), as Local Network does.
    public static var otherMacNotFoundLines: [String] { [
        "The other Mac isn't found yet. Check that:",
        "· the other Mac shows this screen too (run `darkbloom cluster` there);",
        "· macOS's firewall lets \(ClusterOnboardingCommand.app) in on both Macs (System Settings → Network → Firewall);",
        "· or pair directly: press q, run `darkbloom cluster pair --listen` on this Mac (it prints its cable address),",
        "  then `darkbloom cluster pair --connect <that address>` on the other Mac, and `darkbloom cluster` on both again."] }

    /// The question after the code, and its two answers (a menu: arrows and enter, or 1 and 2). Each Mac answers for
    /// itself: a "yes" passed on from the other Mac could come from a Mac in between.
    public static let codeQuestion = "Same on the other Mac?"
    public static let codeAnswers = ["Yes", "No"]
    /// Said once this Mac answered yes and the other Mac has not answered yet: the next thing to do, kept on screen
    /// (a plain console shows no live line).
    public static let otherMacAnswerLine = "Now confirm on the other Mac."

    /// What the live line says while the pairing runs: the action again while this Mac waits for the other one.
    public var working: String? {
        switch phase {
        case .searching: return "Looking for the other Mac on the cable"
        case .waiting: return "Waiting for the other Mac (run `darkbloom cluster\(localOnly ? " local" : "")` there; q cancels)"
        case .joining: return "Exchanging keys with the other Mac"
        case .confirmed: return "Waiting for the other Mac to confirm the code"
        case .confirming, .done: return nil
        }
    }

    /// What the pairing's progress says on screen: the action on the other Mac while this one waits, the code with its
    /// question, and a code the other Mac declined. Finding, joining and its confirmation stay on the live line.
    public mutating func handle(_ event: ClusterOnboardingPairEvent) -> [String] {
        switch event {
        case .searching:
            phase = .searching
            return []
        case .waitingAsLeader:
            phase = .waiting
            role = .leader
            guard !announcedWait else { return [] }
            announcedWait = true
            return [otherMacLine]
        case .joining:
            phase = .joining
            role = .member
            return []
        case .connected:
            return []
        case .code(let code, _):
            let shown = Self.spaced(code)
            phase = .confirming(shown)
            asking = shown
            return ["Code \(shown). " + Self.codeQuestion]
        case .peerDecided(let accepted):
            peerAnswered = true
            return accepted ? [] : ["The other Mac declined the code."]
        case .note(let text):
            return [text]
        }
    }

    /// The person's answer to the code on screen.
    public mutating func answered(_ accept: Bool) -> [String] {
        guard asking != nil else { return [] }
        asking = nil
        phase = .confirmed
        guard accept else { return ["Declined: nothing paired."] }
        return peerAnswered ? [] : [Self.otherMacAnswerLine]
    }

    /// `named`: this Mac's own name, said beside "this Mac" where it leads (`ClusterOnboardingDriver.thisMac`).
    public mutating func finished(_ result: ClusterOnboardingPairResult, named: String? = nil) -> [String] {
        phase = .done
        asking = nil
        switch result {
        case .paired(let role, _):
            self.role = role
            switch role {
            case .member: return ["\(ClusterOnboardingDriver.done) Paired. The other Mac leads."]
            case .leader: return ["\(ClusterOnboardingDriver.done) Paired. \(ClusterOnboardingDriver.thisMac(named: named)) leads."]
            }
        case .failed(let lines):
            return ["Not paired."] + lines + ["Run `darkbloom cluster` again."]
        }
    }

    /// "123456" -> "123 456".
    static func spaced(_ code: String) -> String {
        code.count == 6 && !code.contains(" ") ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// The keys and lines the onboarding reads, and where it writes.
public protocol ClusterOnboardingConsole: AnyObject {
    func say(_ line: String)
    /// One line whose middle part is stressed where the console can (bold in a colour terminal); the same plain text
    /// elsewhere.
    func sayStressed(_ lead: String, _ stressed: String, _ tail: String)
    /// The window's width in columns; nil when not known.
    var width: Int? { get }
    func heading(_ title: String)
    /// The setup's opening: its name and the steps ahead.
    func banner(_ title: String, _ subtitle: String)
    /// Work that is still running, said again while it runs; the next said
    /// line replaces it. A transcript shows nothing extra.
    func working(_ text: String)
    /// Live work of several rows (one per Mac), replaced as `working` is.
    func workingRows(_ rows: [String])
    /// The setup's outcome as its own block (`ClusterOnboardingDriver.resultRule` above and below).
    func result(_ succeeded: Bool, _ title: String, _ lines: [String])
    /// The work said by `working` finished.
    func settle()
    /// A copy's or download's live report (`ClusterOnboardingProgress.live`): redrawn in place where `working`
    /// lines show; otherwise said only when `logged`.
    func progress(_ text: (_ width: Int?) -> String, logged: Bool)
    /// One key, or nil when `milliseconds` passed with none. "\r" is enter; a lone escape is "\u{1B}"; a key that
    /// sends a sequence (an arrow) reads as none, so it never stops a wait.
    func key(milliseconds: Int) -> Character?
    /// One of `options` (their order), as `darkbloom start` picks models: ↑↓ and enter where the console can redraw,
    /// else a number, enter for `selected`, or an option's first letter. Nil when the person cancelled (q or escape),
    /// the input closed, or `abandon` turned true while it waited (asked between keys).
    func choose(_ options: [String], selected: Int, abandon: () -> Bool) -> Int?
    /// `choose` with options that fit the window: each is asked for its text again at every redraw with the room a
    /// row has then (nil: no limit, the whole line), so a resized window redraws them for its width. A text may hold
    /// "\n" between the rows of one option.
    func chooseFitting(_ options: [(_ room: Int?) -> String], selected: Int, abandon: () -> Bool) -> Int?
    /// Runs `body` with the terminal in its ordinary mode, nothing live on screen (sudo asks for a password there).
    func suspended<T>(_ body: () -> T) -> T
    /// The one thing to do on the other Mac (`ClusterOnboardingPairing.otherMacCallout`), set apart and stressed.
    func callout(_ line: String)
    /// The input is closed: nothing more can be asked.
    var closed: Bool { get }
    /// The end of a run that reached its outcome: "Press Enter to exit." and the wait for Enter, q or Esc, only where a
    /// person is at an interactive terminal; a plain transcript, a pipe or an agent run never waits.
    func waitForExit()
    /// The room a live row has (the window's columns less its indent and marks); nil where no live rows show (a plain
    /// transcript), which says each change once instead.
    var liveWidth: Int? { get }
}

public extension ClusterOnboardingConsole {
    func sayStressed(_ lead: String, _ stressed: String, _ tail: String) { say(lead + stressed + tail) }
    var width: Int? { nil }

    var liveWidth: Int? { nil }
    /// The setup's outcome as its own block: a blank line, a rule, ✓ or ✗ with what serves (or why nothing does),
    /// its details, a rule.
    func result(_ succeeded: Bool, _ title: String, _ lines: [String]) {
        say("")
        say(ClusterOnboardingDriver.resultRule)
        say((succeeded ? ClusterOnboardingDriver.done : ClusterOnboardingDriver.failed) + " " + title)
        for line in lines { say("  " + line) }
        say(ClusterOnboardingDriver.resultRule)
    }

    /// Live work of several rows (one per Mac); a console with one live row shows the first.
    func workingRows(_ rows: [String]) { working(rows.first ?? "") }

    /// Scrollable sections also work in transcripts and non-terminal consoles.
    func heading(_ title: String) { say(""); say(title) }
    func banner(_ title: String, _ subtitle: String) { heading(title); if !subtitle.isEmpty { say(subtitle) } }
    func working(_ text: String) {}
    func settle() {}
    func progress(_ text: (_ width: Int?) -> String, logged: Bool) { if logged { say("  " + text(nil)) } }
    func suspended<T>(_ body: () -> T) -> T { body() }
    func waitForExit() {}
    /// The one thing to do on the other Mac, set apart (blank lines around it) and, where the console can, stressed.
    func callout(_ line: String) { say(""); say("  " + line); say("") }

    func choose(_ options: [String], selected: Int = 0) -> Int? { choose(options, selected: selected, abandon: { false }) }
    func chooseFitting(_ options: [(_ room: Int?) -> String], selected: Int, abandon: () -> Bool) -> Int? {
        choose(options.map { $0(nil) }, selected: selected, abandon: abandon)
    }
}

/// How a typed answer picks one of a list's options, the same on every console: enter takes the default, a number
/// its line, and a letter the one option whose first word starts with it ("y" for "Yes, pair").
public enum ClusterOnboardingChoice {
    public static func match(_ typed: String, options: [String], selected: Int) -> Int? {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return selected }
        if let number = Int(text) { return options.indices.contains(number - 1) ? number - 1 : nil }
        let starting = options.indices.filter { options[$0].lowercased().hasPrefix(text) }
        return starting.count == 1 ? starting[0] : nil
    }
}

/// Runs the onboarding on a console with the operations given; returns the exit status.
///
/// The screens follow the 2026-11-02 onboarding review: four steps (Connect, Pair, Choose, Start), one line per
/// thing that happened, every macOS permission asked at a stated moment while the person is at that Mac (the cable's
/// approval and this terminal's Local Network access in Connect, Darkbloom's own once paired), choices from a list
/// with ↑↓ and enter as `darkbloom start` picks models, and the one thing to do next as the last line.
public enum ClusterOnboardingDriver {
    public static func run(_ operations: ClusterOnboardingOperations, console: ClusterOnboardingConsole,
                           request: ClusterOnboardingRequest = .init()) -> Int32 {
        let resume = operations.resume()
        if let refusal = request.privateQualificationRefusal(role: resume.role) {
            console.say(refusal)
            return 1
        }
        if request.privateGLMImageQualification {
            console.say("Private unqualified GLM PNG candidate selected; image qualification and public admission remain open.")
        }
        if request.privateMiMoImageQualification {
            console.say("Private unqualified MiMo PNG candidate selected; actual image and all applicable modality gates remain open.")
        }
        let named = shownName(operations.thisMacName())
        guard let role = resume.role else { return onboard(operations, console, request: request) }
        if let problem = resume.pairingProblem {
            console.banner(title(role), role == .leader ? leaderSubtitle(named: named) : followerSubtitle(named: named))
            return offerPairAgain(problem, operations, console, request: request)
        }
        // The other Mac is asked first, so the opening says who leads, who follows and whether the cable works
        // (2026-11-04, the owner: "much clearer of what is what"). A cable on a port that is not set up is said below.
        let answered = resume.unsetCablePort == nil ? otherMacAnswers(operations, console) : nil
        let peer = role == .leader ? resume.peerName : resume.leaderName ?? resume.peerName
        console.banner(title(role), pairLine(role, named: named, other: peer, cableReady: answered == true, silent: answered == false))
        switch role {
        case .member: return member(resume, operations, console, request: request, answered: answered)
        case .leader: return leader(resume, operations, console, justPaired: false, request: request, answered: answered)
        }
    }

    /// The opening of a paired Mac: "This Mac (Studio A) leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable
    /// ready" (the other Mac by the name pairing showed; no computer name crosses the cable). `silent`: the other Mac
    /// didn't answer, so no roles are named (journey 3, D3: after the leading Mac left, the Mac left behind said it led
    /// and the other Mac followed).
    static func pairLine(_ role: ClusterOnboardingRole, named: String?, other: String?, cableReady: Bool, silent: Bool = false) -> String {
        let peer = ClusterOnboardingMacName.other(named: other)
        if silent { return thisMac(named: named) + " \u{00B7} " + peer + " isn't answering" }
        let parts = role == .leader ? [thisMac(named: named) + " leads", peer + " follows"] : [thisMac(named: named) + " follows", peer + " leads"]
        return (parts + (cableReady ? ["cable ready"] : [])).joined(separator: " \u{00B7} ")
    }

    /// The item that unpairs this Mac and pairs the two Macs again, code on both screens (`pairAgain`), offered without a
    /// question only for a pairing that cannot be used (`ClusterOnboardingPairingProblem`).
    public static let pairAgainItem = "Pair again"
    /// Said once this Mac unpaired: the other Mac still holds the old pairing until it pairs again too. This Mac no
    /// longer answers it, so it offers Start over (or Pair again, when its own pairing cannot be used either).
    public static let otherMacPairAgainLine =
        "On the other Mac, run `darkbloom cluster` too; if it offers Start over or Pair again, choose it."

    /// What every paired Mac offers while its pairing works (the leader in its list, the member under its next step):
    /// unpair, then pair again from the start, after one confirmation (No is the default).
    public static let startOverItem = "Start over (unpair and set up again)"
    public static let startOverQuestion = "Unpair this Mac and pair the two Macs again? The Mac that leads then chooses the model."
    public static let startOverAnswers = ["Yes, start over", "No"]

    /// Under the member's status.
    public static let memberRunsByItselfLine = "This Mac runs its part by itself."

    /// Change model on a serving pair: what stops while the new model loads, one confirmation (No by default).
    public static func switchQuestion(to model: String, from current: String) -> String {
        "Switch to \(model)? \(current) stops serving on both Macs while \(model) loads (a few minutes for a large model)."
    }
    public static let switchAnswers = ["Yes, switch", "No"]
    /// Said once the setup that stopped the old model was sent.
    public static func stoppedLine(_ model: String) -> String { "Stopped \(model) on both Macs" }

    /// The mode question for a model with more than one mode, and each mode's line.
    public static func modeQuestion(model: String) -> String { "How should both Macs split \(model)?" }
    /// A mode's line in `room` columns (nil: the whole line): its name, the Recommended tag on the mode the setup would
    /// choose (`ClusterOnboardingMode.automaticIndex`), how many requests it serves at once and the context it serves
    /// (owner, 2026-11-11: "just a recommended tag next to either"). Too wide, the short words; then on more than one
    /// row. No speed figure (owner, 2026-11-05).
    public static func modeLine(_ mode: ClusterOnboardingMode, recommended: Bool = false, room: Int? = nil) -> String {
        let lead = [mode.label] + (recommended ? [recommendedTag] : [])
        let full = (lead + [mode.requestsWords, mode.contextWords].compactMap { $0 }).joined(separator: " \u{00B7} ")
        guard let room else { return full }
        let short = lead + [mode.shortRequestsWords, mode.shortContextWords].compactMap { $0 }
        if let fits = [full, short.joined(separator: " \u{00B7} ")].first(where: { ClusterOnboardingBrand.textColumns($0) <= room }) {
            return fits
        }
        return rows(short, room: room)
    }

    /// The tag on the mode `darkbloom cluster local` recommends and preselects.
    public static let recommendedTag = "Recommended"

    /// `parts` joined with " · " on as few rows of `room` columns as hold them, each part whole on its row unless it
    /// is wider than a row by itself (then it breaks between words).
    static func rows(_ parts: [String], room: Int) -> String {
        var rows = [String](), row = ""
        for part in parts {
            let joined = row.isEmpty ? part : row + " · " + part
            if ClusterOnboardingBrand.textColumns(joined) <= room { row = joined; continue }
            if !row.isEmpty { rows.append(row) }
            row = ""
            for word in part.split(separator: " ").map(String.init) {
                let next = row.isEmpty ? word : row + " " + word
                if row.isEmpty || ClusterOnboardingBrand.textColumns(next) <= room { row = next } else { rows.append(row); row = word }
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows.joined(separator: "\n")
    }

    /// The fresh setup's opening (brief: "one screen before 1/4"): what will be asked, where it is answered, and how long
    /// it takes. The prompts are on each Mac's own screen, and many pair Macs have none (2026-11-04, owner: "it should
    /// tell you that you need Screen Sharing access to go through the approval prompts").
    public static func firstRunLines(localOnly: Bool) -> [String] {
        ["You'll approve macOS prompts on each Mac's own screen: its password for the cable port, Allow for Local Network, "
            + "and Yes to the pairing code" + (localOnly ? "." : "; then a Darkbloom login to serve through Darkbloom."),
         "For a Mac with no display, open Screen Sharing to it first.",
         "It takes about 2 minutes to connect and pair; a model copy or download depends on its size; loading takes a few minutes."]
    }

    /// Over SSH with no desktop, macOS cannot show its approval prompt (the administrator password, Local Network): said
    /// before the first step that needs one, with where to run `command` instead.
    public static func noPromptOverSSHLines(command: String = "darkbloom cluster") -> [String] {
        ["macOS can't show its approval prompt over SSH.",
         "Run `\(command)` in Terminal on this Mac's own screen, or through Screen Sharing."]
    }
    /// The choice after them: Quit (the default, nothing tried) or go on here, typing the password into sudo and
    /// answering Local Network on this Mac's own screen.
    public static let overSSHAnswers = ["Quit", "Go on over SSH"]

    /// The member's last line: the Mac it follows, by the name pairing showed, and the one thing to do there.
    public static func memberLeaderLine(_ leader: String?) -> String {
        "To change the model, run `darkbloom cluster` or `darkbloom start` on \(ClusterOnboardingMacName.other(named: leader)). "
            + "`darkbloom stop` here stops both Macs."
    }

    /// The other Mac does not answer over the cable: that Mac by the name pairing showed, its likely reasons and the one
    /// thing to do there. Silence is not a broken pairing, so it is followed by Start over (which asks first), never by
    /// Pair again (2026-11-04 UX audit P3: a Mac asleep, at its FileVault login after a restart, or with its cluster
    /// service stopped was offered Pair again after 8 s of silence). A Mac that left the pair (`darkbloom cluster leave`)
    /// is silent too, and this Mac can't tell: what to do here then, last.
    public static func otherMacSilentLine(_ other: String?) -> String {
        ClusterOnboardingMacName.sentence(ClusterOnboardingMacName.other(named: other))
            + " isn't answering over the cable. Its cluster service is off, or that Mac is asleep, off, or waiting for someone "
            + "to log in. On that Mac, run `darkbloom start` or `darkbloom cluster`. If it left the pair, choose Start over "
            + "to pair again, or Quit and run `darkbloom cluster leave` here."
    }

    /// The saved pairing cannot be used: why, in one sentence, then Pair again or Quit (which changes nothing).
    static func offerPairAgain(_ problem: ClusterOnboardingPairingProblem, _ operations: ClusterOnboardingOperations,
                               _ console: ClusterOnboardingConsole, request: ClusterOnboardingRequest) -> Int32 {
        console.say("  " + problem.line)
        console.say("")
        guard console.choose([pairAgainItem, "Quit"], selected: 0) == 0 else { return 0 }
        return pairAgain(operations, console, request: request)
    }

    /// Unpairs this Mac, then pairs as a Mac with no pairing does: the cable, the code on both screens and, on the Mac
    /// that leads, the model.
    static func pairAgain(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                          request: ClusterOnboardingRequest) -> Int32 {
        switch busy(console, "Unpairing this Mac", operations.unpair) {
        case .success(let lines):
            for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        console.say("  " + otherMacPairAgainLine)
        return onboard(operations, console, request: request, opening: false)
    }

    /// Whether the other Mac answers over the cable with the saved pairing, asked with a live line.
    static func otherMacAnswers(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
        busy(console, "Asking the other Mac over the cable", operations.otherMacAnswers)
    }

    /// While the other Mac does not answer (`answers` false): why (`otherMacSilentLine`), then Try again, Start over
    /// (which asks first) or Quit. Nil once it answers; else the run's exit status.
    static func untilOtherMacAnswers(_ answers: Bool, other: String?, _ operations: ClusterOnboardingOperations,
                                     _ console: ClusterOnboardingConsole, request: ClusterOnboardingRequest) -> Int32? {
        var answers = answers
        while !answers {
            console.say("  " + otherMacSilentLine(other))
            console.say("")
            switch console.choose(["Try again", startOverItem, "Quit"], selected: 0) {
            case 0?: answers = otherMacAnswers(operations, console)
            case 1?: return startOver(operations, console, request: request)
            default: return 0
            }
        }
        return nil
    }

    /// Start over on a pairing that works: one confirmation (No by default), then `pairAgain`.
    static func startOver(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                          request: ClusterOnboardingRequest) -> Int32 {
        console.say("  " + startOverQuestion)
        guard console.choose(startOverAnswers, selected: 1) == 0 else {
            console.say("Nothing changed.")
            return 0
        }
        return pairAgain(operations, console, request: request)
    }

    /// Reads both Macs, saying each new reason the other Mac has not answered yet while it keeps asking (2026-11-03,
    /// the owner's second pair: minutes of "Reading both Macs over the cable" with no reason, 0% CPU, no message).
    static func readBothMacs(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole)
        -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure> {
        let waiting = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>>()
        Thread.detachNewThread { finished.post(operations.reachMembers { waiting.post($0) }) }
        var said: String?
        func show() {
            for line in waiting.take() where line != said {
                console.settle()
                console.say("  " + line)
                said = line
            }
        }
        while true {
            show()
            if let result = finished.take().first {
                show()
                console.settle()
                return result
            }
            console.working("Reading both Macs over the cable")
            usleep(40_000)
        }
    }

    /// The setup's opening (the name alone), and the opening on a Mac that is already in a cluster (`darkbloom
    /// cluster` run again): the same mark, with the part this Mac plays. `named`: this Mac's own name beside "This
    /// Mac" (`thisMac`).
    public static let title = "Darkbloom cluster"

    /// The opening's title on a paired Mac: which part this Mac plays, by the mark, so each Mac's screen says it at the
    /// top (the owner, 2026-11-05: "so the user always knows which machine is the leader, and which is the member").
    /// Before pairing the role is not known, and the title is `title` alone.
    public static func title(_ role: ClusterOnboardingRole) -> String { title + " \u{00B7} " + roleWords(role) }

    /// "Leading Mac", "Joining Mac": the words the screens use for the two Macs.
    public static func roleWords(_ role: ClusterOnboardingRole) -> String { role == .leader ? "Leading Mac" : "Joining Mac" }
    public static let leaderSubtitle = "This Mac leads"
    static func leaderSubtitle(named: String?) -> String { thisMac(named: named) + " leads" }
    static func followerSubtitle(named: String? = nil) -> String { thisMac(named: named) + " follows the other Mac" }

    /// "This Mac", with its own name when known ("This Mac (Studio A)"): two identical Macs read the same hardware, so
    /// each screen says which physical Mac it is. Said on that Mac's own screen only; the name never crosses the cable.
    static func thisMac(named: String?) -> String { named.map { "This Mac (\($0))" } ?? "This Mac" }

    /// A name macOS gave, when it can be said plainly in a line: no control characters, at most 40 characters.
    static func shownName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 40,
              ClusterOnboardingDeployment.shownPlainly(name) else { return nil }
        return name
    }

    /// A step that is done, at the start of its line.
    public static let done = "\u{2713}"
    /// An outcome that is not what was asked for, at the start of its block's line.
    public static let failed = "\u{2717}"

    /// What to answer, for the program macOS names. `remote` (over SSH): the prompt is on this Mac's own screen, not in
    /// this terminal.
    public static func localNetworkLine(_ app: String, remote: Bool = false) -> String {
        "Click Allow on the Local Network prompt for \(app)\(onScreen(remote))."
    }

    /// The same where the probe could not tell whether macOS will ask (nothing to wait for).
    public static func localNetworkMaybeLine(_ app: String, remote: Bool = false) -> String {
        "If macOS asks about Local Network for \(app)\(onScreen(remote)), click Allow."
    }

    /// What to do on this Mac when macOS keeps its cluster service's follower off the local network (P2-1): plainly,
    /// with the row to turn on, what to do where there is none, and the way in on a Mac with no display. `then`: what
    /// follows once it's on.
    public static func localNetworkBlockedLines(app: String, row: String = ClusterOnboardingCommand.localNetworkRow,
                                                then: String = "the start goes on by itself once it's on") -> [String] {
        ["This Mac can't reach the other Mac over the cable: macOS keeps \(app) off the local network.",
         "On this Mac: " + localNetworkSteps(app: app, row: row, screen: "this Mac's screen")
            + " (on a Mac with no display, through Screen Sharing); \(then)."]
    }

    /// Where Local Network is turned on for `app`, on the Mac whose screen `screen` names: the row System Settings shows
    /// for it (`row`; R4-4: both apps share one bundle ID, so the DevNet app's row reads "Darkbloom"), and where macOS
    /// never recorded an answer for the app, and lists no row, the prompt it shows on that Mac's screen at the next dial.
    public static func localNetworkSteps(app: String, row: String, screen: String) -> String {
        "System Settings → Privacy & Security → Local Network → turn on “\(row)”"
            + localNetworkRowNote(app: app, row: row)
            + "; if it isn't listed, click Allow when macOS asks on \(screen), the next time \(app) dials over the cable"
    }

    /// Said after the row's name when the app's own name differs (the DevNet app): the name macOS lists it by.
    public static func localNetworkRowNote(app: String, row: String) -> String {
        row == app ? "" : " (macOS lists \(app) as “\(row)”)"
    }

    private static func onScreen(_ remote: Bool) -> String {
        remote ? " on this Mac's screen (Screen Sharing if headless)" : ""
    }

    /// Said once paired: both cluster services ask at the same moment, one on each Mac; the other one by the name pairing
    /// showed, and the way in to a Mac with no display.
    public static func otherMacAllowLine(_ other: String?) -> String {
        let mac = ClusterOnboardingMacName.other(named: other)
        let named = mac == ClusterOnboardingMacName.other ? "" : " " + String(mac.dropFirst(ClusterOnboardingMacName.other.count + 1))
        return "Approve it on the other Mac's screen too\(named); use Screen Sharing if it has no display."
    }

    /// Connect's first line: every approval the setup asks for on this Mac (2026-11-02 review: "bundle all of the
    /// permissions ahead of time").
    public static func approvalsLine(remote: Bool) -> String {
        remote ? "Allow macOS permissions here and on this Mac's screen (Screen Sharing if headless)."
            : "Allow macOS permissions."
    }

    /// Said on the Mac that joined when it was asked for `darkbloom cluster local` (a model too, perhaps): nothing of it
    /// runs here, because the Mac that leads chooses how the cluster serves and its model.
    public static let joinedLocalLine = "Run `darkbloom cluster local` on the other Mac: it leads."

    /// Said when the person leaves the follow where this Mac's service lives for this session only (a development build,
    /// or one launchd did not take as a login agent): a login agent keeps serving once the window closes.
    public static let keepWindowLine = "Keep this window open."

    /// How long the setup waits for a service that was just started to report its own probe (a service that never
    /// reports is an older build: nothing to wait for). A Local Network prompt itself is waited for until it is
    /// answered or q: the person may be at the other Mac, answering its own.
    static let serviceReportSeconds: Double = 10
    /// After this long still refused, the screen also says where the setting is (the prompt was answered before).
    static let settingsHintSeconds: Double = 15

    /// The cable check's line as the setup says it: "✓ Cable ready" for its plain "Cable ready.", nothing for a found
    /// cable (the ready line or what is wrong follows) or the link flow's own pointer to the other Mac (Pair says it).
    static func linkLine(_ line: String) -> String? {
        if line == "Cable ready." { return "\(done) Cable ready" }
        if line.hasPrefix("Cable found") || line == "Run `darkbloom cluster` on the other Mac too." { return nil }
        return line
    }

    /// Runs the cable checks with each line shown as it is made (the approval line comes before the macOS prompt).
    static func checkLink(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ClusterOnboardingLinkResult {
        let lines = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<ClusterOnboardingLinkResult>()
        Thread.detachNewThread { finished.post(operations.checkLink { lines.post($0) }) }
        func show() { for line in lines.take().compactMap(linkLine) { console.say("  " + line) } }
        while true {
            show()
            if let result = finished.take().first { show(); console.settle(); return result }
            console.working("Checking the cable")
            usleep(50_000)
        }
    }

    /// Asks macOS for Local Network access for `subject` now, while the person is at this Mac, instead of whenever the
    /// first traffic happens to flow (2026-11-02: the prompts came out of sync, on the other Mac's turn). Says nothing
    /// when it is allowed already; otherwise the prompt to answer, then waits for the probe to pass, for as long as the
    /// person takes (they may be at the other Mac, answering its prompt) or until q. A service whose probe tells
    /// nothing gets the prompt's line as an "if". False (with where to turn it on) when the person stopped waiting.
    static func allowLocalNetwork(_ subject: ClusterOnboardingLocalNetworkSubject, _ operations: ClusterOnboardingOperations,
                                  _ console: ClusterOnboardingConsole, other: String? = nil) -> Bool {
        let app = subject == .service ? ClusterOnboardingCommand.app : operations.commandApp()
        let remote = operations.remote()
        var state = operations.localNetwork(subject)
        if state == .unknown, subject == .service {
            let deadline = Date().addingTimeInterval(serviceReportSeconds)
            while state == .unknown, Date() < deadline {
                console.working("Checking local network access")
                usleep(250_000)
                state = operations.localNetwork(subject)
            }
            console.settle()
        }
        switch state {
        case .allowed: return true
        case .unknown:
            // This command cannot be probed before the cable has an address, and macOS lets it through by itself
            // (TN3179); the service is a launchd agent, which macOS asks about.
            if subject == .service { console.say("  " + localNetworkMaybeLine(app, remote: remote) + " " + otherMacAllowLine(other)) }
            return true
        case .blocked: break
        }
        console.say("  " + localNetworkLine(app, remote: remote) + (subject == .service ? " " + otherMacAllowLine(other) : ""))
        // The other Mac follows this step from the leading Mac's status (`ClusterOnboardingLeaderStep.localNetwork`).
        if subject == .service { operations.publishStep(.init(.localNetwork)) }
        let started = Date()
        let bound = operations.localNetworkWaitSeconds
        var hinted = false
        while !console.closed {
            let waited = Date().timeIntervalSince(started)
            if waited >= bound {
                console.settle()
                console.result(false, "Local Network access is off for \(app): no Allow within \(minutes(bound)) minutes.",
                               localNetworkOffLines(subject, app: app))
                return false
            }
            if !hinted, waited >= settingsHintSeconds {
                hinted = true
                console.settle()
                console.say("  No prompt? On this Mac: System Settings → Privacy & Security → Local Network → turn on “\(app)” "
                    + "(on a Mac with no display, through Screen Sharing).")
            }
            console.progress({ width in
                fitted(["Waiting for Allow \u{00B7} " + waitedWords(waited, of: bound) + " (q cancels)",
                        "Waiting for Allow \u{00B7} " + waitedWords(waited, of: bound), "Allow \u{00B7} " + waitedWords(waited, of: bound)], width: width)
            }, logged: false)
            if let key = console.key(milliseconds: 1_000), key == "q" || key == "Q" || key == "\u{1B}" { break }
            state = operations.localNetwork(subject)
            if state == .allowed {
                console.settle()
                console.say("  \(done) Allowed")
                return true
            }
        }
        console.settle()
        console.say("Local Network is off for \(app). On this Mac: System Settings → Privacy & Security → Local Network → turn on "
            + "“\(app)” (on a Mac with no display, through Screen Sharing), then run `darkbloom cluster` again.")
        return false
    }

    /// Under the ✗ when no Allow came: where to turn it on, the row macOS shows ("Darkbloom" for the cluster service),
    /// and what to do when that row isn't there (macOS never recorded an answer).
    static func localNetworkOffLines(_ subject: ClusterOnboardingLocalNetworkSubject, app: String) -> [String] {
        let row = subject == .service ? "Darkbloom" : app
        return ["On this Mac: System Settings → Privacy & Security → Local Network → turn on “\(row)” (on a Mac with no display, through Screen Sharing).",
                "If “\(row)” isn't listed, macOS asks on this Mac's screen the next time it connects over the cable: run `darkbloom cluster` again and click Allow."]
    }

    /// Starts this Mac's cluster service (its login agent) unless it runs; says only what went wrong.
    static func startService(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
        switch operations.ensureService() {
        case .success: return true
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return false
        }
    }

    /// No pairing yet: checks, then find a waiting leader or become one. `opening`: the setup's name first (a Mac that
    /// just unpaired to pair again said it already).
    static func onboard(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                        request: ClusterOnboardingRequest = .init(), opening: Bool = true) -> Int32 {
        if opening {
            console.banner(title, "")
            for line in firstRunLines(localOnly: request.scope?.isLocalOnly == true) { console.say("  " + line) }
        }
        if operations.remote() {
            // Said before anything is tried, so the setup does not stop part way at a prompt no one can see.
            console.say("")
            for line in noPromptOverSSHLines() { console.say("  " + line) }
            guard console.choose(overSSHAnswers, selected: 0) == 1 else {
                console.say("\(failed) Nothing changed. " + noPromptOverSSHLines()[1])
                return 1
            }
        }
        console.heading("1/4 Connect")
        console.say("  " + approvalsLine(remote: operations.remote()))
        var link = checkLink(operations, console)
        if !link.ready, link.ports.count > 1 {
            // Two cables (two links to the other Mac, or one to a third Mac): the person says which one to use here.
            console.say("  Which cable goes to the other Mac?")
            guard let index = console.choose(link.ports, selected: 0) else {
                console.say("Nothing changed.")
                return 1
            }
            operations.useLinkPort(link.ports[index])
            link = checkLink(operations, console)
        }
        if !link.ready, let script = link.manualScript, !console.closed {
            // macOS could not show its approval window (an SSH session with no desktop): the same commands with sudo
            // right here, instead of a script for the person to find and run by hand (2026-11-02, `link-fix.sh`).
            guard setUpPortWithSudo(script, operations, console) else {
                console.say("Cable port not set up. Run `darkbloom cluster` again.")
                return 1
            }
            link = checkLink(operations, console)
        }
        guard link.ready else {
            console.say("Cable not ready. Fix the step above, then run `darkbloom cluster` again.")
            return max(link.exitCode, 1)
        }
        guard allowLocalNetwork(.thisCommand, operations, console) else { return 1 }
        console.heading("2/4 Pair")
        let events = ClusterOnboardingMailbox<ClusterOnboardingPairEvent>()
        let outcome = ClusterOnboardingMailbox<ClusterOnboardingPairResult>()
        Thread.detachNewThread { outcome.post(operations.pair { events.post($0) }) }
        var pairing = ClusterOnboardingPairing(localOnly: request.scope?.isLocalOnly == true)
        var result: ClusterOnboardingPairResult?
        func show() {
            for event in events.take() {
                for line in pairing.handle(event) { line == pairing.otherMacLine ? console.callout(line) : console.say("  " + line) }
            }
        }
        let pairingBegan = Date()
        var saidNotFound = false
        while result == nil {
            show()
            if let finished = outcome.take().first {
                // Whatever the pairing said last comes before its result.
                show()
                result = finished
                break
            }
            if pairing.asking != nil {
                // The code on screen: a choice, which ends by itself when the pairing does (the other Mac declined).
                console.settle()
                let answer = console.choose(ClusterOnboardingPairing.codeAnswers, selected: 0, abandon: { outcome.hasItems })
                if answer == nil {
                    if outcome.hasItems { continue }
                    if console.closed { console.say("Input closed: nothing paired."); return 1 }
                }
                let accept = answer == 0
                // What the other Mac said while the list was up comes first: its answer decides what this one says.
                show()
                for line in pairing.answered(accept) { console.say("  " + line) }
                operations.answerCode(accept)
                continue
            }
            // Not found after a while (a firewall may drop the discovery probe): what to check, once; the wait goes on.
            if !saidNotFound, pairing.phase == .searching || pairing.phase == .waiting,
               Date().timeIntervalSince(pairingBegan) >= operations.pairHintSeconds {
                saidNotFound = true
                console.settle()
                for line in ClusterOnboardingPairing.otherMacNotFoundLines { console.say("  " + line) }
            }
            if let working = pairing.working { console.working(working) }
            guard let key = console.key(milliseconds: 100) else {
                if console.closed { console.say("Input closed: nothing paired."); return 1 }
                continue
            }
            if key == "q" || key == "Q" || key == "\u{1B}", pairing.phase != .confirmed {
                console.settle()
                console.say("Cancelled: nothing paired.")
                return 130
            }
        }
        console.settle()
        for line in pairing.finished(result!, named: shownName(operations.thisMacName())) { console.say("  " + line) }
        guard case .paired(let role, let peerName) = result! else { return 1 }
        switch role {
        case .member:
            guard startService(operations, console) else {
                console.say("Run `darkbloom cluster` again to start it (the pairing is kept).")
                return 1
            }
            guard allowLocalNetwork(.service, operations, console, other: peerName) else { return 1 }
            // Nothing else is asked on the Mac that joined, `darkbloom cluster local` included: the Mac that leads is on
            // its own model list by now (2026-10-25: both Macs showed the list). This window follows its start.
            console.say("")
            if request.scope?.isLocalOnly == true { console.say(joinedLocalLine) }
            return followStart(leader: peerName, operations, console)
        case .leader:
            return leader(.init(role: .leader, peerName: peerName), operations, console, justPaired: true, request: request)
        }
    }

    /// A member: its part runs by itself and the cluster is managed on the Mac that leads, so it shows the cluster as
    /// it is, the Mac it follows and the command to run there (2026-11-02: "why does the member have the choices to
    /// change model, test …"; 2026-11-03, an end user: "Nothing to do here" said neither which Mac nor what to type).
    /// Its one choice is to start over.
    static func member(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                       request: ClusterOnboardingRequest = .init(), answered: Bool? = nil) -> Int32 {
        guard startService(operations, console) else { return 1 }
        if let port = resume.unsetCablePort {
            // The cable moved to a port that was never set up: this Mac's first thing to do; the run then goes on
            // (2026-11-03: it ended at "Cable port set up", leaving no hint of the next step).
            console.say(unsetPortLine(port))
            guard console.choose([fixPortItem, "Quit"], selected: 0) == 0 else { return 0 }
            guard fixPort(operations, console) == 0 else { return 1 }
        }
        // The cluster is managed on the other Mac, so it must answer: while it does not, why, and the way on from here
        // (2026-11-03: a member whose other Mac no longer held the pairing said "Nothing to do here" while that Mac
        // waited at Pair). Start over asks first: silence is not a broken pairing (`otherMacSilentLine`).
        if let ended = untilOtherMacAnswers(answered ?? otherMacAnswers(operations, console), other: resume.leaderName ?? resume.peerName,
                                            operations, console, request: request) { return ended }
        // The leading Mac runs a start (a model or mode change, or a Retry): this Mac follows it as on first setup.
        if request.scope == nil, request.model == nil, leaderStarting(operations) {
            return followStart(leader: resume.leaderName ?? resume.peerName, operations, console)
        }
        // Single-Mac serving blocks the pair (this Mac's, or the leading Mac's): the same ✗ as the leading Mac's screen,
        // naming it, never just "Stopped" (0.10.9 DevNet build C, R8-1: the joining Mac said "Stopped … Close" while its own
        // single-Mac provider blocked the leader's start).
        let solo = operations.soloServing()
        if !solo.isEmpty {
            console.result(false, ClusterOnboardingSoloServing.title(solo) + ".",
                           ClusterOnboardingSoloServing.remedies(solo) + [ClusterOnboardingSoloServing.leaderOffersLine(resume.leaderName ?? resume.peerName)])
            return 1
        }
        showStatus(operations, console)
        console.say("  " + memberRunsByItselfLine)
        console.say("")
        if request.scope != nil || request.model != nil {
            console.say(joinedLocalLine)
            return 1
        }
        console.say(memberLeaderLine(resume.leaderName ?? resume.peerName))
        guard console.choose(["Close", startOverItem], selected: 0) == 1 else { return 0 }
        return startOver(operations, console, request: request)
    }

    /// Whether the leading Mac publishes a start in progress (`ClusterOnboardingStartProgress`; R5-8, DevNet 2026-11-05:
    /// the joining Mac showed "This Mac runs its part by itself … Close" through the leader's model change).
    static func leaderStarting(_ operations: ClusterOnboardingOperations) -> Bool {
        guard let start = operations.leaderStatus?().start else { return false }
        return start.phase != .unknown
    }

    /// The pair's status: the outcome block when it says Serving or why not (`showOutcome`), else its lines (Stopped, …).
    @discardableResult
    static func showStatus(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> [String] {
        let status = operations.status()
        if !showOutcome(status, console) { for line in status { console.say("  " + line) } }
        return status
    }

    /// Whether `status` says the pair serves now, settled: its first line is "Serving …" and not a start still checking
    /// with Darkbloom (an older leader's shape of that line). `showOutcome`'s ✓ and the list's "serving now" both read
    /// it, so the marker never contradicts the block above it.
    static func servesNow(_ status: [String]) -> Bool {
        guard let first = status.first else { return false }
        return first.hasPrefix("Serving ") && !first.contains(ClusterOnboardingReady.offerPendingWords)
    }

    /// The cluster's status as the outcome block on the other Mac, when its first line tells it: "Serving …" (✓) or
    /// "<model> is not serving yet: <reason>." (✗, `ClusterOnboardingNotServing.statusLine`); false (nothing said) for
    /// any other status.
    static func showOutcome(_ status: [String], _ console: ClusterOnboardingConsole) -> Bool {
        guard let first = status.first else { return false }
        // A start still checking with Darkbloom is not its outcome (as the Mac that joined follows it): no ✓.
        if first.contains(ClusterOnboardingReady.offerPendingWords) { return false }
        if servesNow(status) {
            console.result(true, first.hasSuffix(".") ? String(first.dropLast()) : first, Array(status.dropFirst()))
            return true
        }
        guard let reason = ClusterOnboardingNotServing.reason(inStatusLine: first) else { return false }
        console.result(false, ClusterOnboardingNotServing.title(reason: reason), Array(status.dropFirst()))
        return true
    }

    /// The leader: the model and options, the sync, the start, serving.
    static func leader(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations,
                       _ console: ClusterOnboardingConsole, justPaired: Bool, request: ClusterOnboardingRequest = .init(),
                       answered: Bool? = nil) -> Int32 {
        guard startService(operations, console) else { return 1 }
        if justPaired { guard allowLocalNetwork(.service, operations, console, other: resume.peerName) else { return 1 } }
        // A pairing kept from earlier whose other Mac does not answer over the cable (a cable on a port that is not set
        // up is said first): the screen says so, with what to run there.
        let silent = !justPaired && resume.unsetCablePort == nil && !(answered ?? otherMacAnswers(operations, console))
        // Plain `darkbloom cluster` in a terminal serves Both (`servesBoth`), with no question: Darkbloom keeps serving
        // while the owner uses the pair's local API. `[local]` says so once the pair switches, starts or is confirmed
        // serving that way (`saveChoice`), never on a run that changes nothing.
        let both = request.scope == nil && operations.servesBoth() ? ClusterServingChoice.both.scope(keeping: resume.scope) : nil
        // Serving, or stopped after a model was chosen: the pair's screen. Only a leader that never chose a model goes
        // straight to the choice (which first waits for the other Mac to answer).
        if !justPaired, resume.serving || resume.modelName != nil || silent {
            return pairScreen(resume, operations, console, request: request, otherMacSilent: silent, both: both)
        }
        return chooseAndServe(operations, console, scope: request.scope ?? both ?? resume.scope, saveScope: request.scope != nil || both != nil,
                              model: request.model, privateImage: request.privateImageQualification,
                              startOverRequest: justPaired ? nil : request, peer: resume.peerName, saveChoice: both != nil)
    }

    /// A set-up pair on the leading Mac, as `darkbloom start` works (owner, 2026-11-04: "make it similar to how normal
    /// darkbloom works"; `darkbloom start` on a paired Mac opens this screen): the status, then the pair's model list with
    /// the current model preselected, so enter keeps it or starts it again; a line under the models switches how the
    /// pair serves, another starts over. It ends with the result and the commands that control the pair; nothing to
    /// choose after that. `darkbloom cluster local` comes here asking for local-only serving: a pair that is not
    /// serving (or asked for a model by name) goes to the choice and starts that way; a serving pair switches.
    /// `both`: plain `darkbloom cluster` serves the pair that way (`servesBoth`); a pair saved another way (Only me, or
    /// the Darkbloom network alone) switches to it now, said in one line, and never by itself on an update or restart.
    static func pairScreen(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                           request: ClusterOnboardingRequest = .init(), otherMacSilent: Bool = false,
                           both: ClusterServingScope? = nil) -> Int32 {
        if let wanted = request.scope {
            if request.model != nil || !resume.serving {
                return chooseAndServe(operations, console, scope: wanted, saveScope: true, model: request.model,
                                      privateImage: request.privateImageQualification, startOverRequest: request,
                                      peer: resume.peerName, heading: request.model == nil ? modelHeading : startHeading)
            }
            if wanted != resume.scope { return changeScope(to: wanted, resume, startOverRequest: request, operations, console) }
        }
        let status = showStatus(operations, console)
        if let port = resume.unsetCablePort {
            // A cable moved to a port that was never set up: the one thing to do first (2026-10-16, Thunderbolt 1).
            console.say(unsetPortLine(port))
            guard console.choose([fixPortItem, "Quit"], selected: 0) == 0 else { return 0 }
            guard fixPort(operations, console) == 0 else { return 1 }
        }
        // The list needs the other Mac: while it does not answer, the member's words and choices (UX audit P3).
        if let ended = untilOtherMacAnswers(!otherMacSilent, other: resume.peerName, operations, console, request: request) { return ended }
        let switching = both.map { $0 != resume.scope } == true
        if switching {
            console.say("  " + switchToBothLine(from: resume.scope))
            if resume.serving { return changeScope(to: both!, resume, startOverRequest: request, operations, console, saveChoice: true) }
        }
        return chooseAndServe(operations, console, scope: both ?? resume.scope, saveScope: switching, privateImage: request.privateImageQualification,
                              startOverRequest: request, pair: resume, servingNow: servesNow(status),
                              notOffered: ClusterOnboardingReady.notOfferedLines(inStatus: status) != nil,
                              peer: resume.peerName, heading: modelHeading, saveChoice: both != nil)
    }

    /// The one line a pair saved another way says when `darkbloom cluster` serves it Both.
    static func switchToBothLine(from scope: ClusterServingScope) -> String {
        (scope.isLocalOnly ? "This pair served only on your local API; " : "This pair served Darkbloom without your local API; ")
            + "`darkbloom cluster` serves it through Darkbloom, with your local API beside it."
    }

    /// A set-up pair with no list to show (no model can run here, or planning failed; said above): Start over or Quit,
    /// as every resumed Mac offers (validator D, m4). Quit changes nothing.
    static func noListChoices(startOverRequest: ClusterOnboardingRequest?, _ operations: ClusterOnboardingOperations,
                              _ console: ClusterOnboardingConsole) -> Int32 {
        console.say("")
        guard console.choose([startOverItem, "Quit"], selected: 1) == 0 else { return 1 }
        return startOver(operations, console, request: startOverRequest ?? .init())
    }

    /// The serving model chosen in another mode (the list may hold another mode: it was planned while the parts held
    /// their memory): a mode change, said as one. Nil when either mode is unknown.
    public static func modeSwitchQuestion(model: String, from: String?, to: String?) -> String? {
        guard let from, let to else { return nil }
        return "Switch \(model) from \(ClusterOnboardingDeployment.modeWords(from)) to \(ClusterOnboardingDeployment.modeWords(to))? "
            + "It stops serving on both Macs while it loads again (a few minutes for a large model)."
    }

    /// The list's heading on a set-up pair.
    static let modelHeading = "Model"

    /// What the switch to Darkbloom of a serving pair does, said before it plans (never its result before the outcome).
    public static let switchingToDarkbloomLine =
        "Switching to serving through Darkbloom: both Macs load the model again from a plan made for Darkbloom."

    /// Choosing the serving model again while the pair is set to serve through Darkbloom but isn't offered: it starts
    /// again from a plan made for Darkbloom (the one it runs may be what the coordinator can't register).
    public static func replanQuestion(model: String) -> String {
        "Start \(model) again from a plan made for Darkbloom? It stops serving on both Macs while it loads again "
            + "(a few minutes for a large model)."
    }

    /// The list's line that switches how the pair serves; its current (or last) model then serves that way.
    static func scopeLine(_ scope: ClusterServingScope) -> String {
        scope.isLocalOnly ? "Switch to serving through Darkbloom (both Macs logged in)" : "Switch to local only (this Mac's API, no Darkbloom traffic)"
    }

    /// Saves how the pair serves as the leading Mac's `[local]` (`ClusterOnboardingOperations.saveServingChoice`); a save
    /// that failed is said, and changes nothing else.
    static func saveServingChoice(_ choice: ClusterServingChoice, _ operations: ClusterOnboardingOperations,
                                  _ console: ClusterOnboardingConsole) {
        if case .failure(let failure) = operations.saveServingChoice(choice) {
            for line in failure.lines { console.say("  " + line) }
        }
    }

    /// What controls the pair once it runs, as `darkbloom start` ends (on a paired Mac they act on both Macs).
    public static var pairCommands: [String] {
        let cli = ClusterOnboardingCommand.name
        return ["\(cli) stop     Stop both Macs", "\(cli) restart  Restart with the current model", "\(cli) status   Check status"]
    }

    /// How a run that changed nothing ends: the status again, and the commands.
    static func unchangedEnding(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) {
        showStatus(operations, console)
        console.say("")
        for line in pairCommands { console.say("  " + line) }
    }

    /// The model the pair serves, chosen again in its mode and scope: one test request, the start's, and its result. A
    /// failed test leaves the pair marked serving, so this is how `darkbloom cluster` tests again. Passed: the start's
    /// ending (`servedEnding`); failed: the start's ✗ block and its choices; a pair served only through Darkbloom has
    /// no local API on this Mac to test from, said plainly, then the pair's own status (from both Macs' reports).
    /// `saveChoice`: `darkbloom cluster` confirms the pair serving Both, so `[local]` says so once it is shown serving, with
    /// what that changes (the pause ends at the pair's next start).
    static func testServing(_ title: String, pair: ClusterOnboardingResume, peer: String?, startOverRequest: ClusterOnboardingRequest?,
                            saveChoice: Bool = false, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        func served() -> Int32 {
            if saveChoice {
                let said: [String]
                switch operations.saveServingChoice(ClusterServingChoice(scope: pair.scope)) {
                case .success(let lines): said = lines
                case .failure(let failure): said = failure.lines
                }
                for line in said { console.say("  " + line) }
            }
            // The same ending as a start's (the test's time is in `darkbloom status`).
            let local = pair.scope.isLocalOnly ? operations.status().first.flatMap(ClusterOnboardingReady.endingTitle(inStatusLine:)) : nil
            return servedEnding(local ?? ClusterOnboardingReady.endingTitle(model: title), operations, console)
        }
        while true {
            switch busy(console, "Sending a test request", operations.testRequest) {
            case .success:
                return served()
            case .failure(let failure) where failure.lines.first == ClusterOnboardingReady.offeredTestLine:
                // Darkbloom has the pair (the status above says it serves): no local API on this Mac to test from, and the
                // same ending.
                return served()
            case .failure(let failure):
                switch notServing(failure.lines, scope: pair.scope, operations, console) {
                case .retry:
                    // As the start's Retry: wait for both parts (and an offered pair for the coordinator), then test.
                    return finishStart(title: title, scope: pair.scope, registers: false, startOverRequest: startOverRequest, peer: peer,
                                       operations, console)
                case .changeModel:
                    return chooseAndServe(operations, console, scope: pair.scope, startOverRequest: startOverRequest, peer: peer, heading: "Change model")
                case .leave:
                    console.say(notServingLastLine)
                    return 1
                }
            }
        }
    }

    /// The start's heading outside the first setup (UX audit P6: "1/4 … 4/4" only in the first setup).
    static let startHeading = "Start"

    /// The cable moved to a port that was never set up (the Macs cannot reach each other there), and the one item that
    /// sets it up (macOS asks for the password).
    static func unsetPortLine(_ port: String) -> String { "The cable is on \(port), which isn't set up." }
    static let fixPortItem = "Set up the cable port"

    /// Sets up the port the cable moved to (macOS asks once), and says how it went.
    static func fixPort(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        if operations.remote() { console.say("  " + noPromptOverSSHLines()[0]) }
        var result = checkLink(operations, console)
        if !result.ready, let script = result.manualScript, !console.closed, setUpPortWithSudo(script, operations, console) {
            result = checkLink(operations, console)
        }
        console.say(result.ready ? "\(done) Cable port set up. The Macs reconnect by themselves."
                                 : "Cable port not set up. Run `darkbloom cluster` again.")
        return result.ready ? 0 : 1
    }

    /// Where macOS could not show its approval window: the port's setup `script` runs with sudo in this terminal, the
    /// person typing this Mac's password into sudo. True when it exited 0.
    static func setUpPortWithSudo(_ script: String, _ operations: ClusterOnboardingOperations,
                                  _ console: ClusterOnboardingConsole) -> Bool {
        console.say("  Type this Mac's password to set up the cable port.")
        return console.suspended { operations.runAsAdministrator(script) }
    }

    /// Saves the other way to serve on the control leader. A cluster serving locally only that switches to Darkbloom
    /// (with or without its local API) starts its model again from a plan made for Darkbloom, as a start does; any
    /// other switch starts its leading part again that way (the setup and the model stay). Either way the screen waits
    /// for it as it does after a start. `startOverRequest`: the menu's (its Mac was paired before this run), for the
    /// outcome's Change model. `saveChoice`: the switch answers the question, so the way it serves is also saved as the
    /// person's choice (`[local] mode`), with the scope.
    static func changeScope(to wanted: ClusterServingScope, _ resume: ClusterOnboardingResume, startOverRequest: ClusterOnboardingRequest?,
                            _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                            saveChoice: Bool = false) -> Int32 {
        // Both logins are checked before the working local API stops (UX audit P8a: it stopped, then said "not logged in").
        if !wanted.isLocalOnly, !checkLogins(scope: wanted, operations, console) {
            console.say(resume.serving ? "Nothing changed: the pair keeps serving \(ClusterServingChoice(scope: resume.scope).serves)."
                                       : "Nothing changed.")
            return 0
        }
        // A local plan may carry what the coordinator can't register (Qwen's speculative assistant, unequal tensor-parallel
        // shares), and only a start asks it for the pair's approval (DevNet, 2026-11-04: the switch kept the local plan's
        // [2, 3] shares, the pair was never offered, and both windows said ✓). So the model is planned for Darkbloom and
        // adopted before anything stops, the scope saved after the adopt, and the start's outcome is the switch's.
        if !wanted.isLocalOnly, resume.scope.isLocalOnly, resume.serving, let model = resume.modelName {
            console.say("  " + switchingToDarkbloomLine)
            return chooseAndServe(operations, console, scope: wanted, saveScope: true, model: model, startOverRequest: startOverRequest,
                                  peer: resume.peerName, keepMode: resume.servingMode, heading: startHeading, saveChoice: saveChoice)
        }
        // `[local]` first: the leading part reads it as it starts again for the new scope.
        if saveChoice { saveServingChoice(ClusterServingChoice(scope: wanted), operations, console) }
        switch busy(console, "Switching to " + ClusterServingChoice(scope: wanted).switching, { operations.setScope(wanted) }) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say("Nothing changed.")
            return 1
        }
        guard resume.serving else {
            guard let model = resume.modelName else {
                console.say("Saved: the pair serves " + ClusterServingChoice(scope: wanted).serves + " from its next start.")
                return 0
            }
            // A stopped pair starts its last model that way, in the mode it served in (UX audit P1).
            return chooseAndServe(operations, console, scope: wanted, model: model, startOverRequest: startOverRequest,
                                  peer: resume.peerName, keepMode: resume.servingMode, heading: startHeading)
        }
        // What it does, never the result before the outcome below (the candidate, 2026-11-04: it said "Serving through
        // Darkbloom." and then ✗).
        console.say("  " + switchingLine(to: wanted))
        // The same truth as the start (2026-11-04: from the menu, a pair only registered with the coordinator was
        // called serving): ✓ once the pair serves and a request answered, else ✗ with the reason and the choices.
        return finishStart(title: resume.modelTitle ?? resume.modelName ?? "the model", scope: wanted, registers: false,
                           startOverRequest: startOverRequest, peer: resume.peerName, operations, console)
    }

    /// What a switch of a serving pair that keeps its plan does: only the leading Mac's part starts again.
    static func switchingLine(to wanted: ClusterServingScope) -> String {
        switch wanted {
        case .localOnly: return "Switching to local only: the leading Mac's part starts again that way."
        case .publicServingWithLocalAPI: return "Switching to serving through Darkbloom with your local API: the leading Mac's part starts again with it."
        case .publicServing: return "Switching to the Darkbloom network: the leading Mac's part starts again without its local API."
        }
    }

    /// Each reason once, where it first appears.
    static func reasonsInOrder(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// The choice, then the start. `scope` is how it will serve; `saveScope` saves it on the control leader first
    /// (`darkbloom cluster local`); `model` names the choice so the list is not asked; `privateImage`: a private image
    /// candidate, which never takes public traffic. `startOverRequest`: on a Mac paired before this run, the request
    /// Start over runs with when the other Mac does not answer; nil right after pairing. `pair`: a set-up pair's state
    /// (its current or last model marked and preselected, the scope and Start over lines under the models, a serving
    /// model confirmed before it stops). `notOffered`: the status says the pair is set to serve through Darkbloom but
    /// isn't offered, so its model chosen again starts again from a new plan instead of being tested. `peer`: the other
    /// Mac, for the ending. `keepMode`: the mode the current model served in, kept when listed. `heading`: nil in the
    /// first setup (its numbered steps); else the list's heading and then "Start", or "Start" alone for a model started
    /// again (UX audit P6). `saveChoice`: the way it then serves is also saved as the person's choice (`[local]`), with
    /// the scope after the adopt.
    static func chooseAndServe(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                               scope: ClusterServingScope = .publicServing, saveScope: Bool = false, model: String? = nil,
                               privateImage: Bool = false, startOverRequest: ClusterOnboardingRequest? = nil,
                               pair: ClusterOnboardingResume? = nil, servingNow: Bool? = nil, notOffered: Bool = false,
                               peer: String? = nil, keepMode: String? = nil, heading: String? = nil,
                               saveChoice: Bool = false) -> Int32 {
        let serving = pair?.serving == true ? pair : nil
        console.heading(heading ?? "3/4 Model")
        var reached: [ClusterOnboardingMachine]?
        while reached == nil {
            operations.publishStep(.init(.reading))
            switch readBothMacs(operations, console) {
            case .success(let value): reached = value
            case .failure(let failure):
                for line in failure.lines { console.say(line) }
                operations.publishStep(.init(.tryAgain))
                let gone = "Nothing changed. Run `darkbloom cluster` again when the other Mac is on."
                if let request = startOverRequest {
                    // Paired before: the other Mac may no longer hold the pairing, or may only be away (UX audit P3), so
                    // Start over asks first.
                    switch console.choose(["Try again", startOverItem, "Quit"], selected: 0) {
                    case 0?: continue
                    case 1?: return startOver(operations, console, request: request)
                    default: console.say(gone); return 1
                    }
                }
                // Once paired, the other Mac's service may still wait for its Allow (both Macs ask at the same moment).
                guard console.choose(["Try again", "Cancel"], selected: 0) == 0 else {
                    console.say(gone)
                    return 1
                }
            }
        }
        if let notice = operations.developerNotice() { console.say(notice) }
        operations.planScope(scope)
        let choices: [ClusterOnboardingModelChoice]
        switch busy(console, "Planning each model for both Macs", operations.planModels) {
        case .success(let value): choices = value
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return pair == nil ? 1 : noListChoices(startOverRequest: startOverRequest, operations, console)
        }
        // Only models the owner approved for clusters that these Macs can serve, those that fit now first, so enter
        // picks one that fits (2026-11-02: the list showed the whole catalog); last, those a Mac has no room for on disk.
        let listed = choices.indices.filter { choices[$0].listed }
        let roomy = listed.filter { choices[$0].provision?.fitsOnDisk != false }
        let open = roomy.filter { choices[$0].fitRemedy == nil } + roomy.filter { choices[$0].fitRemedy != nil }
            + listed.filter { choices[$0].provision?.fitsOnDisk == false }
        guard !open.isEmpty else {
            console.say("No approved model can run on these Macs now.")
            // One line per reason, the approved models it holds back named before it.
            let held = choices.indices.filter { choices[$0].validated != false && choices[$0].blocker != nil }
            let reasons = reasonsInOrder(held.compactMap { choices[$0].blocker })
            for reason in reasons {
                let titles = held.filter { choices[$0].blocker == reason }.map { choices[$0].title }
                console.say("  \(titles.joined(separator: ", ")): \(reason)")
            }
            // Fail closed on both screens: the other Mac follows this refusal from the status (`followRefused`).
            let builds = reasons == [ClusterOnboardingLeaderStep.differentBuildsReason]
            operations.publishStep(.init(.refused, reason: builds ? ClusterOnboardingLeaderStep.differentBuildsReason
                : reasons.first ?? "no approved model can run on these Macs now"))
            if builds {
                console.result(false, differentBuildsTitle, ["Run `darkbloom --version` on both Macs, and `darkbloom update` on the one that's behind.",
                                                             "Then run `darkbloom cluster` here again."])
            }
            return pair == nil ? 1 : noListChoices(startOverRequest: startOverRequest, operations, console)
        }
        var chosen: Int?
        let names = { (index: Int, name: String) in
            [choices[index].modelID, choices[index].title].contains { $0?.caseInsensitiveCompare(name) == .orderedSame }
        }
        // A set-up pair's model: serving now, or the last one used; preselected so enter keeps it or starts it again.
        let current = pair?.modelName.flatMap { name in open.first { names($0, name) } }
        if let model {
            // Named on the command line: matched to a model id or title, without the list.
            let named = { (index: Int) in names(index, model) }
            if let index = open.first(where: named) {
                chosen = index
            } else if let index = choices.indices.first(where: named) {
                console.say(choices[index].validated == false ? "\(choices[index].title) is not approved for clusters yet."
                    : "\(choices[index].title) can't run on these Macs: \(choices[index].blocker ?? "not offered here").")
                return 1
            } else {
                console.say("No model on the list is named \(model).")
            }
        }
        if chosen == nil {
            let titles = choices.map(\.title)
            let lines = open.map { index -> String in
                let line = choices[index].listLine(sameTitleElsewhere: titles.filter { $0 == choices[index].title }.count > 1)
                // "Serving now" only when the status above says it serves (a pair offered and not formed doesn't).
                let marked = index == current ? line + ((servingNow ?? (serving != nil)) && serving != nil ? " · serving now" : " · last used") : line
                return marked + (choices[index].fitRemedy == nil ? "" : " · does not fit now")
                    + (choices[index].provision?.fitsOnDisk == false ? " · not enough free disk" : "")
            }
            // A set-up pair's other things to do, under its models: Start over, and, where this screen doesn't set how the
            // pair serves (`darkbloom cluster local`), the switch between Darkbloom and local only. `darkbloom cluster`
            // serves one way (`servesBoth`): no line asks how (owner, 2026-11-11: "Remove the step of serving choice").
            let switches = pair != nil && !operations.servesBoth()
            let actions = pair.map { (switches ? [scopeLine($0.scope)] : []) + [startOverItem] } ?? []
            // A model the owner approved for clusters that cannot run here is never hidden silently (2026-11-05: Qwen
            // 3.8 27B left a pair's list without a word when its plan failed): one line each, with its reason, above the
            // list. An older leader, which does not say whether a model is approved, keeps its list as it came.
            for choice in choices where choice.validated == true {
                if let blocker = choice.blocker { console.say("  \(choice.title): not offered on these two Macs: \(blocker)") }
            }
            operations.publishStep(.init(.modelList))
            guard let picked = console.choose(lines + actions, selected: current.flatMap { open.firstIndex(of: $0) } ?? 0) else {
                console.say("Nothing changed.")
                if pair != nil { unchangedEnding(operations, console) }
                return 0
            }
            if picked >= lines.count, let pair {
                guard switches, picked == lines.count else { return startOver(operations, console, request: startOverRequest ?? .init()) }
                // Through Darkbloom is Both, as `darkbloom cluster` serves it, and saved as such.
                let local = pair.scope.isLocalOnly
                return changeScope(to: local ? ClusterServingChoice.both.scope(keeping: pair.scope) : .localOnly(bind: ClusterServingScope.localOnlyDefaultBind),
                                   pair, startOverRequest: startOverRequest, operations, console, saveChoice: local)
            }
            chosen = open[picked]
        }
        var choice = choices[chosen!]
        // A model a Mac has no room for on disk now, or that cannot be copied or downloaded here, is refused before
        // anything is asked or stopped, in `provision`'s one wording.
        if let offer = choice.provision, offer.blocker != nil {
            _ = provision(offer, title: choice.title, index: chosen!, operations, console)
            return 1
        }
        // How both Macs split it, chosen for the person (`ClusterOnboardingMode.automaticIndex`; owner, 2026-11-11: "don't
        // even give the option to pick") for a new model or plan. The pair's own model keeps the mode it served in (owner,
        // 2026-11-11: no pipeline → tensor parallel flip when a stopped pair starts again; `keepMode` for a switch), and
        // through Darkbloom the model serving now keeps it listed or not, so choosing it again tests it, never reloads it.
        // `darkbloom cluster local` alone asks, the automatic mode tagged Recommended and preselected, unless the model was
        // named on the command line.
        let automatic = choice.modes.flatMap { ClusterOnboardingMode.automaticIndex($0, throughDarkbloom: !scope.isLocalOnly, serving: serving != nil) }
        let keep = chosen == current || model != nil ? keepMode ?? pair?.servingMode : nil
        var mode = choice.modes.flatMap { modes in modes.first { $0.mode == keep }?.mode ?? automatic.map { modes[$0].mode } }
        if !scope.isLocalOnly, chosen == current, let serving { mode = serving.servingMode }
        if model == nil, scope.isLocalOnly, let modes = choice.modes, modes.count > 1 {
            console.say("  " + modeQuestion(model: choice.title))
            let lines = modes.indices.map { index in { (room: Int?) in modeLine(modes[index], recommended: index == automatic, room: room) } }
            guard let picked = console.chooseFitting(lines, selected: automatic ?? 0, abandon: { false }) else {
                console.say("Nothing changed.")
                if pair != nil { unchangedEnding(operations, console) }
                return 0
            }
            mode = modes[picked].mode
        }
        // A pair that serves another model stops it for this one: said and confirmed first (No by default).
        if let serving, let currentTitle = serving.modelTitle ?? serving.modelName {
            let sameModel = chosen == current && scope == serving.scope
            // Tested, unless it isn't offered: a test on the local API would say ✓ for a pair Darkbloom never has (DevNet, 2026-11-04).
            let again = sameModel && mode == serving.servingMode
            if again, !notOffered {
                return testServing(choice.title, pair: serving, peer: peer, startOverRequest: startOverRequest, saveChoice: saveChoice,
                                   operations, console)
            }
            let modeChange = sameModel && !again ? modeSwitchQuestion(model: choice.title, from: serving.servingMode, to: mode) : nil
            console.say("  " + (again ? replanQuestion(model: choice.title) : modeChange ?? switchQuestion(to: choice.title, from: currentTitle)))
            guard console.choose(switchAnswers, selected: 1) == 0 else {
                console.say("Nothing changed: \(currentTitle) keeps serving.")
                return 0
            }
        }
        // A private image candidate says at the choice that it never takes public traffic; whether the pair earns is
        // said once it serves (`ClusterOnboardingReady.outcome`).
        if privateImage, let line = choice.publicTraffic {
            console.say("  " + ClusterOnboardingMacName.sentence(line) + (line.hasSuffix(".") ? "" : "."))
        }
        if let offer = choice.provision {
            operations.publishStep(.init(.copy))
            switch provision(offer, title: choice.title, index: chosen!, operations, console) {
            case .stopped: return 0
            case .failed: return 1
            case .done:
                // A model this Mac downloaded (or copied from the other Mac) is planned from its own files now.
                if offer.leaderDownloads {
                    guard case .success(let again) = busy(console, "Planning \(choice.title)", operations.planModels),
                          let index = again.firstIndex(where: { ($0.modelID ?? $0.title) == (choice.modelID ?? choice.title) }) else {
                        console.say("Couldn't plan \(choice.title) after the \(offer.fromOtherMac ? "copy" : "download"). "
                            + "Run `darkbloom cluster` again.")
                        return 1
                    }
                    if let blocker = again[index].blocker {
                        console.say("\(choice.title) can't run on these Macs: \(blocker)")
                        return 1
                    }
                    choice = again[index]
                    chosen = index
                    if let more = choice.provision {
                        switch provision(more, title: choice.title, index: index, operations, console) {
                        case .stopped: return 0
                        case .failed: return 1
                        case .done: break
                        }
                    }
                }
            }
        }
        // Serving through Darkbloom needs both Macs logged in: said before anything starts (2026-11-03: neither Mac of the
        // owner's second pair had a login, and both screens said Done while the coordinator never paired them).
        guard checkLogins(scope: scope, operations, console) else {
            console.say("Nothing changed.")
            return 0
        }
        if heading != startHeading { console.heading(heading == nil ? "4/4 Start" : startHeading) }
        console.say("  " + startNotice)
        let index = chosen!
        // The mode first: the fit check below checks the plan that mode loads.
        if let mode, choice.modes?.contains(where: { $0.mode == mode }) == true { operations.useMode(index, mode) }
        // Memory moves while the person reads: the fit is checked again right before anything starts.
        if let remedy = operations.recheckFit(index) {
            console.say("\(choice.title) doesn't fit in free memory now: \(remedy)")
            console.say("Nothing changed.")
            return 1
        }
        operations.publishStep(.init(.starting))
        switch busy(console, "Sending the setup to the other Mac", { operations.adopt(index) }) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        // The adopt stopped the model that served (each Mac released its memory first).
        if let current = serving.flatMap({ $0.modelTitle ?? $0.modelName }) { console.say("  \(done) " + stoppedLine(current)) }
        // After the adopt (which stopped a running model first), so the scope never restarts the old model; `[local]`
        // before the parts start, which read it then.
        if saveScope {
            switch operations.setScope(scope) {
            case .success: break
            case .failure(let failure):
                for line in failure.lines { console.say("  " + line) }
                return 1
            }
        }
        if saveChoice { saveServingChoice(ClusterServingChoice(scope: scope), operations, console) }
        // Different versions, then single-Mac serving: neither ends by itself, so each is said before anything starts.
        guard clearVersionSplit(operations.versionSplit(), operations, console) else { return 1 }
        // Single-Mac serving on either Mac never ends by itself: said once, before anything starts, never waited for.
        guard clearSoloServing(operations.soloServing(), operations, console) else { return 1 }
        switch busy(console, "Starting both Macs", operations.serve) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        return finishStart(title: choice.title, scope: scope, startOverRequest: startOverRequest, peer: peer, operations, console)
    }

    /// Serving through Darkbloom needs every Mac logged in: the coordinator pairs only Macs logged in to one account.
    /// Names the Macs without a login before anything starts, offers `darkbloom login` here (the other Mac's own login is
    /// asked for), and says in one line how to use the pair locally instead (`localPairHint`). False when the person
    /// cancelled.
    static func checkLogins(scope: ClusterServingScope, _ operations: ClusterOnboardingOperations,
                            _ console: ClusterOnboardingConsole) -> Bool {
        guard !scope.isLocalOnly else { return true }
        while true {
            let missing = operations.missingLogins()
            guard !missing.isEmpty else { return true }
            operations.publishStep(.init(.login))
            console.say("  " + ClusterOnboardingNotServing.notLoggedIn(missing) + ".")
            let here = missing.contains(ClusterOnboardingMacName.this)
            if !here { console.say("  Run `darkbloom login` on the other Mac, then Check again.") }
            console.say("  " + localPairHint)
            guard console.choose([here ? "Log in on this Mac" : "Check again", "Cancel"], selected: 0) == 0 else { return false }
            if here, !console.suspended({ operations.login() }) { console.say("  This Mac is still not logged in.") }
        }
    }

    /// Where a pair can't serve through Darkbloom (no login, no approval, a coordinator without cluster support): the
    /// one line that names the local-only command, instead of a choice (owner, 2026-11-11: "for users that don't
    /// qualify just run darkbloom cluster local").
    public static let localPairHint = "To use the pair just for yourself, run `darkbloom cluster local`."

    /// How a start ended up: serving (the outcome block's title and lines), its test failed, or not serving (why, first).
    enum StartOutcome {
        case served(ClusterOnboardingReady), testFailed, notServing([String]), left
        /// Single-Mac serving blocks the pair (`ClusterOnboardingSoloServing`): no Retry, it never clears by itself.
        case soloServing([ClusterOnboardingSoloServing])
        /// The two Macs run different versions (`ClusterOnboardingVersionSplit`): no Retry until the older Mac updates.
        case versionSplit(ClusterOnboardingVersionSplit)
        /// The pair was stopped from anywhere while the screen waited: said, nothing more (`ClusterOnboardingStopped`).
        case stopped
        /// The person left the coordinator's wait (q or Esc); the pair keeps trying by itself.
        case leftPairWait
    }

    /// After the start. Serving and Done are said only once the model is loaded on both Macs and a request answered
    /// (2026-11-03: a pair offered for pairing said both while nothing was loaded). A pair that does not serve says why
    /// and stays open with the choices; leaving it never claims success.
    /// `registers`: a pair on the leader's API is registered with the coordinator after its test (a start, and the
    /// switch to Darkbloom, which is one; not the switch to local only or the serving model's Retry). `startOverRequest`: as `chooseAndServe`'s, kept for
    /// Change model, so a Mac paired before this run keeps its choices when the other Mac stops answering.
    static func finishStart(title: String, scope: ClusterServingScope, registers: Bool = true,
                            startOverRequest: ClusterOnboardingRequest? = nil, peer: String? = nil,
                            _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        var mayRegister = registers
        // The screen's start marks itself until its test is answered (through Darkbloom, until the coordinator decides),
        // so the leading Mac publishes its outcome and the Mac that joined ends with the same.
        if registers { operations.markRegistrationPending() }
        while true {
            let outcome = startOutcome(title: title, scope: scope, mayRegister: &mayRegister, operations, console)
            // The start's steps are over (left: they go on by themselves, and the published figures age out). A pair that
            // doesn't serve publishes its ✗ in their place below, with no gap between them where the Mac that joined would
            // read no start and show the status' ✗ without its next step.
            switch outcome {
            case .left, .leftPairWait, .notServing: break
            default: operations.publishStart(nil)
            }
            switch outcome {
            case .served(let ready):
                // 2026-11-03 call: "it should show whether it is success or not VERY clearly".
                return servedEnding(ready.endingTitle(model: title, scope: scope), operations, console)
            case .left:
                console.settle()
                console.say(leftStartLine)
                return 1
            case .testFailed:
                console.say("")
                console.say("Setup saved, but the test failed. To test again, run `darkbloom cluster` and choose \(title): it sends one test request.")
                console.waitForExit()
                return 1
            case .stopped:
                console.settle()
                console.say(ClusterOnboardingCommand.named(ClusterOnboardingStopped.line))
                return 1
            case .leftPairWait:
                console.settle()
                console.say(ClusterOnboardingCommand.named(ClusterOnboardingStopped.leftPairWaitLine))
                return 1
            case .versionSplit(let split):
                guard clearVersionSplit(split, operations, console),
                      clearSoloServing(operations.soloServing(), operations, console) else { return 1 }
                if case .failure(let failure) = busy(console, "Starting both Macs", operations.serve) {
                    for line in failure.lines { console.say("  " + line) }
                    return 1
                }
                continue
            case .soloServing(let serving):
                guard clearSoloServing(serving, operations, console) else { return 1 }
                if case .failure(let failure) = busy(console, "Starting both Macs", operations.serve) {
                    for line in failure.lines { console.say("  " + line) }
                    return 1
                }
                continue
            case .notServing(let lines):
                // The start's outcome, published so the Mac that joined ends with the same ✗ and points to Retry here.
                let block = notServingBlock(lines)
                operations.publishStart(.failed(title: block.title, lines: block.lines, retry: true))
                switch notServing(lines, scope: scope, operations, console) {
                case .retry:
                    // The versions first: a Retry of a pair split across versions would only end the same way.
                    guard clearVersionSplit(operations.versionSplit(), operations, console) else { return 1 }
                    // A pair stopped meanwhile (`cluster stop --service` on a Mac): Retry starts it again and says so, instead
                    // of waiting for parts nothing would start (the pair-2 run, P2-4).
                    if operations.status().first?.hasPrefix("Stopped") == true {
                        guard clearSoloServing(operations.soloServing(), operations, console) else { return 1 }
                        console.say("  The pair is stopped: starting both Macs again.")
                        if case .failure(let failure) = busy(console, "Starting both Macs", operations.serve) {
                            for line in failure.lines { console.say("  " + line) }
                            return 1
                        }
                    }
                    // A start asks Darkbloom again for a pair that isn't offered (it may serve an approval now).
                    mayRegister = registers
                    continue
                case .changeModel: return chooseAndServe(operations, console, scope: scope, startOverRequest: startOverRequest, peer: peer,
                                                         heading: "Change model")
                case .leave:
                    console.say(notServingLastLine)
                    return 1
                }
            }
        }
    }

    /// The last line when the person leaves a pair that does not serve.
    public static let notServingLastLine = "Not serving yet. Both Macs keep trying by themselves; run `darkbloom cluster` to check."

    /// How a start (or a test of the model that serves) ends once the pair serves, the same on both Macs (owner,
    /// 2026-11-11: "Ending screen is too verbose, visually standout, just serving successfully. Press enter to exit
    /// instead of just ending"): the ✓ line alone in its block, where the details are (the pair's card is `darkbloom
    /// status`'s), then Enter on an interactive terminal (`ClusterOnboardingConsole.waitForExit`). A service that stops
    /// with this window says so too.
    static func servedEnding(_ title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.result(true, title, [])
        console.say("  " + statusHint)
        if !operations.serviceOutlivesWindow() { console.say("  " + keepWindowServiceLine) }
        console.waitForExit()
        return 0
    }

    /// The one hint under the ✓.
    public static let statusHint = "`darkbloom status` for details"
    /// Under it, where this Mac's cluster service lives only as long as its window (a development build).
    public static let keepWindowServiceLine = "Keep this window open: this Mac's cluster service stops with it."
    /// The last line on an interactive terminal; Enter, q or Esc ends the command, and the pair keeps serving.
    public static let exitLine = "Press Enter to exit."

    /// Said as the Start step begins (2026-11-03 call: no sense of how long it takes).
    public static let startNotice = "Loading takes a few minutes for a large model; both Macs show progress here."

    /// The rule above and below the outcome block.
    public static let resultRule = String(repeating: "\u{2500}", count: 48)

    /// Waits for the started parts; a pair offered for pairing then for the coordinator to pair both Macs and load the
    /// model there (registered is not serving); a pair on the leader's API is tested, then registered with the
    /// coordinator when it serves a cluster approval (once per start: both parts then start again and are awaited).
    static func startOutcome(title: String, scope: ClusterServingScope, mayRegister: inout Bool,
                             _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> StartOutcome {
        let ready: ClusterOnboardingReady
        switch waitForParts(title: title, operations, console) {
        case .success(let value)?: ready = value
        case .failure(let failure)? where failure.stopped: return .stopped
        case .failure(let failure)? where failure.versionSplit != nil: return .versionSplit(failure.versionSplit!)
        case .failure(let failure)? where !failure.soloServing.isEmpty: return .soloServing(failure.soloServing)
        case .failure(let failure)?: return .notServing(failure.lines)
        case nil: return .left
        }
        let tested: String?
        if ready.offered != nil {
            switch awaitPairServing(title: title, operations, console) {
            case .success(let test)?: tested = test
            case .failure(let failure)? where failure.stopped: return .stopped
            case .failure(let failure)?: return .notServing(failure.lines)
            case nil: return .leftPairWait
            }
        } else {
            // The test's time is said in the outcome block; only a failure is said here.
            operations.publishStart(.init(.testing))
            switch busy(console, "Sending a test request", operations.testRequest) {
            case .success(let lines): tested = lines.first.flatMap { $0.isEmpty ? nil : $0 }
            case .failure(let failure):
                for line in failure.lines { console.say("  " + line) }
                return .testFailed
            }
            if mayRegister, !scope.isLocalOnly {
                mayRegister = false
                if register(title: title, operations, console) { return startOutcome(title: title, scope: scope, mayRegister: &mayRegister, operations, console) }
            }
            // Set to serve through Darkbloom, but not offered after the registration (the coordinator serves no approval
            // for it, or the check refused it): a pair on the leading Mac's API never earns, so this ends with ✗, never
            // ✓ (owner: no ✓ without proof; DevNet, 2026-11-04). Only `awaitPairServing` proves the coordinator has the
            // pair. The leading Mac's status gives the reason, as the other Mac's window shows it; when it doesn't say,
            // the reason is the one this screen knows.
            if !scope.isLocalOnly {
                return .notServing(operations.notOfferedStatus() ?? ready.notOfferedLines(model: title, test: tested))
            }
        }
        return .served(ready)
    }

    /// Single-Mac serving on either Mac (`serving`) blocks the pair and never ends by itself: one ✗ naming each Mac and
    /// process and what to run there, then the choice to stop it on each Mac named and start the pair, or to leave.
    /// True when nothing blocks the pair (none ran, or the person chose to stop it and it stopped); false when nothing
    /// starts, said on the last line.
    /// Different versions on the two Macs: the ✗ with the Mac to update and the command, then Check again (the versions
    /// are read again; the start goes on once they match) or Leave. True when nothing splits the pair (any more).
    static func clearVersionSplit(_ split: ClusterOnboardingVersionSplit?, _ operations: ClusterOnboardingOperations,
                                  _ console: ClusterOnboardingConsole) -> Bool {
        guard var split else { return true }
        while true {
            console.result(false, split.title + ".", split.remedies)
            guard console.choose([versionCheckAgainItem, "Leave"], selected: 0) == 0 else {
                console.say(versionSplitLeftLine)
                return false
            }
            guard let still = operations.versionSplit() else { return true }
            split = still
        }
    }

    public static let versionCheckAgainItem = "Check the versions again (after `darkbloom update` on the Mac named)"
    public static let versionSplitLeftLine = "The pair was not started. Run `darkbloom update` on the Mac named, then `darkbloom cluster` here."

    static func clearSoloServing(_ serving: [ClusterOnboardingSoloServing], _ operations: ClusterOnboardingOperations,
                                 _ console: ClusterOnboardingConsole) -> Bool {
        guard !serving.isEmpty else { return true }
        // Published in this Mac's record, so both Macs' status and the joining Mac's screen say the same block.
        operations.markSoloBlocked(true)
        console.result(false, ClusterOnboardingSoloServing.title(serving) + ".", ClusterOnboardingSoloServing.remedies(serving))
        guard console.choose([ClusterOnboardingSoloServing.stopAndStartItem(serving), "Leave"], selected: 0) == 0 else {
            console.say(soloServingLeftLine)
            return false
        }
        switch busy(console, "Stopping single-Mac serving", operations.stopSoloServing) {
        case .success(let said):
            for line in said { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say(soloServingLeftLine)
            return false
        }
        let still = operations.soloServing()
        guard still.isEmpty else {
            console.say("  " + ClusterOnboardingSoloServing.title(still) + ".")
            console.say(soloServingLeftLine)
            return false
        }
        return true
    }

    /// The last line when single-Mac serving still blocks the pair: nothing started, and the pair doesn't start by itself.
    public static let soloServingLeftLine = "The pair was not started. Run `darkbloom stop --solo` on each Mac named, then `darkbloom start`."

    enum NotServingChoice { case retry, changeModel, leave }

    public static let notServingItems = ["Retry", "Change model", "Diagnostics"]

    /// The ✗ block for a start that does not serve: why, in one plain line, then the details and what to do.
    static func notServingBlock(_ lines: [String]) -> (title: String, lines: [String]) {
        let said = lines.first ?? "the cluster did not report ready"
        // A line that is already the title ("Not serving: …", a test's failure from the leading Mac) is said once.
        let prefix = String(ClusterOnboardingNotServing.title(reason: "").dropLast())
        let first = said.hasPrefix(prefix) ? String(said.dropFirst(prefix.count)) : said
        let reason = first.hasSuffix(".") ? String(first.dropLast()) : first
        return (ClusterOnboardingNotServing.title(reason: reason),
                Array(lines.dropFirst()) + (ClusterOnboardingNotServing.remedy(forReason: reason).map { [$0] } ?? []))
    }

    /// Why the pair does not serve in one plain line (details under it), what to do, then the choices; through
    /// Darkbloom, the line that names `darkbloom cluster local` (`localPairHint`) above them. Diagnostics saves the file
    /// and asks again; q leaves.
    static func notServing(_ lines: [String], scope: ClusterServingScope, _ operations: ClusterOnboardingOperations,
                           _ console: ClusterOnboardingConsole) -> NotServingChoice {
        let block = notServingBlock(lines)
        console.result(false, block.title, block.lines)
        if !scope.isLocalOnly { console.say("  " + localPairHint) }
        while true {
            switch console.choose(notServingItems, selected: 0) {
            case 0: return .retry
            case 1: return .changeModel
            case 2:
                switch busy(console, "Saving diagnostics", operations.saveDiagnostics) {
                case .success(let said): for line in said { console.say("  " + line) }
                case .failure(let failure): for line in failure.lines { console.say("  " + line) }
                }
            default: return .leave
            }
        }
    }

    /// A pair offered for pairing: waits for the coordinator to pair both Macs and both to load the model, its progress
    /// live; the pair's first request's time ("in 0.84 s"), or why it does not serve.
    /// Nil when the person left it (q or Esc): the pair keeps trying by itself (DevNet, 2026-11-05: q did nothing here).
    static func awaitPairServing(title: String, _ operations: ClusterOnboardingOperations,
                                 _ console: ClusterOnboardingConsole) -> Result<String?, ClusterOnboardingFailure>? {
        waitWithRows("Serving \(title) through Darkbloom", console, leaving: leaves, operations.pairServing)?
            .map { $0.first.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// How the pair serves, at the end of the serving line: nothing for a pair offered for pairing (its own line says
    /// through Darkbloom once the coordinator has it), else local only. A pair on the serving Mac's API is never offered,
    /// whatever its scope, so it never earns through Darkbloom (DevNet, 2026-11-04: "earning through Darkbloom" followed
    /// the scope alone while the coordinator never had the pair).
    public static func servesWords(ready: ClusterOnboardingReady) -> String {
        ready.offered == nil ? " (local only)" : ""
    }

    /// After the Test stage: registers the pair with the coordinator when it serves a cluster approval for this pair.
    /// True when both parts start again (as cluster members, or as before after a refusal), which the caller awaits as
    /// after the start; false, with nothing said or stopped, when the coordinator serves none. A registration is said in
    /// plain words for `title`, never as its log line with the approval's id and end.
    static func register(title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
        operations.publishStart(.init(.registering))
        let lines: [String]
        switch operations.register() {
        case .success(let said): lines = said
        case .failure(let failure): lines = failure.lines
        }
        guard let first = lines.first else { return false }
        let registered = first.hasPrefix(ClusterOnboardingReady.registeredNotice)
        for line in (registered ? [ClusterOnboardingReady.offeredLine(model: title)] : [first]) + lines.dropFirst() { console.say("  " + line) }
        console.say(registered ? "Starting both Macs' parts again as cluster members…" : "Starting both Macs' parts again…")
        return true
    }

    /// Waits for the started cluster's parts with their progress as the live rows.
    /// Nil when the person left it (q, Esc or Ctrl-C): the parts go on starting by themselves (P2-4: q was ignored).
    static func waitForParts(title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole)
        -> Result<ClusterOnboardingReady, ClusterOnboardingFailure>? {
        waitWithRows("Loading \(title) on both Macs", console, leaving: leaves, operations.waitReady)
    }

    /// Said when the person leaves the start's wait.
    public static let leftStartLine = "Left the start: the pair keeps starting by itself; run `darkbloom cluster` again to see how it is going."

    /// Runs `work` off the console's thread with its progress ("1 of 2 parts ready", then a row per Mac) as live rows
    /// under `title` (`ClusterOnboardingLoadRows`), until it ends. The rows are live only: the screen keeps the result.
    static func waitWithRows<Value: Sendable>(_ title: String, _ console: ClusterOnboardingConsole,
                                              _ work: @escaping @Sendable (_ progress: @escaping @Sendable (String) -> Void) -> Value)
        -> Value {
        // Never nil: no key leaves this wait.
        waitWithRows(title, console, leaving: { _ in false }, work)!
    }

    /// The same, left (nil) at a key `leaving` takes; the work then goes on by itself.
    static func waitWithRows<Value: Sendable>(_ title: String, _ console: ClusterOnboardingConsole, leaving: (Character) -> Bool,
                                              _ work: @escaping @Sendable (_ progress: @escaping @Sendable (String) -> Void) -> Value)
        -> Value? {
        let progress = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Value>()
        Thread.detachNewThread { finished.post(work { progress.post($0) }) }
        var latest: String?
        var clock = ClusterOnboardingLoadRows(started: Date())
        // A plain window shows no live rows: each Mac's row is said once as it changes.
        var said = Set<String>()
        while true {
            for line in progress.take() {
                latest = line
                guard console.liveWidth == nil else { continue }
                for row in line.components(separatedBy: "\n").dropFirst() where !row.isEmpty && said.insert(row).inserted { console.say("  " + row) }
            }
            if let value = finished.take().first { console.settle(); return value }
            console.workingRows(clock.rows(title, report: latest, now: Date(), width: console.liveWidth))
            if let key = console.key(milliseconds: 120), leaving(key) { console.settle(); return nil }
        }
    }

    enum ProvisionOutcome { case done, stopped, failed }

    /// Asks once how the chosen model reaches the Mac that lacks it (the recommended way first, the list saying what
    /// moves), and moves it with progress.
    static func provision(_ offer: ClusterOnboardingProvisionOffer, title: String, index: Int,
                          _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ProvisionOutcome {
        if let blocker = offer.blocker {
            console.say("Can't start \(title): \(blocker). Free space, then run `darkbloom cluster` again.")
            return .failed
        }
        // Every copy is a choice from the list, the copy first so enter takes it; a short one says how long it takes
        // (2026-11-02 review: no key to press to do something, the same list as the rest of Darkbloom).
        let quick = offer.quickSeconds.map { " (\(Self.duration($0)))" } ?? ""
        let get = offer.fromOtherMac ? "Copy from the other Mac" + quick : offer.leaderDownloads ? "Download" : "Copy to the other Mac" + quick
        let options = [get] + (offer.downloadAlternative ? ["Download"] : []) + ["Cancel"]
        guard let answer = console.choose(options, selected: 0), answer != options.count - 1 else {
            console.say("Nothing changed.")
            return .stopped
        }
        return move(index: index, download: offer.downloadAlternative && answer == 1, operations, console)
    }

    /// "about 3 s", "about 2 min" (as `ClusterModelProvisioning.duration`, which this file does not link).
    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "about \(max(1, Int(seconds.rounded()))) s" : "about \(Int((seconds / 60).rounded())) min"
    }

    /// Moves the chosen model until it is done or failed. Its progress is one live line where the console shows
    /// one; a transcript keeps the lines and the logged reports.
    static func move(index: Int, download: Bool, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ProvisionOutcome {
        let progress = ClusterOnboardingMailbox<ClusterOnboardingProgress>()
        let finished = ClusterOnboardingMailbox<Result<[String], ClusterOnboardingFailure>>()
        let chosenDownload = download
        Thread.detachNewThread { finished.post(operations.provision(index, chosenDownload) { progress.post($0) }) }
        var live: (@Sendable (Int?) -> String)?
        func show() {
            for report in progress.take() {
                switch report {
                case .line(let line):
                    live = nil
                    console.settle()
                    console.say("  " + line)
                case .live(let text, let logged):
                    live = text
                    console.progress(text, logged: logged)
                }
            }
        }
        var result: Result<[String], ClusterOnboardingFailure>?
        while result == nil {
            show()
            if let value = finished.take().first { result = value; break }
            // The petal keeps turning while a step reports nothing new (the check of every file after a download).
            if let live { console.progress(live, logged: false) }
            _ = console.key(milliseconds: 200)
        }
        show()
        console.settle()
        switch result! {
        case .success(let lines):
            for line in lines { console.say("  " + line) }
            return .done
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say("Run `darkbloom cluster` again to resume.")
            return .failed
        }
    }

    /// Runs one blocking operation off the console's thread while the console
    /// says `label` as live work, then clears it. Plain consoles see nothing extra.
    static func busy<Value: Sendable>(_ console: ClusterOnboardingConsole, _ label: String,
                                      _ work: @escaping @Sendable () -> Value) -> Value {
        let finished = ClusterOnboardingMailbox<Value>()
        Thread.detachNewThread { finished.post(work()) }
        while true {
            if let value = finished.take().first { console.settle(); return value }
            console.working(label)
            usleep(40_000)
        }
    }

}

/// A small thread-safe queue between a worker thread and the console's thread.
final class ClusterOnboardingMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [Value]()

    func post(_ value: Value) { lock.lock(); items.append(value); lock.unlock() }

    /// Something was posted and not taken yet.
    var hasItems: Bool { lock.lock(); defer { lock.unlock() }; return !items.isEmpty }

    func take() -> [Value] {
        lock.lock()
        defer { items.removeAll(); lock.unlock() }
        return items
    }
}
