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
public struct PairConfiguration: Sendable {
    public static let roles = ["rank 0 local", "rank 1 remote"]
    public static let peerIDs = ["rank0-local", "rank1-remote"]
    public static let arithmeticEnvironment = [
        ("DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "128"), ("DARKBLOOM_BF16_WEIGHTS", "1"), ("MLX_ENABLE_TF32", "1"),
    ]
    public static let pipelineMode = "pipeline_v1"
    public static let phaseSplitMode = "phase_split_v1"
    /// The pipeline with four transfers per decode step instead of eleven.
    public static let pipelineCompactDecodeMode = "pipeline_compact_decode_v1"
    /// The name the runtime reads its declared generation mode from.
    public static let generationModeEnvironment = "DARKBLOOM_CLUSTER_GENERATION_MODE"
    public static let maximumRepetitions = 8
    /// The name a recording worker reads a qualification fault from.
    public static let faultEnvironment = "DARKBLOOM_CLUSTER_QUALIFICATION_FAULT"
    public static let jacclTransport = "jaccl"
    public static let localSocketTransport = "local-socket-test"
    /// The name the runtime reads a declared qualification transport from.
    public static let workerTransportEnvironment = "DARKBLOOM_CLUSTER_TRANSPORT"

    public var request: QualificationRequest
    public var stageCut: Int
    public var local: PairSide
    public var remote: PairSide
    /// Argument vector that runs its final argument, a shell command string, on
    /// the second Mac: `/usr/bin/ssh` with its options and destination.
    public var remoteTransport: [String]
    /// Rank 0's own address on the link and a free port; rank 0 listens there.
    public var coordinator: String
    public var prefillSchedule: String
    public var recording: Bool
    public var lifetimeSeconds: Int
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
    /// Requests run one after another in the same loaded session, each with
    /// its own request ID. The first is the warm-up of a timing run.
    public var repetitions: Int
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
    public var membershipEpoch: UUID
    /// Strings that must never appear in a report (destination, addresses, names).
    public var sensitive: [String]

    public init(request: QualificationRequest, stageCut: Int, local: PairSide, remote: PairSide,
                remoteTransport: [String], coordinator: String, prefillSchedule: String = "serial_v1",
                recording: Bool = true, lifetimeSeconds: Int = 240, startupSeconds: Int = 120,
                requestSeconds: Int = 100, rankOneDelaySeconds: Double = 2, progressTimeoutMilliseconds: Int? = nil,
                requireProgressGuard: Bool = true, keepRunFiles: Bool = false, preflightOnly: Bool = false,
                generationMode: String = PairConfiguration.pipelineMode, repetitions: Int = 1,
                workerTransport: String = PairConfiguration.jacclTransport,
                membershipEpoch: UUID = UUID(), sensitive: [String] = []) throws {
        self.request = request; self.stageCut = stageCut; self.local = local; self.remote = remote
        self.remoteTransport = remoteTransport; self.coordinator = coordinator
        self.prefillSchedule = prefillSchedule; self.recording = recording
        self.lifetimeSeconds = lifetimeSeconds; self.startupSeconds = startupSeconds
        self.requestSeconds = requestSeconds; self.rankOneDelaySeconds = rankOneDelaySeconds
        self.progressTimeoutMilliseconds = progressTimeoutMilliseconds
        self.requireProgressGuard = requireProgressGuard; self.keepRunFiles = keepRunFiles
        self.preflightOnly = preflightOnly
        self.generationMode = generationMode; self.repetitions = repetitions
        self.workerTransport = workerTransport
        self.membershipEpoch = membershipEpoch; self.sensitive = sensitive
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
        for (name, side) in [("local", local), ("remote", remote)] {
            try require(Self.isPath(side.modelDirectory), "\(name) model directory must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isPath(side.workerPath), "\(name) worker must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isPath(side.scratchDirectory), "\(name) scratch directory must be an absolute path of letters, digits, '.', '_', '-', '/'")
            try require(Self.isDevice(side.rdmaDevice), "\(name) RDMA device must be a device name such as rdma_en5")
        }
        try require(Self.isCoordinator(coordinator), "coordinator must be IPV4:PORT with a unicast address")
        try require(["serial_v1", "one_chunk_lookahead_v1"].contains(prefillSchedule), "unknown prefill schedule")
        try require([Self.pipelineMode, Self.pipelineCompactDecodeMode, Self.phaseSplitMode].contains(generationMode),
            "unknown generation mode")
        try require((1...Self.maximumRepetitions).contains(repetitions), "repetitions must be 1...8")
        try require(repetitions == 1 || !recording, "a recording run takes one request; repeat with --evidence none")
        try require([Self.jacclTransport, Self.localSocketTransport].contains(workerTransport), "unknown worker transport")
        try require(workerTransport == Self.jacclTransport || coordinator.hasPrefix("127.0.0.1:"),
            "local-socket-test runs both ranks on this Mac and needs a 127.0.0.1 coordinator")
        try require((faultRank == nil) == (faultValue == nil), "a fault needs both its rank and its value")
        try require(stopAfterTokens.map { !recording && (1..<request.outputCount).contains($0) } ?? true,
            "a client stop is a serving-path input, after 1 or more tokens and before the output limit")
        if let faultRank, let faultValue {
            try require((0...1).contains(faultRank) && recording && generationMode == Self.phaseSplitMode
                && (1...96).contains(faultValue.utf8.count)
                && faultValue.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [58, 61, 95].contains($0) },
                "a fault is a recording phase-split run's input: RANK and name=value of lowercase letters, digits, '_', ':'")
        }
        try require((10...300).contains(lifetimeSeconds), "lifetime must be 10...300 seconds")
        try require((2...lifetimeSeconds).contains(startupSeconds), "startup timeout must be 2 seconds up to the lifetime")
        try require((5...lifetimeSeconds).contains(requestSeconds), "request timeout must be 5 seconds up to the lifetime")
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

    func side(_ rank: Int) -> PairSide { rank == 0 ? local : remote }
    func transport(_ rank: Int) -> [String] { rank == 0 ? ["/bin/sh", "-c"] : remoteTransport }

    /// Row i, column j: the device rank i uses to reach rank j. Both Macs must
    /// read the same bytes; the runtime compares their digest before loading.
    public var deviceMatrix: String { "[[null,\"\(local.rdmaDevice)\"],[\"\(remote.rdmaDevice)\",null]]\n" }

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
        transport(rank) + [rank == 0 ? script : "/bin/sh -c " + Self.quoted(script)]
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

    func evidenceScript(_ rank: Int) -> String {
        "exec /usr/bin/head -c \(PairEvidence.maximumBytes + 1) \(Self.quoted(evidencePath(rank)))"
    }

    /// Writes the device matrix, turns the remaining lifetime into this Mac's
    /// own uptime deadline and replaces itself with the worker. The first
    /// stderr line reports the worker's process ID and that clock. Interrupt
    /// and hangup are ignored from here on, and stay ignored in the worker: an
    /// interrupted driver must not take a loaded worker down with it. The
    /// worker then sees its input end and exits by itself.
    func launchScript(_ rank: Int, artifactSHA256: String, configurationSHA256: String, workerSHA256: String) -> String {
        let side = side(rank), run = runDirectory(rank)
        var environment = [("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), ("LANG", "C"), ("LC_ALL", "C")]
            + Self.arithmeticEnvironment
            + [("JACCL_RANK", String(rank)), ("JACCL_COORDINATOR", coordinator)]
        if let progressTimeoutMilliseconds {
            environment.append(("JACCL_PROGRESS_TIMEOUT_MS", String(progressTimeoutMilliseconds)))
        }
        // The pipeline's launch is unchanged; any other mode is declared to both ranks.
        if generationMode != Self.pipelineMode {
            environment.append((Self.generationModeEnvironment, generationMode))
        }
        if workerTransport != Self.jacclTransport {
            environment.append((Self.workerTransportEnvironment, workerTransport))
        }
        if faultRank == rank, let faultValue {
            environment.append((Self.faultEnvironment, faultValue))
        }
        var arguments = ["--model-dir", side.modelDirectory, "--rank", String(rank), "--stage-cut", String(stageCut),
            "--membership-epoch", membershipEpoch.uuidString.lowercased(), "--model-id", request.modelID,
            "--artifact-sha256", artifactSHA256, "--configuration-sha256", configurationSHA256,
            "--peer0-id", Self.peerIDs[0], "--peer0-build-sha256", workerSHA256,
            "--peer1-id", Self.peerIDs[1], "--peer1-build-sha256", workerSHA256]
        if prefillSchedule != "serial_v1" { arguments += ["--prefill-schedule", prefillSchedule] }
        let fixed = environment.map { "\($0.0)=\(Self.quoted($0.1))" }.joined(separator: " ")
        let evidence = recording ? " --evidence-directory \"$RUN/evidence\"" : ""
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
        DEADLINE=$((NOW + \(lifetimeSeconds)000000000))
        trap '' INT HUP
        echo "\(PairLaunchPreamble.marker) pid=$$ uptime=$NOW deadline=$DEADLINE" >&2
        exec /usr/bin/env -i \(fixed) JACCL_IBV_DEVICES="$RUN/devices.json" "$W" \
        \(arguments.map(Self.quoted).joined(separator: " ")) --deadline-uptime-nanoseconds "$DEADLINE"\(evidence)
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
