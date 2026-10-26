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

/// How the cluster serves, chosen by the person and kept on the leader until changed: publicly through Darkbloom's
/// coordinator (`darkbloom cluster`, the default), or on the leading Mac's local API only (`darkbloom cluster local`),
/// where no Mac of the cluster contacts a coordinator: no registration, heartbeat, public traffic or billing.
public enum ClusterServingScope: Sendable, Equatable {
    case publicServing
    /// The local API listens on `bind` and needs its API key.
    case localOnly(bind: String)

    /// Every interface of the leading Mac (LAN or tailnet) unless the person chose an address (owner, 2026-10-15).
    public static let localOnlyDefaultBind = "0.0.0.0"

    /// Loopback: what a saved address that is not one the API takes falls back to (never a wider exposure).
    static let loopbackBind = "127.0.0.1"

    /// The scope a record keeps (nil from an older build or before the first choice: public).
    public init(localOnly: Bool?, bind: String?) {
        guard localOnly == true else { self = .publicServing; return }
        self = .localOnly(bind: bind.map { Self.isValidBind($0) ? $0 : Self.loopbackBind } ?? Self.localOnlyDefaultBind)
    }

    /// The scope a message carries (`localOnly`, `bind`): nil when it carries none, or an address the API does not take
    /// (a local-only scope without an address listens everywhere, as the default does).
    public static func carried(localOnly: Bool?, bind: String?) -> ClusterServingScope? {
        guard let localOnly else { return nil }
        guard localOnly else { return .publicServing }
        let address = bind ?? localOnlyDefaultBind
        return isValidBind(address) ? .localOnly(bind: address) : nil
    }

    public var isLocalOnly: Bool { bind != nil }

    public var bind: String? {
        if case .localOnly(let bind) = self { return bind }
        return nil
    }

    /// An address the local API may listen on: `localhost` or a numeric IPv4/IPv6 address (`0.0.0.0` = every one).
    public static func isValidBind(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 64 else { return false }
        if text == "localhost" { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// True when hosts other than this Mac can reach the API (any address that is not loopback).
    public var reachableFromNetwork: Bool {
        guard let bind else { return false }
        return !(bind == "localhost" || bind == "::1" || bind.hasPrefix("127."))
    }

    /// One plain line for the screens: how the cluster serves when it runs.
    public var line: String {
        switch self {
        case .publicServing:
            return "Serving through Darkbloom (public traffic when the coordinator supports clusters)"
        case .localOnly(let bind):
            let reach = bind == Self.localOnlyDefaultBind ? "on this Mac's networks (LAN or tailnet)"
                : reachableFromNetwork ? "at \(bind)" : "on this Mac only (\(bind))"
            return "Local only: no coordinator; the API listens \(reach) and needs its API key (`darkbloom local` shows it)"
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
    /// The leader's name on a member; the member's name on the leader.
    public var peerName: String?
    /// The leader asked the cluster to serve (kept across restarts).
    public var serving: Bool
    public var modelName: String?
    /// How the cluster serves (kept across restarts, as the leader saved it).
    public var scope: ClusterServingScope = .publicServing
    /// On a member: the derived control leader's name (commands typed here run there).
    public var leaderName: String?
    /// Why derivation picked the leader, and its term.
    public var leaderReason: String?
    public var term: UInt64?
    /// What this Mac's own service runs now, in words (`ClusterControlWords`).
    public var localLine: String?
    /// The cable is on a port Darkbloom has not set up ("Thunderbolt 1 (en1)"): the Macs cannot reach each other
    /// there until it is. Nil when the active port is set up, or nothing could be read.
    public var unsetCablePort: String?

    public init(role: ClusterOnboardingRole? = nil, peerName: String? = nil, serving: Bool = false, modelName: String? = nil) {
        self.role = role; self.peerName = peerName; self.serving = serving; self.modelName = modelName
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

    public var line: String {
        let gpu = gpuCores.map { " · \($0)-core GPU" } ?? ""
        let what = leads && here ? "leads (this Mac)" : leads ? "leads" : here ? "member (this Mac)" : "member"
        return "  \(name) · \(memoryGB) GB\(gpu) · \(models) model\(models == 1 ? "" : "s") · \(what)"
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

    public init(title: String, lines: [String], blocker: String?, provision: ClusterOnboardingProvisionOffer? = nil, fitRemedy: String? = nil,
                modelID: String? = nil, publicTraffic: String? = nil) {
        self.title = title; self.lines = lines; self.blocker = blocker; self.provision = provision; self.fitRemedy = fitRemedy
        self.modelID = modelID; self.publicTraffic = publicTraffic
    }

    /// The list's one line: the title (with the model's id when another choice shows the same title) and the first of
    /// its lines (size and how it is split, or how it gets onto the Macs). The rest is said once it is chosen.
    public func listLine(sameTitleElsewhere: Bool) -> String {
        let name = sameTitleElsewhere ? "\(title) (\(modelID ?? title))" : title
        return lines.first.map { "\(name) — \($0)" } ?? name
    }
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
        public init(name: String, layers: Int?, weightsBytes: Int? = nil) { self.name = name; self.layers = layers; self.weightsBytes = weightsBytes }
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
        return "split across the Macs"
    }

    /// "M3 Ultra 40 layers / M5 Ultra 24 layers" (pipeline) or "M3 Ultra 60% / M5 Ultra 40%" (tensor parallel).
    public static func sharesWords(mode: String, shares: [Share]) -> String {
        let names = shares.map { shortName($0.name) }
        // Two Macs of one kind: say which is which by the full name.
        let labels = Set(names).count == names.count ? names : shares.map(\.name)
        if modeWords(mode).contains("tensor parallel") {
            let total = shares.compactMap(\.weightsBytes).reduce(0, +)
            guard total > 0, shares.allSatisfy({ $0.weightsBytes != nil }) else { return labels.joined(separator: " / ") }
            return zip(labels, shares).map { "\($0) \(Int((Double($1.weightsBytes!) * 100 / Double(total)).rounded()))%" }.joined(separator: " / ")
        }
        return zip(labels, shares).map { label, share in share.layers.map { "\(label) \($0) layers" } ?? label }.joined(separator: " / ")
    }

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

    /// One model choice in one line: "6.1 GB · pipeline · M3 Ultra 16 layers / M5 Ultra 16 layers · about 90 tokens/s".
    public static func choiceLine(size: String, mode: String, shares: [Share], speed: String?) -> String {
        ([size, modeWords(mode), sharesWords(mode: mode, shares: shares)] + (speed.map { [$0] } ?? [])).joined(separator: " · ")
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
    /// The predicted time of a copy over the cable short enough to start without asking (derived from the copy rate
    /// measured on these Macs and the bytes to move; `ClusterModelProvisioning.quickCopySeconds`): it starts with a
    /// stated line and n still stops it. Nil: asked for (a long copy, a download, or no rate measured yet).
    public var quickSeconds: Double?

    public init(lines: [String], downloadAlternative: Bool, leaderDownloads: Bool, blocker: String? = nil, quickSeconds: Double? = nil) {
        self.lines = lines; self.downloadAlternative = downloadAlternative; self.leaderDownloads = leaderDownloads; self.blocker = blocker
        self.quickSeconds = quickSeconds
    }
}

/// What happens to this Mac's part after a restart or a power cut, said plainly from what macOS is set to do. The
/// cluster service is a login agent (it needs the logged-in session for its keys and attestation), so it comes back by
/// itself only when the Mac logs in by itself; FileVault keeps the disk locked until someone logs in.
public enum ClusterOnboardingRestart {
    public static func line(mac: String, autoLogin: Bool, fileVault: Bool?) -> String {
        if autoLogin { return "After a restart or power cut, \(mac) comes back by itself and serves again (automatic login is on)." }
        if fileVault == true {
            return "After a restart or power cut, \(mac) serves again once someone logs in (FileVault keeps the disk locked until then)."
        }
        return "After a restart or power cut, \(mac) serves again once someone logs in. To make it automatic, turn on automatic login "
            + "(System Settings → Users & Groups; needs FileVault off)."
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

    /// The members whose running worker differs from the digest the saved setup pins. A member whose current digest
    /// is not known now (it did not answer) is not counted: nothing is re-planned on a guess.
    public static func changed(pinned: [String: String], current: [String: String?]) -> [String] {
        pinned.keys.sorted().filter { member in
            guard let now = current[member] ?? nil else { return false }
            return now != pinned[member]
        }
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
    public init(ready: Bool, exitCode: Int32, ports: [String] = []) { self.ready = ready; self.exitCode = exitCode; self.ports = ports }
}

public struct ClusterOnboardingReady: Codable, Sendable, Equatable {
    /// "this Mac" or the other Mac's name: where the serving API listens.
    public var servedBy: String
    public var port: Int
    /// The plan's deployment in one line (`ClusterOnboardingDeployment.line`); nil when it is not known here.
    public var deployment: String?
    /// `ClusterLocalServing.notice` when rank 0 serves on its local API only (no coordinator with cluster support).
    public var notice: String? = nil
    /// The API also listens on the serving Mac's network addresses (local-only serving's default); nil from an older build.
    public var network: Bool? = nil
    public init(servedBy: String, port: Int, deployment: String? = nil, notice: String? = nil, network: Bool? = nil) {
        self.servedBy = servedBy; self.port = port; self.deployment = deployment; self.notice = notice; self.network = network
    }

    /// "API at http://localhost:8000 on this Mac": the serving API listens on loopback on the Mac that runs rank 0, so
    /// when that is the other Mac the line names it (this Mac's own loopback serves nothing). Listening on the network
    /// too, the line says so: other computers use that Mac's LAN or tailnet address with the same port.
    public var apiLine: String {
        let base = "API at http://localhost:\(port) on \(servedBy)"
        guard network == true else { return base }
        // Local only, the API on the other Mac: this Mac's own port passes to it (`ClusterLocalRelay`).
        return base + ", and at port \(port) of \(servedBy == "this Mac" ? "its" : "that Mac's") LAN or tailnet address"
            + (servedBy == "this Mac" ? "" : "; this Mac answers too (`darkbloom local` shows its address)")
    }

    /// The local-serving line as this screen shows it. The part that serves words it for its own Mac ("this Mac's
    /// API"); on the screen of the other Mac (a member's status, or a leader whose API moved) it is that Mac's API,
    /// which `apiLine` names just above.
    public var noticeLine: String? {
        guard let notice else { return nil }
        return servedBy == "this Mac" ? notice : notice.replacingOccurrences(of: "this Mac's API", with: "that Mac's API")
    }

    /// The deployment line, then where the API is, then (serving locally only) the plain local-serving line.
    public func lines(model: String) -> [String] {
        [deployment ?? "Serving \(model) across both Macs", apiLine] + (noticeLine.map { [$0] } ?? [])
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

    /// `memberServing` nil: the member did not answer (asked again at the next check). `memberLocalOnly` nil: the
    /// member's build does not report the serving scope, so only the model and the start are compared.
    public static func action(leaderServing: Bool, leaderModel: String?, memberServing: Bool?, memberModel: String?,
                              leaderLocalOnly: Bool = false, memberLocalOnly: Bool? = nil) -> Action {
        guard let memberServing else { return .none }
        if leaderServing {
            let scopeAgrees = memberLocalOnly.map { $0 == leaderLocalOnly } ?? true
            return memberServing && memberModel == leaderModel && scopeAgrees ? .none : .serve(leaderModel)
        }
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
    /// Each Mac's verify-teardown summary (after a stop: no cluster process, wired memory at baseline).
    public var verifyTeardown: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// The cable port the person chose when more than one is active; the next `checkLink` sets that one up.
    public var useLinkPort: @Sendable (String) -> Void
    /// Right before the start: nil when choice `index` fits in the Macs' free memory now, else what frees it.
    public var recheckFit: @Sendable (_ index: Int) -> String?
    /// What happens after a restart of this Mac, in one line for the end of the onboarding (nil: nothing to add,
    /// because the service already said it will not start at login).
    public var afterRestart: @Sendable () -> String?
    /// Saves a redacted diagnostics file; its lines say where.
    public var saveDiagnostics: @Sendable () -> Result<[String], ClusterOnboardingFailure>
    /// DEVELOPER ONLY: one loud line for the setup screen when a developer setting overrides the planner (a forced
    /// deployment mode, `ClusterForcedModeSetting`); nil, the default and every user's case, says nothing.
    public var developerNotice: @Sendable () -> String?
    /// Saves how the cluster serves on the control leader (kept until changed). While it serves, the leading Mac's
    /// part starts again in the new scope by itself; its lines say so.
    public var setScope: @Sendable (_ scope: ClusterServingScope) -> Result<[String], ClusterOnboardingFailure>

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
                    = { _, _, _ in .success([]) },
                verifyTeardown: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .success([]) },
                useLinkPort: @escaping @Sendable (String) -> Void = { _ in },
                recheckFit: @escaping @Sendable (Int) -> String? = { _ in nil },
                afterRestart: @escaping @Sendable () -> String? = { nil },
                saveDiagnostics: @escaping @Sendable () -> Result<[String], ClusterOnboardingFailure> = { .failure(.init("No diagnostics file can be saved here.")) },
                developerNotice: @escaping @Sendable () -> String? = { nil },
                setScope: @escaping @Sendable (ClusterServingScope) -> Result<[String], ClusterOnboardingFailure>
                    = { _ in .failure(.init("This build cannot change how the cluster serves.")) }) {
        self.resume = resume; self.checkLink = checkLink; self.pair = pair; self.answerCode = answerCode
        self.ensureService = ensureService; self.reachMembers = reachMembers; self.planModels = planModels
        self.adopt = adopt; self.serve = serve; self.waitReady = waitReady; self.testRequest = testRequest
        self.status = status; self.stop = stop; self.provision = provision; self.verifyTeardown = verifyTeardown
        self.useLinkPort = useLinkPort; self.recheckFit = recheckFit; self.afterRestart = afterRestart; self.saveDiagnostics = saveDiagnostics
        self.developerNotice = developerNotice; self.setScope = setScope
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
    func heading(_ title: String)
    /// One key, or nil when `milliseconds` passed with none. "\r" is enter.
    func key(milliseconds: Int) -> Character?
    /// A line typed after `prompt` (echoed as typed), or nil when the input closed.
    func line(prompt: String) -> String?
    /// The input is closed: nothing more can be asked.
    var closed: Bool { get }
}

public extension ClusterOnboardingConsole {
    /// Scrollable sections also work in transcripts and non-terminal consoles.
    func heading(_ title: String) { say(""); say(title) }
}

/// Runs the onboarding on a console with the operations given; returns the exit status.
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
        switch resume.role {
        case .member: return member(resume, operations, console, request: request)
        case .leader: return leader(resume, operations, console, justPaired: false, request: request)
        case nil: return onboard(operations, console, request: request)
        }
    }

    /// macOS asks once, the first time Darkbloom's service talks over the cable. Said before it can appear.
    public static let localNetworkLine = "macOS may ask once to allow Darkbloom on the local network. Allow it."

    /// Runs the cable checks with each line shown as it is made (the approval line comes before the macOS prompt).
    static func checkLink(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ClusterOnboardingLinkResult {
        let lines = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<ClusterOnboardingLinkResult>()
        Thread.detachNewThread { finished.post(operations.checkLink { lines.post($0) }) }
        func show() { for line in lines.take() where line != "Run `darkbloom cluster` on the other Mac too." { console.say("  " + line) } }
        while true {
            show()
            if let result = finished.take().first { show(); return result }
            usleep(50_000)
        }
    }

    /// No pairing yet: checks, then find a waiting leader or become one.
    static func onboard(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                        request: ClusterOnboardingRequest = .init()) -> Int32 {
        console.heading("Darkbloom cluster setup")
        console.say("Connect / Pair / Choose / Start / Test")
        console.heading("1 / 5  Connect the Macs")
        console.say("Checking this Mac's Thunderbolt cable…")
        var link = checkLink(operations, console)
        if !link.ready, link.ports.count > 1 {
            // Two cables (two links to the other Mac, or one to a third Mac): the person says which one to use here.
            let listed = link.ports.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: " ")
            var chosen: String?
            while chosen == nil {
                guard let typed = console.line(prompt: "\(link.ports.count == 2 ? "Two" : "\(link.ports.count)") cables found: \(listed) [enter = 1]: ") else {
                    console.say("The input closed: nothing was changed.")
                    return 1
                }
                let text = typed.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { chosen = link.ports[0] }
                else if let number = Int(text), link.ports.indices.contains(number - 1) { chosen = link.ports[number - 1] }
                else if link.ports.contains(text) { chosen = text }
                else { console.say("Type a number from 1 to \(link.ports.count), or press enter for 1.") }
            }
            operations.useLinkPort(chosen!)
            console.say("Using \(chosen!) for the cluster.")
            link = checkLink(operations, console)
        }
        guard link.ready else {
            console.say("The cable is not ready yet, so pairing waits. Run `darkbloom cluster` again when the step above is done.")
            return max(link.exitCode, 1)
        }
        console.heading("2 / 5  Pair securely")
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
            console.say(localNetworkLine)
            // `darkbloom cluster local` on the Mac that joined carries on here: the choice and the start run on the
            // leader over the cable, as every command typed on a member does.
            if request.scope != nil { return menu(operations.resume(), operations, console, request: request) }
            console.say("Nothing else to do on this Mac: \(peerName) chooses the model and starts this Mac's part.")
            return 0
        case .leader:
            return leader(.init(role: .leader, peerName: peerName), operations, console, justPaired: true, request: request)
        }
    }

    /// A member: `darkbloom cluster` works here too. Every command runs on the derived control leader, forwarded over
    /// the link control channel, and its answer is shown here.
    static func member(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                       request: ClusterOnboardingRequest = .init()) -> Int32 {
        let leader = resume.leaderName ?? resume.peerName ?? "the leading Mac"
        console.say("This Mac is a member of the cluster led by \(leader).")
        switch operations.ensureService() {
        case .success(let line): console.say(line)
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        console.say("Commands typed here run on \(leader) over the cable.")
        return menu(resume, operations, console, request: request)
    }

    /// The leader: the model and options, the sync, the start, serving.
    static func leader(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations,
                       _ console: ClusterOnboardingConsole, justPaired: Bool, request: ClusterOnboardingRequest = .init()) -> Int32 {
        switch operations.ensureService() {
        case .success(let line): console.say(line)
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        if justPaired { console.say(localNetworkLine) }
        // Serving, or stopped after a model was chosen: the same menu as on a member (a stopped leader is offered `v`,
        // whether both Macs released their memory, as well as `m`). Only a leader that never chose a model goes
        // straight to the choice.
        if !justPaired, resume.serving || resume.modelName != nil {
            console.say("This Mac leads the cluster.")
            return menu(resume, operations, console, request: request)
        }
        return chooseAndServe(operations, console, scope: request.scope ?? resume.scope, saveScope: request.scope != nil,
                              model: request.model)
    }

    /// Status, then one key: the same on every member (a member's commands are forwarded to the leader).
    /// `darkbloom cluster local` comes here asking for local-only serving: a cluster that is not serving (or asked for
    /// a model by name) goes to the choice and starts that way; a serving cluster switches and serves again.
    static func menu(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                     request: ClusterOnboardingRequest = .init()) -> Int32 {
        if let wanted = request.scope {
            if request.model != nil || !resume.serving {
                return chooseAndServe(operations, console, scope: wanted, saveScope: true, model: request.model)
            }
            if wanted != resume.scope { return changeScope(to: wanted, resume, operations, console) }
        }
        console.heading("Cluster status")
        for line in operations.status() { console.say("  " + line) }
        // A cable moved to a port that was never set up: the one thing to do first (2026-10-16, Thunderbolt 1).
        if let port = resume.unsetCablePort {
            console.say("The cable is on \(port), which is not set up for the cluster, so the Macs cannot reach each other.")
            console.say("Press f to set it up (macOS asks for your password once).")
        }
        if resume.serving {
            console.say("Enter  Leave setup unchanged")
            console.say("t  Test a response    m  Change model    s  Stop serving")
        } else {
            console.say("Not serving. Press m to choose a model and serve; enter to leave.")
        }
        console.say("v  Check both Macs released their memory")
        // The other way to serve, one key: `l` serves locally only, `p` through Darkbloom again (kept until changed).
        console.say(resume.scope.isLocalOnly ? "This cluster serves locally only (no coordinator); press p to serve through Darkbloom instead."
                                             : "Press l to serve locally only (no coordinator).")
        while true {
            guard let key = console.key(milliseconds: 60_000) else {
                if console.closed { return 0 }
                continue
            }
            switch key {
            case "\r", "\n", "q", "Q": return 0
            case "l" where !resume.scope.isLocalOnly, "L" where !resume.scope.isLocalOnly:
                return changeScope(to: .localOnly(bind: ClusterServingScope.localOnlyDefaultBind), resume, operations, console)
            case "p" where resume.scope.isLocalOnly, "P" where resume.scope.isLocalOnly:
                return changeScope(to: .publicServing, resume, operations, console)
            case "t" where resume.serving, "T" where resume.serving: return test(operations, console) ? 0 : 1
            case "s" where resume.serving, "S" where resume.serving:
                switch operations.stop() {
                case .success(let lines):
                    for line in lines { console.say(line) }
                    return 0
                case .failure(let failure):
                    for line in failure.lines { console.say(line) }
                    return 1
                }
            case "v", "V":
                switch operations.verifyTeardown() {
                case .success(let lines):
                    for line in lines { console.say("  " + line) }
                    return 0
                case .failure(let failure):
                    for line in failure.lines { console.say(line) }
                    return 1
                }
            case "m", "M": return chooseAndServe(operations, console, scope: resume.scope)
            case "f" where resume.unsetCablePort != nil, "F" where resume.unsetCablePort != nil:
                let result = checkLink(operations, console)
                console.say(result.ready ? "The cable's port is set up; the cluster re-forms by itself in a moment."
                                         : "The port is not set up yet; run `darkbloom cluster` again to try once more.")
                return result.ready ? 0 : 1
            default: continue
            }
        }
    }

    /// Saves the other way to serve on the control leader. A serving cluster starts its leading part again that way
    /// (the setup and the model stay), so the screen waits for it as it does after a start.
    static func changeScope(to wanted: ClusterServingScope, _ resume: ClusterOnboardingResume,
                            _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        console.say(wanted.isLocalOnly ? "Serving locally only from now on (no coordinator)…" : "Serving through Darkbloom from now on…")
        switch operations.setScope(wanted) {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say("Nothing was changed.")
            return 1
        }
        console.say(wanted.line + ".")
        guard resume.serving else {
            console.say("Not serving now: the next start serves this way. Press m in `darkbloom cluster` to choose a model.")
            return 0
        }
        return awaitReady(title: resume.modelName ?? "the model", operations, console) ? 0 : 1
    }

    /// How long the start waits for n after the model is chosen (the choice is the start).
    static let startSeconds = 3

    /// Each reason once, where it first appears.
    static func reasonsInOrder(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// The choice, then the start. `scope` is how it will serve (what the screen says); `saveScope` saves it on the
    /// control leader first (`darkbloom cluster local`); `model` names the choice so the list is not asked.
    static func chooseAndServe(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                               scope: ClusterServingScope = .publicServing, saveScope: Bool = false, model: String? = nil) -> Int32 {
        console.heading("3 / 5  Choose a model")
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
        console.say("Working out the fastest way to split each model across both Macs…")
        if let notice = operations.developerNotice() { console.say(notice) }
        let choices: [ClusterOnboardingModelChoice]
        switch operations.planModels() {
        case .success(let value): choices = value
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        // The choices that fit now come first, so enter (= 1) is one that fits.
        let offered = choices.indices.filter { choices[$0].blocker == nil }
        let open = offered.filter { choices[$0].fitRemedy == nil } + offered.filter { choices[$0].fitRemedy != nil }
        // One line per model (owner, 2026-10-15: shorter screens); a second only when it does not fit now. What moves
        // and the planner's reasons are said once a model is chosen.
        let titles = choices.map(\.title)
        for (number, index) in open.enumerated() {
            let shared = titles.filter { $0 == choices[index].title }.count > 1
            console.say("  \(number + 1). " + choices[index].listLine(sameTitleElsewhere: shared))
            if let remedy = choices[index].fitRemedy { console.say("       does not fit now: " + remedy) }
        }
        let blocked = choices.indices.filter { choices[$0].blocker != nil }
        if !blocked.isEmpty {
            console.say("  Not offered:")
            // One line per reason, the models it holds back named before it, in the order the planner listed them.
            for reason in Self.reasonsInOrder(blocked.compactMap { choices[$0].blocker }) {
                let titles = blocked.filter { choices[$0].blocker == reason }.map { choices[$0].title }
                console.say("     \(titles.joined(separator: ", ")): \(reason)")
            }
        }
        guard !open.isEmpty else {
            console.say("No model can be served by these Macs now; the reasons are above.")
            return 1
        }
        var chosen: Int?
        if let model {
            // Named on the command line: matched to a model id or title, without the list's question.
            let named = { (index: Int) in
                [choices[index].modelID, choices[index].title].contains { $0?.caseInsensitiveCompare(model) == .orderedSame }
            }
            if let index = open.first(where: named) {
                chosen = index
                console.say("Chosen: \(choices[index].title).")
            } else if let index = blocked.first(where: named) {
                console.say("\(choices[index].title) is not offered on these Macs: \(choices[index].blocker!)")
                return 1
            } else {
                console.say("No model on the list is named \(model); choose one by its number.")
            }
        }
        if chosen == nil {
            console.say("")
            console.say("Enter selects \(choices[open[0]].title). Choose another model by number.")
        }
        while chosen == nil {
            guard let typed = console.line(prompt: "Choose a model [1-\(open.count), enter = 1]: ") else { return 1 }
            let text = typed.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { chosen = open[0]; break }
            if let number = Int(text), (1...open.count).contains(number) { chosen = open[number - 1]; break }
            console.say("Type a number from 1 to \(open.count), or press enter for 1.")
        }
        var choice = choices[chosen!]
        // The chosen model's other lines: the planner's reason, and whether public traffic may reach it (not when the
        // cluster serves locally only).
        for line in choice.lines.dropFirst() { console.say("  " + line) }
        if !scope.isLocalOnly, let line = choice.publicTraffic { console.say("  " + line) }
        if let offer = choice.provision {
            switch provision(offer, title: choice.title, index: chosen!, operations, console) {
            case .stopped: return 0
            case .failed: return 1
            case .done:
                // A model this Mac downloaded is planned from its own files now.
                if offer.leaderDownloads {
                    console.say("Planning \(choice.title) now that it is on this Mac…")
                    guard case .success(let again) = operations.planModels(),
                          let index = again.firstIndex(where: { ($0.modelID ?? $0.title) == (choice.modelID ?? choice.title) }) else {
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
        console.heading("4 / 5  Start the model")
        console.say(scope.isLocalOnly
            ? "Options: always on (each Mac starts its part again by itself); \(scope.line.prefix(1).lowercased() + scope.line.dropFirst())."
            : "Options: always on (each Mac starts its part again by itself); public serving through Darkbloom is off in this build.")
        // The choice is the start: a moment to stop it, no second question.
        console.say("Starting \(choice.title) on both Macs in \(startSeconds) s; press n to stop here.")
        let deadline = Date().addingTimeInterval(Double(startSeconds))
        wait: while Date() < deadline {
            guard let key = console.key(milliseconds: max(1, Int(deadline.timeIntervalSinceNow * 1000))) else {
                if console.closed { break wait }
                continue
            }
            switch key {
            case "\r", "\n", "y", "Y": break wait
            case "n", "N", "q", "Q":
                console.say("Nothing was changed. Run `darkbloom cluster` here again to choose.")
                return 0
            default: continue
            }
        }
        // Memory moves while the person reads: the fit is checked again right before anything starts.
        if let remedy = operations.recheckFit(chosen!) {
            console.say("\(choice.title) does not fit in the Macs' free memory now: \(remedy)")
            console.say("Nothing was changed. Run `darkbloom cluster` here again after that.")
            return 1
        }
        console.say("Saving the setup and sending it to the other Mac over the cable…")
        switch operations.adopt(chosen!) {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        // After the adopt (which stopped a running model first), so the scope never restarts the old model.
        if saveScope {
            switch operations.setScope(scope) {
            case .success(let lines): for line in lines { console.say("  " + line) }
            case .failure(let failure):
                for line in failure.lines { console.say("  " + line) }
                return 1
            }
        }
        switch operations.serve() {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        console.say("Starting both Macs' parts and loading the model…")
        guard awaitReady(title: choice.title, operations, console) else { return 1 }
        let tested = test(operations, console, setup: true)
        console.say("")
        if tested {
            console.say("Done. Run `darkbloom cluster` on any of these Macs to see it, change the model or stop it.")
        } else {
            console.say("Setup saved, but the test request failed.")
            console.say("Run `darkbloom cluster` to check status and retry the test with t.")
        }
        console.say("Nothing else is needed on the other Mac." + (operations.afterRestart().map { " " + $0 } ?? ""))
        return tested ? 0 : 1
    }

    /// Waits for the started cluster with its progress, then says where it serves; false (with the last errors and the
    /// diagnostics offer) when it did not become ready.
    static func awaitReady(title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
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
            for line in where_.lines(model: title) { console.say(line + ".") }
            return true
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            offerDiagnostics(operations, console)
            console.say("Both Macs keep trying by themselves; run `darkbloom cluster` here to see how it is going.")
            return false
        }
    }

    /// One key to save a diagnostics file (redacted) after a start that did not finish.
    static func offerDiagnostics(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) {
        console.say("Press d to save a diagnostics file to send to Darkbloom, enter to leave.")
        while true {
            guard let key = console.key(milliseconds: 60_000) else {
                if console.closed { return }
                continue
            }
            switch key {
            case "d", "D":
                switch operations.saveDiagnostics() {
                case .success(let lines): for line in lines { console.say("  " + line) }
                case .failure(let failure): for line in failure.lines { console.say("  " + line) }
                }
                return
            case "\r", "\n", "q", "Q", "n", "N": return
            default: continue
            }
        }
    }

    enum ProvisionOutcome { case done, stopped, failed }

    /// Says what has to move for the chosen model, asks once (enter = the recommended way), and moves it with progress.
    static func provision(_ offer: ClusterOnboardingProvisionOffer, title: String, index: Int,
                          _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ProvisionOutcome {
        console.say("")
        console.say(offer.leaderDownloads ? "\(title) is not on this Mac yet. No download by hand is needed:"
                                          : "\(title) is not on every Mac yet. No download by hand is needed:")
        for line in offer.lines { console.say("  " + line) }
        if let blocker = offer.blocker {
            console.say("It cannot start: \(blocker). Free some space and run `darkbloom cluster` here again.")
            return .failed
        }
        var download = false
        if let seconds = offer.quickSeconds {
            // A short copy is not asked for: said, with a moment to stop it (or take the catalog instead).
            let alternative = offer.downloadAlternative ? ", d to download it from Darkbloom's catalog instead" : ""
            console.say("Copying it over the Thunderbolt cable now (\(Self.duration(seconds)) at the speed measured on these Macs); press n in the next 3 s to stop here\(alternative).")
            let deadline = Date().addingTimeInterval(3)
            wait: while Date() < deadline {
                guard let key = console.key(milliseconds: max(1, Int(deadline.timeIntervalSinceNow * 1000))) else {
                    if console.closed { return .stopped }
                    continue
                }
                switch key {
                case "\r", "\n", "c", "C": break wait
                case "d" where offer.downloadAlternative, "D" where offer.downloadAlternative: download = true; break wait
                case "n", "N", "q", "Q":
                    console.say("Nothing was copied or downloaded. Run `darkbloom cluster` here again to choose.")
                    return .stopped
                default: continue
                }
            }
            return move(index: index, download: download, operations, console)
        }
        if offer.leaderDownloads {
            console.say("Press enter to get it, n to stop here.")
        } else if offer.downloadAlternative {
            console.say("Press enter to copy it over the Thunderbolt cable (recommended), d to download it from Darkbloom's catalog instead, n to stop here.")
        } else {
            console.say("Press enter to copy it over the Thunderbolt cable, n to stop here.")
        }
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
        return move(index: index, download: download, operations, console)
    }

    /// "about 3 s", "about 2 min" (as `ClusterModelProvisioning.duration`, which this file does not link).
    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "about \(max(1, Int(seconds.rounded()))) s" : "about \(Int((seconds / 60).rounded())) min"
    }

    /// Moves the chosen model with progress until it is done or failed.
    static func move(index: Int, download: Bool, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> ProvisionOutcome {
        let progress = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Result<[String], ClusterOnboardingFailure>>()
        let chosenDownload = download
        Thread.detachNewThread { finished.post(operations.provision(index, chosenDownload) { progress.post($0) }) }
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

    static func test(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole, setup: Bool = false) -> Bool {
        console.heading(setup ? "5 / 5  Test a response" : "Test a response")
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
