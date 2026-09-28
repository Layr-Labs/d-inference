import Foundation

struct QwenResidentJACCLCheckResult: Encodable {
    let kind = "qwen_resident_jaccl_admission_check", cpuOnly = true
    let acceptedCases: [String], rejectedCases: [String]
    let actualOptionsAndRegisteredAdmissionsUsed = true
    let environmentAndReaderWereInjected = true
    let collectiveInitialized = false, modelPayloadsRead = false
    let physicalTransferQualified = false, runtimeResourceAdmissionPerformed = false
}

/// Exercise the actual closed worker bridge and existing registered/cohort
/// constructors, without opening a file or initializing a native collective.
func checkQwenResidentJACCLAdmission() throws -> QwenResidentJACCLCheckResult {
    let configurationCases = try checkQwenResidentJACCLConfiguration()
    var accepted = configurationCases.accepted, rejected = configurationCases.rejected
    func require(_ name: String, _ condition: Bool) throws {
        guard condition else { throw ProbeError("Resident JACCL admission fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident JACCL admitted invalid fixture: " + name)
    }
    let fixture = try QwenLongPrefillResidentCohortFixture()
    let cohort = "fixture:jaccl"
    let open = QwenResidentBenchmarkWorkerOpen(cohortID: cohort,
        requests: try (1...4).map { index in
            .init(requestID: cohort + QwenResidentBenchmarkWorkerCommand.suffixes[index - 1],
                  epoch: try QwenLongPrefillResidentRankFixture.epoch(index))
        })
    let soloArguments = ["--mode", QwenResidentBenchmarkWorkerCLI.mode, "--role", "solo",
        "--model-dir", "/fixture/model", "--tokens-file", "/fixture/prompt.json",
        "--artifact-aggregate-sha256", QwenLongPrefillResidentRankFixture.artifactSHA256,
        "--long-prompt-sha256", sha256(fixture.promptA)]
    func replacing(_ args: [String], _ key: String, _ value: String) -> [String] {
        var result = args; result[result.firstIndex(of: key)! + 1] = value; return result
    }
    let rankArguments = replacing(soloArguments, "--role", "rank") + ["--stage-prefill-policy", "serial_v1"]
    let matrix = Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8)
    let environment = ["JACCL_RANK": "0", "JACCL_IBV_DEVICES": "/fixture/matrix.json",
                       "JACCL_COORDINATOR": "169.254.70.46:29500"]
    func transport(_ values: [String: String], bytes: Data? = nil) throws -> QwenResidentJACCLConfiguration {
        try .admit(environment: values) { _, _ in bytes ?? matrix }
    }
    let config = try transport(environment)
    func admit(_ cli: QwenResidentBenchmarkWorkerCLI, _ config: QwenResidentJACCLConfiguration? = nil) throws
        -> QwenResidentBenchmarkWorkerAdmission {
        try cli.admit(open: open, arithmetic: fixture.arithmetic, configuration: fixture.configuration,
                      prompt: fixture.promptA, jacclConfiguration: config)
    }
    func agreement(_ value: QwenResidentBenchmarkWorkerAdmission) throws -> QwenLongPrefillResidentCohortAgreement {
        try .init(options: value.options, requests: value.rankRequests, warmupCount: 1,
                  jacclConfiguration: value.jacclConfiguration)
    }
    let loopback = try QwenResidentBenchmarkWorkerCLI(arguments: rankArguments)
    let old = try admit(loopback)
    try require("default rank remains loopback", old.options.transport == .loopbackTest && old.jacclConfiguration == nil)
    let explicitLoopback = try QwenResidentBenchmarkWorkerCLI(arguments: rankArguments + ["--transport", "loopback-test"])
    try require("explicit loopback retains agreement", try agreement(admit(explicitLoopback)).fingerprint == agreement(old).fingerprint)
    let solo = try QwenResidentBenchmarkWorkerCLI(arguments: soloArguments)
    var unusedReads = 0
    let absentSolo = try solo.admitTransport(environment: [:]) { _, _ in unusedReads += 1; return matrix }
    let absentLoopback = try loopback.admitTransport(environment: [:]) { _, _ in unusedReads += 1; return matrix }
    try require("solo and loopback do not read JACCL environment files", unusedReads == 0 && absentSolo == nil && absentLoopback == nil)
    let jacclArguments = rankArguments + ["--transport", "jaccl"]
    let jaccl = try QwenResidentBenchmarkWorkerCLI(arguments: jacclArguments)
    let admitted = try admit(jaccl, config)
    for policy in QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy.allCases {
        let cli = try QwenResidentBenchmarkWorkerCLI(arguments: replacing(jacclArguments, "--stage-prefill-policy", policy.rawValue))
        let value = try admit(cli, config)
        try require("JACCL preserves registered request geometry and " + policy.rawValue,
            value.options.transport == .jaccl && value.options.stagePrefillPolicy == policy &&
            value.requests.count == 4 && value.rankRequests.map(\.epoch) == open.requests.map(\.epoch) &&
            value.requests.allSatisfy { $0.configuration == fixture.configuration &&
                $0.request.request.promptCount == 8192 && $0.request.request.chunkSize == 512 &&
                $0.request.request.outputCount == 1 && $0.request.request.batchSize == 1 })
    }
    var remote = environment; remote["JACCL_RANK"] = "1"; remote["JACCL_IBV_DEVICES"] = "/remote/matrix.json"
    let peer = try admit(jaccl, transport(remote))
    let common = try agreement(admitted)
    try require("two host intents join despite local rank and path", try agreement(peer).fingerprint == common.fingerprint &&
        common.descriptor.jacclConfigurationSHA256 == config.fingerprint && common.descriptor.transport == "jaccl")
    let cut = try QwenResidentBenchmarkWorkerCLI(arguments: jacclArguments + ["--stage-cut", "12"])
    try require("JACCL selected cut uses native Plan", try admit(cut, config).requests.allSatisfy {
        $0.plan.stages.map(\.sourceRange) == [0..<12, 12..<32]
    })
    var different = environment; different["JACCL_COORDINATOR"] = "169.254.70.46:29501"
    try require("cohort binds coordinator", try agreement(admit(jaccl, transport(different))).fingerprint != common.fingerprint)
    try require("cohort binds exact matrix bytes", try agreement(admit(jaccl,
        transport(environment, bytes: matrix + Data([10])))).fingerprint != common.fingerprint)
    let legacyJSON = try JSONSerialization.jsonObject(with: canonicalJSONData(agreement(old).descriptor)) as? [String: Any]
    try require("legacy agreement omits optional new field", legacyJSON != nil && legacyJSON!["jacclConfigurationSHA256"] == nil)
    var reads: [(String, Int)] = []
    let preflight = try jaccl.preflight(open: open, arithmetic: fixture.arithmetic, jacclConfiguration: config) { url, cap in
        reads.append((url.path, cap)); return reads.count == 1 ? fixture.configuration : fixture.promptA
    }
    try require("typed configuration keeps two bounded retained input reads", reads.count == 2 &&
        reads[0].0 == "/fixture/model/config.json" && reads[0].1 == 1_048_576 &&
        reads[1].0 == "/fixture/prompt.json" && reads[1].1 == 65_536 && preflight.jacclConfiguration?.fingerprint == config.fingerprint)

    for backend in ["ring", "auto", "JACCL"] {
        try reject("unknown backend " + backend) { _ = try QwenResidentBenchmarkWorkerCLI(arguments: rankArguments + ["--transport", backend]) }
    }
    for backend in ["jaccl", "loopback-test"] {
        try reject("solo rejects transport " + backend) { _ = try QwenResidentBenchmarkWorkerCLI(arguments: soloArguments + ["--transport", backend]) }
    }
    try reject("duplicate transport selector") { _ = try QwenResidentBenchmarkWorkerCLI(arguments: jacclArguments + ["--transport", "jaccl"]) }
    try reject("JACCL cannot create options without typed admission") { _ = try jaccl.options(open: open) }
    var refusedReads = 0
    try reject("JACCL missing authority before retained input IO") {
        _ = try jaccl.preflight(open: open, arithmetic: fixture.arithmetic) { _, _ in refusedReads += 1; return fixture.configuration }
    }
    try require("missing JACCL authority does not call reader", refusedReads == 0)
    try reject("JACCL authority cannot be reused for solo") { _ = try admit(solo, config) }
    try reject("JACCL authority cannot be reused for loopback") { _ = try admit(loopback, config) }
    let oneShot = ["--mode", "qwen-long-prefill-rank-check", "--model-dir", "/fixture/model",
        "--tokens-file", "/fixture/prompt.json", "--artifact-aggregate-sha256", QwenLongPrefillResidentRankFixture.artifactSHA256,
        "--long-prompt-sha256", sha256(fixture.promptA), "--epoch", open.requests[0].epoch,
        "--transport", "loopback-test", "--stage-prefill-policy", "serial_v1", "--stage-logits-dtype", "bfloat16",
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
    try require("original one-shot loopback control admitted", try Options(arguments: oneShot).transport == .loopbackTest)
    try reject("original one-shot Options still refuses JACCL") { _ = try Options(arguments: replacing(oneShot, "--transport", "jaccl")) }
    try reject("original one-shot validator still refuses JACCL") { try QwenLongPrefillRankAdmission.validateOptions(admitted.options) }
    try reject("resident JACCL direct call without authority") {
        try QwenLongPrefillResidentRankAdmission.validate(options: admitted.options, requests: admitted.rankRequests, warmupCount: 1)
    }
    try reject("resident loopback direct call with JACCL authority") {
        try QwenLongPrefillResidentRankAdmission.validate(options: old.options, requests: old.rankRequests, warmupCount: 1, jacclConfiguration: config)
    }
    func rejectOptions(_ name: String, _ mutate: (inout Options) -> Void) throws {
        var options = admitted.options; mutate(&options)
        try reject(name) { try QwenLongPrefillResidentRankAdmission.validate(options: options,
            requests: admitted.rankRequests, warmupCount: 1, jacclConfiguration: config) }
    }
    try rejectOptions("JACCL cannot change logits precision") { $0.stageLogitsDType = "float32" }
    try rejectOptions("JACCL still requires scheduling policy") { $0.stagePrefillPolicy = nil }
    try rejectOptions("JACCL still binds registered artifact") { $0.expectedArtifactAggregateSHA256 = String(repeating: "0", count: 64) }
    try rejectOptions("JACCL still binds prompt bytes") { $0.longPromptSHA256 = String(repeating: "0", count: 64) }
    try rejectOptions("JACCL cannot enable phase traces") { $0.prefillPhaseTraceFile = URL(fileURLWithPath: "/fixture/phase") }
    try rejectOptions("JACCL cannot relabel selected Plan") { $0.stageCut = 12 }
    try reject("JACCL still validates registered config") {
        _ = try jaccl.admit(open: open, arithmetic: fixture.arithmetic, configuration: Data("{}".utf8),
                           prompt: fixture.promptA, jacclConfiguration: config)
    }
    try reject("JACCL still validates raw prompt") {
        _ = try jaccl.admit(open: open, arithmetic: fixture.arithmetic, configuration: fixture.configuration,
                           prompt: fixture.promptB, jacclConfiguration: config)
    }
    guard accepted.count == 24, rejected.count == 77 else {
        throw ProbeError("Resident JACCL admission fixture count changed")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected)
}
