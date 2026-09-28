import Foundation

struct QwenLongPrefillResidentSoloAdmissionCheckResult: Encodable {
    let kind = "qwen_long_prefill_resident_solo_admission_check", cpuOnly = true
    let acceptedCases: [String], rejectedCases: [String]
    let actualOptionsAndRegisteredAdmissionUsed = true
    let modelPayloadsRead = false, actualProcessEnvironmentAdmitted = false
    let nativeRequestsOrModelsConstructed = false
}

/// Reuses the existing retained fixture without copying model metadata. All
/// requests are created by the actual registered 9B admission constructor.
func checkQwenLongPrefillResidentSoloAdmission() throws -> QwenLongPrefillResidentSoloAdmissionCheckResult {
    let configuration = try QwenLongPrefillResidentRankFixture.configuration()
    let artifact = QwenLongPrefillResidentRankFixture.artifactSHA256
    let promptA = try QwenLongPrefillResidentRankFixture.prompt(0)
    let promptB = try QwenLongPrefillResidentRankFixture.prompt(1)
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
        QwenLongPrefillArithmeticEnvironment.requiredValues)
    func request(_ index: Int, prompt: Data? = nil, cut: Int? = nil) throws
        -> QwenRegistered9BLongPrefillReferenceAdmission {
        let id = try QwenLayerStageRankAdmission.requestID(
            epoch: QwenLongPrefillResidentRankFixture.epoch(index))
        let data = prompt ?? promptA
        return try .init(configuration: configuration, expectedArtifactAggregateSHA256: artifact,
            promptData: data, expectedPromptSHA256: sha256(data), request: .init(
                profile: .longPrefill8KV1, requestID: id, batchSize: 1,
                promptCount: 8192, chunkSize: 512, outputCount: 1), arithmetic: arithmetic, stageCut: cut)
    }
    let options = try Options(arguments: ["--mode", "qwen-long-prefill-solo-check",
        "--model-dir", "unused-model", "--tokens-file", "unused-prompt",
        "--artifact-aggregate-sha256", artifact, "--long-prompt-sha256", sha256(promptA),
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"])
    let first = try request(1), differentPrompt = try request(2, prompt: promptB)
    let four = try (1...4).map { try request($0) }
    var accepted: [String] = [], rejected: [String] = []
    for (name, requests, warmups) in [
        ("one measured request", [first], 0), ("four fresh identical prompts", four, 1),
        ("different admitted prompt history", [first, differentPrompt], 0),
    ] {
        let steps = try QwenLongPrefillResidentSoloAdmission.validate(
            options: options, requests: requests, warmupCount: warmups)
        guard steps.count == requests.count,
              zip(steps, requests).allSatisfy({ step, admission in
                  step.requestID == admission.request.request.requestID
                      && step.recordedRequestFingerprint == admission.request.fingerprint
                      && step.promptFileSHA256 == admission.promptFileSHA256
              }) else { throw ProbeError("Resident solo lost the actual admitted step identity") }
        accepted.append(name)
    }
    func reject(_ name: String, _ requests: [QwenRegistered9BLongPrefillReferenceAdmission],
                warmups: Int = 0, changed: Options? = nil) throws {
        do {
            _ = try QwenLongPrefillResidentSoloAdmission.validate(
                options: changed ?? options, requests: requests, warmupCount: warmups)
        } catch { rejected.append(name); return }
        throw ProbeError("Resident solo admitted invalid case: " + name)
    }
    try reject("empty cohort", [])
    try reject("fifth request", four + [try request(5)])
    try reject("duplicate request identity", [first, first])
    try reject("negative warmup count", [first], warmups: -1)
    try reject("all requests excluded", four, warmups: 4)
    try reject("warmup count above request count", four, warmups: 5)
    try reject("first prompt differs from Options", [differentPrompt])
    try reject("unequal plan is not solo", [try request(1, cut: 12)])
    try reject("later request changes plan", [first, try request(2, cut: 12)])
    let mutations: [(String, (inout Options) -> Void)] = [
        ("phase trace", { $0.prefillPhaseTraceFile = URL(fileURLWithPath: "unused-phase") }),
        ("owner trace", { $0.prefillOwnerTraceFile = URL(fileURLWithPath: "unused-owner") }),
        ("artifact mismatch", { $0.expectedArtifactAggregateSHA256 = String(repeating: "0", count: 64) }),
        ("explicit cut", { $0.stageCut = 16 }),
        ("foreign mode", { $0.mode = .qwenLongPrefillRankCheck }),
        ("prompt geometry", { $0.promptCount = 8191 }), ("chunk geometry", { $0.chunkSize = 256 }),
        ("output geometry", { $0.decodeCount = 2 }), ("repeat option", { $0.repeats = 2 }),
        ("warmup option", { $0.warmups = 1 }), ("timeout", { $0.timeoutSeconds = 301 }),
        ("ordinary forward", { $0.executionPath = .ordinary }),
        ("teacher input", { $0.teacherTokensFile = URL(fileURLWithPath: "unused-teacher") }),
        ("wire epoch", { $0.epoch = String(repeating: "a", count: 32) }),
    ]
    for (name, mutate) in mutations {
        var changed = options; mutate(&changed)
        try reject(name, [first], changed: changed)
    }
    guard accepted.count == 3, rejected.count == 23 else {
        throw ProbeError("Resident solo admission fixture coverage changed")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected)
}
