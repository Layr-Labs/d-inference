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
    /// `phase_split_mtp_v1` or `pipeline_mtp_v1` (MiMo: 1...3); nil means the
    /// product drafter's maximum. Both ranks
    /// bind it into their load agreement, so they must be given the same value.
    let speculativeTerms: QwenMTPTerms?
    /// `--qualification-switches yes`: the explicit test flag without which a
    /// qualification switch in the environment stops the worker at startup.
    /// A private unqualified media owner passes it with its exact profile.
    let qualificationSwitchesPermitted: Bool
    /// Which adapter executes the registered model `--model-id` names.
    let family: ClusterResidentModelCatalog.Family?
    let glmQualificationDocument: String?
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
    /// `--tensor-shares A:B` (tensor_parallel_v1 only): each rank's share
    /// weight of every layer, rank order, as the planner chose it from one of
    /// the model plan's kernel-aligned options; equal (1:1) when absent. Both
    /// ranks bind it into their load agreement, so they must be given the same.
    let tensorShares: [Int]

    init(arguments: [String], now: UInt64) throws {
        let names: Set<String> = ["--model-dir", "--rank", "--stage-cut", "--membership-epoch",
            "--model-id", "--artifact-sha256", "--configuration-sha256", "--peer0-id",
            "--peer0-build-sha256", "--peer1-id", "--peer1-build-sha256", "--deadline-uptime-nanoseconds"]
        let optionalNames: Set<String> = ["--prefill-schedule", "--evidence-directory", "--startup-deadline-uptime-nanoseconds",
            "--generation-mode", "--qualification-switches", "--keep-warm", "--mtp-depth", "--data-plane",
            "--prefix-ssd-key", "--tensor-shares", "--glm-qualification", "--runtime-profile"]
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
        let qualificationDocument = fields["--glm-qualification"]
        let registered = ClusterResidentModelCatalog.entry(runtimeModelID: fields["--model-id"]!)
        if let path = qualificationDocument {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard fields["--model-id"] == GLM5NextWorkerQualification.modelID,
                  fields["--qualification-switches"] == "yes", fields["--keep-warm"] == "off",
                  fields["--data-plane"] == ClusterWorkerDataPlaneTrust.argument,
                  fields["--generation-mode"] == nil || fields["--generation-mode"] == ClusterGenerationMode.pipeline.rawValue,
                  fields["--prefill-schedule"] == nil || fields["--prefill-schedule"] == ClusterPrefillSchedule.serial.rawValue,
                  fields["--prefix-ssd-key"] == nil, fields["--mtp-depth"] == nil,
                  fields["--tensor-shares"] == nil, fields["--evidence-directory"] == nil,
                  path.hasPrefix("/"), components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                throw WorkerFailure.invalid("Private GLM requires explicit qualification, encrypted pipeline, serial prefill, keep-warm off and a normalized evidence path; MTP/prefix/batch/recording are unsupported")
            }
        } else if registered == nil {
            throw WorkerFailure.invalid("Worker requires a registered model ID or explicit private GLM qualification")
        }
        if fields["--runtime-profile"] == ClusterGLMImageCandidate.profileID {
            try ClusterGLMImageCandidate.validateSource(profileID: fields["--runtime-profile"]!,
                modelID: fields["--model-id"]!, artifact: fields["--artifact-sha256"]!,
                configuration: fields["--configuration-sha256"]!)
            guard fields["--qualification-switches"] == "yes", fields["--data-plane"] == ClusterWorkerDataPlaneTrust.argument,
                  fields["--startup-deadline-uptime-nanoseconds"] != nil, qualificationDocument == nil,
                  fields["--evidence-directory"] == nil, fields["--mtp-depth"] == nil, fields["--tensor-shares"] == nil,
                  fields["--generation-mode"] == nil || fields["--generation-mode"] == ClusterGenerationMode.pipeline.rawValue else {
                throw WorkerFailure.invalid("GLM image candidate requires explicit qualification, startup guard and encrypted serial pipeline")
            }
        } else if let profile = fields[ClusterMiMoImageCandidate.runtimeProfileArgument] {
            guard profile == ClusterMiMoImageCandidate.profileID,
                  fields["--model-id"] == ClusterMiMoImageCandidate.runtimeModelID,
                  fields["--artifact-sha256"] == ClusterMiMoImageCandidate.artifactSHA256,
                  fields["--configuration-sha256"] == ClusterMiMoImageCandidate.configurationSHA256,
                  fields["--qualification-switches"] == "yes",
                  fields["--data-plane"] == ClusterWorkerDataPlaneTrust.argument,
                  qualificationDocument == nil,
                  fields["--startup-deadline-uptime-nanoseconds"] != nil,
                  fields["--evidence-directory"] == nil,
                  [nil,ClusterGenerationMode.pipeline.rawValue,ClusterGenerationMode.pipelineCompactDecode.rawValue,
                    ClusterGenerationMode.pipelineMTP.rawValue].contains(fields["--generation-mode"]) else {
                throw WorkerFailure.invalid("MiMo image candidate requires exact artifact/profile, explicit qualification, startup guard and encrypted pipeline")
            }
        }
        glmQualificationDocument = qualificationDocument
        let lifetime = ClusterWorkerLease.maximumNanoseconds
        guard (0...1).contains(rank), fields["--model-dir"]!.hasPrefix("/"),
              (qualificationDocument != nil ? (1..<45).contains(cut) : registered?.supportedCuts.contains(cut) == true),
              let epoch = UUID(uuidString: fields["--membership-epoch"]!),
              epoch.uuidString.lowercased() == fields["--membership-epoch"],
              let deadline = UInt64(fields["--deadline-uptime-nanoseconds"]!),
              String(deadline) == fields["--deadline-uptime-nanoseconds"],
              deadline > now, deadline - now <= lifetime else {
            throw WorkerFailure.invalid("Worker requires a registered model ID, rank0|1, one of that model's cuts and a first lease deadline at most \(lifetime / 1_000_000_000) seconds away")
        }
        family = registered?.family
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
                  (qualificationDocument != nil ? mode == .pipeline : registered?.supportedGenerationModes.contains(mode) == true) else {
                throw WorkerFailure.invalid("Worker generation mode must be one the registered model lists: "
                    + ClusterGenerationMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            generationMode = mode
        } else { generationMode = .pipeline }
        if let text = fields["--mtp-depth"] {
            guard generationMode.usesSpeculativeHead, let depth = Int(text), String(depth) == text,
                  let terms = try? QwenMTPTerms(depth: depth) else {
                throw WorkerFailure.invalid("--mtp-depth takes 1...\(QwenMTPTerms.maximumDepth) and only with a speculative generation mode ("
                    + ClusterGenerationMode.allCases.filter(\.usesSpeculativeHead).map(\.rawValue).joined(separator: ", ") + ")")
            }
            speculativeTerms = terms
        } else { speculativeTerms = nil }
        if let text = fields["--tensor-shares"] {
            let weights = text.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard generationMode == .tensorParallel, weights.count == 2, weights.allSatisfy({ (1...64).contains($0) }),
                  weights.map(String.init).joined(separator: ":") == text else {
                throw WorkerFailure.invalid("--tensor-shares takes two canonical weights of 1...64 (A:B), only with tensor_parallel_v1")
            }
            tensorShares = weights
        } else { tensorShares = [1, 1] }
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
            prefillSchedule: prefillSchedule, lease: lease,runtimeProfile:fields[ClusterMiMoImageCandidate.runtimeProfileArgument],
            startupDeadlineUptimeNanoseconds: startupDeadlineUptimeNanoseconds)
    }
}
