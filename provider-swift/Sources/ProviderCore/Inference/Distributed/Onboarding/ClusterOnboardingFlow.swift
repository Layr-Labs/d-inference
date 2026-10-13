import Foundation

// Leader-first onboarding (owner spec 2026-10-12, `darkbloom cluster`):
//
//   Mac 1: `darkbloom cluster` -> checks (RDMA, cable, isolation behind ONE
//   macOS approval, GID) -> nobody waits on the cable, so this Mac becomes the
//   leader-to-be, answers discovery on the cable and says "On your other Mac,
//   run `darkbloom cluster`." -> waits (q cancels).
//   Mac 2: `darkbloom cluster` -> its own checks -> finds the waiting leader
//   on the cable by itself -> the same code on both screens, y on each ->
//   "Paired with <leader>. Continue on <leader>." -> its cluster service runs.
//   Mac 1 (the leader, where onboarding started): both Macs' hardware, the
//   model choice, the planner's placement (which Mac decodes is derived, not
//   the leader), the setup synced to the member over the link control
//   channel, the member started remotely, serving, one test request.
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

/// What `darkbloom cluster` finds on this Mac when it starts.
public struct ClusterOnboardingResume: Sendable, Equatable {
    public var role: ClusterOnboardingRole?
    /// The leader's name on a member; the member's name on the leader.
    public var peerName: String?
    /// The leader asked the cluster to serve (kept across restarts).
    public var serving: Bool
    public var modelName: String?

    public init(role: ClusterOnboardingRole? = nil, peerName: String? = nil, serving: Bool = false, modelName: String? = nil) {
        self.role = role; self.peerName = peerName; self.serving = serving; self.modelName = modelName
    }
}

/// One Mac as the leader shows it before the model is chosen.
public struct ClusterOnboardingMachine: Sendable, Equatable {
    public var name: String
    public var memoryGB: Int
    public var gpuCores: Int?
    public var leads: Bool
    public var models: Int

    public init(name: String, memoryGB: Int, gpuCores: Int?, leads: Bool, models: Int) {
        self.name = name; self.memoryGB = memoryGB; self.gpuCores = gpuCores; self.leads = leads; self.models = models
    }

    public var line: String {
        let gpu = gpuCores.map { " · \($0)-core GPU" } ?? ""
        let what = leads ? "leads (this Mac)" : "member"
        return "  \(name) · \(memoryGB) GB\(gpu) · \(models) model\(models == 1 ? "" : "s") · \(what)"
    }
}

/// One model the leader may choose, with the planner's placement in words.
public struct ClusterOnboardingModelChoice: Sendable, Equatable {
    public var title: String
    /// Where each part runs and what the planner expects, one fact per line.
    public var lines: [String]
    /// Why it cannot be chosen; nil when it can.
    public var blocker: String?
    /// What has to move before it can be served (a Mac lacks it); nil when every Mac has it.
    public var provision: ClusterOnboardingProvisionOffer?

    public init(title: String, lines: [String], blocker: String?, provision: ClusterOnboardingProvisionOffer? = nil) {
        self.title = title; self.lines = lines; self.blocker = blocker; self.provision = provision
    }
}

/// A chosen model some Mac lacks (compared by the catalog manifest's digests): how it gets there. No model is ever
/// downloaded by hand for clustering: a Mac that has it copies it over the Thunderbolt cable (the default), and when
/// no Mac has it the leader downloads it from Darkbloom's catalog as single-Mac Darkbloom does, then copies it.
public struct ClusterOnboardingProvisionOffer: Sendable, Equatable {
    /// One line per Mac that needs it, with size and time ("Apple M5 Ultra: copy from … over the Thunderbolt cable (6.1 GB, about 3 s)").
    public var lines: [String]
    /// The members may take it from the catalog instead of the cable.
    public var downloadAlternative: Bool
    /// This Mac lacks it too: it downloads it first and plans from its files afterwards.
    public var leaderDownloads: Bool
    /// Why it cannot start (not enough free disk on a Mac), nil when it can.
    public var blocker: String?

    public init(lines: [String], downloadAlternative: Bool, leaderDownloads: Bool, blocker: String? = nil) {
        self.lines = lines; self.downloadAlternative = downloadAlternative; self.leaderDownloads = leaderDownloads; self.blocker = blocker
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
    public init(ready: Bool, exitCode: Int32) { self.ready = ready; self.exitCode = exitCode }
}

public struct ClusterOnboardingReady: Sendable, Equatable {
    /// "this Mac" or the other Mac's name: where the serving API listens.
    public var servedBy: String
    public var port: Int
    public init(servedBy: String, port: Int) { self.servedBy = servedBy; self.port = port }

    /// "Serving <model> from …": the serving API listens on loopback on the Mac that runs rank 0, so when that is
    /// the other Mac the line says the address is on that Mac (this Mac's own loopback serves nothing).
    public func servingLine(model: String) -> String {
        servedBy == "this Mac" ? "Serving \(model) from this Mac at 127.0.0.1:\(port)"
            : "Serving \(model) from \(servedBy), at 127.0.0.1:\(port) on that Mac"
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

    /// `memberServing` nil: the member did not answer (asked again at the next check).
    public static func action(leaderServing: Bool, leaderModel: String?, memberServing: Bool?, memberModel: String?) -> Action {
        guard let memberServing else { return .none }
        if leaderServing { return memberServing && memberModel == leaderModel ? .none : .serve(leaderModel) }
        return memberServing ? .stop : .none
    }
}

/// A step that failed, in words for the screen.
public struct ClusterOnboardingFailure: Error, Sendable, Equatable {
    public var lines: [String]
    public init(_ lines: [String]) { self.lines = lines }
    public init(_ line: String) { self.lines = [line] }
}

/// Everything the onboarding does, as blocking calls.
public struct ClusterOnboardingOperations: Sendable {
    public var resume: @Sendable () -> ClusterOnboardingResume
    /// RDMA, cable, isolation (one macOS approval when needed) and GID; says each observation as it is made.
    public var checkLink: @Sendable (_ say: @escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult
    /// Finds a Mac waiting on the cable and joins it, or waits there as the leader-to-be. Records the role.
    public var pair: @Sendable (_ events: @escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult
    public var answerCode: @Sendable (_ accept: Bool) -> Void
    /// Starts this Mac's cluster service unless it runs; its line for the screen.
    public var ensureService: @Sendable () -> Result<String, ClusterOnboardingFailure>
    /// Every Mac of the cluster, the leader first, read over the link control channel.
    public var reachMembers: @Sendable (_ say: @escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
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
    /// it, or from the catalog when `download` (or when no Mac has it); says its progress as it goes.
    public var provision: @Sendable (_ index: Int, _ download: Bool, _ progress: @escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure>

    public init(resume: @escaping @Sendable () -> ClusterOnboardingResume,
                checkLink: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult,
                pair: @escaping @Sendable (@escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult,
                answerCode: @escaping @Sendable (Bool) -> Void,
                ensureService: @escaping @Sendable () -> Result<String, ClusterOnboardingFailure>,
                reachMembers: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>,
                planModels: @escaping @Sendable () -> Result<[ClusterOnboardingModelChoice], ClusterOnboardingFailure>,
                adopt: @escaping @Sendable (Int) -> Result<[String], ClusterOnboardingFailure>,
                serve: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                waitReady: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Result<ClusterOnboardingReady, ClusterOnboardingFailure>,
                testRequest: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                status: @escaping @Sendable () -> [String],
                stop: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure>,
                provision: @escaping @Sendable (Int, Bool, @escaping @Sendable (String) -> Void) -> Result<[String], ClusterOnboardingFailure>
                    = { _, _, _ in .success([]) }) {
        self.resume = resume; self.checkLink = checkLink; self.pair = pair; self.answerCode = answerCode
        self.ensureService = ensureService; self.reachMembers = reachMembers; self.planModels = planModels
        self.adopt = adopt; self.serve = serve; self.waitReady = waitReady; self.testRequest = testRequest
        self.status = status; self.stop = stop; self.provision = provision
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
    /// The code is on screen and waits for y or n.
    public private(set) var asking: String?

    public init() {}

    public static let otherMacLine = "On your other Mac, run `darkbloom cluster`."

    public mutating func handle(_ event: ClusterOnboardingPairEvent) -> [String] {
        switch event {
        case .searching:
            phase = .searching
            return ["Looking for a Mac waiting on the cable…"]
        case .waitingAsLeader:
            phase = .waiting
            role = .leader
            guard !announcedWait else { return [] }
            announcedWait = true
            return ["No other Mac is waiting on the cable, so this Mac will lead the cluster.",
                    "",
                    "    " + Self.otherMacLine,
                    "",
                    "Waiting for it here (up to 10 minutes; press q to cancel)…"]
        case .joining:
            let yielded = role == .leader
            phase = .joining
            role = .member
            return [yielded ? "The other Mac started waiting at the same moment and leads; this Mac joins it."
                            : "Found a Mac waiting on the cable: this Mac joins its cluster."]
        case .connected:
            return ["Connected over the cable; exchanging keys…"]
        case .code(let code, let peer):
            let shown = Self.spaced(code)
            phase = .confirming(shown)
            asking = shown
            return ["", "The other Mac: " + (peer.first ?? "a Mac on the cable")] + peer.dropFirst().map { "  " + $0 }
                + ["", "Code: \(shown)   (the same code is on the other Mac's screen)",
                   "Does the other Mac show \(shown)? Press y if it does, n if it does not."]
        case .peerDecided(let accepted):
            return [accepted ? "The other Mac confirmed the code." : "The other Mac declined the code."]
        case .note(let text):
            return [text]
        }
    }

    /// The person's answer to the code on screen.
    public mutating func answered(_ accept: Bool) -> [String] {
        guard asking != nil else { return [] }
        asking = nil
        phase = .confirmed
        return [accept ? "Confirmed here; waiting for the other Mac…" : "Declined here: nothing is paired."]
    }

    public mutating func finished(_ result: ClusterOnboardingPairResult) -> [String] {
        phase = .done
        asking = nil
        switch result {
        case .paired(let role, let peerName):
            self.role = role
            switch role {
            case .member: return ["", "Paired with \(peerName). Continue on \(peerName)."]
            case .leader: return ["", "Paired with \(peerName). This Mac leads the cluster."]
            }
        case .failed(let lines):
            return ["Not paired."] + lines + ["Run `darkbloom cluster` again to try again."]
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
    /// One key, or nil when `milliseconds` passed with none. "\r" is enter.
    func key(milliseconds: Int) -> Character?
    /// A line typed after `prompt` (echoed as typed), or nil when the input closed.
    func line(prompt: String) -> String?
    /// The input is closed: nothing more can be asked.
    var closed: Bool { get }
}

/// Runs the onboarding on a console with the operations given; returns the exit status.
public enum ClusterOnboardingDriver {
    public static func run(_ operations: ClusterOnboardingOperations, console: ClusterOnboardingConsole) -> Int32 {
        let resume = operations.resume()
        switch resume.role {
        case .member: return member(resume, operations, console)
        case .leader: return leader(resume, operations, console, justPaired: false)
        case nil: return onboard(operations, console)
        }
    }

    /// No pairing yet: checks, then find a waiting leader or become one.
    static func onboard(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.say("Darkbloom cluster setup")
        console.say("")
        console.say("Checking this Mac's cluster link…")
        let lines = ClusterOnboardingMailbox<String>()
        let link = operations.checkLink { lines.post($0) }
        for line in lines.take() where line != "Run `darkbloom cluster` on the other Mac too." { console.say("  " + line) }
        guard link.ready else {
            console.say("The cluster link is not ready, so pairing waits. Run `darkbloom cluster` again when the step above is done.")
            return max(link.exitCode, 1)
        }
        console.say("")
        let events = ClusterOnboardingMailbox<ClusterOnboardingPairEvent>()
        let outcome = ClusterOnboardingMailbox<ClusterOnboardingPairResult>()
        Thread.detachNewThread { outcome.post(operations.pair { events.post($0) }) }
        var pairing = ClusterOnboardingPairing()
        var result: ClusterOnboardingPairResult?
        while result == nil {
            for event in events.take() { for line in pairing.handle(event) { console.say(line) } }
            if let finished = outcome.take().first {
                // Whatever the pairing said last comes before its result.
                for event in events.take() { for line in pairing.handle(event) { console.say(line) } }
                result = finished
                break
            }
            guard let key = console.key(milliseconds: 100) else {
                if console.closed { console.say("The input closed: nothing was paired."); return 1 }
                continue
            }
            let lower = Character(key.lowercased())
            if pairing.asking != nil, lower == "y" || lower == "n" {
                for line in pairing.answered(lower == "y") { console.say(line) }
                operations.answerCode(lower == "y")
            } else if lower == "q" || key == "\u{1B}", pairing.asking == nil, pairing.phase != .confirmed {
                console.say("Cancelled: nothing was paired. Run `darkbloom cluster` again to start over.")
                return 130
            }
        }
        for line in pairing.finished(result!) { console.say(line) }
        guard case .paired(let role, let peerName) = result! else { return 1 }
        switch role {
        case .member:
            switch operations.ensureService() {
            case .success(let line): console.say(line)
            case .failure(let failure):
                for line in failure.lines { console.say(line) }
                console.say("Run `darkbloom cluster` here again to start it; the pairing is kept.")
                return 1
            }
            console.say("Nothing else to do on this Mac: \(peerName) chooses the model and starts this Mac's part.")
            return 0
        case .leader:
            return leader(.init(role: .leader, peerName: peerName), operations, console, justPaired: true)
        }
    }

    /// A member: it is never asked anything; it says where to continue.
    static func member(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        let leader = resume.peerName ?? "the leading Mac"
        console.say("This Mac is a member of the cluster led by \(leader).")
        switch operations.ensureService() {
        case .success(let line): console.say(line)
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        if resume.serving { console.say("\(leader) has it serving\(resume.modelName.map { " " + $0 } ?? "").") }
        console.say("Nothing to do here: continue on \(leader).")
        return 0
    }

    /// The leader: the model and options, the sync, the start, serving.
    static func leader(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations,
                       _ console: ClusterOnboardingConsole, justPaired: Bool) -> Int32 {
        switch operations.ensureService() {
        case .success(let line): console.say(line)
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        if resume.serving, !justPaired {
            console.say("This Mac leads the cluster.")
            for line in operations.status() { console.say("  " + line) }
            console.say("Press enter to leave it as it is, t to send a test request, m to choose another model, s to stop serving.")
            while true {
                guard let key = console.key(milliseconds: 60_000) else {
                    if console.closed { return 0 }
                    continue
                }
                switch key {
                case "\r", "\n", "q", "Q": return 0
                case "t", "T": return test(operations, console) ? 0 : 1
                case "s", "S":
                    switch operations.stop() {
                    case .success(let lines):
                        for line in lines { console.say(line) }
                        return 0
                    case .failure(let failure):
                        for line in failure.lines { console.say(line) }
                        return 1
                    }
                case "m", "M": return chooseAndServe(operations, console)
                default: continue
                }
            }
        }
        return chooseAndServe(operations, console)
    }

    static func chooseAndServe(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.say("")
        console.say("Reading both Macs over the cable…")
        let notes = ClusterOnboardingMailbox<String>()
        let reached = operations.reachMembers { notes.post($0) }
        for line in notes.take() { console.say("  " + line) }
        let machines: [ClusterOnboardingMachine]
        switch reached {
        case .success(let value): machines = value
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            console.say("Run `darkbloom cluster` here again once the other Mac is on; nothing was changed.")
            return 1
        }
        console.say("The cluster:")
        for machine in machines { console.say(machine.line) }
        console.say("")
        console.say("Planning every model both Macs have (the planner decides which Mac holds which layers and which one decodes)…")
        let choices: [ClusterOnboardingModelChoice]
        switch operations.planModels() {
        case .success(let value): choices = value
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        let open = choices.indices.filter { choices[$0].blocker == nil }
        for (number, index) in open.enumerated() {
            console.say("  \(number + 1). \(choices[index].title)")
            for line in choices[index].lines { console.say("       " + line) }
            if let offer = choices[index].provision {
                for line in offer.lines { console.say("       needs: " + line) }
            }
        }
        let blocked = choices.indices.filter { choices[$0].blocker != nil }
        if !blocked.isEmpty {
            console.say("  Not offered:")
            for index in blocked { console.say("     \(choices[index].title): \(choices[index].blocker!)") }
        }
        guard !open.isEmpty else {
            console.say("No model can be served by these Macs now; the reasons are above.")
            return 1
        }
        var chosen: Int?
        while chosen == nil {
            guard let typed = console.line(prompt: "Choose a model [1-\(open.count), enter = 1]: ") else { return 1 }
            let text = typed.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { chosen = open[0]; break }
            if let number = Int(text), (1...open.count).contains(number) { chosen = open[number - 1]; break }
            console.say("Type a number from 1 to \(open.count), or press enter for 1.")
        }
        var choice = choices[chosen!]
        if let offer = choice.provision {
            switch provision(offer, title: choice.title, index: chosen!, operations, console) {
            case .stopped: return 0
            case .failed: return 1
            case .done:
                // A model this Mac downloaded is planned from its own files now.
                if offer.leaderDownloads {
                    console.say("Planning \(choice.title) now that it is on this Mac…")
                    guard case .success(let again) = operations.planModels(),
                          let index = again.firstIndex(where: { $0.title == choice.title }) else {
                        console.say("\(choice.title) could not be planned after the download. Run `darkbloom cluster` here again.")
                        return 1
                    }
                    if let blocker = again[index].blocker {
                        console.say("\(choice.title) is on this Mac now, but it cannot be served by these Macs: \(blocker)")
                        return 1
                    }
                    choice = again[index]
                    chosen = index
                    for line in choice.lines { console.say("  " + line) }
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
        console.say("Options: always on — each Mac's cluster service starts its part again when it ends, and the cluster re-forms by itself (on).")
        console.say("         Public serving through Darkbloom — off (not offered by this build).")
        console.say("Serve \(choice.title) on both Macs? Press y to start, n to stop here.")
        guard ask(console) else {
            console.say("Nothing was changed. Run `darkbloom cluster` here again to choose.")
            return 0
        }
        console.say("Saving the plan and syncing it to the member over the cable…")
        switch operations.adopt(chosen!) {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        switch operations.serve() {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        console.say("Starting both Macs' parts and loading the model…")
        let progress = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Result<ClusterOnboardingReady, ClusterOnboardingFailure>>()
        Thread.detachNewThread { finished.post(operations.waitReady { progress.post($0) }) }
        var ready: Result<ClusterOnboardingReady, ClusterOnboardingFailure>?
        while ready == nil {
            for line in progress.take() { console.say("  " + line) }
            if let value = finished.take().first { ready = value; break }
            _ = console.key(milliseconds: 200)
        }
        for line in progress.take() { console.say("  " + line) }
        switch ready! {
        case .success(let where_):
            console.say(where_.servingLine(model: choice.title) + ".")
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            console.say("Both Macs keep trying by themselves; run `darkbloom cluster` here to see how it is going.")
            return 1
        }
        let tested = test(operations, console)
        console.say("")
        console.say("Done. This Mac leads the cluster: run `darkbloom cluster` here to see it, change the model or stop it.")
        console.say("Nothing else is needed on the other Mac. After a Mac restarts, run `darkbloom cluster` on it once (it asks nothing).")
        return tested ? 0 : 1
    }

    enum ProvisionOutcome { case done, stopped, failed }

    /// Says what has to move for the chosen model, asks once (enter = the recommended way), and moves it with progress.
    static func provision(_ offer: ClusterOnboardingProvisionOffer, title: String, index: Int,
                          _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ProvisionOutcome {
        console.say("")
        console.say(offer.leaderDownloads ? "\(title) is not on these Macs yet. No download by hand is needed:"
                                          : "\(title) is not on every Mac yet. No download by hand is needed:")
        for line in offer.lines { console.say("  " + line) }
        if let blocker = offer.blocker {
            console.say("It cannot start: \(blocker). Free some space and run `darkbloom cluster` here again.")
            return .failed
        }
        if offer.leaderDownloads {
            console.say("Press enter to get it, n to stop here.")
        } else if offer.downloadAlternative {
            console.say("Press enter to copy it over the Thunderbolt cable (recommended), d to download it from Darkbloom's catalog instead, n to stop here.")
        } else {
            console.say("Press enter to copy it over the Thunderbolt cable, n to stop here.")
        }
        var download = false
        answer: while true {
            guard let key = console.key(milliseconds: 60_000) else {
                if console.closed { return .stopped }
                continue
            }
            switch key {
            case "\r", "\n", "c", "C": break answer
            case "d" where offer.downloadAlternative, "D" where offer.downloadAlternative: download = true; break answer
            case "n", "N", "q", "Q":
                console.say("Nothing was copied or downloaded. Run `darkbloom cluster` here again to choose.")
                return .stopped
            default: continue
            }
        }
        let progress = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Result<[String], ClusterOnboardingFailure>>()
        Thread.detachNewThread { finished.post(operations.provision(index, download) { progress.post($0) }) }
        var result: Result<[String], ClusterOnboardingFailure>?
        while result == nil {
            for line in progress.take() { console.say("  " + line) }
            if let value = finished.take().first { result = value; break }
            _ = console.key(milliseconds: 200)
        }
        for line in progress.take() { console.say("  " + line) }
        switch result! {
        case .success(let lines):
            for line in lines { console.say("  " + line) }
            return .done
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say("Run `darkbloom cluster` here again: a copy or download resumes where it stopped.")
            return .failed
        }
    }

    static func test(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
        console.say("Sending one test request…")
        switch operations.testRequest() {
        case .success(let lines):
            for line in lines { console.say("  " + line) }
            return true
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return false
        }
    }

    /// y or n (enter is no answer); false when the input closed.
    static func ask(_ console: ClusterOnboardingConsole) -> Bool {
        while true {
            guard let key = console.key(milliseconds: 60_000) else {
                if console.closed { return false }
                continue
            }
            switch key {
            case "y", "Y": return true
            case "n", "N", "q", "Q": return false
            default: continue
            }
        }
    }
}

/// A small thread-safe queue between a worker thread and the console's thread.
final class ClusterOnboardingMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [Value]()

    func post(_ value: Value) { lock.lock(); items.append(value); lock.unlock() }

    func take() -> [Value] {
        lock.lock()
        defer { items.removeAll(); lock.unlock() }
        return items
    }
}
