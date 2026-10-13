import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

enum WorkerFailure: Error { case invalid(String) }

struct WorkerConfiguration {
    let load: QwenResidentLoadConfiguration
    let bootstrap: WorkerBootstrapConfiguration?
    /// Qualification only: selects the recording runtime and its sidecar directory.
    let evidenceDirectory: String?
    /// When named by the owner, the worker ends itself here unless it is ready.
    let startupDeadlineUptimeNanoseconds: UInt64?
    /// How the two ranks divide a request (`--generation-mode`); the pipeline
    /// when the argument is absent. Both ranks must be started with the same
    /// mode, and it must be one the registered model's resident row lists.
    let generationMode: ClusterGenerationMode
    /// `--mtp-depth N` (1...4): the speculative head's fixed draft depth under
    /// `phase_split_mtp_v1`; nil means the product drafter's maximum. Both ranks
    /// bind it into their load agreement, so they must be given the same value.
    let speculativeTerms: QwenMTPTerms?
    /// `--qualification-switches yes`: the explicit test flag without which a
    /// qualification switch in the environment stops the worker at startup.
    /// An installed owner never passes it.
    let qualificationSwitchesPermitted: Bool
    /// Which adapter executes the registered model `--model-id` names.
    let family: ClusterResidentModelCatalog.Family
    /// The rank lease (S03). `--deadline-uptime-nanoseconds` is its first
    /// deadline, at most one lease grant away; the owner renews it on the
    /// control pipe while it keeps this worker. There is no fixed lifetime.
    let lease: ClusterLeaseDeadline
    /// Keep-warm tier 1 (`--keep-warm on|off`, on unless off is named): a GPU
    /// pulse every half second while idle, once the first request has run.
    let keepWarm: Bool
    /// `--data-plane encrypted_v1` (S16): the first line of the control pipe is
    /// this worker's data-plane credential, and every transfer to the peer is an
    /// authenticated, encrypted record after a pinned key exchange. Absent: the
    /// plaintext data plane (diagnosis and qualification only).
    let dataPlaneEncrypted: Bool
    /// `--prefix-ssd-key darkbloom/prefix-ssd-key/input-line/v1`: the key of
    /// this rank's prompt-prefix SSD tier is the next line of the control pipe
    /// (after the data-plane credential), bound to this epoch and rank. The
    /// argument names the scheme only; the key is never an argument or a
    /// variable. Absent: no key, and the SSD tier stays off.
    let prefixSSDKeyOnInput: Bool

    init(arguments: [String], now: UInt64) throws {
        let names: Set<String> = ["--model-dir", "--rank", "--stage-cut", "--membership-epoch",
            "--model-id", "--artifact-sha256", "--configuration-sha256", "--peer0-id",
            "--peer0-build-sha256", "--peer1-id", "--peer1-build-sha256", "--deadline-uptime-nanoseconds"]
        let optionalNames: Set<String> = ["--prefill-schedule", "--evidence-directory", "--startup-deadline-uptime-nanoseconds",
            "--generation-mode", "--qualification-switches", "--keep-warm", "--mtp-depth", "--data-plane",
            "--prefix-ssd-key"]
        let bootstrapCounts = [0, WorkerBootstrapConfiguration.names.count, WorkerBootstrapConfiguration.names.count + 1]
        let counts = bootstrapCounts.map { names.count + $0 }.flatMap { required in
            (0...optionalNames.count).map { (required + $0) * 2 }
        }
        guard counts.contains(arguments.count) else {
            throw WorkerFailure.invalid("Expected twelve worker pairs, optional prefill schedule, optional evidence directory, optional startup deadline, optional generation mode, optional speculative depth, optional qualification-switches flag, optional keep-warm switch, optional data-plane protection, optional prefix-SSD key scheme and optional complete bootstrap triple with its optional native start")
        }
        var fields: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard names.union(optionalNames).union(WorkerBootstrapConfiguration.allNames).contains(key), fields[key] == nil, !value.isEmpty, value.utf8.count <= 4096,
                  !value.contains("\0") else { throw WorkerFailure.invalid("Unknown, duplicate or empty worker argument") }
            fields[key] = value
        }
        guard names.allSatisfy({ fields[$0] != nil }) else { throw WorkerFailure.invalid("Missing worker argument") }
        func integer(_ key: String) throws -> Int {
            guard let value = Int(fields[key]!), String(value) == fields[key] else { throw WorkerFailure.invalid("Worker integer must be canonical") }
            return value
        }
        func hash(_ key: String) throws -> String {
            let value = fields[key]!
            guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw WorkerFailure.invalid("Worker SHA256 must be lowercase hexadecimal")
            }
            return value
        }
        let rank = try integer("--rank"), cut = try integer("--stage-cut")
        // The closed catalog of every adapter: an ID outside it has no entry.
        guard let registered = ClusterResidentModelCatalog.entry(runtimeModelID: fields["--model-id"]!) else {
            throw WorkerFailure.invalid("Worker requires a registered model ID")
        }
        let lifetime = ClusterWorkerLease.maximumNanoseconds
        guard (0...1).contains(rank), fields["--model-dir"]!.hasPrefix("/"),
              registered.supportedCuts.contains(cut),
              let epoch = UUID(uuidString: fields["--membership-epoch"]!),
              epoch.uuidString.lowercased() == fields["--membership-epoch"],
              let deadline = UInt64(fields["--deadline-uptime-nanoseconds"]!),
              String(deadline) == fields["--deadline-uptime-nanoseconds"],
              deadline > now, deadline - now <= lifetime else {
            throw WorkerFailure.invalid("Worker requires a registered model ID, rank0|1, one of that model's cuts and a first lease deadline at most \(lifetime / 1_000_000_000) seconds away")
        }
        family = registered.family
        lease = ClusterLeaseDeadline(uptimeNanoseconds: deadline)
        switch fields["--data-plane"] {
        case nil: dataPlaneEncrypted = false
        case ClusterWorkerDataPlaneTrust.argument: dataPlaneEncrypted = true
        default: throw WorkerFailure.invalid("--data-plane takes only \(ClusterWorkerDataPlaneTrust.argument)")
        }
        switch fields["--prefix-ssd-key"] {
        case nil: prefixSSDKeyOnInput = false
        case ClusterWorkerPrefixSSDKey.argument: prefixSSDKeyOnInput = true
        default: throw WorkerFailure.invalid("--prefix-ssd-key takes only \(ClusterWorkerPrefixSSDKey.argument)")
        }
        switch fields["--keep-warm"] {
        case nil, "on": keepWarm = true
        case "off": keepWarm = false
        default: throw WorkerFailure.invalid("--keep-warm takes on or off")
        }
        guard let prefillSchedule = ClusterPrefillSchedule(rawValue: fields["--prefill-schedule"] ?? ClusterPrefillSchedule.serial.rawValue) else {
            throw WorkerFailure.invalid("Unknown worker prefill schedule")
        }
        // A closed choice, and one the named model's own row must list: an
        // unknown or unsupported mode never falls back to the pipeline.
        if let text = fields["--generation-mode"] {
            guard let mode = ClusterGenerationMode(rawValue: text),
                  registered.supportedGenerationModes.contains(mode) else {
                throw WorkerFailure.invalid("Worker generation mode must be one the registered model lists: "
                    + ClusterGenerationMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            generationMode = mode
        } else { generationMode = .pipeline }
        if let text = fields["--mtp-depth"] {
            guard generationMode.usesSpeculativeHead, let depth = Int(text), String(depth) == text,
                  let terms = try? QwenMTPTerms(depth: depth) else {
                throw WorkerFailure.invalid("--mtp-depth takes 1...\(QwenMTPTerms.maximumDepth) and only with --generation-mode \(ClusterGenerationMode.phaseSplitMTP.rawValue)")
            }
            speculativeTerms = terms
        } else { speculativeTerms = nil }
        if let text = fields["--qualification-switches"] {
            guard text == "yes" else { throw WorkerFailure.invalid("--qualification-switches takes only the value yes") }
            qualificationSwitchesPermitted = true
        } else { qualificationSwitchesPermitted = false }
        if let text = fields["--startup-deadline-uptime-nanoseconds"] {
            guard let startup = UInt64(text), String(startup) == text, startup > now,
                  startup - now <= ClusterWorkerLimits.deadlineNanoseconds else {
                throw WorkerFailure.invalid("Worker startup deadline must be canonical, in the future and within an hour")
            }
            startupDeadlineUptimeNanoseconds = startup
        } else { startupDeadlineUptimeNanoseconds = nil }
        bootstrap = try WorkerBootstrapConfiguration.parse(fields, now: now, lifetime: ClusterWorkerLimits.deadlineNanoseconds)
        if let directory = fields["--evidence-directory"] {
            let components = directory.split(separator: "/", omittingEmptySubsequences: false)
            guard directory.hasPrefix("/"), directory.utf8.count <= 1024, components.count > 1,
                  components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !directory.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                throw WorkerFailure.invalid("Worker evidence directory must be a normalized absolute path")
            }
        }
        evidenceDirectory = fields["--evidence-directory"]
        let peers = try (0...1).map { index -> ClusterWorkerPeer in
            let label = fields["--peer\(index)-id"]!
            guard label.utf8.count <= 128, label.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw WorkerFailure.invalid("Worker peer label is invalid")
            }
            return .init(id: label, buildSHA256: try hash("--peer\(index)-build-sha256"))
        }
        guard peers[0].id != peers[1].id else { throw WorkerFailure.invalid("Worker peers must be distinct") }
        load = .init(identity: .init(membershipEpoch: epoch, modelID: fields["--model-id"]!,
            artifactSHA256: try hash("--artifact-sha256"), configurationSHA256: try hash("--configuration-sha256"), peers: peers),
            modelDirectory: URL(fileURLWithPath: fields["--model-dir"]!), rank: rank, stageCut: cut,
            deadlineUptimeNanoseconds: deadline, allocatorPolicy: .disableFreedBufferCache,
            prefillSchedule: prefillSchedule, lease: lease)
    }
}
