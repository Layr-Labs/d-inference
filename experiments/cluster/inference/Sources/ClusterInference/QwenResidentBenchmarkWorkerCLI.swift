import Foundation

/// Closed command-line bridge to the existing registered long admissions.
/// This file performs no IO, process/environment observation or native work.
struct QwenResidentBenchmarkWorkerCLI {
    enum Role: String { case solo, rank }
    static let mode = "qwen-resident-benchmark-worker"

    let role: Role
    let modelDirectory: URL
    let tokensFile: URL
    let artifactAggregateSHA256: String
    let promptSHA256: String
    let timeoutSeconds: Int
    let schedulingPolicy: QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy?
    let stageCut: Int?
    let transport: ClusterTransport?

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.indices.dropLast().contains {
            arguments[$0] == "--mode" && arguments[$0 + 1] == mode
        }
    }

    init(arguments: [String]) throws {
        let required: Set<String> = ["--mode", "--role", "--model-dir",
            "--artifact-aggregate-sha256", "--tokens-file", "--long-prompt-sha256"]
        let allowed = required.union(["--timeout-seconds", "--stage-prefill-policy", "--stage-cut", "--transport"])
        guard arguments.count.isMultiple(of: 2), (12...20).contains(arguments.count) else {
            throw ProbeError("Resident benchmark worker requires closed unique flag/value pairs")
        }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard allowed.contains(key), values[key] == nil, !value.isEmpty else {
                throw ProbeError("Resident benchmark worker has an unknown, duplicate or empty option")
            }
            values[key] = value
        }
        guard required.isSubset(of: Set(values.keys)), values["--mode"] == Self.mode,
              let role = Role(rawValue: values["--role"]!),
              QwenRegistered9BLongPrefillReferenceAdmission.isSHA256(values["--artifact-aggregate-sha256"]!),
              QwenRegistered9BLongPrefillReferenceAdmission.isSHA256(values["--long-prompt-sha256"]!) else {
            throw ProbeError("Resident benchmark worker requires its mode, role and exact source/input pins")
        }
        func path(_ key: String, directory: Bool = false) throws -> URL {
            let value = values[key]!
            guard value.hasPrefix("/"), value.utf8.count <= 4096, !value.utf8.contains(0) else {
                throw ProbeError("Resident benchmark worker paths must be bounded absolute paths without NUL")
            }
            return URL(fileURLWithPath: value, isDirectory: directory)
        }
        func decimal(_ raw: String) throws -> Int {
            guard !raw.isEmpty, raw.utf8.count <= 20,
                  raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(raw), String(value) == raw else {
                throw ProbeError("Resident benchmark worker integer options must be canonical decimal integers")
            }
            return value
        }
        let timeout = try decimal(values["--timeout-seconds"] ?? "300")
        guard (1...300).contains(timeout) else {
            throw ProbeError("Resident benchmark worker timeout must be in 1...300 seconds")
        }
        let policy: QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy?
        let cut: Int?
        let transport: ClusterTransport?
        switch role {
        case .solo:
            guard values["--stage-prefill-policy"] == nil, values["--stage-cut"] == nil,
                  values["--transport"] == nil else {
                throw ProbeError("Resident solo does not accept rank scheduling, transport or a selected stage cut")
            }
            policy = nil; cut = nil; transport = nil
        case .rank:
            guard let raw = values["--stage-prefill-policy"],
                  let selected = QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy(rawValue: raw) else {
                throw ProbeError("Resident rank requires an explicit existing prefill scheduling policy")
            }
            guard let selectedTransport = ClusterTransport(rawValue: values["--transport"] ?? "loopback-test") else {
                throw ProbeError("Resident rank transport must be jaccl or loopback-test")
            }
            transport = selectedTransport
            policy = selected
            cut = try values["--stage-cut"].map(decimal)
            // Existing native selection remains the authority, without a copied
            // list of legal layer boundaries in this worker adapter.
            _ = try QwenLongPrefillStageCut.resolved(cut)
        }
        self.role = role
        modelDirectory = try path("--model-dir", directory: true)
        tokensFile = try path("--tokens-file")
        artifactAggregateSHA256 = values["--artifact-aggregate-sha256"]!
        promptSHA256 = values["--long-prompt-sha256"]!
        timeoutSeconds = timeout
        schedulingPolicy = policy
        stageCut = cut
        self.transport = transport
    }

    /// The open epoch is the only wire epoch source. Existing Options and long
    /// CLI validators still own the fixed numerical/geometry/mode restrictions.
    func options(open: QwenResidentBenchmarkWorkerOpen,
        jacclConfiguration: QwenResidentJACCLConfiguration? = nil
    ) throws -> Options {
        try QwenResidentBenchmarkWorkerCommand.open(open).validate()
        var arguments = ["--mode", role == .solo ? "qwen-long-prefill-solo-check" : "qwen-long-prefill-rank-check",
            "--model-dir", modelDirectory.path, "--tokens-file", tokensFile.path,
            "--artifact-aggregate-sha256", artifactAggregateSHA256,
            "--long-prompt-sha256", promptSHA256, "--execution-path", "cbv2-contiguous",
            "--prompt-tokens", "8192", "--chunk-size", "512", "--decode-tokens", "1",
            "--repeats", "1", "--warmups", "0", "--seed", "7",
            "--timeout-seconds", String(timeoutSeconds)]
        if role == .rank {
            guard let policy = schedulingPolicy else { throw ProbeError("Resident rank lost its scheduling policy") }
            arguments += ["--transport", "loopback-test", "--epoch", open.requests[0].epoch,
                "--stage-prefill-policy", policy.rawValue, "--stage-logits-dtype", "bfloat16"]
            if let cut = stageCut { arguments += ["--stage-cut", String(cut)] }
        }
        // Preserve the one-shot Options gate. Only this closed resident bridge
        // may select JACCL after validating its separate configuration authority.
        var options = try Options(arguments: arguments)
        if role == .rank, transport == .jaccl {
            guard jacclConfiguration != nil else {
                throw ProbeError("Resident JACCL requires admitted effective environment and device configuration")
            }
            options.transport = .jaccl
        } else if jacclConfiguration != nil {
            throw ProbeError("JACCL configuration cannot be applied to solo or loopback resident work")
        }
        return options
    }
}
