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
            return "Serving through Darkbloom"
        case .localOnly(let bind):
            let reach = bind == Self.localOnlyDefaultBind ? "on this Mac's networks"
                : reachableFromNetwork ? "at \(bind)" : "on this Mac only (\(bind))"
            return "Local only, \(reach); API key: `darkbloom local`"
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

    public init(role: ClusterOnboardingRole? = nil, peerName: String? = nil, serving: Bool = false, modelName: String? = nil) {
        self.role = role; self.peerName = peerName; self.serving = serving; self.modelName = modelName
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

    public init(title: String, lines: [String], blocker: String?, provision: ClusterOnboardingProvisionOffer? = nil, fitRemedy: String? = nil,
                modelID: String? = nil, publicTraffic: String? = nil, tensorParallelNote: String? = nil, validated: Bool? = nil,
                split: String? = nil) {
        self.title = title; self.lines = lines; self.blocker = blocker; self.provision = provision; self.fitRemedy = fitRemedy
        self.modelID = modelID; self.publicTraffic = publicTraffic; self.tensorParallelNote = tensorParallelNote
        self.validated = validated; self.split = split
    }

    /// Offered on the setup's list: it can be served on these Macs and is not known to be unapproved.
    public var listed: Bool { blocker == nil && validated != false }

    /// The list's one line: the title (with the model's id when another choice shows the same title) and its size,
    /// the first fact of its first line, the split's marker, then "copy" or "download" when it has to reach a Mac
    /// first (2026-11-03: the list keeps only what the choice needs; the owner kept whether it is tensor parallel or
    /// a pipeline, the rest of the plan is the planner's business).
    public func listLine(sameTitleElsewhere: Bool) -> String {
        let name = sameTitleElsewhere ? "\(title) (\(modelID ?? title))" : title
        let size = lines.first?.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 }
        let move = provision.map { $0.leaderDownloads && !$0.fromOtherMac ? "download" : "copy" }
        return ([name] + [size, ClusterOnboardingDeployment.shownMarker(split), move].compactMap { $0 }).joined(separator: " · ")
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
    public init(servedBy: String, port: Int, deployment: String? = nil, notice: String? = nil, network: Bool? = nil,
                offered: String? = nil, split: String? = nil) {
        self.servedBy = servedBy; self.port = port; self.deployment = deployment; self.notice = notice; self.network = network
        self.offered = offered; self.split = split
    }

    /// The screens' one line (2026-11-03: less is better), "Serving Qwen3.8 27B (pipeline) at http://localhost:8000",
    /// with the split's marker the owner kept: when rank 0, which serves the API, is the other Mac the line says so
    /// (this Mac's own loopback serves nothing), and listening on the network too, it says that. Offered for pairing,
    /// the offered line instead: there is no local API.
    public func summary(model: String) -> String {
        let name = ClusterOnboardingDeployment.shownMarker(split).map { "\(model) (\($0))" } ?? model
        if let offered { return "Serving \(name): \(offered)" }
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
            + (servesHere ? "" : "; this Mac answers too (`darkbloom local` shows its address)")
    }

    private var servesHere: Bool { servedBy == ClusterOnboardingMacName.this }

    /// The local-serving line as this screen shows it. The part that serves words it for its own Mac ("this Mac's
    /// API"); on the screen of the other Mac (a member's status, or a leader whose API moved) it is that Mac's API,
    /// which `apiLine` names just above.
    public var noticeLine: String? {
        guard let notice else { return nil }
        return servesHere ? notice : notice.replacingOccurrences(of: "this Mac's API", with: "that Mac's API")
    }

    /// How the line of a pair registered with the coordinator as a cluster member starts (`ClusterLocalServing`).
    public static let registeredNotice = "Registered with the coordinator as a cluster member"

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
    /// Every Mac of the cluster, the leader first, read over the link control channel.
    public var reachMembers: @Sendable () -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>
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

    public init(resume: @escaping @Sendable () -> ClusterOnboardingResume,
                checkLink: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> ClusterOnboardingLinkResult,
                pair: @escaping @Sendable (@escaping @Sendable (ClusterOnboardingPairEvent) -> Void) -> ClusterOnboardingPairResult,
                answerCode: @escaping @Sendable (Bool) -> Void,
                ensureService: @escaping @Sendable () -> Result<Void, ClusterOnboardingFailure>,
                reachMembers: @escaping @Sendable () -> Result<[ClusterOnboardingMachine], ClusterOnboardingFailure>,
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
                afterRestart: @escaping @Sendable () -> String? = { nil },
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
                thisMacName: @escaping @Sendable () -> String? = { nil }) {
        self.resume = resume; self.checkLink = checkLink; self.pair = pair; self.answerCode = answerCode
        self.ensureService = ensureService; self.reachMembers = reachMembers; self.planModels = planModels
        self.adopt = adopt; self.serve = serve; self.waitReady = waitReady; self.testRequest = testRequest
        self.status = status; self.stop = stop; self.provision = provision; self.verifyTeardown = verifyTeardown
        self.useLinkPort = useLinkPort; self.recheckFit = recheckFit; self.afterRestart = afterRestart; self.saveDiagnostics = saveDiagnostics
        self.developerNotice = developerNotice; self.setScope = setScope; self.register = register
        self.localNetwork = localNetwork; self.commandApp = commandApp; self.runAsAdministrator = runAsAdministrator
        self.serviceOutlivesWindow = serviceOutlivesWindow; self.remote = remote; self.thisMacName = thisMacName
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

    public init() {}

    /// The one thing to do on the other Mac while this one waits: said last, so it is the line the person reads.
    public static let otherMacLine = "Run `darkbloom cluster` on the other Mac."

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
        case .waiting: return "Waiting for the other Mac (run `darkbloom cluster` there; q cancels)"
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
            return [Self.otherMacLine]
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
    func heading(_ title: String)
    /// The setup's opening: its name and the steps ahead.
    func banner(_ title: String, _ subtitle: String)
    /// Work that is still running, said again while it runs; the next said
    /// line replaces it. A transcript shows nothing extra.
    func working(_ text: String)
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
    /// Runs `body` with the terminal in its ordinary mode, nothing live on screen (sudo asks for a password there).
    func suspended<T>(_ body: () -> T) -> T
    /// The input is closed: nothing more can be asked.
    var closed: Bool { get }
}

public extension ClusterOnboardingConsole {
    /// Scrollable sections also work in transcripts and non-terminal consoles.
    func heading(_ title: String) { say(""); say(title) }
    func banner(_ title: String, _ subtitle: String) { heading(title); if !subtitle.isEmpty { say(subtitle) } }
    func working(_ text: String) {}
    func settle() {}
    func progress(_ text: (_ width: Int?) -> String, logged: Bool) { if logged { say("  " + text(nil)) } }
    func suspended<T>(_ body: () -> T) -> T { body() }

    func choose(_ options: [String], selected: Int = 0) -> Int? { choose(options, selected: selected, abandon: { false }) }
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
        switch resume.role {
        case .member:
            console.banner(title, followerSubtitle(named: named))
            return member(resume, operations, console, request: request)
        case .leader:
            console.banner(title, leaderSubtitle(named: named))
            return leader(resume, operations, console, justPaired: false, request: request)
        case nil: return onboard(operations, console, request: request)
        }
    }

    /// The setup's opening (the name alone), and the opening on a Mac that is already in a cluster (`darkbloom
    /// cluster` run again): the same mark, with the part this Mac plays. `named`: this Mac's own name beside "This
    /// Mac" (`thisMac`).
    public static let title = "Darkbloom cluster"
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

    /// What to answer, for the program macOS names. `remote` (over SSH): the prompt is on this Mac's own screen, not in
    /// this terminal.
    public static func localNetworkLine(_ app: String, remote: Bool = false) -> String {
        "Click Allow on the Local Network prompt for \(app)\(onScreen(remote))."
    }

    /// The same where the probe could not tell whether macOS will ask (nothing to wait for).
    public static func localNetworkMaybeLine(_ app: String, remote: Bool = false) -> String {
        "If macOS asks about Local Network for \(app)\(onScreen(remote)), click Allow."
    }

    private static func onScreen(_ remote: Bool) -> String {
        remote ? " on this Mac's screen (Screen Sharing if headless)" : ""
    }

    /// Said once paired: both cluster services ask at the same moment, one on each Mac.
    public static let otherMacAllowLine = "Allow it on the other Mac too."

    /// Connect's first line: every approval the setup asks for on this Mac (2026-11-02 review: "bundle all of the
    /// permissions ahead of time").
    public static func approvalsLine(remote: Bool) -> String {
        remote ? "Allow macOS's password prompt here and its Local Network prompt on this Mac's screen (Screen Sharing if headless)."
            : "Allow macOS's password and Local Network prompts."
    }

    /// The Mac that joined ends its onboarding once paired; the last thing it says (the one thing to do next), with
    /// whether its window may close.
    public static let joinedLine = "Done here: the other Mac chooses the model."

    /// The same, for a Mac that joined when it was asked for `darkbloom cluster local`.
    public static let joinedLocalContinueLine = "Done here: run `darkbloom cluster local` on the other Mac."

    /// Said on the Mac that joined when it was asked for `darkbloom cluster local` (a model too, perhaps): nothing of it
    /// runs here, because the Mac that leads chooses how the cluster serves and its model.
    public static let joinedLocalLine = "Run `darkbloom cluster local` on the other Mac: it leads."

    /// Whether the window may close: a login agent keeps serving; a service for this session only (a development
    /// build, or one launchd did not take as a login agent) does not.
    public static let closeWindowLine = "You can close this window."
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
                                  _ console: ClusterOnboardingConsole) -> Bool {
        let app = subject == .service ? "Darkbloom" : operations.commandApp()
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
            if subject == .service { console.say("  " + localNetworkMaybeLine(app, remote: remote) + " " + otherMacAllowLine) }
            return true
        case .blocked: break
        }
        console.say("  " + localNetworkLine(app, remote: remote) + (subject == .service ? " " + otherMacAllowLine : ""))
        let started = Date()
        var hinted = false
        while !console.closed {
            if !hinted, Date().timeIntervalSince(started) >= settingsHintSeconds {
                hinted = true
                console.settle()
                console.say("  No prompt? Turn on \(app) in System Settings → Privacy & Security → Local Network.")
            }
            console.working("Waiting for Allow (q cancels)")
            if let key = console.key(milliseconds: 1_000), key == "q" || key == "Q" || key == "\u{1B}" { break }
            state = operations.localNetwork(subject)
            if state == .allowed {
                console.settle()
                console.say("  \(done) Allowed")
                return true
            }
        }
        console.settle()
        console.say("Local Network is off for \(app). Turn it on in System Settings → Privacy & Security → Local Network, "
            + "then run `darkbloom cluster` again.")
        return false
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

    /// No pairing yet: checks, then find a waiting leader or become one.
    static func onboard(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                        request: ClusterOnboardingRequest = .init()) -> Int32 {
        console.banner(title, "")
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
        var pairing = ClusterOnboardingPairing()
        var result: ClusterOnboardingPairResult?
        func show() { for event in events.take() { for line in pairing.handle(event) { console.say("  " + line) } } }
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
            guard allowLocalNetwork(.service, operations, console) else { return 1 }
            // Nothing else is asked on the Mac that joined, `darkbloom cluster local` included: the Mac that leads is on
            // its own model list by now (2026-10-25: both Macs showed the list). Its last line is the one thing to do
            // on the other Mac, `local` included, and whether this window may close.
            console.say("")
            if let restart = operations.afterRestart() { console.say(restart) }
            console.say((request.scope?.isLocalOnly == true ? joinedLocalContinueLine : joinedLine) + " "
                + (operations.serviceOutlivesWindow() ? closeWindowLine : keepWindowLine))
            return 0
        case .leader:
            return leader(.init(role: .leader, peerName: peerName), operations, console, justPaired: true, request: request)
        }
    }

    /// The member's last line once it is in a cluster: where the cluster is managed.
    public static let memberNothingLine = "Nothing to do here: manage it on the other Mac (`darkbloom cluster`)."

    /// A member: its part runs by itself and the cluster is managed on the Mac that leads, so it shows the cluster as
    /// it is and says where to manage it (2026-11-02: "why does the member have the choices to change model, test …").
    static func member(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                       request: ClusterOnboardingRequest = .init()) -> Int32 {
        guard startService(operations, console) else { return 1 }
        for line in operations.status() { console.say("  " + line) }
        if let port = resume.unsetCablePort {
            // The cable moved to a port that was never set up: the one thing that is this Mac's to do.
            console.say("")
            console.say(unsetPortLine(port))
            guard console.choose([fixPortItem, "Quit"], selected: 0) == 0 else { return 0 }
            return fixPort(operations, console)
        }
        console.say("")
        if request.scope != nil || request.model != nil {
            console.say(joinedLocalLine)
            return 1
        }
        console.say(memberNothingLine)
        return 0
    }

    /// The leader: the model and options, the sync, the start, serving.
    static func leader(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations,
                       _ console: ClusterOnboardingConsole, justPaired: Bool, request: ClusterOnboardingRequest = .init()) -> Int32 {
        guard startService(operations, console) else { return 1 }
        if justPaired { guard allowLocalNetwork(.service, operations, console) else { return 1 } }
        // Serving, or stopped after a model was chosen: the menu. Only a leader that never chose a model goes straight
        // to the choice.
        if !justPaired, resume.serving || resume.modelName != nil {
            return menu(resume, operations, console, request: request)
        }
        return chooseAndServe(operations, console, scope: request.scope ?? resume.scope, saveScope: request.scope != nil,
                              model: request.model, privateImage: request.privateImageQualification)
    }

    /// One thing the leader's menu does.
    enum MenuItem { case fixPort, test, model, scope, stop, verify, quit }

    /// The status, then one choice from a list. `darkbloom cluster local` comes here asking for local-only serving: a
    /// cluster that is not serving (or asked for a model by name) goes to the choice and starts that way; a serving
    /// cluster switches and serves again.
    static func menu(_ resume: ClusterOnboardingResume, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                     request: ClusterOnboardingRequest = .init()) -> Int32 {
        if let wanted = request.scope {
            if request.model != nil || !resume.serving {
                return chooseAndServe(operations, console, scope: wanted, saveScope: true, model: request.model,
                                      privateImage: request.privateImageQualification)
            }
            if wanted != resume.scope { return changeScope(to: wanted, resume, operations, console) }
        }
        for line in operations.status() { console.say("  " + line) }
        var items = [(MenuItem, String)]()
        if let port = resume.unsetCablePort {
            // A cable moved to a port that was never set up: the one thing to do first (2026-10-16, Thunderbolt 1).
            console.say(unsetPortLine(port))
            items.append((.fixPort, fixPortItem))
        }
        if resume.serving { items.append((.test, "Test")) }
        items.append((.model, resume.serving ? "Change model" : "Choose a model"))
        items.append((.scope, resume.scope.isLocalOnly ? "Serve through Darkbloom" : "Serve locally"))
        if resume.serving { items.append((.stop, "Stop")) }
        items.append((.verify, "Check memory is freed"))
        items.append((.quit, "Quit"))
        console.say("")
        guard let index = console.choose(items.map(\.1), selected: 0) else { return 0 }
        switch items[index].0 {
        case .quit: return 0
        case .test: return test(operations, console) ? 0 : 1
        case .model: return chooseAndServe(operations, console, scope: resume.scope, privateImage: request.privateImageQualification)
        case .scope:
            return changeScope(to: resume.scope.isLocalOnly ? .publicServing : .localOnly(bind: ClusterServingScope.localOnlyDefaultBind),
                               resume, operations, console)
        case .stop:
            switch busy(console, "Stopping both Macs", operations.stop) {
            case .success(let lines):
                for line in lines { console.say(line) }
                return 0
            case .failure(let failure):
                for line in failure.lines { console.say(line) }
                return 1
            }
        case .verify:
            switch busy(console, "Asking both Macs", operations.verifyTeardown) {
            case .success(let lines):
                for line in lines { console.say("  " + line) }
                return 0
            case .failure(let failure):
                for line in failure.lines { console.say(line) }
                return 1
            }
        case .fixPort: return fixPort(operations, console)
        }
    }

    /// The cable moved to a port that was never set up (the Macs cannot reach each other there), and the one item that
    /// sets it up (macOS asks for the password).
    static func unsetPortLine(_ port: String) -> String { "The cable is on \(port), which isn't set up." }
    static let fixPortItem = "Set up the cable port"

    /// Sets up the port the cable moved to (macOS asks once), and says how it went.
    static func fixPort(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
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

    /// Saves the other way to serve on the control leader. A serving cluster starts its leading part again that way
    /// (the setup and the model stay), so the screen waits for it as it does after a start.
    static func changeScope(to wanted: ClusterServingScope, _ resume: ClusterOnboardingResume,
                            _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Int32 {
        switch busy(console, wanted.isLocalOnly ? "Switching to local only" : "Switching to serving through Darkbloom", { operations.setScope(wanted) }) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            console.say("Nothing changed.")
            return 1
        }
        console.say(wanted.line + ".")
        guard resume.serving else {
            console.say("Takes effect at the next start.")
            return 0
        }
        let title = resume.modelName ?? "the model"
        guard let ready = awaitReady(title: title, operations, console) else { return 1 }
        console.say("  \(done) " + ready.summary(model: title) + servesWords(scope: wanted, ready: ready))
        return 0
    }

    /// Each reason once, where it first appears.
    static func reasonsInOrder(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    /// The choice, then the start. `scope` is how it will serve; `saveScope` saves it on the control leader first
    /// (`darkbloom cluster local`); `model` names the choice so the list is not asked; `privateImage`: a private image
    /// candidate, which never takes public traffic.
    static func chooseAndServe(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole,
                               scope: ClusterServingScope = .publicServing, saveScope: Bool = false, model: String? = nil,
                               privateImage: Bool = false) -> Int32 {
        console.heading("3/4 Model")
        var reached: [ClusterOnboardingMachine]?
        while reached == nil {
            switch busy(console, "Reading both Macs over the cable", operations.reachMembers) {
            case .success(let value): reached = value
            case .failure(let failure):
                for line in failure.lines { console.say(line) }
                // Once paired, the other Mac's service may still wait for its Allow (both Macs ask at the same moment).
                guard console.choose(["Try again", "Cancel"], selected: 0) == 0 else {
                    console.say("Nothing changed. Run `darkbloom cluster` again when the other Mac is on.")
                    return 1
                }
            }
        }
        if let notice = operations.developerNotice() { console.say(notice) }
        let choices: [ClusterOnboardingModelChoice]
        switch busy(console, "Planning each model for both Macs", operations.planModels) {
        case .success(let value): choices = value
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            return 1
        }
        // Only models the owner approved for clusters that these Macs can serve, those that fit now first, so enter
        // picks one that fits (2026-11-02: the list showed the whole catalog).
        let listed = choices.indices.filter { choices[$0].listed }
        let open = listed.filter { choices[$0].fitRemedy == nil } + listed.filter { choices[$0].fitRemedy != nil }
        guard !open.isEmpty else {
            console.say("No approved model can run on these Macs now.")
            // One line per reason, the approved models it holds back named before it.
            let held = choices.indices.filter { choices[$0].validated != false && choices[$0].blocker != nil }
            for reason in reasonsInOrder(held.compactMap { choices[$0].blocker }) {
                let titles = held.filter { choices[$0].blocker == reason }.map { choices[$0].title }
                console.say("  \(titles.joined(separator: ", ")): \(reason)")
            }
            return 1
        }
        var chosen: Int?
        if let model {
            // Named on the command line: matched to a model id or title, without the list.
            let named = { (index: Int) in
                [choices[index].modelID, choices[index].title].contains { $0?.caseInsensitiveCompare(model) == .orderedSame }
            }
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
                return choices[index].fitRemedy == nil ? line : line + " · does not fit now"
            }
            guard let picked = console.choose(lines, selected: 0) else {
                console.say("Nothing changed.")
                return 0
            }
            chosen = open[picked]
        }
        var choice = choices[chosen!]
        // A private image candidate says at the choice that it never takes public traffic; whether the pair earns is
        // said once it serves (`servesWords`).
        if privateImage, let line = choice.publicTraffic {
            console.say("  " + ClusterOnboardingMacName.sentence(line) + (line.hasSuffix(".") ? "" : "."))
        }
        if let offer = choice.provision {
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
        console.heading("4/4 Start")
        // Memory moves while the person reads: the fit is checked again right before anything starts.
        if let remedy = operations.recheckFit(chosen!) {
            console.say("\(choice.title) doesn't fit in free memory now: \(remedy)")
            console.say("Nothing changed.")
            return 1
        }
        let index = chosen!
        switch busy(console, "Sending the setup to the other Mac", { operations.adopt(index) }) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        // After the adopt (which stopped a running model first), so the scope never restarts the old model.
        if saveScope {
            switch operations.setScope(scope) {
            case .success: break
            case .failure(let failure):
                for line in failure.lines { console.say("  " + line) }
                return 1
            }
        }
        switch busy(console, "Starting both Macs", operations.serve) {
        case .success: break
        case .failure(let failure):
            for line in failure.lines { console.say("  " + line) }
            return 1
        }
        guard let ready = awaitReady(title: choice.title, operations, console) else { return 1 }
        console.say("  \(done) " + ready.summary(model: choice.title) + servesWords(scope: scope, ready: ready))
        // A pair offered for pairing has no local API to test: its requests come through Darkbloom.
        if ready.offered != nil { console.say(ClusterOnboardingReady.offeredTestLine) }
        let tested = ready.offered != nil || test(operations, console)
        if tested, ready.offered == nil, !scope.isLocalOnly { register(title: choice.title, operations, console) }
        console.say("")
        guard tested else {
            console.say("Setup saved, but the test failed. Run `darkbloom cluster` to test again.")
            return 1
        }
        if let restart = operations.afterRestart() { console.say(restart) }
        console.say("Done. " + (operations.serviceOutlivesWindow() ? "You can close both windows." : "Keep both windows open."))
        console.say(againLine)
        return 0
    }

    /// The leader's last line: `darkbloom cluster` again manages the cluster (its menu tests, changes the model, stops).
    public static let againLine = "Run `darkbloom cluster` again to manage it."

    /// How the pair serves, at the end of the serving line: earning through Darkbloom, or local only (asked for, or a
    /// coordinator without cluster support, which leaves its local-serving notice).
    public static func servesWords(scope: ClusterServingScope, ready: ClusterOnboardingReady) -> String {
        guard ready.offered == nil else { return "" }
        if scope.isLocalOnly { return " (local only)" }
        if let notice = ready.notice, !notice.hasPrefix(ClusterOnboardingReady.registeredNotice) { return " (local only)" }
        return " (earning through Darkbloom)"
    }

    /// After the Test stage: registers the pair with the coordinator when it serves a cluster approval for this pair,
    /// then waits until both Macs serve again. Nothing is said, and nothing stopped, when the coordinator serves none.
    /// A registration that stopped the parts and was then refused also waits: both parts start again as before.
    static func register(title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) {
        let lines: [String]
        switch operations.register() {
        case .success(let said): lines = said
        case .failure(let failure): lines = failure.lines
        }
        guard !lines.isEmpty else { return }
        for line in lines { console.say("  " + line) }
        console.say(lines.first?.hasPrefix(ClusterOnboardingReady.registeredNotice) == true
            ? "Starting both Macs' parts again as cluster members…" : "Starting both Macs' parts again…")
        _ = awaitReady(title: title, operations, console)
    }

    /// Waits for the started cluster with its progress (the caller says where it serves); nil (with the last errors
    /// and the diagnostics offer) when it did not become ready.
    static func awaitReady(title: String, _ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole)
        -> ClusterOnboardingReady? {
        let progress = ClusterOnboardingMailbox<String>()
        let finished = ClusterOnboardingMailbox<Result<ClusterOnboardingReady, ClusterOnboardingFailure>>()
        Thread.detachNewThread { finished.post(operations.waitReady { progress.post($0) }) }
        var ready: Result<ClusterOnboardingReady, ClusterOnboardingFailure>?
        // The parts' progress ("1 of 2 parts ready") is the live line only: the screen keeps the result.
        var latest: String?
        while ready == nil {
            if let line = progress.take().last { latest = line }
            if let value = finished.take().first { ready = value; break }
            console.working("Loading \(title) on both Macs" + (latest.map { " (\($0))" } ?? ""))
            _ = console.key(milliseconds: 120)
        }
        console.settle()
        switch ready! {
        case .success(let where_):
            return where_
        case .failure(let failure):
            for line in failure.lines { console.say(line) }
            offerDiagnostics(operations, console)
            console.say("Both Macs keep trying. Run `darkbloom cluster` to check.")
            return nil
        }
    }

    /// One choice to save a diagnostics file (redacted) after a start that did not finish.
    static func offerDiagnostics(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) {
        guard console.choose(["Save diagnostics for Darkbloom", "Skip"], selected: 0) == 0 else { return }
        switch operations.saveDiagnostics() {
        case .success(let lines): for line in lines { console.say("  " + line) }
        case .failure(let failure): for line in failure.lines { console.say("  " + line) }
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

    /// One test request; one line ("✓ Test response in 0.6 s, 120.0 tokens/s"), or what went wrong.
    static func test(_ operations: ClusterOnboardingOperations, _ console: ClusterOnboardingConsole) -> Bool {
        switch busy(console, "Sending a test request", operations.testRequest) {
        case .success(let lines):
            console.say("  \(done) Test response" + (lines.first.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""))
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

    /// Something was posted and not taken yet.
    var hasItems: Bool { lock.lock(); defer { lock.unlock() }; return !items.isEmpty }

    func take() -> [Value] {
        lock.lock()
        defer { items.removeAll(); lock.unlock() }
        return items
    }
}
