import DarkbloomClusterProtocol
import Foundation

/// One Mac's side of a pair run.
public struct PairSide: Equatable, Sendable {
    public var modelDirectory: String
    public var workerPath: String
    public var rdmaDevice: String
    public var scratchDirectory: String

    public init(modelDirectory: String, workerPath: String, rdmaDevice: String, scratchDirectory: String) {
        self.modelDirectory = modelDirectory; self.workerPath = workerPath
        self.rdmaDevice = rdmaDevice; self.scratchDirectory = scratchDirectory
    }
}

/// Every input of a pair run, validated before anything is launched. Values
/// that reach a shell are restricted to characters that need no quoting, and
/// are single-quoted anyway.
/// One side's prompt-prefix SSD tier for a qualification run.
public struct PairPrefixSSD: Equatable, Sendable {
    public var directory: String
    public var keyFile: String
    public init(directory: String, keyFile: String) { self.directory = directory; self.keyFile = keyFile }
}

public struct PairConfiguration: Sendable {
    public static let roles = ["rank 0 local", "rank 1 remote"]
    public static let peerIDs = ["rank0-local", "rank1-remote"]
    /// Which rank the local process holds. 0 is the arrangement every run
    /// before this option had, with its labels and bytes unchanged. 1 turns
    /// the sides round: rank 0 runs on the second Mac behind the remote
    /// transport and rank 1 here, for a placement whose first range belongs
    /// on the second Mac when only this Mac can reach the other.
    public var localRank = 0
    /// Each rank's role in a report, saying which side held it.
    public var roles: [String] { localRank == 0 ? Self.roles : ["rank 0 remote", "rank 1 local"] }
    /// Each rank's member ID in the worker identity both ranks are given.
    public var peerIDs: [String] { localRank == 0 ? Self.peerIDs : ["rank0-remote", "rank1-local"] }
    public static let arithmeticEnvironment = [
        ("DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "128"), ("DARKBLOOM_BF16_WEIGHTS", "1"), ("MLX_ENABLE_TF32", "1"),
    ]
    public static let pipelineMode = "pipeline_v1"
    public static let phaseSplitMode = "phase_split_v1"
    /// The phase split with the model's speculative head on rank 1.
    public static let phaseSplitMTPMode = "phase_split_mtp_v1"
    /// The pipeline with the model's speculative head on the last rank.
    public static let pipelineMTPMode = "pipeline_mtp_v1"
    /// Tensor parallel: both ranks hold a share of every layer (the dense Qwen rows).
    public static let tensorParallelMode = "tensor_parallel_v1"
    /// The worker argument tensor-parallel share weights are declared with.
    public static let tensorSharesArgument = "--tensor-shares"
    /// The worker argument the speculative head's fixed depth is declared with.
    public static let speculativeDepthArgument = "--mtp-depth"
    /// The pipeline with four transfers per decode step instead of eleven.
    public static let pipelineCompactDecodeMode = "pipeline_compact_decode_v1"
    /// The worker argument a mode other than the pipeline is declared with.
    public static let generationModeArgument = "--generation-mode"
    /// The worker argument without which a worker refuses the two
    /// qualification switches below. Passed only when one of them is set.
    public static let qualificationSwitchesArgument = "--qualification-switches"
    /// A bound on one run's size, not on a session: a worker has no request
    /// count and no lifetime, and an endurance run serves hundreds of requests.
    public static let maximumRepetitions = 100_000
    /// The name a recording worker reads a qualification fault from.
    public static let faultEnvironment = "DARKBLOOM_CLUSTER_QUALIFICATION_FAULT"
    public static let jacclTransport = "jaccl"
    public static let localSocketTransport = "local-socket-test"
    /// The name the runtime reads a declared qualification transport from.
    public static let workerTransportEnvironment = "DARKBLOOM_CLUSTER_TRANSPORT"
    /// Qualification only: the host memory gate records a refusal for
    /// admissible memory alone instead of enforcing it. Both ranks.
    public static let memoryGateEnvironment = "DARKBLOOM_CLUSTER_QUALIFICATION_MEMORY_GATE"
    /// Qualification only, MiMo: run without the stage's standing residency.
    public static let mimoStageResidencyEnvironment = "DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY"
    /// Qualification only, MiMo: rank 1 writes one step line per selected token.
    public static let mimoStepEvidenceEnvironment = "DARKBLOOM_CLUSTER_MIMO_STEP_EVIDENCE"
    /// The name and only value a worker reads a requested standing stage
    /// residency from (S00's measurement; qualification only).
    public static let stageResidencyEnvironment = "DARKBLOOM_CLUSTER_STAGE_RESIDENCY"
    public static let stageResidencyPolicy = "stage_wired_residency_v1"

    public var request: QualificationRequest
    public var stageCut: Int
    public var local: PairSide
    public var remote: PairSide
    /// Argument vector that runs its final argument, a shell command string, on
    /// the second Mac: `/usr/bin/ssh` with its options and destination.
    public var remoteTransport: [String]
    /// Rank 0's own address on the link and a free port; rank 0 listens there.
    /// With `localRank` 1 that is the second Mac's own link address.
    public var coordinator: String
    public var prefillSchedule: String
    public var recording: Bool
    public var startupSeconds: Int
    public var requestSeconds: Int
    public var rankOneDelaySeconds: Double
    public var progressTimeoutMilliseconds: Int?
    /// Refuse a worker that does not contain JACCL's progress guard. Without
    /// it a rank whose peer dies spins in the completion poll forever.
    public var requireProgressGuard: Bool
    /// Leave each side's run directory (device matrix, records) in place.
    public var keepRunFiles: Bool
    /// Inspect both sides and stop: hashes, running workers, runtime
    /// description and the selected cut. Nothing is launched or written.
    public var preflightOnly: Bool
    /// `pipeline_v1`, or `phase_split_v1`: pair prefill, then rank 0 hands its
    /// request state to rank 1, which decodes alone. Declared to both workers.
    public var generationMode: String
    /// `phase_split_mtp_v1` or `pipeline_mtp_v1` only: the speculative head's draft depth, declared
    /// to both workers. Nil: the worker's default (the family's standard terms).
    public var speculativeDepth: Int?
    /// Tensor parallel only: each rank's share weight (rank order); nil is equal.
    public var tensorShares: [Int]?
    /// Requests run one after another in the same loaded session, each with
    /// its own request ID. The first is the warm-up of a timing run.
    public var repetitions: Int
    /// Idle gaps before requests 2, 3, ...: the list repeats. Empty: none.
    /// The session stays loaded and leased throughout; an idle-latency run
    /// reads each request's first-token time against the gap before it.
    public var idleSeconds: [Double] = []
    /// Keep-warm (S27, both tiers): on by default; off for the comparison.
    public var keepWarm = true
    /// Qualification only: both endpoints stop renewing their rank leases this
    /// long after launch, with the inputs still open. The workers must then end
    /// by themselves within the time to live, through the forced exit.
    public var stopRenewalsAfterSeconds: Double?
    /// Requests run once each after the repetitions, in the same loaded
    /// session (prefix reuse across different prompts). Serving path only.
    public var followRequests: [QualificationRequest] = []
    /// Diagnosis: both workers keep no prompt prefixes (cold prefill always).
    public var prefixCacheOff = false
    /// Whether the pair refuses a request longer than its serving context
    /// before asking either rank (the product's behaviour). Off to qualify a
    /// rank's own gate refusal at reservation (`--serving-context-check off`).
    public var servingContextCheck = true
    /// Continuous batching: both workers serve this many requests at once
    /// (`DARKBLOOM_CLUSTER_BATCH_LANES`); one is the one-request owner.
    public var batchLanes = 1
    /// Both workers' stage KV storage (`DARKBLOOM_CLUSTER_KV_BACKEND`); nil
    /// leaves the default (paged).
    public var kvBackend: String?
    /// Request files of the batching phase, after the repetitions: each runs
    /// alone first (`batchSolo`), then each wave starts its first N together.
    public var batchRequests: [QualificationRequest] = []
    public var batchWaves: [Int] = []
    public var batchSolo = true
    /// Within a wave, request i starts this many milliseconds after request
    /// i - 1, so later requests join lanes that are already decoding.
    public var batchStaggerMilliseconds = 0
    /// In every wave of two or more, the last request is cancelled once it
    /// has this many tokens: it must retire alone while the others finish.
    public var batchCancelAfterTokens: Int?
    /// The prompt-prefix SSD tier of each side's worker: that Mac's own root
    /// directory and key file (a file only its user can read). Nil: no tier.
    /// The driver reads the key on that side (`prefixSSDKeyScript`) and sends
    /// it as a line of the worker's input; the worker's environment carries
    /// only the directory.
    public var localPrefixSSD: PairPrefixSSD?
    public var remotePrefixSSD: PairPrefixSSD?
    /// Diagnosis: both workers keep nothing on disk and delete what they kept.
    public var prefixSSDOff = false
    public var totalRequests: Int { repetitions + followRequests.count }
    /// `jaccl`, or `local-socket-test`: both ranks on this Mac over a 127.0.0.1
    /// socket. That is a correctness run of the two-rank runtime, never an
    /// RDMA result, and its timings are not pair timings.
    public var workerTransport: String
    /// A fault one rank's recording worker is asked to commit during the
    /// hand-off (`handoff_corrupt_segment=N` on rank 0,
    /// `handoff_stall_after_segment=N:MILLISECONDS` on rank 1). Qualification only.
    public var faultRank: Int?
    public var faultValue: String?
    /// The request owner stops after this many committed tokens, as a client
    /// that hangs up would. Serving path only: a recording run compares a
    /// complete history.
    public var stopAfterTokens: Int?
    /// Both workers keep a record of the host memory gate's decisions:
    /// "record" (nothing changes) or "measure" (a refusal for admissible
    /// memory alone is not enforced). Nil: no record.
    public var memoryGateMode: String?
    /// Both workers run without the stage's standing residency (MiMo only).
    public var withoutStageResidency = false
    /// Both workers get the MiMo step-evidence switch; rank 1 writes the lines.
    public var mimoStepEvidence = false
    /// Both workers hold a standing MLX wired limit for their loaded stage
    /// (`stage_wired_residency_v1`). Qualification only.
    public var stageResidency = false
    /// S16: `encrypted_v1` (the default): both workers key their data plane
    /// with credentials this driver issues for the run from two per-run member
    /// identities, each pinning the other's; every transfer between the ranks
    /// is then an authenticated, encrypted record. `plaintext` only for the
    /// overhead comparison.
    public var dataPlane = ClusterWorkerDataPlane.encrypted
    public static let plaintextDataPlane = "plaintext"
    public static let encryptedDataPlane = ClusterWorkerDataPlane.encrypted
    /// Qualification: this rank pins an identity that is not its peer's; its
    /// key exchange must refuse the peer's hello before any key.
    public var wrongPinRank: Int?
    /// Qualification: this rank flips one ciphertext byte of the n-th record
    /// of a kind it sends (`residualPayload:3`); its peer must refuse it.
    public var tamperRank: Int?
    public var tamperValue: String?
    public static let tamperEnvironment = "DARKBLOOM_CLUSTER_QUALIFICATION_TAMPER"
    /// Qualification: both ranks rekey every n records per direction instead
    /// of the data plane's 262,144, so one request crosses key generations.
    public var rekeyRecords: Int?
    public static let rekeyEnvironment = "DARKBLOOM_CLUSTER_QUALIFICATION_REKEY"
    public var membershipEpoch: UUID
    /// Strings that must never appear in a report (destination, addresses, names).
    public var sensitive: [String]

    public init(request: QualificationRequest, stageCut: Int, local: PairSide, remote: PairSide,
                remoteTransport: [String], coordinator: String, prefillSchedule: String = "serial_v1",
                recording: Bool = true, startupSeconds: Int = 120,
                requestSeconds: Int = 100, rankOneDelaySeconds: Double = 2, progressTimeoutMilliseconds: Int? = nil,
                requireProgressGuard: Bool = true, keepRunFiles: Bool = false, preflightOnly: Bool = false,
                generationMode: String = PairConfiguration.pipelineMode, repetitions: Int = 1,
                workerTransport: String = PairConfiguration.jacclTransport,
                membershipEpoch: UUID = UUID(), sensitive: [String] = [], localRank: Int = 0) throws {
        self.request = request; self.stageCut = stageCut; self.local = local; self.remote = remote
        self.remoteTransport = remoteTransport; self.coordinator = coordinator
        self.prefillSchedule = prefillSchedule; self.recording = recording
        self.startupSeconds = startupSeconds
        self.requestSeconds = requestSeconds; self.rankOneDelaySeconds = rankOneDelaySeconds
        self.progressTimeoutMilliseconds = progressTimeoutMilliseconds
        self.requireProgressGuard = requireProgressGuard; self.keepRunFiles = keepRunFiles
        self.preflightOnly = preflightOnly
        self.generationMode = generationMode; self.repetitions = repetitions
        self.workerTransport = workerTransport
        self.membershipEpoch = membershipEpoch; self.sensitive = sensitive
        self.localRank = localRank
        try validate()
    }

    /// `ssh` with options that make it a quiet, non-interactive pipe which ends
    /// by itself when the link dies. Later `-o` values do not override earlier
    /// ones, so the caller's options come first.
    public static func sshTransport(destination: String, options: [String]) throws -> [String] {
        guard isDestination(destination) else {
            throw QualificationError("SSH destination must be [user@]host using letters, digits, '.', '_', '-'")
        }
        guard options.allSatisfy(isSSHOption) else {
            throw QualificationError("SSH options must be Key=Value without spaces or shell characters")
        }
        let fixed = ["BatchMode=yes", "RequestTTY=no", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes",
            "PermitLocalCommand=no", "ControlMaster=no", "ControlPath=none", "ConnectTimeout=10",
            "ServerAliveInterval=5", "ServerAliveCountMax=3"]
        return ["/usr/bin/ssh", "-T"] + (options + fixed).flatMap { ["-o", $0] } + ["--", destination]
    }

    static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 1024 && value.count > 1
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }
            && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func isDevice(_ value: String) -> Bool {
        (1...63).contains(value.utf8.count) && !value.hasPrefix("-")
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
    static func isDestination(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && value.utf8.count <= 320 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix("-") && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }
    }
    static func isSSHOption(_ value: String) -> Bool {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && value.utf8.count <= 1100
            && parts[0].utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
            && parts[1].utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [37, 43, 44, 45, 46, 47, 58, 64, 95].contains($0) }
    }
    /// The runtime's rule: a canonical unicast IPv4 address and a port.
    static func isCoordinator(_ value: String) -> Bool {
        func decimal(_ text: Substring, _ maximum: Int) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(text), number <= maximum, String(number) == text else { return nil }
            return number
        }
        let endpoint = value.split(separator: ":", omittingEmptySubsequences: false)
        guard endpoint.count == 2, let port = decimal(endpoint[1], 65_535), port > 0 else { return false }
        let octets = endpoint[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = octets.compactMap { decimal($0, 255) }
        return octets.count == 4 && numbers.count == 4 && numbers[0] > 0 && numbers[0] < 224
    }

    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw QualificationError("Pair configuration: " + message) }
        }
        try request.validate()
        try require(request.supportedCuts.contains(stageCut), "stage cut must be one of the request model's cuts: "
            + request.supportedCuts.map(String.init).joined(separator: ", "))
        try require((0...1).contains(localRank), "the local rank is 0 or 1")
        for (name, side) in [("local", local), ("remote", remote)] {
            try require(Self.isPath(side.modelDirectory), "\(name) model directory must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isPath(side.workerPath), "\(name) worker must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isPath(side.scratchDirectory), "\(name) scratch directory must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isDevice(side.rdmaDevice), "\(name) RDMA device must be a device name such as rdma_en5")
        }
        try require(Self.isCoordinator(coordinator), "coordinator must be IPV4:PORT with a unicast address")
        try require(["serial_v1", "one_chunk_lookahead_v1"].contains(prefillSchedule), "unknown prefill schedule")
        try require([Self.pipelineMode, Self.pipelineCompactDecodeMode, Self.phaseSplitMode, Self.phaseSplitMTPMode,
                     Self.pipelineMTPMode, Self.tensorParallelMode].contains(generationMode), "unknown generation mode")
        try require(tensorShares.map { $0.count == 2 && $0.allSatisfy({ (1...64).contains($0) })
                && generationMode == Self.tensorParallelMode } ?? true,
            "tensor shares are two weights of 1...64 and only with tensor_parallel_v1")
        try require(generationMode != Self.tensorParallelMode || !recording,
            "a tensor-parallel run has no recording worker; run it with --evidence none")
        try require(speculativeDepth.map { (1...4).contains($0)
                && [Self.phaseSplitMTPMode, Self.pipelineMTPMode].contains(generationMode) } ?? true,
            "a speculative depth is 1...4 and only with phase_split_mtp_v1 or pipeline_mtp_v1")
        try require((1...Self.maximumRepetitions).contains(repetitions), "repetitions must be 1...\(Self.maximumRepetitions)")
        try require(repetitions == 1 || !recording, "a recording run takes one request; repeat with --evidence none")
        try require(followRequests.isEmpty || !recording, "follow-up requests run with --evidence none")
        try require(followRequests.count <= Self.maximumRepetitions, "at most 8 follow-up requests")
        try require(followRequests.allSatisfy { $0.modelID == request.modelID && $0.profileID == request.profileID },
            "follow-up requests must name the same model and profile")
        try require((1...8).contains(batchLanes), "batch lanes are 1...8")
        try require(batchRequests.isEmpty || (!recording && [Self.pipelineMode, Self.tensorParallelMode].contains(generationMode)),
            "batch requests run with --evidence none in the pipeline or tensor-parallel mode")
        try require((0...60_000).contains(batchStaggerMilliseconds) && (batchCancelAfterTokens.map { $0 >= 1 } ?? true),
            "a batch stagger is 0...60000 ms and a batch cancel comes after at least one token")
        try require(batchRequests.count <= 8 && batchWaves.allSatisfy { (1...batchLanes).contains($0) && $0 <= batchRequests.count },
            "at most 8 batch requests; each wave is 1...lanes and at most the request count")
        try require(batchRequests.allSatisfy { $0.modelID == request.modelID && $0.profileID == request.profileID },
            "batch requests must name the same model and profile")
        try require([Self.jacclTransport, Self.localSocketTransport].contains(workerTransport), "unknown worker transport")
        try require(workerTransport == Self.jacclTransport || coordinator.hasPrefix("127.0.0.1:"),
            "local-socket-test runs both ranks on this Mac and needs a 127.0.0.1 coordinator")
        try require((faultRank == nil) == (faultValue == nil), "a fault needs both its rank and its value")
        try require([ClusterWorkerDataPlane.encrypted, Self.plaintextDataPlane].contains(dataPlane),
            "the data plane is encrypted_v1 or plaintext")
        try require((tamperRank == nil) == (tamperValue == nil), "a tamper fault needs both its rank and its value")
        try require(tamperRank.map { (0...1).contains($0) } ?? true, "a tamper fault names rank 0 or 1")
        try require(wrongPinRank.map { (0...1).contains($0) } ?? true, "a wrong pin names rank 0 or 1")
        try require((tamperValue == nil && wrongPinRank == nil) || dataPlane == ClusterWorkerDataPlane.encrypted,
            "a data-plane fault needs the encrypted data plane")
        try require(rekeyRecords.map { (2...262_144).contains($0) && dataPlane == ClusterWorkerDataPlane.encrypted } ?? true,
            "a rekey interval is 2...262144 records and needs the encrypted data plane")
        try require(tamperValue.map { v in (3...64).contains(v.utf8.count) && v.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 58 } } ?? true,
            "a tamper fault is KIND:ORDINAL")
        try require(stopAfterTokens.map { !recording && (1..<request.outputCount).contains($0) } ?? true,
            "a client stop is a serving-path input, after 1 or more tokens and before the output limit")
        if let faultRank, let faultValue {
            // A prompt-prefix SSD fault applies to any mode and to serving requests.
            let prefixSSDFault = faultValue.hasPrefix("prefix_ssd_")
            // A model with no recording runtime runs its phase split only as a serving run; its
            // hand-off fault is that run's input (the worker refuses one it cannot commit).
            let handoffRun = [Self.phaseSplitMode, Self.phaseSplitMTPMode].contains(generationMode)
                && (recording || QualificationRequest.registeredModel(request.modelID)?.hasRecordingRuntime == false)
            try require((0...1).contains(faultRank)
                && (prefixSSDFault || handoffRun)
                && (1...96).contains(faultValue.utf8.count)
                && faultValue.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [58, 61, 95].contains($0) },
                "a fault is a recording phase-split run's input (a serving one for a model with no recording runtime; a prefix_ssd_ fault in any run): "
                    + "RANK and name=value of lowercase letters, digits, '_', ':'")
        }
        for (name, ssd) in [("local", localPrefixSSD), ("remote", remotePrefixSSD)] {
            guard let ssd else { continue }
            try require(Self.isPath(ssd.directory) && Self.isPath(ssd.keyFile),
                "\(name) prefix SSD directory and key file must be absolute paths of letters, digits, '.', '_', '-', '/'")
        }
        try require(!recording || QualificationRequest.registeredModel(request.modelID)?.hasRecordingRuntime == true,
            "this model has no recording runtime; run it with --evidence none")
        try require((2...3600).contains(startupSeconds), "startup timeout must be 2...3600 seconds")
        try require((5...3600).contains(requestSeconds), "request timeout must be 5...3600 seconds")
        try require((0...30).contains(rankOneDelaySeconds), "rank 1 delay must be 0...30 seconds")
        try require(progressTimeoutMilliseconds.map { (1000...600_000).contains($0) } ?? true, "progress timeout must be 1000...600000 ms")
        try require(!requireProgressGuard || progressTimeoutMilliseconds != nil, "a guarded run needs a progress timeout")
        try require(!remoteTransport.isEmpty && remoteTransport[0].hasPrefix("/")
            && remoteTransport.allSatisfy { !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 2048 },
            "remote transport must be an absolute executable and its arguments")
    }

    /// The environment of a transport process (the local shell, `ssh`) and of
    /// inspection commands: a fixed base, plus what `ssh` needs to find the
    /// operator's keys and agent. A worker never inherits it; its launch
    /// script starts it with an exact environment of its own.
    static var transportEnvironment: [String: String] {
        var value = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        for name in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] {
            if let inherited = ProcessInfo.processInfo.environment[name] { value[name] = inherited }
        }
        return value
    }

    /// Everything below is by rank; only these two say which side a rank is on.
    func side(_ rank: Int) -> PairSide { rank == localRank ? local : remote }
    func transport(_ rank: Int) -> [String] { rank == localRank ? ["/bin/sh", "-c"] : remoteTransport }

    /// Row i, column j: the device rank i uses to reach rank j. Both Macs must
    /// read the same bytes; the runtime compares their digest before loading.
    public var deviceMatrix: String { "[[null,\"\(side(0).rdmaDevice)\"],[\"\(side(1).rdmaDevice)\",null]]\n" }

    /// One directory per run and side, named after the membership epoch.
    func runRoot(_ rank: Int) -> String {
        "\(side(rank).scratchDirectory)/darkbloom-pair-\(membershipEpoch.uuidString.lowercased())"
    }
    func runDirectory(_ rank: Int) -> String { "\(runRoot(rank))/rank\(rank)" }

    /// Removes exactly the directory this run created on that side.
    func removalScript(_ rank: Int) -> String {
        """
        set -eu
        D=\(Self.quoted(runRoot(rank)))
        /bin/rm -rf "$D"
        if [ -e "$D" ]; then printf 'removed=0\\n'; else printf 'removed=1\\n'; fi
        """
    }
    func evidencePath(_ rank: Int) -> String { "\(runDirectory(rank))/evidence/\(request.requestID).json" }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// What the transport runs: `sh -c` gets the script as is; the remote
    /// login shell gets one quoted `sh -c` command.
    func command(_ rank: Int, script: String) -> [String] {
        transport(rank) + [rank == localRank ? script : "/bin/sh -c " + Self.quoted(script)]
    }

    /// The environment name the guarded JACCL reads. A worker built on the
    /// stock JACCL does not contain it.
    static let progressGuardMarker = "JACCL_PROGRESS_TIMEOUT_MS"

    /// Hashes, hardware, whether the worker carries the progress guard, wired
    /// memory, and any worker already running from this path.
    func inspectionScript(_ rank: Int) -> String {
        let worker = Self.quoted(side(rank).workerPath)
        return """
        set -eu
        W=\(worker)
        D=$(/usr/bin/dirname "$W")
        printf 'worker=%s\\n' "$(/usr/bin/shasum -a 256 "$W" | /usr/bin/cut -d ' ' -f 1)"
        printf 'metallib=%s\\n' "$(/usr/bin/shasum -a 256 "$D/mlx.metallib" | /usr/bin/cut -d ' ' -f 1)"
        printf 'chip=%s\\n' "$(/usr/sbin/sysctl -n machdep.cpu.brand_string)"
        printf 'os=%s\\n' "$(/usr/bin/sw_vers -productVersion)"
        printf 'guard=%s\\n' "$(/usr/bin/grep -a -c \(Self.progressGuardMarker) "$W" || true)"
        \(Self.runningScript)
        """
    }

    func runningScript(_ rank: Int) -> String {
        "set -eu\nW=\(Self.quoted(side(rank).workerPath))\n\(Self.runningScript)"
    }

    /// Processes whose executable is exactly this worker (counting, no signal)
    /// and the Mac's wired memory in bytes.
    private static let runningScript = """
        printf 'running=%s\\n' "$(/bin/ps -axo comm= | /usr/bin/awk -v w="$W" '$0 == w { n++ } END { print n + 0 }')"
        printf 'wired=%s\\n' "$(/usr/bin/vm_stat | /usr/bin/awk -v p="$(/usr/sbin/sysctl -n hw.pagesize)" '/Pages wired down/ { gsub("[.]", "", $4); printf "%.0f", $4 * p }')"
        """

    func capabilityScript(_ rank: Int, workerSHA256: String) -> String {
        let side = side(rank)
        return "exec \(Self.quoted(side.workerPath)) --describe-runtime --config \(Self.quoted(side.modelDirectory + "/config.json"))"
            + " --manifest \(Self.quoted(side.modelDirectory + "/manifest.json")) --expected-executable-sha256 \(workerSHA256)"
    }

    /// This rank's prefix-SSD tier, if the run gives it one.
    func prefixSSD(_ rank: Int) -> PairPrefixSSD? { rank == localRank ? localPrefixSSD : remotePrefixSSD }

    /// Prints this rank's prefix-SSD key file, on the Mac that holds it, after
    /// checking that it is a regular file this user owns and nobody else can
    /// read. The driver sends the key on the worker's input.
    func prefixSSDKeyScript(_ rank: Int) -> String? {
        guard let ssd = prefixSSD(rank) else { return nil }
        return """
        F=\(Self.quoted(ssd.keyFile))
        [ -f "$F" ] && [ ! -L "$F" ] && [ -O "$F" ] || { echo "the prefix SSD key file is not a regular file of this user" >&2; exit 65; }
        case "$(/usr/bin/stat -f %Lp "$F")" in ?00) ;; *) echo "the prefix SSD key file is readable by others" >&2; exit 65 ;; esac
        exec /usr/bin/head -c 129 "$F"
        """
    }

    func evidenceScript(_ rank: Int) -> String {
        "exec /usr/bin/head -c \(PairEvidence.maximumBytes + 1) \(Self.quoted(evidencePath(rank)))"
    }

    /// Writes the device matrix, turns the first rank-lease grant into this
    /// Mac's own uptime deadline and replaces itself with the worker. The first
    /// stderr line reports the worker's process ID and that clock. Interrupt
    /// and hangup are ignored from here on, and stay ignored in the worker: an
    /// interrupted driver must not take a loaded worker down with it. The
    /// worker then sees its input end and exits by itself.
    func launchScript(_ rank: Int, artifactSHA256: String, configurationSHA256: String, workerSHA256: String) -> String {
        let side = side(rank), run = runDirectory(rank)
        var environment = [("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), ("LANG", "C"), ("LC_ALL", "C")]
            + request.arithmeticEnvironment
            + [("JACCL_RANK", String(rank)), ("JACCL_COORDINATOR", coordinator)]
        if let progressTimeoutMilliseconds {
            environment.append(("JACCL_PROGRESS_TIMEOUT_MS", String(progressTimeoutMilliseconds)))
        }
        if workerTransport != Self.jacclTransport {
            environment.append((Self.workerTransportEnvironment, workerTransport))
        }
        if faultRank == rank, let faultValue {
            environment.append((Self.faultEnvironment, faultValue))
        }
        if let memoryGateMode { environment.append((Self.memoryGateEnvironment, memoryGateMode)) }
        if prefixCacheOff { environment.append(("DARKBLOOM_CLUSTER_PREFIX_CACHE", "off")) }
        if batchLanes > 1 { environment.append(("DARKBLOOM_CLUSTER_BATCH_LANES", String(batchLanes))) }
        if let kvBackend { environment.append(("DARKBLOOM_CLUSTER_KV_BACKEND", kvBackend)) }
        if let ssd = rank == localRank ? localPrefixSSD : remotePrefixSSD {
            environment.append(("DARKBLOOM_CLUSTER_PREFIX_SSD_DIR", ssd.directory))
        }
        if prefixSSDOff { environment.append(("DARKBLOOM_CLUSTER_PREFIX_SSD", "off")) }
        if withoutStageResidency { environment.append((Self.mimoStageResidencyEnvironment, "off")) }
        if mimoStepEvidence { environment.append((Self.mimoStepEvidenceEnvironment, "on")) }
        if stageResidency {
            environment.append((Self.stageResidencyEnvironment, Self.stageResidencyPolicy))
        }
        if tamperRank == rank, let tamperValue { environment.append((Self.tamperEnvironment, tamperValue)) }
        if let rekeyRecords { environment.append((Self.rekeyEnvironment, "records:\(rekeyRecords)")) }
        var arguments = ["--model-dir", side.modelDirectory, "--rank", String(rank), "--stage-cut", String(stageCut),
            "--membership-epoch", membershipEpoch.uuidString.lowercased(), "--model-id", request.modelID,
            "--artifact-sha256", artifactSHA256, "--configuration-sha256", configurationSHA256,
            "--peer0-id", peerIDs[0], "--peer0-build-sha256", workerSHA256,
            "--peer1-id", peerIDs[1], "--peer1-build-sha256", workerSHA256]
        if prefillSchedule != "serial_v1" { arguments += ["--prefill-schedule", prefillSchedule] }
        // The pipeline's launch is unchanged; any other mode is declared to both ranks.
        if generationMode != Self.pipelineMode { arguments += [Self.generationModeArgument, generationMode] }
        if let speculativeDepth { arguments += [Self.speculativeDepthArgument, String(speculativeDepth)] }
        if let tensorShares { arguments += [Self.tensorSharesArgument, tensorShares.map(String.init).joined(separator: ":")] }
        // A worker refuses a qualification switch in its environment unless it
        // was started with this flag. Both ranks get it when either has one,
        // so the two launches differ only where the run says they do.
        if !keepWarm { arguments += ["--keep-warm", "off"] }
        // The credential itself is the first line of the worker's input.
        if dataPlane == ClusterWorkerDataPlane.encrypted { arguments += ["--data-plane", ClusterWorkerDataPlaneTrust.argument] }
        // The prefix-SSD key is the next line of the worker's input (never a variable).
        if prefixSSD(rank) != nil { arguments += ["--prefix-ssd-key", ClusterWorkerPrefixSSDKey.argument] }
        if workerTransport != Self.jacclTransport || faultValue != nil || memoryGateMode != nil || withoutStageResidency
            || mimoStepEvidence || stageResidency || tamperValue != nil || rekeyRecords != nil {
            arguments += [Self.qualificationSwitchesArgument, "yes"]
        }
        let fixed = environment.map { "\($0.0)=\(Self.quoted($0.1))" }.joined(separator: " ")
        let evidence = recording ? " --evidence-directory \"$RUN/evidence\"" : ""
        // GLM's load holds a bounded startup wait across both ranks, which a
        // leased worker accepts only with a fixed startup deadline on its own clock.
        let startup = request.modelID == "registered_glm53_flash"
            ? " --startup-deadline-uptime-nanoseconds \"$((NOW + \(UInt64(startupSeconds) * 1_000_000_000)))\"" : ""
        return """
        set -eu
        umask 077
        W=\(Self.quoted(side.workerPath))
        RUN=\(Self.quoted(run))
        /bin/mkdir -p "$RUN/evidence"
        set -C
        printf '%s\\n' \(Self.quoted(String(deviceMatrix.dropLast()))) > "$RUN/devices.json"
        set +C
        NOW=$("$W" --uptime-nanoseconds)
        DEADLINE=$((NOW + \(ClusterWorkerLease.ttlNanoseconds)))
        trap '' INT HUP
        echo "\(PairLaunchPreamble.marker) pid=$$ uptime=$NOW deadline=$DEADLINE" >&2
        exec /usr/bin/env -i \(fixed) JACCL_IBV_DEVICES="$RUN/devices.json" "$W" \
        \(arguments.map(Self.quoted).joined(separator: " ")) --deadline-uptime-nanoseconds "$DEADLINE"\(startup)\(evidence)
        """
    }
}

/// The launch script's first stderr line.
struct PairLaunchPreamble: Equatable {
    static let marker = "darkbloom-pair-launch-v1"
    let processID: Int32
    let uptimeNanoseconds: UInt64
    let deadlineUptimeNanoseconds: UInt64

    init?(line: String) {
        let fields = line.split(separator: " ")
        guard fields.count == 4, fields[0] == Self.marker else { return nil }
        func value(_ field: Substring, _ name: String) -> Substring? {
            field.hasPrefix(name + "=") ? field.dropFirst(name.count + 1) : nil
        }
        guard let pid = value(fields[1], "pid").flatMap({ Int32($0) }), pid > 1,
              let uptime = value(fields[2], "uptime").flatMap({ UInt64($0) }),
              let deadline = value(fields[3], "deadline").flatMap({ UInt64($0) }), deadline > uptime else { return nil }
        processID = pid; uptimeNanoseconds = uptime; deadlineUptimeNanoseconds = deadline
    }
}

/// Removes anything that identifies a Mac, a person or a network from text
/// that came from a tool: configured strings first, then address and
/// home-directory shapes.
public struct PairRedactor: Sendable {
    private let replacements: [(String, String)]

    public init(sensitive: [String]) {
        var values = Set<String>()
        for item in sensitive {
            values.insert(item)
            for part in item.split(whereSeparator: { $0 == "@" || $0 == ":" }) { values.insert(String(part)) }
        }
        values.insert(NSUserName()); values.insert(ProcessInfo.processInfo.hostName)
        if let short = ProcessInfo.processInfo.hostName.split(separator: ".").first { values.insert(String(short)) }
        // Longest first, so a name is not left half-replaced by a part of itself.
        replacements = values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }.map { ($0, "<redacted>") }
    }

    public func callAsFunction(_ text: String) -> String {
        var result = text
        for (needle, replacement) in replacements { result = result.replacingOccurrences(of: needle, with: replacement) }
        for (pattern, replacement) in [
            (#"/(Users|home)/[^/\s:'"]+"#, "/$1/<user>"),
            (#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "<ipv4>"),
            (#"\b[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){3,7}\b"#, "<address>"),
        ] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }
}
