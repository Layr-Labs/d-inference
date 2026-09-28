import Foundation

/// Actual Options and retained-input admission only. This check never calls
/// preflight file readers, constructs a Collective/model, or initializes MLX.
func checkQwenLongPrefillResidentRankAdmission() throws {
    let configuration = try QwenLongPrefillResidentRankFixture.configuration()
    let artifact = QwenLongPrefillResidentRankFixture.artifactSHA256
    let promptA = try QwenLongPrefillResidentRankFixture.prompt(0)
    let promptB = try QwenLongPrefillResidentRankFixture.prompt(1)
    // A fixture receipt, not a claim about the actual process environment.
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
        QwenLongPrefillArithmeticEnvironment.requiredValues)

    func request(_ index: Int, prompt: Data? = nil, cut: Int? = 12,
                 config: Data? = nil, expectedArtifact: String? = nil,
                 expectedPrompt: String? = nil) throws -> QwenLongPrefillResidentRankRequest {
        let epoch = try QwenLongPrefillResidentRankFixture.epoch(index)
        let data = prompt ?? promptA
        let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
            requestID: QwenLayerStageRankAdmission.requestID(epoch: epoch), batchSize: 1,
            promptCount: 8192, chunkSize: 512, outputCount: 1)
        let local = try QwenRegistered9BLongPrefillReferenceAdmission(configuration: config ?? configuration,
            expectedArtifactAggregateSHA256: expectedArtifact ?? artifact,
            promptData: data, expectedPromptSHA256: expectedPrompt ?? sha256(data),
            request: spec, arithmetic: arithmetic, stageCut: cut)
        return .init(epoch: epoch, local: local)
    }

    func options(_ first: QwenLongPrefillResidentRankRequest, cut: Int? = 12) throws -> Options {
        var arguments = ["--mode", "qwen-long-prefill-rank-check", "--model-dir", "unused-model",
            "--tokens-file", "unused-prompt", "--artifact-aggregate-sha256", artifact,
            "--long-prompt-sha256", first.local.promptFileSHA256, "--epoch", first.epoch,
            "--transport", "loopback-test", "--stage-prefill-policy", "serial_v1",
            "--stage-logits-dtype", "bfloat16", "--execution-path", "cbv2-contiguous",
            "--prompt-tokens", "8192", "--chunk-size", "512", "--decode-tokens", "1",
            "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
        if let cut { arguments += ["--stage-cut", String(cut)] }
        return try Options(arguments: arguments)
    }

    var accepted: [String] = [], rejected: [String] = []
    func accept(_ name: String, _ options: Options, _ requests: [QwenLongPrefillResidentRankRequest],
                warmups: Int) throws {
        try QwenLongPrefillResidentRankAdmission.validate(options: options, requests: requests, warmupCount: warmups)
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident admission accepted invalid case: " + name)
    }

    let first = try request(1), middle = try request(2, prompt: promptB), last = try request(3)
    let base = try options(first)
    guard first.local.promptTokenIDsSHA256 == last.local.promptTokenIDsSHA256,
          first.local.promptTokenIDsSHA256 != middle.local.promptTokenIDsSHA256,
          first.local.request.fingerprint != last.local.request.fingerprint,
          first.local.request.steps.count == 16 else {
        throw ProbeError("Resident fixture did not construct distinct admitted A/B/A requests")
    }
    try accept("one fresh request without warmup", base, [first], warmups: 0)
    try accept("A B A histories with fresh identities", base, [first, middle, last], warmups: 1)
    let maximum = try (1...16).map { try request($0) }
    try accept("sixteen requests leave one measured request", base, maximum, warmups: 15)
    let half = try request(1, cut: nil)
    try accept("omitted cut retains default half plan", try options(half, cut: nil), [half], warmups: 0)

    func rejectCohort(_ name: String, _ requests: [QwenLongPrefillResidentRankRequest],
                      warmups: Int = 0, changed: Options? = nil) throws {
        try reject(name) {
            try QwenLongPrefillResidentRankAdmission.validate(options: changed ?? base,
                requests: requests, warmupCount: warmups)
        }
    }
    try rejectCohort("empty request list", [])
    try rejectCohort("seventeenth request exceeds cohort cap", maximum + [try request(17)])
    try rejectCohort("negative warmup count", [first], warmups: -1)
    try rejectCohort("all requests marked warmup", [first], warmups: 1)
    try rejectCohort("warmup count exceeds request count", [first], warmups: 2)
    var changed = base; changed.epoch = try QwenLongPrefillResidentRankFixture.epoch(2)
    try rejectCohort("initial epoch differs from Options", [first], changed: changed)
    try rejectCohort("duplicate request UUID and epoch", [first, first])
    try rejectCohort("request UUID differs from wire epoch", [first, .init(epoch: middle.epoch, local: last.local)])
    for epoch in [String(repeating: "A", count: 32), String(repeating: "a", count: 31), String(repeating: "g", count: 32)] {
        try rejectCohort("malformed epoch " + epoch, [first, .init(epoch: epoch, local: middle.local)])
    }
    changed = base; changed.longPromptSHA256 = middle.local.promptFileSHA256
    try rejectCohort("initial raw prompt pin differs from Options", [first], changed: changed)
    changed = base; changed.expectedArtifactAggregateSHA256 = String(repeating: "0", count: 64)
    try rejectCohort("initial artifact pin differs from Options", [first], changed: changed)
    try rejectCohort("later request changes admitted plan", [first, try request(2, cut: nil)])
    changed = base; changed.stageCut = nil
    try rejectCohort("omitted cut cannot carry unequal plan", [first], changed: changed)
    try rejectCohort("explicit cut cannot carry half plan", [half])

    // Mutating real parsed Options exercises direct callers of the admission,
    // including forbidden traces that the ordinary one-shot rank mode accepts.
    let mutations: [(String, (inout Options) -> Void)] = [
        ("phase trace forbidden", { $0.prefillPhaseTraceFile = URL(fileURLWithPath: "unused-phase") }),
        ("owner trace forbidden", { $0.prefillOwnerTraceFile = URL(fileURLWithPath: "unused-owner") }),
        ("prompt geometry changed", { $0.promptCount = 8191 }),
        ("chunk geometry changed", { $0.chunkSize = 256 }),
        ("multiple output tokens", { $0.decodeCount = 2 }),
        ("one-shot repeat gate preserved", { $0.repeats = 2 }),
        ("one-shot warmup gate preserved", { $0.warmups = 1 }),
        ("teacher input forbidden", { $0.teacherTokensFile = URL(fileURLWithPath: "unused-teacher") }),
        ("ordinary execution forbidden", { $0.executionPath = .ordinary }),
        ("timeout cap preserved", { $0.timeoutSeconds = 301 }),
        ("physical transport not admitted", { $0.transport = .jaccl }),
        ("foreign mode rejected", { $0.mode = .qwenLongPrefillSoloCheck }),
        ("missing scheduling policy", { $0.stagePrefillPolicy = nil }),
        ("non-BF16 logits forbidden", { $0.stageLogitsDType = "float32" }),
    ]
    for (name, mutate) in mutations {
        var options = base; mutate(&options)
        try rejectCohort(name, [first], changed: options)
    }

    // Invalid source/prompt metadata is rejected by the unchanged typed local
    // admission before a resident request can be assembled. No fake receipt is
    // manufactured to bypass that constructor merely to reach a later guard.
    try reject("local admission rejects changed configuration bytes") {
        _ = try request(1, config: configuration + Data([32]))
    }
    try reject("local admission rejects wrong registered artifact") {
        _ = try request(1, expectedArtifact: String(repeating: "0", count: 64))
    }
    try reject("local admission rejects raw prompt pin drift") {
        _ = try request(1, prompt: promptB, expectedPrompt: sha256(promptA))
    }
    try reject("local admission rejects non-integer token lexeme") {
        _ = try request(1, prompt: Data(("[1.0," + Array(repeating: "1", count: 8191).joined(separator: ",") + "]").utf8))
    }
    try reject("local admission rejects vocabulary overflow") {
        _ = try request(1, prompt: JSONSerialization.data(withJSONObject: [248_320] + Array(repeating: 1, count: 8191)))
    }

    guard accepted.count == 4, rejected.count == 35 else {
        throw ProbeError("Resident admission fixture coverage changed")
    }
    struct Record: Encodable {
        let kind = "qwen_long_prefill_resident_rank_admission_check", cpuOnly = true
        let acceptedCases: [String], rejectedCases: [String]
        let acceptedFixtures: Int, rejectedFixtures: Int
        let retainedConfigurationSHA256: String
        let actualOptionsAndLocalAdmissionUsed = true
        let configurationFilesOrModelPayloadsRead = false
        let collectiveOrModelConstructed = false
        let actualProcessEnvironmentAdmitted = false
        let nativeResidentReuseQualified = false
    }
    try emitJSON(Record(acceptedCases: accepted, rejectedCases: rejected,
        acceptedFixtures: accepted.count, rejectedFixtures: rejected.count,
        retainedConfigurationSHA256: QwenLongPrefillResidentRankFixture.configurationSHA256))
}
