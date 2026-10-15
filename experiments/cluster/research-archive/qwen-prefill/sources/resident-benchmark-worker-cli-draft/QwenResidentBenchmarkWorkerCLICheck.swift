import Foundation

struct QwenResidentBenchmarkWorkerCLICheckResult: Encodable {
    let kind = "qwen_resident_benchmark_worker_cli_check", cpuOnly = true
    let acceptedCases: [String], rejectedCases: [String]
    let actualOptionsAndRegisteredAdmissionsUsed = true
    let inputReaderWasInjected = true, modelPayloadsRead = false
    let actualProcessEnvironmentAdmitted = false, nativeRequestsOrModelsConstructed = false
}

/// Uses the existing pinned configuration and fabricated token IDs. The reader
/// checks below exercise callback ordering/counts, not filesystem safety.
func checkQwenResidentBenchmarkWorkerCLI() throws -> QwenResidentBenchmarkWorkerCLICheckResult {
    let configuration = try QwenLongPrefillResidentRankFixture.configuration()
    let prompt = try QwenLongPrefillResidentRankFixture.prompt(0)
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
        QwenLongPrefillArithmeticEnvironment.requiredValues)
    let cohort = "fixture:condition"
    let open = QwenResidentBenchmarkWorkerOpen(cohortID: cohort,
        requests: try (1...4).map { index in
            .init(requestID: cohort + QwenResidentBenchmarkWorkerCommand.suffixes[index - 1],
                  epoch: QwenLongPrefillResidentRankFixture.epoch(index))
        })
    let basic = ["--mode", QwenResidentBenchmarkWorkerCLI.mode, "--role", "solo",
        "--model-dir", "/unused-model", "--tokens-file", "/unused-prompt",
        "--artifact-aggregate-sha256", QwenLongPrefillResidentRankFixture.artifactSHA256,
        "--long-prompt-sha256", sha256(prompt)]
    func replacing(_ arguments: [String], _ flag: String, _ value: String) -> [String] {
        var result = arguments; result[result.firstIndex(of: flag)! + 1] = value; return result
    }
    let serial = replacing(basic, "--role", "rank") + ["--stage-prefill-policy", "serial_v1"]
    var accepted: [String] = [], rejected: [String] = []
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident worker admitted invalid fixture: " + name)
    }
    func rejectCLI(_ name: String, _ arguments: [String]) throws {
        try reject(name) { _ = try QwenResidentBenchmarkWorkerCLI(arguments: arguments) }
    }
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw ProbeError("Resident worker fixture assertion failed: " + name) }
        accepted.append(name)
    }
    let solo = try QwenResidentBenchmarkWorkerCLI(arguments: basic)
    let admittedSolo = try solo.admit(open: open, arithmetic: arithmetic,
                                      configuration: configuration, prompt: prompt)
    try require(admittedSolo.requests.count == 4 && admittedSolo.rankRequests.isEmpty
        && admittedSolo.options.mode == .qwenLongPrefillSoloCheck
        && admittedSolo.options.epoch == nil && admittedSolo.options.stageCut == nil
        && solo.timeoutSeconds == 300, "solo keeps default plan and implicit timeout")
    let expectedIDs = try open.requests.map { try QwenLayerStageRankAdmission.requestID(epoch: $0.epoch) }
    let actualIDs = admittedSolo.requests.map { $0.request.request.requestID }
    try require(actualIDs == expectedIDs && Set(actualIDs).count == 4
        && Set(admittedSolo.requests.map { $0.request.fingerprint }).count == 4
        && Set(admittedSolo.requests.map { $0.promptFileSHA256 }) == [sha256(prompt)]
        && admittedSolo.requests.allSatisfy { $0.configuration == configuration },
        "four unique epoch identities retain one source and prompt")
    try require(admittedSolo.requests.allSatisfy { request in
        request.request.request.promptCount == 8192 && request.request.request.chunkSize == 512
            && request.request.request.outputCount == 1 && request.request.request.batchSize == 1
    } && admittedSolo.options.repeats == 1 && admittedSolo.options.warmups == 0
        && admittedSolo.options.seed == 7 && admittedSolo.options.executionPath == .cbv2Contiguous
        && admittedSolo.options.attentionOutputPrecision == .native
        && admittedSolo.options.ffnOutputPrecision == .native
        && admittedSolo.options.ffnBranchPrecision == .native,
        "actual Options and requests keep fixed geometry and arithmetic")
    for policy in QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy.allCases {
        let cli = try QwenResidentBenchmarkWorkerCLI(arguments:
            replacing(serial, "--stage-prefill-policy", policy.rawValue))
        let result = try cli.admit(open: open, arithmetic: arithmetic,
                                  configuration: configuration, prompt: prompt)
        try require(result.rankRequests.count == 4 && result.options.transport == .loopbackTest
            && result.options.stageLogitsDType == "bfloat16" && result.options.stagePrefillPolicy == policy
            && result.options.epoch == open.requests[0].epoch
            && result.rankRequests.map(\.epoch) == open.requests.map(\.epoch)
            && result.requests.map { $0.request.request.requestID } == expectedIDs,
            "rank retains all declared epochs with " + policy.rawValue)
    }
    let cut = try QwenResidentBenchmarkWorkerCLI(arguments: serial + ["--stage-cut", "12"])
    let cutAdmission = try cut.admit(open: open, arithmetic: arithmetic,
                                    configuration: configuration, prompt: prompt)
    try require(cutAdmission.requests.allSatisfy { $0.plan.stages.map(\.sourceRange) == [0..<12, 12..<32] }
        && cutAdmission.options.stageCut == 12, "selected cut uses actual native Plan admission")
    let shortTimeout = try QwenResidentBenchmarkWorkerCLI(arguments: basic + ["--timeout-seconds", "1"])
    try require(try shortTimeout.options(open: open).timeoutSeconds == 1,
                "bounded timeout reaches actual Options")
    try require(QwenResidentBenchmarkWorkerCLI.isRequested(basic)
        && !QwenResidentBenchmarkWorkerCLI.isRequested(["--mode"])
        && !QwenResidentBenchmarkWorkerCLI.isRequested(["--tokens-file", QwenResidentBenchmarkWorkerCLI.mode])
        && !QwenResidentBenchmarkWorkerCLI.isRequested(["--mode", "worker"]),
        "early selector requires the exact paired mode")

    var reads: [(URL, Int)] = []
    _ = try cut.preflight(open: open, arithmetic: arithmetic) { url, cap in
        reads.append((url, cap))
        return reads.count == 1 ? configuration : prompt
    }
    try require(reads.count == 2
        && reads[0].0.path == "/unused-model/config.json" && reads[0].1 == 1024 * 1024
        && reads[1].0.path == "/unused-prompt" && reads[1].1 == 65_536,
        "preflight reads each retained input once with its exact cap")

    for flag in ["--mode", "--role", "--model-dir", "--tokens-file",
                 "--artifact-aggregate-sha256", "--long-prompt-sha256"] {
        var missing = basic; let index = missing.firstIndex(of: flag)!
        missing.removeSubrange(index...(index + 1))
        try rejectCLI("missing " + flag, missing)
        try rejectCLI("duplicate " + flag, basic + [flag, basic[index + 1]])
    }
    for extra in [["--epoch", String(repeating: "a", count: 32)], ["--prompt-tokens", "8192"],
        ["--chunk-size", "512"], ["--decode-tokens", "1"], ["--warmups", "0"], ["--repeats", "1"],
        ["--transport", "loopback-test"], ["--stage-logits-dtype", "bfloat16"],
        ["--prefill-phase-trace-file", "/unused"], ["--teacher-tokens-file", "/unused"],
        ["--execution-path", "cbv2-contiguous"]] {
        try rejectCLI("caller cannot set fixed or foreign " + extra[0], basic + extra)
    }
    try rejectCLI("odd argument count", basic + ["--timeout-seconds"])
    try rejectCLI("foreign original mode", replacing(basic, "--mode", "qwen-long-prefill-solo-check"))
    try rejectCLI("unknown role", replacing(basic, "--role", "pair"))
    for flag in ["--model-dir", "--tokens-file"] {
        for value in ["", "relative", "/nul\0path", "/" + String(repeating: "x", count: 4096)] {
            try rejectCLI("bounded path " + flag + " " + String(value.utf8.count), replacing(basic, flag, value))
        }
    }
    for flag in ["--artifact-aggregate-sha256", "--long-prompt-sha256"] {
        for value in [String(repeating: "A", count: 64), String(repeating: "b", count: 63),
                      String(repeating: "g", count: 64)] {
            try rejectCLI("pin format " + flag + " " + value, replacing(basic, flag, value))
        }
    }
    for value in ["0", "301", "01", "+1", "-1", "1.0", "1e2", "18446744073709551616"] {
        try rejectCLI("timeout " + value, basic + ["--timeout-seconds", value])
    }
    try rejectCLI("rank requires explicit policy", replacing(basic, "--role", "rank"))
    try rejectCLI("unknown policy", replacing(serial, "--stage-prefill-policy", "unknown"))
    try rejectCLI("solo policy leakage", basic + ["--stage-prefill-policy", "serial_v1"])
    try rejectCLI("solo cut leakage", basic + ["--stage-cut", "16"])
    for value in ["0", "1", "31", "32", "128", "012", "+12"] {
        try rejectCLI("actual selected cut or decimal gate " + value, serial + ["--stage-cut", value])
    }
    let repeatedEpoch = QwenResidentBenchmarkWorkerOpen(cohortID: cohort,
        requests: open.requests.enumerated().map { ordinal, row in
            .init(requestID: row.requestID, epoch: ordinal == 1 ? open.requests[0].epoch : row.epoch)
        })
    var refusedReads = 0
    try reject("invalid open before retained input reads") {
        _ = try solo.preflight(open: repeatedEpoch, arithmetic: arithmetic) { _, _ in
            refusedReads += 1; return configuration
        }
    }
    try require(refusedReads == 0, "invalid open invokes no reader")
    enum ReaderFailure: Error { case original }
    do {
        _ = try solo.preflight(open: open, arithmetic: arithmetic) { _, _ in throw ReaderFailure.original }
        throw ProbeError("Resident worker swallowed the input reader failure")
    } catch ReaderFailure.original { accepted.append("original input reader failure propagates") }
    var oversizedReads = 0
    try reject("oversize configuration stops before prompt read") {
        _ = try solo.preflight(open: open, arithmetic: arithmetic) { _, _ in
            oversizedReads += 1
            return Data(repeating: 0, count: QwenResidentBenchmarkWorkerCLI.maximumConfigurationBytes + 1)
        }
    }
    try require(oversizedReads == 1, "invalid configuration size does not read prompt")
    for (name, config, tokens) in [
        ("empty configuration", Data(), prompt), ("wrong registered configuration", Data("{}".utf8), prompt),
        ("empty prompt", configuration, Data()),
        ("prompt beyond cap", configuration, Data(repeating: 32, count: 65_537)),
        ("changed prompt bytes", configuration, try QwenLongPrefillResidentRankFixture.prompt(1)),
    ] {
        try reject(name) { _ = try solo.admit(open: open, arithmetic: arithmetic, configuration: config, prompt: tokens) }
    }
    let wrongArtifact = try QwenResidentBenchmarkWorkerCLI(arguments:
        replacing(basic, "--artifact-aggregate-sha256", String(repeating: "0", count: 64)))
    try reject("well-formed wrong registered artifact") {
        _ = try wrongArtifact.admit(open: open, arithmetic: arithmetic, configuration: configuration, prompt: prompt)
    }
    guard accepted.count == 12, rejected.count == 67 else {
        throw ProbeError("Resident worker CLI fixture coverage changed")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected)
}
