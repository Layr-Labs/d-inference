import Foundation

func checkQwenLongPrefillCohortReadinessAdmission() throws {
    let epoch = String(repeating: "1", count: 32)
    let base = ["--mode", "qwen-long-prefill-cohort-readiness-check", "--transport", "loopback-test",
        "--epoch", epoch, "--cohort-readiness-case", "match", "--timeout-seconds", "30"]
    func replacing(_ flag: String, _ value: String, in arguments: [String] = []) -> [String] {
        var result = arguments.isEmpty ? base : arguments
        result[result.firstIndex(of: flag)! + 1] = value
        return result
    }
    var accepted: [String] = [], rejected: [String] = [], identities: [String] = []
    for fixtureCase in QwenLongPrefillCohortReadinessCase.allCases {
        _ = try Options(arguments: replacing("--cohort-readiness-case", fixtureCase.rawValue))
        accepted.append(fixtureCase.rawValue)
    }
    _ = try Options(arguments: replacing("--timeout-seconds", "1"))
    accepted.append("minimum native timeout")
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Readiness entry admitted invalid fixture: " + label)
    }
    func identity(_ label: String, _ condition: Bool) throws {
        guard condition else { throw ProbeError("Readiness identity fixture failed: " + label) }
        identities.append(label)
    }

    for (flag, value) in [("--cohort-readiness-case", "unknown"), ("--timeout-seconds", "0"),
        ("--timeout-seconds", "31"), ("--timeout-seconds", "+30"),
        ("--epoch", String(repeating: "A", count: 32)), ("--epoch", "abc")] {
        try reject("invalid " + flag + " " + value) { _ = try Options(arguments: replacing(flag, value)) }
    }
    for flag in ["--mode", "--transport", "--epoch", "--cohort-readiness-case", "--timeout-seconds"] {
        let index = base.firstIndex(of: flag)!
        var missing = base; missing.removeSubrange(index...(index + 1))
        try reject("missing " + flag) { _ = try Options(arguments: missing) }
        try reject("duplicate " + flag) { _ = try Options(arguments: base + [flag, base[index + 1]]) }
    }
    for mode in ["baseline", "adapter-check", "qwen-long-prefill-rank-check", "qwen-long-prefill-solo-check"] {
        try reject("foreign original mode " + mode) { _ = try Options(arguments: replacing("--mode", mode)) }
    }
    for extra in [["--model-dir", "unused"], ["--synthetic"], ["--tokens-file", "unused"],
        ["--stage-cut", "12"], ["--prefill-phase-trace-file", "unused"],
        ["--prefill-owner-trace-file", "unused"], ["--prompt-tokens", "128"], ["--seed", "7"],
        ["--stage-logits-dtype", "bfloat16"], ["--stage-prefill-policy", "serial_v1"]] {
        try reject("extra " + extra[0]) { _ = try Options(arguments: base + extra) }
    }
    let direct = try Options(arguments: base)
    let mutations: [(String, (inout Options) -> Void)] = [
        ("direct model directory", { $0.modelDirectory = URL(fileURLWithPath: "unused") }),
        ("direct synthetic", { $0.synthetic = true }),
        ("direct repeats", { $0.repeats = 4 }),
        ("direct warmups", { $0.warmups = 0 }),
        ("direct trace", { $0.prefillPhaseTraceFile = URL(fileURLWithPath: "unused") }),
        ("direct missing case", { $0.cohortReadinessCase = nil }),
        ("direct foreign mode", { $0.mode = .qwenLongPrefillRankCheck }),
        ("direct transport", { $0.transport = .jaccl }),
        ("direct epoch", { $0.epoch = "bad" }),
        ("direct timeout", { $0.timeoutSeconds = 31 }),
    ]
    for (label, mutate) in mutations {
        var changed = direct; mutate(&changed)
        try reject(label) { _ = try QwenLongPrefillCohortReadinessAdmission(options: changed) }
    }

    let matched = try QwenLongPrefillCohortReadinessAdmission(options: direct)
    let rank0 = try matched.agreement(forRank: 0), rank1 = try matched.agreement(forRank: 1)
    try identity("both matching rank intents admitted before native selection",
        rank0.fingerprint == rank1.fingerprint && rank0.descriptor == rank1.descriptor &&
        rank0.descriptor.requestCount == 3 && rank0.descriptor.warmupCount == 1)
    let mismatched = try QwenLongPrefillCohortReadinessAdmission(options:
        Options(arguments: replacing("--cohort-readiness-case", "warmup-mismatch")))
    let mismatch0 = try mismatched.agreement(forRank: 0), mismatch1 = try mismatched.agreement(forRank: 1)
    func withoutWarmupLabels(_ descriptor: QwenLongPrefillResidentCohortAgreement.Descriptor) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: canonicalJSONData(descriptor)) as? [String: Any],
              var entries = object["requests"] as? [[String: Any]] else {
            throw ProbeError("Readiness fixture lost its typed descriptor encoding")
        }
        object.removeValue(forKey: "warmupCount")
        for index in entries.indices { entries[index].removeValue(forKey: "excludedWarmup") }
        object["requests"] = entries
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    try identity("mismatch changes only warmup classification",
        mismatch0.fingerprint == rank0.fingerprint && mismatch1.fingerprint != mismatch0.fingerprint &&
        mismatch1.descriptor.warmupCount == 0 && mismatch1.descriptor.requests.allSatisfy { !$0.excludedWarmup } &&
        withoutWarmupLabels(mismatch0.descriptor) == withoutWarmupLabels(mismatch1.descriptor))
    let requestEpochs = rank0.descriptor.requests.map(\.epoch)
    try identity("three fresh epochs derive from the run epoch",
        requestEpochs == [epoch, "a76dcf545cb5be98dff623df474b57ae", "a410045a3477334545b86d6e853a64c3"] &&
        Set(requestEpochs).count == 3 && Set(rank0.descriptor.requests.map(\.requestID)).count == 3)
    let repeated = try QwenLongPrefillCohortReadinessAdmission(options: direct)
    try identity("same run case reproduces exact intent", repeated.agreement(forRank: 0).fingerprint == rank0.fingerprint)
    let changedRun = try QwenLongPrefillCohortReadinessAdmission(options:
        Options(arguments: replacing("--epoch", String(repeating: "2", count: 32))))
    let changedRank = try changedRun.agreement(forRank: 0)
    try identity("new run epoch changes every request identity", changedRank.fingerprint != rank0.fingerprint &&
        Set(changedRank.descriptor.requests.map(\.epoch)).isDisjoint(with: Set(requestEpochs)))
    try reject("negative native rank") { _ = try matched.agreement(forRank: -1) }
    try reject("out-of-range native rank") { _ = try matched.agreement(forRank: 2) }

    guard accepted.count == 3, rejected.count == 42, identities.count == 5 else {
        throw ProbeError("Readiness entry admission fixture count changed")
    }
    struct Result: Encodable {
        let kind = "qwen_long_prefill_cohort_readiness_admission_check", cpuOnly = true
        let acceptedFixtures = 3, rejectedFixtures = 42, identityFixtures = 5
        let accepted: [String], rejected: [String], identities: [String]
        let actualOptionsAndLocalAdmissionUsed = true
        let nativeExchangeExecuted = false, modelConstructed = false, weightsMaterialized = false
    }
    try emitJSON(Result(accepted: accepted, rejected: rejected, identities: identities))
}
