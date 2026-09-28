import Foundation

struct QwenResidentSoloCheckRecord: Encodable {
    let kind = "qwen_resident_solo_generation_check"
    let accepted: Int
    let rejected: Int
    let modelOrKernelExecuted = false
    let actualRetirementProved = false
}

/// Admission/clock/lifecycle contracts only. Actual kernel dispatch and native
/// state retirement remain required from the later one-load physical cohort.
func checkQwenResidentSoloGeneration() throws -> QwenResidentSoloCheckRecord {
    guard let path = ProcessInfo.processInfo.environment["DARKBLOOM_RETAINED_PROFILE_FIXTURE"] else {
        throw ProbeError("Solo CPU check requires the retained registered profile fixture")
    }
    let data = try BoundedProbeInput.data(URL(fileURLWithPath: path), maximumBytes: 1_048_576)
    guard sha256(data) == "1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25",
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let row = root["nine"] as? [String: Any],
          let configText = row["configuration"] as? String, let config = Data(base64Encoded: configText),
          let manifestText = row["manifest"] as? String, let manifest = Data(base64Encoded: manifestText) else {
        throw ProbeError("Solo retained profile fixture differs")
    }
    let prompt = try JSONEncoder().encode(Array(repeating: 17, count: 8192))
    let expected = try JSONEncoder().encode(Array(repeating: 19, count: 128))
    let ids = (1...4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
    let arguments = ["--mode", QwenResidentSoloCLI.mode,
        "--model-dir", "/invented/model", "--tokens-file", "/invented/prompt.json", "--tokens-sha256", sha256(prompt),
        "--request-id", ids[0].uuidString.lowercased(), "--stage-cut", "4", "--output-count", "128",
        "--stop-token-ids", "[]", "--timeout-seconds", "300",
        "--registered-dense-profile", "registered_qwen35_9b", "--prompt-count", "8192", "--chunk-size", "512",
        "--expected-token-ids-file", "/invented/expected.json", "--expected-token-ids-sha256", sha256(expected)]
    var accepted = 0, rejected = 0
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError("Solo CPU check: \(message)") }; accepted += 1
    }
    func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Solo CPU check accepted an invalid case")
    }
    func changed(_ flag: String, _ value: String) -> [String] {
        var copy = arguments; copy[copy.firstIndex(of: flag)! + 1] = value; return copy
    }
    func read(_ url: URL, _: Int) throws -> Data {
        switch url.path {
        case "/invented/model/config.json": return config
        case "/invented/model/manifest.json": return manifest
        case "/invented/prompt.json": return prompt
        case "/invented/expected.json": return expected
        default: throw ProbeError("Unexpected fabricated solo read")
        }
    }
    let environment = QwenLongPrefillArithmeticEnvironment.requiredValues
    let cli = try QwenResidentSoloCLI(arguments: arguments)
    var index = 1, reads = 0
    let input = try cli.preflight(environment: environment,
        read: { url, cap in reads += 1; return try read(url, cap) },
        makeUUID: { defer { index += 1 }; return ids[index] })
    try require(reads == 4 && input.requests.map { $0.request.requestID } == ids
        && input.warmupCount == 1 && input.measuredCount == 3, "one pinned source and four fresh request identities")
    try require(input.requests.allSatisfy { $0.request.forwardCount == 143 && $0.request.finalCommittedTokens == 8319 },
        "full 128 target selections require127 decode forwards")
    try require(input.requests.allSatisfy { $0.source.plan.fingerprint == input.first.admission.source.plan.fingerprint },
        "same full-reference planning identity across requests")
    for (flag, value) in [("--mode", "qwen-registered-full-generation-reference"),
        ("--registered-dense-profile", "registered_qwen38_27b"), ("--stage-cut", "16"),
        ("--prompt-count", "8191"), ("--chunk-size", "256"), ("--output-count", "1"),
        ("--stop-token-ids", "[19]"), ("--expected-token-ids-file", "relative"),
        ("--expected-token-ids-sha256", String(repeating: "A", count: 64))] {
        try refuse { _ = try QwenResidentSoloCLI(arguments: changed(flag, value)) }
    }
    try refuse { _ = try QwenResidentSoloCLI(arguments: Array(arguments.dropLast())) }
    var repeated = arguments; repeated[0] = "--expected-token-ids-file"
    try refuse { _ = try QwenResidentSoloCLI(arguments: repeated) }
    try refuse { _ = try cli.preflight(environment: environment, read: read, makeUUID: { ids[0] }) }
    try refuse { _ = try cli.preflight(environment: environment, read: { url, cap in
        url.lastPathComponent == "expected.json" ? expected + Data([32]) : try read(url, cap)
    }) }
    for bad in [Data("[true]".utf8), Data("[1,]".utf8),
                try JSONEncoder().encode(Array(repeating: 19, count: 127)),
                try JSONEncoder().encode(Array(repeating: 248_320, count: 128))] {
        let value = try QwenResidentSoloCLI(arguments: changed("--expected-token-ids-sha256", sha256(bad)))
        try refuse { _ = try value.preflight(environment: environment, read: { url, cap in
            url.lastPathComponent == "expected.json" ? bad : try read(url, cap)
        }) }
    }
    var wrongEnvironment = environment; wrongEnvironment["MLX_ENABLE_TF32"] = "0"; reads = 0
    try refuse { _ = try cli.preflight(environment: wrongEnvironment,
        read: { url, cap in reads += 1; return try read(url, cap) }) }
    try require(reads == 0, "arithmetic refusal precedes inputs and native initialization")
    try refuse { _ = try QwenResidentSoloPreflight(first: input.first,
        requests: Array(input.requests.dropLast()), expectedTokenIDs: input.expectedTokenIDs,
        expectedTokenFileSHA256: input.expectedTokenFileSHA256) }
    let stamps = (0..<128).map { UInt64(2_000_000_000 + $0 * 1_000_000) }
    let timing = try QwenResidentSoloTiming(start: 1_000_000_000, selected: stamps, retired: 3_000_000_000)
    try require(timing.prefillSeconds == 1 && timing.prefillTokensPerSecond == 8192
        && abs(timing.decodeTokensPerSecond - 1000) < 0.000001, "8192 prefill and127 decode denominator")
    try require(!timing.includesLoading && timing.includesFreshStateConstruction
        && !timing.includesDiagnosticRowOrStateCapture && !timing.externalTTFTMeasured, "clock boundary labels")
    try refuse { _ = try QwenResidentSoloTiming(start: 1, selected: Array(stamps.dropLast()), retired: 3_000_000_000) }
    try refuse { _ = try QwenResidentSoloTiming(start: stamps[0], selected: stamps, retired: 3_000_000_000) }
    try refuse { _ = try QwenResidentSoloTiming(start: 1, selected: stamps, retired: stamps.last! - 1) }
    var reversed = stamps; reversed.swapAt(31,32)
    try refuse { _ = try QwenResidentSoloTiming(start: 1, selected: reversed, retired: 3_000_000_000) }
    let lifecycle = try QwenLayerStageResidentLifecycle(maximumRequests: 4)
    for request in input.requests {
        let identity = QwenLayerStageResidentRequestIdentity(requestID: request.request.requestID,
            epoch: request.request.requestID, recordedRequestFingerprint: request.request.fingerprint)
        let result = try lifecycle.withRequest(identity: identity) { 128 }
        try require(result == 128 && !lifecycle.snapshot.requestScopeActive, "fresh serial request scope returns CPU values")
    }
    try require(lifecycle.snapshot.admittedRequests == 4 && lifecycle.snapshot.completedRequestScopes == 4,
        "warmup is a counted admission")
    try lifecycle.withModelRelease {}
    try require(lifecycle.snapshot.releaseCallbackCompleted, "trusted release callback completed")
    let failure = try QwenLayerStageResidentLifecycle(maximumRequests: 4)
    let identity = QwenLayerStageResidentRequestIdentity(requestID: ids[0], epoch: ids[0],
        recordedRequestFingerprint: input.requests[0].request.fingerprint)
    enum Marker: Error { case warmup }
    do { let _: Int = try failure.withRequest(identity: identity) { throw Marker.warmup } }
    catch Marker.warmup { accepted += 1 }
    try require(failure.snapshot.failed && failure.snapshot.completedRequestScopes == 0,
        "failed warmup cannot become a measured result")
    try refuse { _ = try failure.withRequest(identity: .init(requestID: ids[1], epoch: ids[1],
        recordedRequestFingerprint: input.requests[1].request.fingerprint)) { 128 } }
    try failure.withModelRelease {}
    try require(failure.snapshot.releaseCallbackCompleted, "failed body permits independent final cleanup")
    return .init(accepted: accepted, rejected: rejected)
}
